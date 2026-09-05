local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Version = nil
local MspRuntime = nil
local VariantApi = nil
local BoardInfoApi = nil
local BuildInfoApi = nil
local TelemetryConfigApi = nil
local LoadingOverlay = nil
local AsyncLoadUi = nil
local packetRateCacheKey = nil
local packetRateCacheText = "-"
local RFMD_SENSOR_CANDIDATES = { "RFMD", "Rfmd" }
local RFMD_MAP = {
  [0] = { mode = "25Hz", band = "900Mhz" },
  [1] = { mode = "50Hz", band = "900Mhz" },
  [2] = { mode = "100Hz", band = "900Mhz" },
  [3] = { mode = "100Hz Full", band = "900Mhz" },
  [4] = { mode = "150Hz", band = "900Mhz" },
  [5] = { mode = "200Hz", band = "900Mhz" },
  [6] = { mode = "200Hz Full", band = "900Mhz" },
  [7] = { mode = "250Hz", band = "900Mhz" },
  [8] = { mode = "333Hz Full", band = "900Mhz" },
  [9] = { mode = "500Hz", band = "900Mhz" },
  [10] = { mode = "D25", band = "900Mhz" },
  [11] = { mode = "K500 Full", band = "900Mhz" },
  [21] = { mode = "50Hz", band = "2.4GHz" },
  [22] = { mode = "100Hz", band = "2.4GHz" },
  [23] = { mode = "100Hz Full", band = "2.4GHz" },
  [24] = { mode = "150Hz", band = "2.4GHz" },
  [25] = { mode = "200Hz", band = "2.4GHz" },
  [26] = { mode = "200Hz Full", band = "2.4GHz" },
  [27] = { mode = "250Hz", band = "2.4GHz" },
  [28] = { mode = "333Hz Full", band = "2.4GHz" },
  [29] = { mode = "500Hz", band = "2.4GHz" },
  [30] = { mode = "D250", band = "2.4GHz" },
  [31] = { mode = "D500", band = "2.4GHz" },
  [32] = { mode = "F500", band = "2.4GHz" },
  [33] = { mode = "F1000", band = "2.4GHz" },
  [34] = { mode = "DK250", band = "2.4GHz" },
  [35] = { mode = "DK500", band = "2.4GHz" },
  [36] = { mode = "K1000", band = "2.4GHz" },
  [37] = { mode = "K1000", band = "2.4GHz" },
  [101] = { mode = "X100 Full", band = "900MHz" },
  [102] = { mode = "X150", band = "900MHz" }
}

-- The prefix every key on this page hangs under. It is spelled out here rather than built
-- inside the lookup, because .vscode/scripts/precompile_i18n.py reads it off this assignment
-- and uses it to resolve the calls below at package time -- which is the only time this tree
-- can be localised, since a packaged install carries i18n/init.lua and no locale table.
local keyPrefix = "app.pages.diagnostics_info"

-- One row per line of the page: the value to look up, the key its label lives under, and the
-- English label. The label was previously looked up under a key held in a variable, so the
-- packager could not see it and the lookup stayed a runtime one -- which on a packaged card
-- resolves to nothing. `labelKey`/`labelFallback` is the shape the packager does rewrite.
local ROWS = {
  { key = "version",            labelKey = "version",            labelFallback = "Version" },
  { key = "edgetx_version",     labelKey = "edgetx_version",     labelFallback = "EdgeTX Version" },
  { key = "rf_version",         labelKey = "rf_version",         labelFallback = "Rotorflight Version" },
  { key = "fc_version",         labelKey = "fc_version",         labelFallback = "FC Version" },
  { key = "fbl_uid",            labelKey = "fbl_uid",            labelFallback = "FBL Serial" },
  { key = "variant",            labelKey = "variant",            labelFallback = "Variant" },
  { key = "board_info",         labelKey = "board_info",         labelFallback = "Board Info" },
  { key = "build_info",         labelKey = "build_info",         labelFallback = "Build Info" },
  { key = "rf_mode",            labelKey = "rf_mode",            labelFallback = "RF Mode" },
  { key = "rf_band",            labelKey = "rf_band",            labelFallback = "RF Band" },
  { key = "packet_rate",        labelKey = "packet_rate",        labelFallback = "Packet Ratio" },
  { key = "msp_version",        labelKey = "msp_version",        labelFallback = "MSP Version" },
  { key = "msp_transport",      labelKey = "msp_transport",      labelFallback = "MSP Transport" },
  { key = "supported_versions", labelKey = "supported_versions", labelFallback = "Supported MSP API" },
  { key = "simulation",         labelKey = "simulation",         labelFallback = "Simulation" }
}

