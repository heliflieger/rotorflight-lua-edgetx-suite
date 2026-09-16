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
local TelemetryApi = nil
local LoadingOverlay = nil
local t = nil

local SENSOR_CATALOG = {
  [3] = { label = "Battery Voltage", source = "Vbat" },
  [4] = { label = "Battery Current", source = "Curr" },
  [5] = { label = "Battery Consumption", source = "Capa" },
  [6] = { label = "Battery Charge Level", source = "Bat%" },
  [7] = { label = "Battery Cell Count", source = "Cel#" },
  [8] = { label = "Battery Cell Voltage", source = "Vcel" },
  [9] = { label = "Battery Cell Voltages", source = "Cels" },
  [10] = { label = "Control (Combined)", source = "Ctrl" },
  [11] = { label = "Pitch Control", source = "CPtc" },
  [12] = { label = "Roll Control", source = "CRol" },
  [13] = { label = "Yaw Control", source = "CYaw" },
  [14] = { label = "Collective Control", source = "CCol" },
  [15] = { label = "Throttle Control", source = "Thr" },
  [17] = { label = "ESC1 Voltage", source = "EscV" },
  [18] = { label = "ESC1 Current", source = "EscI" },
  [19] = { label = "ESC1 Consumption", source = "EscC" },
  [20] = { label = "ESC1 ERPM", source = "EscR" },
  [21] = { label = "ESC1 Power", source = "EscP" },
  [22] = { label = "ESC1 Throttle", source = "Esc%" },
  [23] = { label = "ESC1 Temp 1", source = "EscT" },
  [24] = { label = "ESC1 Temp 2", source = "BecT" },
  [25] = { label = "ESC1 BEC Voltage", source = "BecV" },
  [26] = { label = "ESC1 BEC Current", source = "BecI" },
  [27] = { label = "ESC1 Status", source = "EscF" },
  [28] = { label = "ESC1 Model", source = "Esc#" },
  [30] = { label = "ESC2 Voltage", source = "Es2V" },
  [31] = { label = "ESC2 Current", source = "Es2I" },
  [32] = { label = "ESC2 Consumption", source = "Es2C" },
  [33] = { label = "ESC2 ERPM", source = "Es2R" },
  [36] = { label = "ESC2 Temp", source = "Es2T" },
  [41] = { label = "ESC2 Model", source = "Es2#" },
  [42] = { label = "ESC Voltage", source = "Vesc" },
  [43] = { label = "BEC Voltage", source = "Vbec" },
  [44] = { label = "Bus Voltage", source = "Vbus" },
  [45] = { label = "MCU Voltage", source = "Vmcu" },
  [46] = { label = "ESC Current", source = "Iesc" },
  [47] = { label = "BEC Current", source = "Ibec" },
  [48] = { label = "Bus Current", source = "Ibus" },
  [49] = { label = "MCU Current", source = "Imcu" },
  [50] = { label = "ESC Temp", source = "Tesc" },
  [51] = { label = "BEC Temp", source = "Tbec" },
  [52] = { label = "MCU Temp", source = "Tmcu" },
  [57] = { label = "Heading", source = "Hdg" },
  [58] = { label = "Altitude", source = "Alt" },
  [59] = { label = "Vario", source = "Var" },
  [60] = { label = "Headspeed", source = "Hspd" },
  [61] = { label = "Tailspeed", source = "Tspd" },
  [64] = { label = "Attitude (Combined)", source = "Attd" },
  [65] = { label = "Pitch Attitude", source = "Ptch" },
  [66] = { label = "Roll Attitude", source = "Roll" },
  [67] = { label = "Yaw Attitude", source = "Yaw" },
  [68] = { label = "Accel (Combined)", source = "Accl" },
  [69] = { label = "Accel X", source = "AccX" },
  [70] = { label = "Accel Y", source = "AccY" },
  [71] = { label = "Accel Z", source = "AccZ" },
  [73] = { label = "GPS Sats", source = "Sats" },
  [74] = { label = "GPS PDOP", source = "PDOP" },
  [75] = { label = "GPS HDOP", source = "HDOP" },
  [76] = { label = "GPS VDOP", source = "VDOP" },
  [77] = { label = "GPS Coordinates", source = "GPS" },
  [78] = { label = "GPS Altitude", source = "GAlt" },
  [79] = { label = "GPS Heading", source = "GHdg" },
  [80] = { label = "GPS Speed", source = "GSpd" },
  [81] = { label = "GPS Home Distance", source = "GDis" },
  [82] = { label = "GPS Home Direction", source = "GDir" },
  [85] = { label = "CPU Load", source = "CPU%" },
  [86] = { label = "SYS Load", source = "SYS%" },
  [87] = { label = "RT Load", source = "RT%" },
  [88] = { label = "Model ID", source = "MDL#" },
  [89] = { label = "Flight Mode", source = "Mode" },
  [90] = { label = "Arming Flags", source = "ARM" },
  [91] = { label = "Arming Disable Flags", source = "ARMD" },
  [92] = { label = "Rescue State", source = "Resc" },
  [93] = { label = "Governor State", source = "Gov" },
  [95] = { label = "PID Profile", source = "PID#" },
  [96] = { label = "Rates Profile", source = "RTE#" },
  [97] = { label = "Battery Profile", source = "BAT#" },
  [98] = { label = "LED Profile", source = "LED#" },
  [99] = { label = "Adjustment Function", sources = { "AdjF", "AdjV" } },
}

