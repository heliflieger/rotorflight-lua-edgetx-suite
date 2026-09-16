local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Controls = nil
local Common = nil
local MspRuntime = nil
local PidProfileApi = nil
local LoadingOverlay = nil
local Sensors = nil
local Profile = nil
local ApiVersion = nil
local t = nil

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  config = {},
  runtime = newRuntime(),
  loading = false,
  progress = 0,
  baseTitle = nil
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not PidProfileApi then PidProfileApi = loadModule("tasks/msp/api/pid_profile.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_advanced_pid_controller") or nil end
  
  if Common then
    if not ui.runtimeBase then
      ui.runtimeBase = Common.createProfileAwareRuntime({ profileType = "pid" })
    end
    if type(ui.runtime) ~= "table" then
      ui.runtime = newRuntime()
      setmetatable(ui.runtime, { __index = ui.runtimeBase })
    end
  end
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.pid_profile) ~= "table" then
    session.pid_profile = session.pidProfile or {}
  end
  session.pidProfile = session.pid_profile
  return session.pid_profile
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  for k, v in pairs(rcConfig) do
    ui.config[k] = v
  end
end

local function queueRcRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not PidProfileApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = type(getSession()) == "table"
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = PidProfileApi.command,
    simulatorResponse = PidProfileApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = PidProfileApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        local session = getSession()
        if session then
          local rcConfig = getRcConfig(session)
          for k, v in pairs(parsed) do
            rcConfig[k] = v
          end
          loadFromSession()
          ui.runtime.readPending = false
          ui.loading = false
          ui.dirty = false
          ui.progress = 100
          ui.runtime.readComplete = readValid
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      end
    end,
    errorHandler = function()
      readValid = false
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueRcWrite()
  if not PidProfileApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local session = getSession()
  local rcConfig = getRcConfig(session)
  
  -- Update config values in session
  for k, v in pairs(ui.config) do
    rcConfig[k] = v
  end

  queue:add({
    command = PidProfileApi.writeCommand,
    payload = PidProfileApi.buildWritePayload(rcConfig),
    isWrite = true,
    processReply = function() 
      ui.dirty = false
      
      local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
      if eepromApi then
        queue:add({
          command = eepromApi.command,
          payload = {},
          isWrite = true,
          processReply = function()
            queueRcRead(true)
          end
        })
      else
        queueRcRead(true)
      end
    end,
    errorHandler = function() end
  })

  return true, nil
end

local function getLiveProfile()
  return Profile and Profile.getActivePidProfile(1) or 1
end

local function getBaseTitle()
  return pageText(nil, "title", "PID Controller")
end

local function buildSessionSignature()
  return tostring(getLiveProfile() or "1")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueRcRead(false)
end

local function formatValue(val, spec)
  val = tonumber(val) or 0
  local scale = spec.scale or 1
  local mult = spec.mult or 1
  local decimals = spec.decimals or 0
  
  local displayVal = (val * mult) / scale
  local fmt = "%." .. tostring(decimals) .. "f"
  return string.format(fmt, displayVal)
end

local function isAtLeastVersion(req)
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  if not rawApiVersion or rawApiVersion == "" or tostring(rawApiVersion) == "0" then
    return true -- default true for offline/simulator
  end
  return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, req)
end



