local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = nil
local MspRuntime = nil
local Sensors = nil
local SmartfuelApi = nil
local SmartFuelReserve = nil
local LoadingOverlay = nil
local t = nil

local state = {
  loaded = false,
  rows = {},
  rowSignature = "",
  requestRebuild = nil,
  lastRefreshAt = 0,
  refreshIntervalSec = nil, -- Disable auto refresh to allow scrolling
  firmwareConfig = nil,
  loading = false,
  progress = 0,
  tasksDone = 0,
  tasksTotal = 0,
}

local SOURCE_LABELS = {
  [0] = "OFF",
  [1] = "VOLTAGE",
  [2] = "CURRENT",
  [3] = "COMBINED",
}

local LOCAL_SOURCE_LABELS = {
  [0] = "CURRENT",
  [1] = "VOLTAGE",
  [2] = "COMBINED",
}

local SENSOR_MAP = {
  sim = {
    protocol = "Simulator / MSP",
    fuel = { label = "MSP fuel", name = "fuel", unit = "%" },
    consumption = { label = "MSP mAh", name = "consumption", unit = "mAh" },
  },
  sport = {
    protocol = "FBus / S.Port",
    fuel = { label = "Fuel", name = "fuel", unit = "%" },
    consumption = { label = "Capa", name = "consumption", unit = "mAh" },
  },
  crsf = {
    protocol = "CRSF / ELRS",
    fuel = { label = "Fuel", name = "fuel", unit = "%" },
    consumption = { label = "Capa", name = "consumption", unit = "mAh" },
  },
}

local SMART_SENSORS = {
  fuel = { label = "SmFt", name = "smartfuel", unit = "%" },
  consumption = { label = "SmCp", name = "smartconsumption", unit = "mAh" },
}

