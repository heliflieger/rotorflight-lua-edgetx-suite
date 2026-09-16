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
local RescueProfileApi = nil
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
  if not RescueProfileApi then RescueProfileApi = loadModule("tasks/msp/api/rescue_profile.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_advanced_rescue") or nil end
  
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
  if type(session.rescue_profile) ~= "table" then
    session.rescue_profile = session.rescueProfile or {}
  end
  session.rescueProfile = session.rescue_profile
  return session.rescue_profile
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
  if not RescueProfileApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
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
    command = RescueProfileApi.command,
    simulatorResponse = RescueProfileApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = RescueProfileApi.parse(buf)
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
  if not RescueProfileApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
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
    command = RescueProfileApi.writeCommand,
    payload = RescueProfileApi.buildWritePayload(rcConfig),
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
  return pageText(nil, "title", "Rescue")
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

  -- Draw separator line below the row
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
      message = pageText(i18n, "loading_message", "Reading Rescue Settings"),
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

  -- 1) Rescue Mode Enable (Switch)
  local modeVal = (tonumber(ui.config.rescue_mode) or 0) == 1
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w, pageText(i18n, "mode_enable", "Rescue mode enable"), modeVal, function(nextBool)
    ui.config.rescue_mode = nextBool and 1 or 0
    ui.dirty = true
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end)

  if modeVal then
    -- 2) Flip to upright (Switch)
    local flipUpVal = (tonumber(ui.config.rescue_flip_mode) or 0) == 1
    cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w, pageText(i18n, "flip_upright", "Flip to upright"), flipUpVal, function(nextBool)
      ui.config.rescue_flip_mode = nextBool and 1 or 0
      ui.dirty = true
    end)

    -- Specs
    local specCollective = { scale=10, mult=1, min=0, max=1000, suffix="%", decimals=0 }
    local specTime       = { scale=10, mult=1, min=0, max=250, suffix="s", decimals=1 }
    local specGain       = { scale=1, mult=1, min=0, max=250, suffix="", decimals=0 }
    local specRate       = { scale=1, mult=1, min=5, max=1000, suffix="°/s", decimals=0 }
    local specAccel      = { scale=1, mult=1, min=0, max=10000, suffix="°/s^2", decimals=0 }

    -- 3) Pull-up (Collective & Time)
    cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
      pageText(i18n, "pull_up", "Pull-up"), 
      pageText(i18n, "collective", "Collective"), "rescue_pull_up_collective", specCollective, 
      pageText(i18n, "time", "Time"), "rescue_pull_up_time", specTime
    )

    -- 4) Climb (Collective & Time)
    cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
      pageText(i18n, "climb", "Climb"), 
      pageText(i18n, "collective", "Collective"), "rescue_climb_collective", specCollective, 
      pageText(i18n, "time", "Time"), "rescue_climb_time", specTime
    )

    -- 5) Hover (Collective)
    cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
      pageText(i18n, "hover", "Hover"), 
      pageText(i18n, "collective", "Collective"), "rescue_hover_collective", specCollective, 
      nil, nil, nil
    )

    -- 6) Flip (Fail time & Exit time)
    cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
      pageText(i18n, "flip", "Flip"), 
      pageText(i18n, "fail_time", "Fail time"), "rescue_flip_time", specTime, 
      pageText(i18n, "exit_time", "Exit time"), "rescue_exit_time", specTime
    )

    -- 7) Gains (Level & Flip)
    cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
      pageText(i18n, "gains", "Gains"), 
      pageText(i18n, "level_gain", "Level"), "rescue_level_gain", specGain, 
      pageText(i18n, "flip", "Flip"), "rescue_flip_gain", specGain
    )

    -- 8) Dynamics (Rate & Accel)
    cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w, 
      pageText(i18n, "dynamics", "Dynamics"), 
      pageText(i18n, "rate", "Rate"), "rescue_max_setpoint_rate", specRate, 
      pageText(i18n, "accel", "Accel"), "rescue_max_setpoint_accel", specAccel
    )
  end
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
  RescueProfileApi = nil
  LoadingOverlay = nil
  Sensors = nil
  t = nil
end

M.ui = ui
return M
