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
local RcTuningApi = nil
local LoadingOverlay = nil
local Sensors = nil
local Profile = nil
local t = nil

local RATE_TABLE_DEFAULTS = {
  [0] = { -- None
    rcRates_1 = 0, rcRates_2 = 0, rcRates_3 = 0, rcRates_4 = 0,
    rates_1 = 0, rates_2 = 0, rates_3 = 0, rates_4 = 0,
    rcExpo_1 = 0, rcExpo_2 = 0, rcExpo_3 = 0, rcExpo_4 = 0
  },
  [1] = { -- Betaflight
    rcRates_1 = 120, rcRates_2 = 120, rcRates_3 = 200, rcRates_4 = 203,
    rates_1 = 0, rates_2 = 0, rates_3 = 0, rates_4 = 1,
    rcExpo_1 = 0, rcExpo_2 = 0, rcExpo_3 = 0, rcExpo_4 = 0
  },
  [2] = { -- Raceflight
    rcRates_1 = 24, rcRates_2 = 24, rcRates_3 = 40, rcRates_4 = 50,
    rates_1 = 0, rates_2 = 0, rates_3 = 0, rates_4 = 0,
    rcExpo_1 = 0, rcExpo_2 = 0, rcExpo_3 = 0, rcExpo_4 = 0
  },
  [3] = { -- KISS
    rcRates_1 = 120, rcRates_2 = 120, rcRates_3 = 200, rcRates_4 = 250,
    rates_1 = 0, rates_2 = 0, rates_3 = 0, rates_4 = 0,
    rcExpo_1 = 0, rcExpo_2 = 0, rcExpo_3 = 0, rcExpo_4 = 0
  },
  [4] = { -- Actual
    rcRates_1 = 18, rcRates_2 = 18, rcRates_3 = 18, rcRates_4 = 50,
    rates_1 = 24, rates_2 = 24, rates_3 = 40, rates_4 = 50,
    rcExpo_1 = 0, rcExpo_2 = 0, rcExpo_3 = 0, rcExpo_4 = 0
  },
  [5] = { -- Quick
    rcRates_1 = 120, rcRates_2 = 120, rcRates_3 = 200, rcRates_4 = 250,
    rates_1 = 24, rates_2 = 24, rates_3 = 40, rates_4 = 104,
    rcExpo_1 = 0, rcExpo_2 = 0, rcExpo_3 = 0, rcExpo_4 = 0
  },
  [6] = { -- Rotorflight
    rcRates_1 = 49, rcRates_2 = 48, rcRates_3 = 25, rcRates_4 = 50,
    rates_1 = 12, rates_2 = 12, rates_3 = 12, rates_4 = 12,
    rcExpo_1 = 0, rcExpo_2 = 0, rcExpo_3 = 0, rcExpo_4 = 0
  }
}

local RATE_TABLE_NAMES = {
  [0] = "NONE",
  [1] = "BETAFLIGHT",
  [2] = "RACEFLIGHT",
  [3] = "KISS",
  [4] = "ACTUAL",
  [5] = "QUICK",
  [6] = "ROTORFLIGHT"
}

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    fieldSetters = {},
    lastSessionSignature = nil,
    resetRates = false
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
  if not RcTuningApi then RcTuningApi = loadModule("tasks/msp/api/rc_tuning.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_rates") or nil end
  
  if Common then
    if not ui.runtimeBase then
      ui.runtimeBase = Common.createProfileAwareRuntime({ profileType = "rate" })
    end
    if type(ui.runtime) ~= "table" then
      ui.runtime = newRuntime()
      setmetatable(ui.runtime, { __index = ui.runtimeBase })
    end
  end
end

local function pageText(i18n, key)
  if t then
    local translated = t(i18n, key)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return key
end

local function getRatesTypeName(i18n, key)
  if key == "none" then return pageText(i18n, "none") end
  if key == "betaflight" then return pageText(i18n, "betaflight") end
  if key == "raceflight" then return pageText(i18n, "raceflight") end
  if key == "kiss" then return pageText(i18n, "kiss") end
  if key == "actual" then return pageText(i18n, "actual") end
  if key == "quick" then return pageText(i18n, "quick") end
  if key == "rotorflight" then return pageText(i18n, "rotorflight") end
  return key
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.rc_tuning) ~= "table" then
    session.rc_tuning = session.rcTuning or {}
  end
  session.rcTuning = session.rc_tuning
  return session.rc_tuning
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
  if not RcTuningApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
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
    command = RcTuningApi.command,
    simulatorResponse = RcTuningApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = RcTuningApi.parse(buf)
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
  if not RcTuningApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local session = getSession()
  local rcConfig = getRcConfig(session)
  
  if ui.runtime.resetRates then
    local newType = ui.config.rates_type
    local defaults = RATE_TABLE_DEFAULTS[newType]
    if defaults then
      for k, v in pairs(defaults) do
        rcConfig[k] = v
      end
    end
    ui.runtime.resetRates = false
  end
  
  -- Update the type in the session config before writing
  rcConfig.rates_type = ui.config.rates_type

  queue:add({
    command = RcTuningApi.writeCommand,
    payload = RcTuningApi.buildWritePayload(rcConfig),
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
  return Profile and Profile.getActiveRateProfile(1) or 1
end

local function getBaseTitle()
  return pageText(nil, "table", "Rate Table")
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
      title = pageText(i18n, "loading_title"),
      message = pageText(i18n, "loading_message"),
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
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- Help context
  ctx.ratesType = ui.config.rates_type or 6
  
  local ratesKeys = { "none", "betaflight", "raceflight", "kiss", "actual", "quick", "rotorflight" }
  local ratesOptions = {}
  for i = 0, 6 do
    ratesOptions[#ratesOptions + 1] = { label = getRatesTypeName(i18n, ratesKeys[i + 1]), value = i }
  end

  cursorY = cursorY + 10
  Controls.appendComboSelect(children, x, cursorY, w, pageText(i18n, "rates_type"), ratesOptions, ui.config.rates_type or 6, function(value)
    if ui.config.rates_type == value then return end
    ui.config.rates_type = value
    ui.runtime.resetRates = true
    ui.dirty = true
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end)
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  if ui.runtime.resetRates then
    local ConfirmDialog = loadModule("ui/confirm_dialog.lua")
    if ConfirmDialog and type(ConfirmDialog.show) == "function" then
      ConfirmDialog.show({
        title = pageText(ctx and ctx.i18n, "warning_title", "@i18n(app.pages.flight_tuning_rates.warning_title)@"),
        message = pageText(ctx and ctx.i18n, "msg_reset_to_defaults", "@i18n(app.pages.flight_tuning_rates.msg_reset_to_defaults)@"),
        onConfirm = function()
          queueRcWrite()
        end
      })
      return true
    end
  end

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
  RcTuningApi = nil
  LoadingOverlay = nil
  Sensors = nil
  t = nil
end

M.ui = ui
return M