local function widgetLog(msg, level)
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.smartfuel.diag", tostring(msg), level or "debug")
  end
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then
      return v / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not SmartfuelApi then SmartfuelApi = loadModule("tasks/msp/api/smartfuel_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("diagnostics_smartfuel") or nil end
  if not SmartFuelReserve then SmartFuelReserve = loadModule("lib/smartfuel_reserve.lua") end
end

local function pageText(i18n, key, fallback)
  if t then return t(i18n, key, fallback) end
  return fallback
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function readTelemetryNumeric(name)
  if not (Sensors and type(Sensors.getValue) == "function") then return nil end
  return Sensors.getValue(name)
end

local function getProtocol()
  -- Detect simulation from EdgeTX system info if available, or just check MspRuntime
  if type(system) == "table" and type(system.getVersion) == "function" then
    local v = system.getVersion()
    if v and v.simulation then return "sim" end
  end
  
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return "crsf" end
  local mspState = MspRuntime.getState()
  local proto = mspState and mspState.protocol
  if proto == "sport" or proto == "crsf" then return proto end
  return "crsf"
end

local function getBatteryPrefs()
  local session = getSession()
  return session and session.modelPreferences and session.modelPreferences.battery or nil
end

local function getLocalSource()
  local prefs = getBatteryPrefs()
  if not prefs then return 0 end
  local source = tonumber(prefs.smartfuel_source)
  if source ~= nil then return source end
  return tonumber(prefs.calc_local) or 0
end

local function getFirmwareSource()
  if state.firmwareConfig and state.firmwareConfig.smartfuel_mode ~= nil then
    return state.firmwareConfig.smartfuel_mode
  end

  local session = getSession()
  local bc = session and session.battery_config
  -- Check if session has smartfuel_config
  if session and session.smartfuel_config then
    return tonumber(session.smartfuel_config.smartfuel_mode) or 0
  end
  return nil
end

local function getMode()
  local firmwareSource = getFirmwareSource()
  if firmwareSource and firmwareSource > 0 then
    return "Firmware " .. (SOURCE_LABELS[firmwareSource] or tostring(firmwareSource))
  end

  local localSource = getLocalSource()
  return "Local " .. (LOCAL_SOURCE_LABELS[localSource] or tostring(localSource))
end

local function getModeDetail()
  local firmwareSource = getFirmwareSource()
  local firmwareText = firmwareSource == nil and "n/a" or (SOURCE_LABELS[firmwareSource] or tostring(firmwareSource))
  local localSource = getLocalSource()
  local localText = LOCAL_SOURCE_LABELS[localSource] or tostring(localSource)
  return "FBL " .. firmwareText .. " / Local " .. localText
end

local function formatNumber(value, decimals)
  if value == nil then return "-" end
  local d = decimals or 0
  if d <= 0 then return tostring(math.floor(value + 0.5)) end
  local scale = 10 ^ d
  return string.format("%." .. tostring(d) .. "f", math.floor(value * scale + 0.5) / scale)
end

local function formatSensor(sourceDef)
  if not sourceDef then return "n/a" end
  local value = readTelemetryNumeric(sourceDef.name)
  if value == nil then return sourceDef.label .. ": -" end
  return sourceDef.label .. ": " .. formatNumber(value, 0) .. (sourceDef.unit and (" " .. sourceDef.unit) or "")
end

local function requestData()
  if state.loading then return false end
  
  if not (MspRuntime and type(MspRuntime.getState) == "function") then 
    return false 
  end
  local mspState = MspRuntime.getState()
  if not mspState or not mspState.queue then 
    return false 
  end
  
  widgetLog("requestData: starting load", "info")
  state.loading = true
  state.tasksTotal = 2
  state.tasksDone = 0
  state.progress = 0

  local function onTaskDone()
    state.tasksDone = state.tasksDone + 1
    state.progress = state.tasksDone / state.tasksTotal
    widgetLog("onTaskDone: " .. tostring(state.tasksDone) .. "/" .. tostring(state.tasksTotal))
    if state.tasksDone >= state.tasksTotal then
      state.loading = false
      state.progress = 1
      widgetLog("requestData: finished", "info")
    end
    if type(state.requestRebuild) == "function" then
      state.requestRebuild()
    end
  end

  -- Request SmartFuel Config
  local sfApi = SmartfuelApi
  if sfApi then
    widgetLog("requestData: enqueuing smartfuel_config (cmd=" .. tostring(sfApi.command) .. ")")
    mspState.queue:add({
      command = sfApi.command,
      simulatorResponse = sfApi.simulatorResponse,
      processReply = function(_, buf)
        widgetLog("requestData: smartfuel_config received")
        local res = sfApi.parse(buf)
        if res then
          state.firmwareConfig = res
          local session = getSession()
          if session then session.smartfuel_config = res end
        end
        onTaskDone()
      end,
      errorHandler = function()
        widgetLog("requestData: smartfuel_config failed", "warn")
        onTaskDone()
      end
    })
  else
    onTaskDone()
  end

  -- Request Battery Config (cmd 32) for accurate capacity display
  local batteryApi = loadModule("tasks/msp/api/battery_config.lua")
  if batteryApi then
    local bApi = batteryApi
    widgetLog("requestData: enqueuing battery_config (cmd=" .. tostring(bApi.command) .. ")")
    mspState.queue:add({
      command = bApi.command,
      simulatorResponse = bApi.simulatorResponse,
      processReply = function(_, buf)
        widgetLog("requestData: battery_config received")
        local data = bApi.parse(buf)
        if data then
          local session = getSession()
          if session then session.battery_config = data end
        end
        onTaskDone()
      end,
      errorHandler = function()
        widgetLog("requestData: battery_config failed", "warn")
        onTaskDone()
      end
    })
  else
    onTaskDone()
  end

  return true
end

local function rebuildRows(i18n)
  local protocolKey = getProtocol()
  local protocol = SENSOR_MAP[protocolKey]
  local protocolText = protocol and protocol.protocol or tostring(protocolKey or "Unknown")
  
  local prefs = getBatteryPrefs() or {}
  local session = getSession()
  local bc = session and session.battery_config or {}
  local firmwareSource = getFirmwareSource()
  local usingFirmware = firmwareSource and firmwareSource > 0
  local localSource = getLocalSource()

  local fuelInput = ""
  if usingFirmware then
    fuelInput = formatSensor(protocol and protocol.fuel)
  else
    fuelInput = "Local " .. (LOCAL_SOURCE_LABELS[localSource] or tostring(localSource))
  end

  local voltageDrop = (usingFirmware and state.firmwareConfig and state.firmwareConfig.voltage_drop_rate) or tonumber(prefs.voltage_drop_rate) or 10
  local chargeDrop = (usingFirmware and state.firmwareConfig and state.firmwareConfig.charge_drop_rate) or tonumber(prefs.charge_drop_rate) or 50
  local sagGain = (usingFirmware and state.firmwareConfig and state.firmwareConfig.sag_gain) or tonumber(prefs.sag_gain) or 40
  
  -- Use profile-specific capacity if battery_config is present
  local activeProfile = tonumber(readTelemetryNumeric("battery_profile")) or 1
  local configIndex = math.max(0, activeProfile - 1)
  local capacity = bc["batteryCapacity_" .. tostring(configIndex)] or bc.batteryCapacity or 0
  local reserve = SmartFuelReserve and SmartFuelReserve.resolve(session, bc) or 0
  
  local rawFuel = nil
  if usingFirmware and protocol and protocol.fuel then
    rawFuel = readTelemetryNumeric(protocol.fuel.name)
  else
    -- Fallback to standard fuel sensor if not using firmware or specific protocol sensor
    rawFuel = readTelemetryNumeric("fuel")
  end
  local targetFuel = SmartFuelReserve and SmartFuelReserve.applyPercent(rawFuel, reserve)
  
  local rows = {
    { label = pageText(i18n, "protocol", "Protocol"), value = protocolText },
    { label = pageText(i18n, "active_mode", "Active mode"), value = getMode() },
    { label = pageText(i18n, "fbl_local", "FBL / local"), value = getModeDetail() },
    { label = pageText(i18n, "tuning_source", "Tuning source"), value = usingFirmware and "Firmware MSP" or "Local prefs" },
    { label = pageText(i18n, "fuel_input", "Fuel input"), value = fuelInput },
    { label = pageText(i18n, "source_mah", "Source mAh"), value = formatSensor(protocol and protocol.consumption) },
    { label = pageText(i18n, "smart_fuel", "Smart Fuel"), value = formatSensor(SMART_SENSORS.fuel) },
    { label = pageText(i18n, "smart_mah", "Smart mAh"), value = formatSensor(SMART_SENSORS.consumption) },
    { label = pageText(i18n, "voltage_slew", "Voltage slew"), value = formatNumber(voltageDrop, 0) .. " mV/s" },
    { label = pageText(i18n, "charge_slew", "Charge slew"), value = formatNumber(chargeDrop / 100, 2) .. " %/s" },
    { label = pageText(i18n, "sag_gain", "Sag gain"), value = formatNumber(sagGain, 0) .. "%" },
    { label = pageText(i18n, "capacity", "Pack capacity"), value = formatNumber(capacity, 0) .. " mAh" },
    { label = pageText(i18n, "reserve_alert", "Reserve alert"), value = formatNumber(reserve, 0) .. "%" },
    { label = pageText(i18n, "reserve_target", "Reserve target"), value = targetFuel and (formatNumber(targetFuel, 0) .. "%") or "-" },
  }

  local signatureParts = {}
  for i = 1, #rows do
    signatureParts[#signatureParts + 1] = tostring(rows[i].label) .. "|" .. tostring(rows[i].value)
  end
  local signature = table.concat(signatureParts, "|")
  if signature == state.rowSignature then
    return false
  end

  state.rows = rows
  state.rowSignature = signature
  return true
end

function M.getModuleTitle()
  return "SmartFuel Status"
end

function M.getHeaderActions()
  return { reload = true, save = false, help = false }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  state.loaded = false
  state.loading = false
  if type(state.requestRebuild) == "function" then
    state.requestRebuild()
  end
  return true
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild

  local i18n = ctx.i18n
  
  if not state.loaded then
    if requestData() then
      state.loaded = true
    end
  end
  
  rebuildRows(i18n)

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h or 200
  
  -- SmartFuel diagnostics has 14 rows, so we definitely need small rows
  local rowY = y + 4
  local rowH = 30
  local labelW = math.floor(w * 0.50)
  local valueX = x + labelW
  local valueW = w - labelW

  for i = 1, #state.rows do
    local row = state.rows[i]
    local thisY = rowY + (i - 1) * rowH

    children[#children + 1] = {
      type = "label",
      x = x,
      y = thisY + 4,
      w = labelW - 10,
      text = row.label,
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "label",
      x = valueX,
      y = thisY + 4,
      w = valueW - 6,
      text = tostring(row.value),
      color = COLOR_THEME_PRIMARY1,
      align = RIGHT,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = thisY + rowH - 2,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY1,
      filled = true
    }
  end

  if state.loading and LoadingOverlay then
    LoadingOverlay.append(children, {
      x = x,
      y = y,
      w = w,
      h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_message", "Reading SmartFuel config"),
      progress = state.progress
    })
  end
end

function M.wakeup()
  -- Automatic rebuild is disabled to allow scrolling.
  -- The user must click the RELOAD button to update values.
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.loaded = false
  state.rows = {}
  state.rowSignature = ""
  state.requestRebuild = nil
  state.lastRefreshAt = 0
  state.loading = false
  state.progress = 0
  state.tasksDone = 0
  state.tasksTotal = 0
  Common = nil
  MspRuntime = nil
  Sensors = nil
  SmartfuelApi = nil
  t = nil
end

return M