local state = {
  started = false,
  attached = false,
  pendingStart = false,
  deferStartBuild = false,
  forceReload = false,
  loading = false,
  showLoadingOverlay = false,
  loadingStartedAt = 0,
  loadingTimeoutSec = 12,
  refreshIntervalSec = 45,
  packetRateRefreshSec = 1.2,
  lastFetchAt = 0,
  lastPacketRateFetchAt = 0,
  packetRateRequestPending = false,
  progress = 0,
  done = 0,
  total = 0,
  errorMessage = nil,
  errorDialogShown = nil,
  rebuild = nil,
  i18n = nil,
  values = {
    fc_version = nil,
    rf_version = nil,
    variant = "-",
    board_info = "-",
    build_info = "-",
    packet_rate = "-"
  }
}

local function ensureCoreDeps()
  if not Version then
    Version = loadModule("lib/version.lua")
  end
  if not MspRuntime then
    MspRuntime = loadModule("tasks/msp/runtime.lua")
  end
  if not AsyncLoadUi then
    AsyncLoadUi = loadModule("app/pages/lib/async_load_ui.lua")
  end
end

local function isFblConnected()
  ensureCoreDeps()
  local runtimeState = MspRuntime and MspRuntime.getState and MspRuntime.getState() or nil
  if type(runtimeState) == "table" then
    if runtimeState.isSimulator == true or runtimeState.lastConnected == true then
      return true
    end
  end
  local root = type(_G) == "table" and _G.rfsuite or nil
  local session = root and root.session
  if type(session) == "table" and session.isConnected == true then
    return true
  end
  return false
end

local function ensureLiveDeps()
  ensureCoreDeps()
  if not VariantApi then
    VariantApi = loadModule("tasks/msp/api/variant.lua")
  end
  if not BoardInfoApi then
    BoardInfoApi = loadModule("tasks/msp/api/board_info.lua")
  end
  if not BuildInfoApi then
    BuildInfoApi = loadModule("tasks/msp/api/build_info.lua")
  end
  if not TelemetryConfigApi then
    TelemetryConfigApi = loadModule("tasks/msp/api/telemetry_config.lua")
  end
  if not LoadingOverlay then
    LoadingOverlay = loadModule("ui/loading_overlay.lua")
  end
end

local function t(i18n, key, fallback)
  if i18n and i18n.t then
    local full = keyPrefix .. "." .. key
    local val = i18n.t(full, fallback)
    if val ~= nil and val ~= full then
      return val
    end
  end
  return fallback
end

local function readRuntimeField(name, fallback)
  local raw = nil
  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return fallback end

  local diagnostics = root.diagnostics
  if type(diagnostics) == "table" and diagnostics[name] ~= nil then
    raw = diagnostics[name]
  else
    local session = root.session
    if type(session) == "table" and session[name] ~= nil then
      raw = session[name]
    end
  end

  if raw == nil then
    return fallback
  end

  return tostring(raw)
end

local function readEdgeTxVersion()
  if type(system) == "table" and type(system.getVersion) == "function" then
    local ok, v = pcall(system.getVersion)
    if ok and type(v) == "table" then
      if v.major and v.minor and v.revision then
        return string.format("%s.%s.%s", tostring(v.major), tostring(v.minor), tostring(v.revision))
      end
      if v.version then
        return tostring(v.version)
      end
    end
  end

  if type(getVersion) == "function" then
    local ok, a = pcall(getVersion)
    if ok and type(a) == "string" and a ~= "" then
      return a
    end
  end

  return "-"
end

local function readSimulationState()
  if type(getVersion) == "function" then
    local ok, _, fw = pcall(getVersion)
    if ok and type(fw) == "string" then
      return string.sub(string.lower(fw), -4) == "simu" and "ON" or "OFF"
    end
  end
  return "OFF"
end