local state = {
  loaded = false,
  readPending = false,
  loading = false,
  progress = 0,
  rows = {},
  rowSignature = "",
  lastSnapshot = "",
  lastReadAttemptAt = 0,
  rebuild = nil,
}

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
  if not TelemetryApi then TelemetryApi = loadModule("tasks/msp/api/telemetry_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("diagnostics_validate_sensors") or nil end
end

local function pageText(i18n, key, fallback)
  if t then return t(i18n, key, fallback) end
  return fallback
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function queueTelemetryRead()
  if state.readPending then
    return false
  end
  if not MspRuntime or not TelemetryApi or type(MspRuntime.getState) ~= "function" then
    return false
  end

  local runtimeState = MspRuntime.getState()
  local queue = runtimeState and runtimeState.queue
  if type(queue) ~= "table" or type(queue.add) ~= "function" then
    return false
  end

  local session = getSession()
  state.readPending = true
  state.loading = true
  state.progress = 0
  state.lastReadAttemptAt = nowSeconds()

  queue:add({
    command = TelemetryApi.command,
    simulatorResponse = TelemetryApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(_, buf)
      state.readPending = false
      state.loading = false
      state.progress = 1

      local parsed = TelemetryApi.parse and TelemetryApi.parse(buf) or nil
      if type(session) == "table" and type(parsed) == "table" then
        session.telemetry_config = parsed
      end

      if type(state.rebuild) == "function" then
        state.rebuild()
      end
    end,
    errorHandler = function()
      state.readPending = false
      state.loading = false
      state.progress = 1
    end
  })

  return true
end

local function buildConfiguredSensorIds(cfg)
  local ids = {}
  local seen = {}
  if type(cfg) ~= "table" then
    return ids
  end

  for i = 1, 40 do
    local id = tonumber(cfg["telem_sensor_slot_" .. tostring(i)])
    if id and id ~= 0 and not seen[id] then
      ids[#ids + 1] = id
      seen[id] = true
    end
  end

  return ids
end

local function hasTelemetryField(name)
  if type(name) ~= "string" or name == "" or type(getFieldInfo) ~= "function" then
    return false
  end
  local ok, info = pcall(getFieldInfo, name)
  return ok and type(info) == "table" and info.id ~= nil
end

local function hasNumericValue(name)
  if type(name) ~= "string" or name == "" or type(getValue) ~= "function" then
    return false
  end
  local ok, value = pcall(getValue, name)
  return ok and type(value) == "number"
end

local function rowColor(status)
  if status == "ok" then
    return type(GREEN) == "number" and GREEN or COLOR_THEME_PRIMARY1
  end
  if status == "novalue" then
    return type(ORANGE) == "number" and ORANGE or COLOR_THEME_PRIMARY1
  end
  return type(RED) == "number" and RED or COLOR_THEME_PRIMARY1
end

local function statusText(i18n, status)
  if status == "ok" then
    return pageText(i18n, "status_ok", "OK")
  end
  return pageText(i18n, "status_invalid", "INVALID")
end

local function isSourceAvailable(source)
  return hasTelemetryField(source) and hasNumericValue(source)
end

local function buildRows()
  local session = getSession()
  local cfg = type(session) == "table" and session.telemetry_config or nil
  local ids = buildConfiguredSensorIds(cfg)
  local rows = {}
  local sigParts = { tostring(#ids) }

  for i = 1, #ids do
    local id = ids[i]
    local meta = SENSOR_CATALOG[id]
    local label = meta and meta.label or ("Sensor #" .. tostring(id))
    local status = "invalid"
    local source = meta and meta.source or nil
    local sources = meta and meta.sources or nil

    if type(sources) == "table" and #sources > 0 then
      local allPresent = true
      local anyPresent = false
      for j = 1, #sources do
        local sourceName = sources[j]
        local present = isSourceAvailable(sourceName)
        if present then
          anyPresent = true
        else
          allPresent = false
        end
      end
      if allPresent then
        status = "ok"
      elseif anyPresent then
        status = "novalue"
      end
    else
      local exists = source and hasTelemetryField(source) or false
      local hasValue = exists and hasNumericValue(source) or false
      if hasValue then
        status = "ok"
      elseif exists then
        status = "novalue"
      end
    end

    rows[#rows + 1] = {
      id = id,
      label = label,
      status = status
    }
    sigParts[#sigParts + 1] = tostring(id) .. ":" .. status
  end

  return rows, table.concat(sigParts, "|")
end

local function refreshRows()
  local rows, signature = buildRows()
  if state.rowSignature == signature then
    return
  end
  state.rows = rows
  state.rowSignature = signature
  if type(state.rebuild) == "function" then
    state.rebuild()
  end
end

local function buildSnapshot()
  local session = getSession()
  local cfg = type(session) == "table" and session.telemetry_config or nil
  local ids = buildConfiguredSensorIds(cfg)
  local parts = { tostring(#ids) }
  for i = 1, #ids do
    parts[#parts + 1] = tostring(ids[i])
  end
  return table.concat(parts, "|")
end

local function ensureLoaded()
  if state.loaded then
    return
  end
  state.loaded = true
  refreshRows()

  local session = getSession()
  if not (type(session) == "table" and type(session.telemetry_config) == "table") then
    queueTelemetryRead()
  end
end

function M.getModuleTitle()
  return "Validate Sensors"
end

function M.getHeaderActions()
  return { reload = false, save = false, help = true }
end

function M.onReload()
  return false
end

function M.isPageOpen()
  return true
end

function M.build(ctx)
  ensureDeps()
  state.rebuild = ctx.requestRebuild
  ensureLoaded()
  refreshRows()

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h or 200

  local rowY = y + 6
  local rowH = 44
  local labelW = math.floor(w * 0.62)
  local valueX = x + labelW
  local valueW = w - labelW

  if #state.rows == 0 then
    children[#children + 1] = {
      type = "label",
      x = x,
      y = rowY + 8,
      w = w,
      text = pageText(ctx.i18n, "no_sensors", "No telemetry sensors configured."),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
  else
    for i = 1, #state.rows do
      local row = state.rows[i]
      local thisY = rowY + (i - 1) * rowH

      children[#children + 1] = {
        type = "label",
        x = x,
        y = thisY + 8,
        w = labelW - 10,
        text = row.label,
        color = COLOR_THEME_PRIMARY1,
        font = SMLSIZE
      }

      children[#children + 1] = {
        type = "label",
        x = valueX,
        y = thisY + 8,
        w = valueW - 6,
        text = statusText(ctx.i18n, row.status),
        color = rowColor(row.status),
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
  end

  if state.loading and LoadingOverlay then
    LoadingOverlay.append(children, {
      x = x,
      y = y,
      w = w,
      h = h,
      title = pageText(ctx.i18n, "loading_title", "Loading"),
      message = pageText(ctx.i18n, "loading_message", "Reading telemetry config"),
      progress = state.progress
    })
  end
end

function M.wakeup()
  if not state.loaded then
    return
  end

  local now = nowSeconds()
  local snapshot = buildSnapshot()
  if snapshot ~= state.lastSnapshot then
    state.lastSnapshot = snapshot
    refreshRows()
    return
  end

  if not state.readPending and not state.loading and (now - (state.lastReadAttemptAt or 0)) >= 0.8 then
    state.lastReadAttemptAt = now
    refreshRows()
  end

  local session = getSession()
  if not state.readPending
    and not state.loading
    and (type(session) ~= "table" or type(session.telemetry_config) ~= "table")
    and (now - (state.lastReadAttemptAt or 0)) >= 3.0 then
    queueTelemetryRead()
  end
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.loaded = false
  state.readPending = false
  state.loading = false
  state.progress = 0
  state.rows = {}
  state.rowSignature = ""
  state.lastSnapshot = ""
  state.lastReadAttemptAt = 0
  state.rebuild = nil

  Common = nil
  MspRuntime = nil
  TelemetryApi = nil
  LoadingOverlay = nil
  t = nil
end

function M.getValidationSummary(opts)
  opts = opts or {}

  ensureDeps()
  local session = getSession()
  local loaded = type(session) == "table" and type(session.telemetry_config) == "table"
  if opts.passive == true then
    if type(session) == "table" and type(session.telemetry_config) == "table" then
      local rows, signature = buildRows()
      if state.rowSignature ~= signature then
        state.rows = rows
        state.rowSignature = signature
      end
    end
  else
    ensureLoaded()
    refreshRows()
  end

  local okCount = 0
  for i = 1, #state.rows do
    if state.rows[i].status == "ok" then
      okCount = okCount + 1
    end
  end

  return {
    loaded = loaded,
    total = #state.rows,
    ok = okCount,
    invalid = #state.rows - okCount,
    rows = state.rows
  }
end

return M