local function appendSingleFieldRow(children, x, y, w, labelText, label1, key1, spec1)
  local rowH = (Controls and Controls.ROW_H) or 40
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  local editW1   = math.floor(w * 0.24)
  local labelW1  = math.floor(w * 0.16)
  local labelGap = 4

  local xEdit1   = x + w - editW1 - 10
  local xLabel1  = xEdit1 - labelW1
  local mainW    = xLabel1 - x

  -- Left main label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = mainW,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  -- Sublabel (if any)
  if label1 and label1 ~= "" then
    children[#children + 1] = {
      type  = "label",
      x = xLabel1, y = labelY,
      w = labelW1 - labelGap,
      text  = label1,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE,
      align = RIGHT
    }
  end

  local rawMin = spec1.min or 0
  local rawMax = spec1.max or 1000
  local stepSize = spec1.step or 1

  children[#children + 1] = {
    type = "numberEdit",
    x = xEdit1,
    y = cellTop,
    w = editW1,
    min = math.floor(rawMin / stepSize),
    max = math.ceil(rawMax / stepSize),
    active = function() return true end,
    get = function()
      local rVal = ui.config[key1] or rawMin
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      return math.floor(rVal / stepSize)
    end,
    set = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      ui.config[key1] = rVal
      ui.dirty = true
    end,
    display = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      return formatValue(rVal, spec1) .. spec1.suffix
    end
  }

  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

local function appendDualFieldRow(children, x, y, w, rowLabel, label1, key1, spec1, label2, key2, spec2)
  local rowH = (Controls and Controls.ROW_H) or 40
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))
  
  local editW   = math.floor(w * 0.24)
  local labelW  = math.floor(w * 0.14)
  local gap     = 8
  local margin  = 10
  local labelGap = 4
  
  local xEdit2  = x + w - editW - margin
  local xLabel2 = xEdit2 - labelW - gap
  local xEdit1  = xLabel2 - editW - gap
  local xLabel1 = xEdit1 - labelW - gap
  local mainW   = xLabel1 - x - 8
  
  -- Left main label
  if rowLabel and rowLabel ~= "" then
    children[#children + 1] = {
      type  = "label",
      x = x, y = labelY,
      w = mainW,
      text  = rowLabel,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE
    }
  end
  
  -- Column 1
  children[#children + 1] = {
    type  = "label",
    x = xLabel1, y = labelY,
    w = labelW - labelGap,
    text  = label1,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE,
    align = RIGHT
  }
  
  local spec = spec1
  local rawMin = spec.min or 0
  local rawMax = spec.max or 1000
  local stepSize = spec.step or 1
  children[#children + 1] = {
    type = "numberEdit",
    x = xEdit1,
    y = cellTop,
    w = editW,
    min = math.floor(rawMin / stepSize),
    max = math.ceil(rawMax / stepSize),
    active = function() return true end,
    get = function()
      local rVal = ui.config[key1] or rawMin
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      return math.floor(rVal / stepSize)
    end,
    set = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      ui.config[key1] = rVal
      ui.dirty = true
    end,
    display = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      return formatValue(rVal, spec) .. spec.suffix
    end
  }

  -- Column 2
  if label2 and key2 and spec2 then
    children[#children + 1] = {
      type  = "label",
      x = xLabel2, y = labelY,
      w = labelW - labelGap,
      text  = label2,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE,
      align = RIGHT
    }
    
    local specB = spec2
    local rawMinB = specB.min or 0
    local rawMaxB = specB.max or 1000
    local stepSizeB = specB.step or 1
    children[#children + 1] = {
      type = "numberEdit",
      x = xEdit2,
      y = cellTop,
      w = editW,
      min = math.floor(rawMinB / stepSizeB),
      max = math.ceil(rawMaxB / stepSizeB),
      active = function() return true end,
      get = function()
        local rVal = ui.config[key2] or rawMinB
        if rVal < rawMinB then rVal = rawMinB end
        if rVal > rawMaxB then rVal = rawMaxB end
        return math.floor(rVal / stepSizeB)
      end,
      set = function(val)
        local rVal = math.floor((tonumber(val) or math.floor(rawMinB / stepSizeB)) * stepSizeB)
        if rVal < rawMinB then rVal = rawMinB end
        if rVal > rawMaxB then rVal = rawMaxB end
        ui.config[key2] = rVal
        ui.dirty = true
      end,
      display = function(val)
        local rVal = math.floor((tonumber(val) or math.floor(rawMinB / stepSizeB)) * stepSizeB)
        return formatValue(rVal, specB) .. specB.suffix
      end
    }
  end

  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