local function formatPacketRate(value)
  local numeric = tonumber(value)
  local quantized = nil
  if numeric and numeric > 0 then
    quantized = math.floor(numeric + 0.5)
    if quantized <= 0 then
      quantized = nil
    end
  end

  if packetRateCacheKey == quantized then
    return packetRateCacheText
  end

  packetRateCacheKey = quantized
  if quantized == nil then
    packetRateCacheText = "-"
  else
    packetRateCacheText = "1:" .. tostring(quantized)
  end

  return packetRateCacheText
end

local function readLiveRfInfo()
  if type(getValue) ~= "function" then
    return "-", "-"
  end

  for i = 1, #RFMD_SENSOR_CANDIDATES do
    local ok, value = pcall(getValue, RFMD_SENSOR_CANDIDATES[i])
    if ok and type(value) == "number" then
      local rfmd = math.floor(value + 0.5)
      local info = RFMD_MAP[rfmd]
      if info then
        return info.mode or "-", info.band or "-"
      end
      break
    end
  end

  return "-", "-"
end

local function buildInfoValues()
  ensureCoreDeps()
  local runtimeState = MspRuntime and MspRuntime.getState and MspRuntime.getState() or nil
  local transport = "-"
  if type(runtimeState) == "table" then
    if runtimeState.isSimulator == true then
      transport = "SIMULATOR"
    elseif runtimeState.protocol and runtimeState.protocol ~= "" then
      transport = runtimeState.protocol
    end
  end
  if transport == "-" then
    transport = readRuntimeField("mspProtocol", "-")
  end
  local rfMode, rfBand = readLiveRfInfo()

  return {
    version = Version.getVersionString and Version.getVersionString() or "-",
    edgetx_version = readEdgeTxVersion(),
    rf_version = state.values.rf_version or readRuntimeField("rfVersion", "-"),
    fc_version = state.values.fc_version or readRuntimeField("fcVersion", "-"),
    fbl_uid = readRuntimeField("mcu_id", "-"),
    variant = state.values.variant,
    board_info = state.values.board_info,
    build_info = state.values.build_info,
    rf_mode = rfMode,
    rf_band = rfBand,
    packet_rate = state.values.packet_rate or "-",
    msp_version = readRuntimeField("apiVersion", "-"),
    msp_transport = string.upper(tostring(transport or "-")),
    supported_versions = (Version.getSupportedMspApiVersionsString and Version.getSupportedMspApiVersionsString()) or "-",
    simulation = readSimulationState()
  }
end

local function requestRebuild()
  if type(state.rebuild) == "function" then
    state.rebuild()
  end
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then
      return ticks / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function readRuntimeErrorMessage()
  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return nil end
  local diagnostics = root.diagnostics
  if type(diagnostics) == "table" and diagnostics.mspLastError and diagnostics.mspLastError ~= "" then
    return tostring(diagnostics.mspLastError)
  end
  local session = root.session
  if type(session) == "table" and session.mspLastError and session.mspLastError ~= "" then
    return tostring(session.mspLastError)
  end
  return nil
end

local function markStepDone()
  if AsyncLoadUi.stepDone(state) then
    state.lastFetchAt = nowSeconds()
  end
  requestRebuild()
end

local function abortLoading(i18n, reason)
  if AsyncLoadUi and type(AsyncLoadUi.fail) == "function" then
    AsyncLoadUi.fail(state, i18n or state.i18n, t, reason)
  else
    state.loading = false
    state.showLoadingOverlay = false
    state.errorMessage = tostring(reason or "Loading failed")
  end
  requestRebuild()
end

