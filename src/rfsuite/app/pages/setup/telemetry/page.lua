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
local TelemetryApi = nil
local ConfirmDialog = nil
local LoadingOverlay = nil
local t = nil

M.eepromWrite = true

local SENSOR_GROUP_ORDER = {
  "battery", "voltage", "current", "temps", "esc1", "esc2",
  "rpm", "barometer", "gyro", "gps", "status", "profiles", "control", "system", "debug"
}

local SENSOR_GROUP_TITLES = {
  battery = "Battery",
  voltage = "Voltage",
  current = "Current",
  temps = "Temperatures",
  esc1 = "ESC 1",
  esc2 = "ESC 2",
  rpm = "RPM",
  barometer = "Barometer",
  gyro = "Gyro",
  gps = "GPS",
  status = "Status",
  profiles = "Profiles",
  control = "Control",
  system = "System",
  debug = "Debug"
}

local SENSOR_CATALOG = {
  { id = 1, name = "Heartbeat", group = "system" },
  { id = 3, name = "Battery Voltage", group = "battery" },
  { id = 4, name = "Battery Current", group = "battery" },
  { id = 5, name = "Battery Consumption", group = "battery" },
  { id = 6, name = "Battery Charge Level", group = "battery" },
  { id = 7, name = "Battery Cell Count", group = "battery" },
  { id = 8, name = "Battery Cell Voltage", group = "battery" },
  { id = 9, name = "Battery Cell Voltages", group = "battery" },
  { id = 10, name = "Control (Combined)", group = "control" },
  { id = 11, name = "Pitch Control", group = "control" },
  { id = 12, name = "Roll Control", group = "control" },
  { id = 13, name = "Yaw Control", group = "control" },
  { id = 14, name = "Collective Control", group = "control" },
  { id = 15, name = "Throttle Control", group = "control" },
  { id = 17, name = "ESC1 Voltage", group = "esc1" },
  { id = 18, name = "ESC1 Current", group = "esc1" },
  { id = 19, name = "ESC1 Consumption", group = "esc1" },
  { id = 20, name = "ESC1 ERPM", group = "esc1" },
  { id = 21, name = "ESC1 Power", group = "esc1" },
  { id = 22, name = "ESC1 Throttle", group = "esc1" },
  { id = 23, name = "ESC1 Temp 1", group = "esc1" },
  { id = 24, name = "ESC1 Temp 2", group = "esc1" },
  { id = 25, name = "ESC1 BEC Voltage", group = "esc1" },
  { id = 26, name = "ESC1 BEC Current", group = "esc1" },
  { id = 27, name = "ESC1 Status", group = "esc1" },
  { id = 28, name = "ESC1 Model", group = "esc1" },
  { id = 30, name = "ESC2 Voltage", group = "esc2" },
  { id = 31, name = "ESC2 Current", group = "esc2" },
  { id = 32, name = "ESC2 Consumption", group = "esc2" },
  { id = 33, name = "ESC2 ERPM", group = "esc2" },
  { id = 36, name = "ESC2 Temp", group = "esc2" },
  { id = 41, name = "ESC2 Model", group = "esc2" },
  { id = 42, name = "ESC Voltage", group = "voltage" },
  { id = 43, name = "BEC Voltage", group = "voltage" },
  { id = 44, name = "Bus Voltage", group = "voltage" },
  { id = 45, name = "MCU Voltage", group = "voltage" },
  { id = 46, name = "ESC Current", group = "current" },
  { id = 47, name = "BEC Current", group = "current" },
  { id = 48, name = "Bus Current", group = "current" },
  { id = 49, name = "MCU Current", group = "current" },
  { id = 50, name = "ESC Temp", group = "temps" },
  { id = 51, name = "BEC Temp", group = "temps" },
  { id = 52, name = "MCU Temp", group = "temps" },
  { id = 57, name = "Heading", group = "gyro" },
  { id = 58, name = "Altitude", group = "barometer" },
  { id = 59, name = "Vario", group = "barometer" },
  { id = 60, name = "Headspeed", group = "rpm" },
  { id = 61, name = "Tailspeed", group = "rpm" },
  { id = 64, name = "Attitude (Combined)", group = "gyro" },
  { id = 65, name = "Pitch Attitude", group = "gyro" },
  { id = 66, name = "Roll Attitude", group = "gyro" },
  { id = 67, name = "Yaw Attitude", group = "gyro" },
  { id = 68, name = "Accel (Combined)", group = "gyro" },
  { id = 69, name = "Accel X", group = "gyro" },
  { id = 70, name = "Accel Y", group = "gyro" },
  { id = 71, name = "Accel Z", group = "gyro" },
  { id = 73, name = "GPS Sats", group = "gps" },
  { id = 74, name = "GPS PDOP", group = "gps" },
  { id = 75, name = "GPS HDOP", group = "gps" },
  { id = 76, name = "GPS VDOP", group = "gps" },
  { id = 77, name = "GPS Coordinates", group = "gps" },
  { id = 78, name = "GPS Altitude", group = "gps" },
  { id = 79, name = "GPS Heading", group = "gps" },
  { id = 80, name = "GPS Speed", group = "gps" },
  { id = 81, name = "GPS Home Distance", group = "gps" },
  { id = 82, name = "GPS Home Direction", group = "gps" },
  { id = 85, name = "CPU Load", group = "system" },
  { id = 86, name = "SYS Load", group = "system" },
  { id = 87, name = "RT Load", group = "system" },
  { id = 88, name = "Model ID", group = "status" },
  { id = 89, name = "Flight Mode", group = "status" },
  { id = 90, name = "Arming Flags", group = "status" },
  { id = 91, name = "Arming Disable Flags", group = "status" },
  { id = 92, name = "Rescue State", group = "status" },
  { id = 93, name = "Governor State", group = "status" },
  { id = 95, name = "PID Profile", group = "profiles" },
  { id = 96, name = "Rates Profile", group = "profiles" },
  { id = 97, name = "Battery Profile", group = "profiles" },
  { id = 98, name = "LED Profile", group = "profiles" },
  { id = 99, name = "Adjustment Function", group = "status" },
  { id = 100, name = "Debug 0", group = "debug" },
  { id = 101, name = "Debug 1", group = "debug" },
  { id = 102, name = "Debug 2", group = "debug" },
  { id = 103, name = "Debug 3", group = "debug" },
  { id = 104, name = "Debug 4", group = "debug" },
  { id = 105, name = "Debug 5", group = "debug" },
  { id = 106, name = "Debug 6", group = "debug" },
  { id = 107, name = "Debug 7", group = "debug" }
}