local function appendTripleFieldRow(children, x, y, w, i18n, labelText, key0, spec0, key1, spec1, key2, spec2)
  local rowH = (Controls and Controls.ROW_H) or 40
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  -- Calculate the exact same startX as appendDualFieldRow to keep alignment consistent
  local editW   = math.floor(w * 0.20)
  local labelW  = math.floor(w * 0.14)
  local gap     = 8
  local margin  = 10
  
  local xEdit2  = x + w - editW - margin
  local xLabel2 = xEdit2 - labelW - gap
  local xEdit1  = xLabel2 - editW - gap
  local startX  = xEdit1 - labelW - gap -- This matches xLabel1 in appendDualFieldRow
  
  local rightEdge = x + w - margin

  local mainW = startX - x - 8

  -- Row label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = mainW,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  local keys = { key0, key1, key2 }
  local specs = { spec0, spec1, spec2 }
  local prefixes = { "R", "P", "Y" }
  local labelW_prefix = 12
  local gap_prefix = 4

  -- Calculate positions for the 3 columns
  local labelX = {}
  local editX = {}

  -- Column 1
  labelX[1] = startX
  editX[1] = startX + labelW_prefix + gap_prefix

  -- Column 3
  editX[3] = rightEdge - editW
  labelX[3] = editX[3] - labelW_prefix - gap_prefix

  -- Column 2
  local midX = startX + math.floor((labelX[3] - startX) / 2)
  labelX[2] = midX
  editX[2] = midX + labelW_prefix + gap_prefix

  for i = 1, 3 do
    local key = keys[i]
    local spec = specs[i]
    
    if key and spec then
      -- Prefix label ("R", "P", "Y")
      children[#children + 1] = {
        type  = "label",
        x = labelX[i], y = labelY,
        w = labelW_prefix,
        text  = prefixes[i],
        color = COLOR_THEME_PRIMARY1,
        font  = SMLSIZE,
        align = RIGHT
      }

      local rawMin = spec.min or 0
      local rawMax = spec.max or 250
      local stepSize = spec.step or 1

      children[#children + 1] = {
        type = "numberEdit",
        x = editX[i],
        y = cellTop,
        w = editW,
        min = math.floor(rawMin / stepSize),
        max = math.ceil(rawMax / stepSize),
        active = function() return true end,
        get = function()
          local rVal = ui.config[key] or rawMin
          if rVal < rawMin then rVal = rawMin end
          if rVal > rawMax then rVal = rawMax end
          return math.floor(rVal / stepSize)
        end,
        set = function(val)
          local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
          if rVal < rawMin then rVal = rawMin end
          if rVal > rawMax then rVal = rawMax end
          ui.config[key] = rVal
          ui.dirty = true
        end,
        display = function(val)
          local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
          return formatValue(rVal, spec) .. spec.suffix
        end
      }
    end
  end

  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

local function appendSingleChoiceRow(children, x, y, w, labelText, key, options)
  local rowH = (Controls and Controls.ROW_H) or 48
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  local comboW = math.floor(w * 0.24)
  local comboX = x + w - comboW - 10
  local mainW = comboX - x - 8

  -- Left label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = mainW,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  local values = {}
  local selectedIndex = 1
  for i, opt in ipairs(options) do
    values[i] = opt.label
  end

  children[#children + 1] = {
    type  = "choice",
    x = comboX, y = cellTop,
    w = comboW,
    title = labelText,
    values = values,
    get = function()
      local val = tonumber(ui.config[key]) or 0
      for idx, opt in ipairs(options) do
        if opt.value == val then return idx end
      end
      return 1
    end,
    set = function(nextIndex)
      local opt = options[nextIndex]
      if opt then
        ui.config[key] = opt.value
        ui.dirty = true
      end
    end
  }

  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

function M.onLoad()
  ensureDeps()
  ensureLoaded()
end

