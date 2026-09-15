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
  if not t then t = Common and Common.pageT("flight_tuning_advanced_autolevel") or nil end
  
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
  return pageText(nil, "title", "Autolevel")
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

local function appendDualFieldRow(children, x, y, w, rowLabel, label1, key1, spec1, label2, key2, spec2)
  local rowH = (Controls and Controls.ROW_H) or 40
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))
  
  local mainW    = math.floor(w * 0.18)
  local labelW1  = math.floor(w * 0.14)
  local editW1   = math.floor(w * 0.24)
  local gap      = 8
  local labelGap = 4
  
  -- Left main label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = mainW,
    text  = rowLabel,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }
  
  -- Column 1
  local xLabel1 = x + mainW
  local xEdit1  = xLabel1 + labelW1
  
  children[#children + 1] = {
    type  = "label",
    x = xLabel1, y = labelY,
    w = labelW1 - labelGap,
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
      return formatValue(rVal, spec) .. spec.suffix
    end
  }

  -- Column 2
  if label2 and key2 and spec2 then
    local labelW2 = math.floor(w * 0.14)
    local editW2  = math.floor(w * 0.24)
    local xLabel2 = xEdit1 + editW1 + gap
    local xEdit2  = xLabel2 + labelW2

    children[#children + 1] = {
      type  = "label",
      x = xLabel2, y = labelY,
      w = labelW2 - labelGap,
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
      w = editW2,
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
      message = pageText(i18n, "loading_message", "Reading Autolevel Settings"),
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
  local specGain  = { scale=1, mult=1, min=0, max=200, suffix="", decimals=0 }
  local specGainT = { scale=1, mult=1, min=25, max=255, suffix="", decimals=0 }
  local specLimit = { scale=1, mult=1, min=10, max=90, suffix="°", decimals=0 }
  local specLimitT = { scale=1, mult=1, min=10, max=80, suffix="°", decimals=0 }

  -- 1) Acro trainer (Gain & Max)
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
    pageText(i18n, "acro_trainer", "Acro trainer"), 
    pageText(i18n, "gain", "Gain"), "trainer_gain", specGainT, 
    pageText(i18n, "max", "Max"), "trainer_angle_limit", specLimitT
  )

  -- 2) Angle mode (Gain & Max)
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
    pageText(i18n, "angle_mode", "Angle mode"), 
    pageText(i18n, "gain", "Gain"), "angle_level_strength", specGain, 
    pageText(i18n, "max", "Max"), "angle_level_limit", specLimit
  )

  -- 3) Horizon mode (Gain only)
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
    pageText(i18n, "horizon_mode", "Horizon mode"), 
    pageText(i18n, "gain", "Gain"), "horizon_level_strength", specGain, 
    nil, nil, nil
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
  local help = loadModule("app/pages/flight_tuning/advanced/autolevel/help.lua")
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
  t = nil
end

ui.runtimeBase = nil
M.ui = ui
return M