local function startLiveLoad()
  if not isFblConnected() then
    state.started = false
    state.forceReload = false
    return
  end
  ensureLiveDeps()

  local forced = state.forceReload == true
  if state.started and not state.forceReload then
    return
  end
  state.started = true
  state.forceReload = false

  if MspRuntime and type(MspRuntime.attach) == "function" and not state.attached then
    MspRuntime.attach("info-page")
    state.attached = true
  end

  local runtimeState = MspRuntime and MspRuntime.getState and MspRuntime.getState() or nil
  local queue = runtimeState and runtimeState.queue

  if type(queue) ~= "table" or type(queue.add) ~= "function" then
    state.started = false
    return
  end

  local now = nowSeconds()
  local hasCachedSlowFields = (state.values.variant and state.values.variant ~= "-")
    and (state.values.board_info and state.values.board_info ~= "-")
    and (state.values.build_info and state.values.build_info ~= "-")
  local cacheFresh = state.lastFetchAt > 0 and (now - state.lastFetchAt) < state.refreshIntervalSec

  if hasCachedSlowFields and cacheFresh and not forced then
    state.loading = false
    state.showLoadingOverlay = false
    state.progress = 1
    state.done = state.total
    return
  end

  -- Show the same progress overlay pattern used by other MSP read flows.
  AsyncLoadUi.begin(state, nowSeconds(), 4, true)

  local function onFailure(name, cmd)
    local runtimeMsg = readRuntimeErrorMessage()
    local details = runtimeMsg or (tostring(name or "MSP") .. " timed out / failed (cmd=" .. tostring(cmd or "?") .. ")")
    abortLoading(state.i18n, details)
  end

  queue:add({
    client = "info-page",
    command = VariantApi.command,
    simulatorResponse = VariantApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.5,
    processReply = function(_, buf)
      local parsed = VariantApi.parse(buf)
      if parsed and parsed.variant and parsed.variant ~= "" then
        state.values.variant = parsed.variant
      end
      markStepDone()
    end,
    errorHandler = function() onFailure("VARIANT", VariantApi.command) end
  })

  queue:add({
    client = "info-page",
    command = BoardInfoApi.command,
    simulatorResponse = BoardInfoApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.5,
    processReply = function(_, buf)
      local parsed = BoardInfoApi.parse(buf)
      if parsed then
        -- The names are the ones the parser sets. They used to be read as boardName/boardId,
        -- which it never returned, so this line showed the fallback whatever the board said.
        if parsed.board_name and parsed.board_name ~= "" then
          state.values.board_info = parsed.board_name
        elseif parsed.board_identifier and parsed.board_identifier ~= "" then
          state.values.board_info = parsed.board_identifier
        end
      end
      markStepDone()
    end,
    errorHandler = function() onFailure("BOARD_INFO", BoardInfoApi.command) end
  })

  queue:add({
    client = "info-page",
    command = BuildInfoApi.command,
    simulatorResponse = BuildInfoApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.5,
    processReply = function(_, buf)
      local parsed = BuildInfoApi.parse(buf)
      if parsed and parsed.buildInfo and parsed.buildInfo ~= "" then
        state.values.build_info = parsed.buildInfo
      end
      markStepDone()
    end,
    errorHandler = function() onFailure("BUILD_INFO", BuildInfoApi.command) end
  })

  queue:add({
    client = "info-page",
    command = TelemetryConfigApi.command,
    simulatorResponse = TelemetryConfigApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.5,
    processReply = function(_, buf)
      local parsed = TelemetryConfigApi.parse(buf)
      if parsed then
        state.values.packet_rate = formatPacketRate(parsed.crsf_telemetry_link_ratio)
      else
        state.values.packet_rate = "-"
      end
      markStepDone()
    end,
    errorHandler = function() onFailure("TELEMETRY_CONFIG", TelemetryConfigApi.command) end
  })

  requestRebuild()
end

local function queueLiveLoad(force)
  state.started = false
  state.forceReload = force == true
  state.deferStartBuild = true
  if force == true then
    state.lastFetchAt = 0
    state.errorMessage = nil
    state.errorDialogShown = nil
  end
  state.pendingStart = true
  requestRebuild()
end

local function pollPacketRateLive()
  if not isFblConnected() then
    state.packetRateRequestPending = false
    return
  end
  if state.loading then
    return
  end

  local now = nowSeconds()
  if state.packetRateRequestPending then
    return
  end
  if (now - (state.lastPacketRateFetchAt or 0)) < (state.packetRateRefreshSec or 1.2) then
    return
  end

  ensureLiveDeps()

  local runtimeState = MspRuntime and MspRuntime.getState and MspRuntime.getState() or nil
  local queue = runtimeState and runtimeState.queue
  if type(queue) ~= "table" or type(queue.add) ~= "function" then
    return
  end

  state.packetRateRequestPending = true
  state.lastPacketRateFetchAt = now

  queue:add({
    client = "info-page",
    command = TelemetryConfigApi.command,
    simulatorResponse = TelemetryConfigApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.0,
    processReply = function(_, buf)
      local parsed = TelemetryConfigApi.parse(buf)
      local newRate = "-"
      if parsed then
        newRate = formatPacketRate(parsed.crsf_telemetry_link_ratio)
      end
      local changed = (state.values.packet_rate ~= newRate)
      state.values.packet_rate = newRate
      state.packetRateRequestPending = false
      if changed then
        requestRebuild()
      end
    end,
    errorHandler = function()
      state.packetRateRequestPending = false
    end
  })