function M.onActivate()
  ensureDeps()
  ensureLoaded()
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    queueRcRead(false)
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    help = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()
  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n
  
  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_message", "Reading PID Controller settings"),
      progress = ui.progress / 100
    })
    return
  end

  local title = ui.baseTitle or getBaseTitle()
  local profile = getLiveProfile()
  local displayTitle = string.format("%s #%d", title, profile)

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
  end

  -- Specs
  local specDecay  = { scale=10, mult=1, min=0, max=250, suffix="s", decimals=1 }
  local specLimitC = { scale=1, mult=1, min=0, max=25, suffix="°", decimals=0 }
  local specLimitE = { scale=1, mult=1, min=0, max=180, suffix="°", decimals=0 }
  local specCutoff = { scale=1, mult=1, min=1, max=100, suffix="Hz", decimals=0 }

  -- 1) Ground Error Decay (single right-aligned field)
  cursorY = cursorY + appendSingleFieldRow(children, x, cursorY, w,
    pageText(i18n, "ground_error_decay", "Ground Error Decay"),
    "", "error_decay_time_ground", specDecay
  )

  -- 2) Inflight Error Decay (dual field: Time & Limit)
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w,
    pageText(i18n, "inflight_error_decay", "Inflight Error Decay"),
    pageText(i18n, "time", "Time"), "error_decay_time_cyclic", specDecay,
    pageText(i18n, "limit", "Limit"), "error_decay_limit_cyclic", specLimitC
  )

  -- 4) Error limit (triple field: Roll, Pitch, Yaw)
  cursorY = cursorY + appendTripleFieldRow(children, x, cursorY, w, i18n,
    pageText(i18n, "error_limit", "Error limit"),
    "error_limit_0", specLimitE,
    "error_limit_1", specLimitE,
    "error_limit_2", specLimitE
  )

  -- 5) HSI Offset limit (dual field under triple column grid: Roll, Pitch)
  cursorY = cursorY + appendTripleFieldRow(children, x, cursorY, w, i18n,
    pageText(i18n, "hsi_offset_limit", "HSI Offset limit"),
    "offset_limit_0", specLimitE,
    "offset_limit_1", specLimitE,
    nil, nil
  )

  -- 6) Error rotation (choice field, only for API version <= 12.0.8)
  local showRotation = not isAtLeastVersion({12, 0, 9})
  if showRotation then
    local rotationOptions = {
      { value = 0, label = pageText(i18n, "tbl_off", "Off") },
      { value = 1, label = pageText(i18n, "tbl_on", "On") }
    }
    cursorY = cursorY + appendSingleChoiceRow(children, x, cursorY, w,
      pageText(i18n, "error_rotation", "Error rotation"),
      "error_rotation", rotationOptions
    )
  end

  -- 7) I-term relax (choice field: Off, RP, RPY)
  local relaxOptions = {
    { value = 0, label = pageText(i18n, "tbl_off", "Off") },
    { value = 1, label = pageText(i18n, "tbl_rp", "RP") },
    { value = 2, label = pageText(i18n, "tbl_rpy", "RPY") }
  }
  cursorY = cursorY + appendSingleChoiceRow(children, x, cursorY, w,
    pageText(i18n, "iterm_relax", "I-term relax"),
    "iterm_relax_type", relaxOptions
  )

  -- 9) I-term relax cutoff / Cut-off point (triple field: Roll, Pitch, Yaw)
  cursorY = cursorY + appendTripleFieldRow(children, x, cursorY, w, i18n,
    pageText(i18n, "cutoff_point", "Cut-off point"),
    "iterm_relax_cutoff_0", specCutoff,
    "iterm_relax_cutoff_1", specCutoff,
    "iterm_relax_cutoff_2", specCutoff
  )
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  queueRcWrite()
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    queueRcRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/flight_tuning/advanced/pid_controller/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end


function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  PidProfileApi = nil
  LoadingOverlay = nil
  Sensors = nil
  ApiVersion = nil
  t = nil
end

ui.runtimeBase = nil
M.ui = ui
return M