local DEFAULT_SENSORS = {
  3, 4, 5, 6, 7, 15, 23, 25, 43, 60, 85, 90, 91, 93, 95, 96, 97, 99
}

local NOT_AT_SAME_TIME = {
  [10] = { 11, 12, 13, 14 },
  [64] = { 65, 66, 67 },
  [68] = { 69, 70, 71 }
}

local SENSOR_BY_ID = {}
local SENSOR_IDS = {}
local SENSOR_BY_GROUP = {}
for i = 1, #SENSOR_CATALOG do
  local item = SENSOR_CATALOG[i]
  SENSOR_BY_ID[item.id] = item
  SENSOR_IDS[#SENSOR_IDS + 1] = item.id
  SENSOR_BY_GROUP[item.group] = SENSOR_BY_GROUP[item.group] or {}
  SENSOR_BY_GROUP[item.group][#SENSOR_BY_GROUP[item.group] + 1] = item
end

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    boolGetters = {},
    boolSetters = {}
  }
end

local ui = {
  loaded = false,
  dirty = false,
  sections = {
    battery = true,
    voltage = true,
    current = true,
    temps = true,
    esc1 = true,
    esc2 = true,
    rpm = true,
    barometer = true,
    gyro = true,
    gps = true,
    status = true,
    profiles = true,
    control = true,
    system = true,
    debug = true
  },
  config = {},
  telemetryBuffer = nil,
  runtime = newRuntime(),
  loading = false,
  progress = 0
}

ui.runtimeBase = nil

local function ensureRuntime()
  if type(ui.runtime) ~= "table" then
    ui.runtime = newRuntime()
  end
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not TelemetryApi then TelemetryApi = loadModule("tasks/msp/api/telemetry_config.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ui.runtimeBase then
    ui.runtimeBase = Common.createFormRuntime(ui)
    if type(ui.runtime) ~= "table" then ui.runtime = {} end
    setmetatable(ui.runtime, { __index = ui.runtimeBase })
  end
  if not t then t = Common and Common.pageT("setup_telemetry") or nil end
end

local function pageText(i18n, key, fallback)
  if t then return t(i18n, key, fallback) end
  return fallback
end

local function copyBuffer(buf)
  local out = {}
  if type(buf) ~= "table" then return out end
  for i = 1, #buf do
    out[i] = tonumber(buf[i]) or 0
  end
  return out
end

local function clearConfig()
  for i = 1, #SENSOR_IDS do
    ui.config[SENSOR_IDS[i]] = false
  end
end

local function markDirty()
  ui.dirty = true
end

local function countSelected()
  local count = 0
  for i = 1, #SENSOR_IDS do
    if ui.config[SENSOR_IDS[i]] == true then
      count = count + 1
    end
  end
  return count
end

local function applyDefaults()
  clearConfig()
  for i = 1, #DEFAULT_SENSORS do
    local id = DEFAULT_SENSORS[i]
    if SENSOR_BY_ID[id] then
      ui.config[id] = true
    end
  end
  markDirty()
end

local function loadFromSession()
  local session = getSession()
  local cfg = (type(session) == "table" and type(session.telemetry_config) == "table") and session.telemetry_config or nil

  clearConfig()

  local hasSlots = false
  if cfg then
    for i = 1, 40 do
      local sensorId = tonumber(cfg["telem_sensor_slot_" .. tostring(i)])
      if sensorId and sensorId ~= 0 and SENSOR_BY_ID[sensorId] then
        ui.config[sensorId] = true
        hasSlots = true
      end
    end
  end

  if not hasSlots then
    for i = 1, #DEFAULT_SENSORS do
      local id = DEFAULT_SENSORS[i]
      if SENSOR_BY_ID[id] then
        ui.config[id] = true
      end
    end
  end

  if cfg and type(cfg.buffer) == "table" then
    ui.telemetryBuffer = copyBuffer(cfg.buffer)
  elseif TelemetryApi and type(TelemetryApi.simulatorResponse) == "table" then
    ui.telemetryBuffer = copyBuffer(TelemetryApi.simulatorResponse)
  else
    ui.telemetryBuffer = {}
  end
end

local function queueTelemetryRead()
  ensureRuntime()
  if ui.runtime.readPending then
    return false, "read_pending"
  end
  if not TelemetryApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local session = getSession()
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  local telemetryApi = TelemetryApi
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.runtime.readPending = true
  ui.loading = true
  ui.progress = 0
  queue:add({
    command = telemetryApi.command,
    simulatorResponse = telemetryApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(_, buf)
      ui.runtime.readPending = false
      ui.loading = false
      ui.progress = 1
      local parsed = telemetryApi.parse and telemetryApi.parse(buf) or nil
      if type(session) == "table" and type(parsed) == "table" then
        session.telemetry_config = parsed
      end
      if not ui.dirty then
        loadFromSession()
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      ui.runtime.readPending = false
      ui.loading = false
      ui.progress = 1
    end
  })

  return true, nil
end

local function ensureLoaded()
  ensureRuntime()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  queueTelemetryRead()
end

local function collectSelectedSensors()
  local selected = {}
  for i = 1, #SENSOR_IDS do
    local id = SENSOR_IDS[i]
    if ui.config[id] == true then
      selected[#selected + 1] = id
    end
  end
  return selected
end

local function buildWritePayload(selected)
  local payload = copyBuffer(ui.telemetryBuffer)
  if #payload < 52 then
    for i = #payload + 1, 52 do payload[i] = 0 end
  end

  local index = 1
  for pos = 13, 52 do
    payload[pos] = selected[index] or 0
    index = index + 1
  end

  return payload
end

local function queueTelemetryWrite(payload)
  if not TelemetryApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local session = getSession()
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  local telemetryApi = TelemetryApi
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  queue:add({
    command = telemetryApi.writeCommand,
    payload = payload,
    timeout = 5.0,
    isWrite = true,
    processReply = function()
      if type(session) == "table" and type(telemetryApi.parse) == "function" then
        session.telemetry_config = telemetryApi.parse(payload)
      end
      ui.telemetryBuffer = copyBuffer(payload)
    end,
    errorHandler = function()
      -- Keep local state; user can retry Save.
    end
  })

  return true, nil
end

local function getBoolGetter(sensorId)
  local getter = ui.runtime.boolGetters[sensorId]
  if getter then return getter end

  getter = function()
    return ui.config[sensorId] == true
  end
  ui.runtime.boolGetters[sensorId] = getter
  return getter
end

local function getBoolSetter(sensorId)
  local setter = ui.runtime.boolSetters[sensorId]
  if setter then return setter end

  setter = function(value)
    local enabled = value == true
    if ui.config[sensorId] == enabled then return end

    ui.config[sensorId] = enabled
    local conflicts = NOT_AT_SAME_TIME[sensorId]
    if enabled and type(conflicts) == "table" then
      for i = 1, #conflicts do
        ui.config[conflicts[i]] = false
      end
    end

    markDirty()
  end
  ui.runtime.boolSetters[sensorId] = setter
  return setter
end

function M.getHeaderActions()
  ensureDeps()
  return {
    save = true,
    reload = true,
    star = true,
    help = true,
    menu = true
  }
end


function M.onReload()
  ensureDeps()
  ui.loaded = false
  ensureLoaded()
  return false
end

function M.onStar(ctx)
  ensureDeps()
  ensureLoaded()

  local function applyAndRefresh()
    applyDefaults()
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  if ConfirmDialog and type(ConfirmDialog.show) == "function" then
    local shown = ConfirmDialog.show({
      title = pageText(ctx and ctx.i18n, "set_defaults_title", "Telemetry Sensors"),
      message = pageText(ctx and ctx.i18n, "set_defaults_msg", "Load default telemetry sensors?"),
      onConfirm = applyAndRefresh,
      onCancel = function() end,
      onFallback = applyAndRefresh
    })
    if shown then
      return false
    end
  end

  applyAndRefresh()
  return true
end

function M.onSave(ctx)
  ensureDeps()
  ensureLoaded()

  local selected = collectSelectedSensors()
  if #selected > 40 then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = pageText(ctx and ctx.i18n, "too_many_sensors", "No more than 40 telemetry sensors can be enabled.")
      })
    end
    return false
  end

  local payload = buildWritePayload(selected)
  local ok, err = queueTelemetryWrite(payload)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  ui.dirty = false
  if ctx and type(ctx.reportSave) == "function" then
    ctx.reportSave({
      title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
      message = pageText(ctx and ctx.i18n, "saved_message", "Telemetry sensors saved")
    })
  end
  return true
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()
  if ui.runtime and ui.runtime.setRequestRebuild then
    ui.runtime.setRequestRebuild(ctx and ctx.requestRebuild or nil)
  else
    ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  end

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local i18n = ctx.i18n
  local h = ctx.h or 200

  local cursorY = y
  for g = 1, #SENSOR_GROUP_ORDER do
    local groupKey = SENSOR_GROUP_ORDER[g]
    local items = SENSOR_BY_GROUP[groupKey]
    if items and #items > 0 then
      Controls.appendSectionHeader(
        children,
        x,
        cursorY,
        w,
        SENSOR_GROUP_TITLES[groupKey] or groupKey,
        ui.sections[groupKey] == true,
        ui.runtime.getSectionToggleHandler(groupKey)
      )
      cursorY = cursorY + Controls.SECTION_H

      if ui.sections[groupKey] == true then
        for i = 1, #items do
          local sensorId = items[i].id
          local label = items[i].name
          cursorY = cursorY + Controls.appendRadioSwitch(
            children,
            x,
            cursorY,
            w,
            label,
            getBoolGetter(sensorId),
            getBoolSetter(sensorId)
          )
        end
      end

      cursorY = cursorY + 8
    end
  end

  if ui.loading then
    local title = pageText(i18n, "loading_title", "Loading")
    local message = pageText(i18n, "loading_message", "Reading telemetry config")
    if LoadingOverlay then
      LoadingOverlay.append(children, {
        x = x,
        y = y,
        w = w,
        h = h,
        title = title,
        message = message,
        progress = ui.progress
      })
    end
  end
end

function M.onClose()
  if type(ui.runtime) == "table" then
    setmetatable(ui.runtime, nil)
  end
  if Common and Common.resetPageState then
    Common.resetPageState(ui, {
      tablesToWipe = { "runtime" }
    })
  else
    ui.loaded = false
    ui.dirty = false
  end
  ui.runtimeBase = nil
  ui.loading = false
  ui.progress = 0
  Controls = nil
  Common = nil
  MspRuntime = nil
  TelemetryApi = nil
  ConfirmDialog = nil
  LoadingOverlay = nil
  t = nil
end

return M