end

function M.getModuleTitle()
  return "Info"
end

function M.getHeaderActions()
  return { reload = true, save = false, help = true }
end

function M.onReload()
  if not isFblConnected() then
    abortLoading(state.i18n, t(state.i18n, "not_connected", "Telemetry / FBL not connected"))
    return false
  end
  queueLiveLoad(true)
  return false
end

function M.isPageOpen()
  return true
end

function M.build(ctx)
  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  state.i18n = i18n
  state.rebuild = ctx.requestRebuild
  if not isFblConnected() then
    state.pendingStart = false
    state.deferStartBuild = false
  elseif not state.started and not state.pendingStart then
    state.pendingStart = true
    state.deferStartBuild = true
  end

  -- Defer one build so page content appears immediately, then start MSP load.
  if state.pendingStart and state.deferStartBuild then
    state.deferStartBuild = false
    requestRebuild()
  elseif state.pendingStart and not state.loading then
    state.pendingStart = false
    startLiveLoad()
  end

  local values = buildInfoValues()
  local rowY = y + 6
  local rowH = 44
  local labelW = math.floor(w * 0.56)
  local valueX = x + labelW
  local valueW = w - labelW

  for i = 1, #ROWS do
    local row = ROWS[i]
    local key = row.key
    local thisY = rowY + (i - 1) * rowH
    local labelText = t(i18n, row.labelKey, row.labelFallback)
    local valueText = values[key] or "-"

    children[#children + 1] = {
      type = "label",
      x = x,
      y = thisY + 8,
      w = labelW - 10,
      text = labelText,
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "label",
      x = valueX,
      y = thisY + 8,
      w = valueW - 6,
      text = tostring(valueText),
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

  if state.loading and state.showLoadingOverlay then
    if AsyncLoadUi and AsyncLoadUi.isTimedOut(state, nowSeconds()) then
      abortLoading(i18n, readRuntimeErrorMessage() or t(i18n, "loading_timeout", "Timeout while reading from FBL"))
    end
    local title = t(i18n, "loading_title", "Loading")
    local message = string.format("%s %d/%d", t(i18n, "loading_message", "Reading live data"), state.done, state.total)
    LoadingOverlay.append(children, {
      x = x,
      y = y,
      w = w,
      h = h,
      title = title,
      message = message,
      progress = state.progress
    })
  elseif state.errorMessage and state.errorMessage ~= "" then
    AsyncLoadUi.appendErrorNotice(children, {
      x = x,
      y = y,
      w = w,
      h = h,
      overlay = LoadingOverlay,
      requestRebuild = state.rebuild
    }, state, i18n, t)
  end
end

function M.wakeup()
  local now = nowSeconds()
  if state.loading then
    if not isFblConnected() then
      abortLoading(state.i18n, t(state.i18n, "link_lost", "Telemetry link lost"))
      return
    end
    if AsyncLoadUi and type(AsyncLoadUi.isTimedOut) == "function" and AsyncLoadUi.isTimedOut(state, now) then
      abortLoading(state.i18n, readRuntimeErrorMessage() or t(state.i18n, "loading_timeout", "Timeout while reading from FBL"))
      return
    end
  else
    local connected = isFblConnected()
    if connected and not state.started and not state.pendingStart then
      queueLiveLoad(false)
      return
    end
  end

  pollPacketRateLive()
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  ensureCoreDeps()
  if state.attached and MspRuntime and type(MspRuntime.detach) == "function" then
    MspRuntime.detach("info-page")
  end
  local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
  local queue = runtimeState and runtimeState.queue
  if queue and type(queue.clear) == "function" then
    queue:clear("info-page")
  end
  state.started = false
  state.attached = false
  state.pendingStart = false
  state.deferStartBuild = false
  state.forceReload = false
  state.packetRateRequestPending = false
  state.lastPacketRateFetchAt = 0
  state.i18n = nil
  if AsyncLoadUi and type(AsyncLoadUi.reset) == "function" then
    AsyncLoadUi.reset(state)
  end
  state.rebuild = nil

  VariantApi = nil
  BoardInfoApi = nil
  BuildInfoApi = nil
  TelemetryConfigApi = nil
  LoadingOverlay = nil
end

return M
