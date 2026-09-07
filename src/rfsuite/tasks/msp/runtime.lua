if type(_G) == "table" and type(_G.__rfsuite_msp_runtime_module) == "table" then
  return _G.__rfsuite_msp_runtime_module
end

local Runtime = {}

-- The runtime's own reads are filed under a client of their own, so that a page giving up, or
-- closing, cannot take the link's version and identity reads down with it.
local HOUSEKEEPING_CLIENT = "msp-runtime"

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then
    return nil
  end
  local ok, mod = pcall(chunk)
  if not ok then
    return nil
  end
  return mod
end

local DetectProtocol = nil
local CommonModule = nil
local QueueModule = nil
local ApiVersionApi = nil
local FcVersionApi = nil
local UidApi = nil
local Log = nil
local Version = nil
local ApiVersion = nil
local ModelPreferences = nil

local state = {
  initialized = false,
  available = false,
  protocol = nil,
  isSimulator = false,
  queue = nil,
  clients = {},
  values = {
    apiVersion = "",
    fcVersion = "",
    rfVersion = "",
    mcuId = nil,
    modelPreferences = nil,
    modelPreferencesFile = nil
  },
  unsupportedApi = false,
  limitedApi = false,
  unsupportedApiLogged = false,
  _disconnectHandled = false,
  requestBackoffUntil = 0,
  consecutiveApiVersionFailures = 0,
  consecutiveUidFailures = 0,
  mspLastError = nil,
  mspLastErrorAt = 0,
  pendingVersionRead = true,
  pendingUidRead = true,
  versionReadCompleted = false,
  lastArmed = nil,
  lastConnected = nil
}

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

-- The logging core's tagged emitter, bound on first use: the default level and the
-- console flag are lib/log.lua's, and this file states only its tag.
local taggedLog = nil
local function log(msg, level)
  if not taggedLog then
    if not Log then Log = loadModule("lib/log.lua") end
    if not (Log and type(Log.tagged) == "function") then return end
    taggedLog = Log.tagged("rfsuite.msp")
  end
  taggedLog(msg, level)
end

-- The transport does not load the log module itself -- it takes what it needs through the
-- options table, the same way it takes `common` -- so the three below are injected beside
-- `log` in the constructor at the bottom of this file.
--
-- `logf` differs from `log` in where the string is built: `log` takes a finished one, so its
-- caller concatenates whether or not anything is emitted. On the send path that happens on
-- every request and every retry, at `debug_level = off`, on every radio.
local function logf(level, fmt, ...)
  if not Log then
    Log = loadModule("lib/log.lua")
  end
  if Log and type(Log.emitf) == "function" then
    Log.emitf("rfsuite.msp", level, fmt, ...)
  end
end

-- For the sites where GATHERING the arguments is the cost, which is what a hex dump of a
-- response buffer is. They ask first and build second.
local function logWanted(level)
  if not Log then
    Log = loadModule("lib/log.lua")
  end
  return Log ~= nil and type(Log.wanted) == "function" and Log.wanted(level) == true
end

local function logHex(buf, limit)
  if Log and type(Log.hex) == "function" then
    return Log.hex(buf, limit)
  end
  return "-"
end

local function ensureBaseDeps()
  if not DetectProtocol then
    DetectProtocol = loadModule("tasks/msp/protocols.lua")
  end
  if not CommonModule then
    CommonModule = loadModule("tasks/msp/common.lua")
  end
  if not QueueModule then
    QueueModule = loadModule("tasks/msp/queue.lua")
  end
end

local function ensureVersionDeps()
  if not ApiVersionApi then
    ApiVersionApi = loadModule("tasks/msp/api/api_version.lua")
  end
  if not FcVersionApi then
    FcVersionApi = loadModule("tasks/msp/api/fc_version.lua")
  end
  if not Version then
    Version = loadModule("lib/version.lua")
  end
  if not ApiVersion then
    ApiVersion = loadModule("lib/api_version.lua")
  end
  return ApiVersionApi ~= nil and FcVersionApi ~= nil and Version ~= nil and ApiVersion ~= nil
end

local function ensureUidDep()
  if not UidApi then
    UidApi = loadModule("tasks/msp/api/uid.lua")
  end
  if not ModelPreferences then
    ModelPreferences = loadModule("lib/model_preferences.lua")
  end
  return UidApi ~= nil and ModelPreferences ~= nil
end

local function ensureRootState()
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.session = _G.rfsuite.session or {}
  _G.rfsuite.diagnostics = _G.rfsuite.diagnostics or {}
end

-- The request facade is loaded once, on the first publish, and never again whether it loaded or
-- not. It is loaded here rather than at the top of this file because it loads this module in
-- turn: by the time anything publishes, both are past their own chunk and the lookup is a table
-- read.
local serviceLoadAttempted = false

local function publishService()
  if serviceLoadAttempted then
    return
  end
  serviceLoadAttempted = true

  local Service = loadModule("tasks/msp/service.lua")
  if type(Service) == "table" then
    _G.rfsuite.msp = Service
  end
end

local function computeFblConnected(s)
  local target = s or state
  if type(target) ~= "table" then return false end
  return (target.lastConnected == true)
    and (target.versionReadCompleted == true)
    and (not target.unsupportedApi)
    and (type(target.values) == "table" and type(target.values.apiVersion) == "string" and target.values.apiVersion ~= "" and target.values.apiVersion ~= "0")
end

local function publish()
  ensureRootState()
  publishService()
  local session = _G.rfsuite.session
  local diagnostics = _G.rfsuite.diagnostics

  local isFblConnected = computeFblConnected(state)

  session.fblConnected = isFblConnected
  session.rawRfConnected = state.lastConnected == true
  session.apiVersion = state.values.apiVersion
  session.fcVersion = state.values.fcVersion
  session.rfVersion = state.values.rfVersion
  session.mcu_id = state.values.mcuId
  if state.values.mcuId == nil then
    session.modelPreferences = nil
    session.modelPreferencesFile = nil
  elseif session.modelPreferences == nil then
    session.modelPreferences = state.values.modelPreferences
    session.modelPreferencesFile = state.values.modelPreferencesFile
  end
  session.apiSupported = not state.unsupportedApi
  session.apiLimited = state.limitedApi == true
  session.mspLastError = state.mspLastError
  session.mspLastErrorAt = state.mspLastErrorAt
  session.mspErrorKind = state.mspErrorKind
  session.telemetryType = state.protocol
  diagnostics.fblConnected = isFblConnected
  diagnostics.rawRfConnected = state.lastConnected == true
  diagnostics.apiVersion = state.values.apiVersion
  diagnostics.fcVersion = state.values.fcVersion
  diagnostics.rfVersion = state.values.rfVersion
  diagnostics.mcu_id = state.values.mcuId
  diagnostics.apiSupported = not state.unsupportedApi
  diagnostics.apiLimited = state.limitedApi == true
  diagnostics.mspLastError = state.mspLastError
  diagnostics.mspLastErrorAt = state.mspLastErrorAt
  diagnostics.mspErrorKind = state.mspErrorKind
end

local function setMspError(message, now, kind)
  state.mspLastError = tostring(message or "")
  state.mspLastErrorAt = now or nowSeconds()
  state.mspErrorKind = kind or (message and "error" or nil)
end

local function isApiVersionSupported(version)
  if type(version) ~= "string" or version == "" then
    return false
  end

  if not Version then
    Version = loadModule("lib/version.lua")
  end

  if not Version or type(Version.getSupportedMspApiVersions) ~= "function" then
    return true
  end

  local supported = Version.getSupportedMspApiVersions()
  if type(supported) ~= "table" then
    return true
  end

  for i = 1, #supported do
    if tostring(supported[i]) == version then
      return true
    end
  end

  return false
end

local function getOldestSupportedApiVersionParsed()
  if not Version then
    Version = loadModule("lib/version.lua")
  end
  if not ApiVersion then
    ApiVersion = loadModule("lib/api_version.lua")
  end
  if not Version or not ApiVersion then
    return nil
  end
  if type(Version.getSupportedMspApiVersions) ~= "function" or type(ApiVersion.parse) ~= "function" then
    return nil
  end

  local supported = Version.getSupportedMspApiVersions()
  if type(supported) ~= "table" or #supported == 0 then
    return nil
  end

  local oldest = nil
  for i = 1, #supported do
    local parsed = ApiVersion.parse(supported[i])
    if type(parsed) == "table" then
      if not oldest then
        oldest = parsed
      elseif ApiVersion.isAtLeast and ApiVersion.isAtLeast(oldest, parsed) then
        oldest = parsed
      end
    end
  end

  return oldest
end

local function isApiVersionLimitedCompatible(version)
  if type(version) ~= "string" or version == "" then
    return false
  end
  if not Version then
    Version = loadModule("lib/version.lua")
  end
  if not ApiVersion then
    ApiVersion = loadModule("lib/api_version.lua")
  end
  if not Version or not ApiVersion then
    return false
  end
  if type(ApiVersion.parse) ~= "function" or type(ApiVersion.isAtLeast) ~= "function" then
    return false
  end
  if type(Version.getLatestSupportedMspApiVersion) ~= "function" then
    return false
  end

  local current = ApiVersion.parse(version)
  local latest = ApiVersion.parse(Version.getLatestSupportedMspApiVersion())
  if type(current) ~= "table" or type(latest) ~= "table" then
    return false
  end

  local oldest = getOldestSupportedApiVersionParsed() or latest

  local currentMajor = tonumber(current[1]) or -1
  local latestMajor = tonumber(latest[1]) or -2
  return currentMajor == latestMajor
    and ApiVersion.isAtLeast(current, oldest)
end

local function isSimulator()
  if type(system) == "table" and type(system.getVersion) == "function" then
    local ok, info = pcall(system.getVersion)
    if ok and type(info) == "table" then
      local sim = info.simulation
      if sim ~= nil and sim ~= false and sim ~= 0 then
        return true
      end
    end
  end
  if type(getVersion) == "function" then
    local ok, _, fw = pcall(getVersion)
    if ok and type(fw) == "string" then
      local fwl = string.lower(fw)
      if string.find(fwl, "simu", 1, true) ~= nil then
        return true
      end
    end
  end
  return false
end

local ARM_SOURCES = { "ARM", "Arm", "ARMF", "ArmF" }

local function readArmedState()
  if type(getValue) ~= "function" then
    return false
  end

  for i = 1, #ARM_SOURCES do
    local ok, value = pcall(getValue, ARM_SOURCES[i])
    if ok and value ~= nil then
      if type(value) == "number" then
        if type(bit32) == "table" and type(bit32.btest) == "function" then
          return bit32.btest(value, 1)
        end
        return value ~= 0
      end
      if type(value) == "boolean" then
        return value
      end
      if type(value) == "string" then
        local n = tonumber(value)
        if type(n) == "number" then
          return n ~= 0
        end
      end
    end
  end

  return false
end

local function isConnected()
  if state.isSimulator then
    return true
  end
  if type(getRSSI) ~= "function" then
    return true
  end
  local ok, rssi = pcall(getRSSI)
  if not ok or type(rssi) ~= "number" then
    return true
  end
  return rssi > 0
end

local function applyModelPreferencesForMcu(mcuId)
  if type(mcuId) ~= "string" or mcuId == "" then
    state.values.modelPreferences = nil
    state.values.modelPreferencesFile = nil
    if _G and _G.rfsuite and _G.rfsuite.session then
      _G.rfsuite.session.modelPreferences = nil
      _G.rfsuite.session.modelPreferencesFile = nil
    end
    return
  end

  if not ModelPreferences then
    ModelPreferences = loadModule("lib/model_preferences.lua")
  end

  if not ModelPreferences or type(ModelPreferences.loadByMcuId) ~= "function" then
    state.values.modelPreferences = nil
    state.values.modelPreferencesFile = nil
    return
  end

  local prefs, filePath = ModelPreferences.loadByMcuId(mcuId, true)
  state.values.modelPreferences = prefs
  state.values.modelPreferencesFile = filePath
  if _G and _G.rfsuite and _G.rfsuite.session then
    _G.rfsuite.session.modelPreferences = prefs
    _G.rfsuite.session.modelPreferencesFile = filePath
  end
end

local function enqueueVersionReads(now)
  if not state.pendingVersionRead then
    return true
  end
  if not state.queue or not state.queue:isProcessed() then
    return true
  end
  if state.requestBackoffUntil and now < state.requestBackoffUntil then
    return true
  end

  if not ensureVersionDeps() then
    return false
  end
  state.pendingVersionRead = false
  state.queue:add({
    client = HOUSEKEEPING_CLIENT,
    command = ApiVersionApi.command,
    simulatorResponse = ApiVersionApi.simulatorResponse,
    timeout = 1.5,
    maxRetries = 3,
    processReply = function(_, buf)
      local parsed = ApiVersionApi.parse(buf)
      if parsed and parsed.version then
        state.consecutiveApiVersionFailures = 0
        state.requestBackoffUntil = 0
        state.mspLastError = nil
        state.mspLastErrorAt = 0
        state.values.apiVersion = parsed.version
        local fullySupported = isApiVersionSupported(parsed.version)
        local limitedCompatible = (not fullySupported) and isApiVersionLimitedCompatible(parsed.version)
        state.unsupportedApi = not (fullySupported or limitedCompatible)
        state.limitedApi = limitedCompatible
        if limitedCompatible then
          log("MSP API version " .. tostring(parsed.version) .. " accepted in limited compatibility mode", "warn")
        end
        if state.unsupportedApi and not state.unsupportedApiLogged then
          state.unsupportedApiLogged = true
          log("Unsupported MSP API version " .. tostring(parsed.version) .. " (supported: " .. tostring(Version and Version.getSupportedMspApiVersionsString and Version.getSupportedMspApiVersionsString() or "-") .. ")", "warn")
          state.queue:clear()
        end
      end
      state.versionReadCompleted = true
      publish()
    end,
    errorHandler = function(msg, reason)
      if reason == "cleared" then return end
      state.consecutiveApiVersionFailures = (state.consecutiveApiVersionFailures or 0) + 1
      local backoff = math.min(30, 2 + state.consecutiveApiVersionFailures * 2)
      state.requestBackoffUntil = nowSeconds() + backoff
      setMspError("No MSP reply from flight controller (cmd=1). Check that FEATURE_TELEMETRY is enabled and the MSP serial port is configured.", nowSeconds(), "no_reply")
      log("API_VERSION read failed repeatedly (no MSP reply); backoff " .. tostring(backoff) .. "s", "warn")
      state.pendingVersionRead = true
      publish()
    end
  })

  state.queue:add({
    client = HOUSEKEEPING_CLIENT,
    command = FcVersionApi.command,
    simulatorResponse = FcVersionApi.simulatorResponse,
    timeout = 1.5,
    maxRetries = 3,
    processReply = function(_, buf)
      local parsed = FcVersionApi.parse(buf)
      if parsed then
        state.values.fcVersion = parsed.fcVersion or state.values.fcVersion
        state.values.rfVersion = parsed.rfVersion or state.values.rfVersion
      end
      publish()
    end
  })
  
  return true
end

local function enqueueUidRead(now)
  if not state.pendingUidRead then
    return true
  end
  -- UID read must only be enqueued AFTER API version read has completed successfully.
  -- The API version determines whether the suite can communicate with the FC at all.
  if not state.versionReadCompleted or state.unsupportedApi then
    return true
  end
  if not state.values.apiVersion or state.values.apiVersion == "" or state.values.apiVersion == "0" then
    return true
  end
  if not state.queue or not state.queue:isProcessed() then
    return true
  end
  if state.requestBackoffUntil and now < state.requestBackoffUntil then
    return true
  end
  if not ensureUidDep() then
    return false
  end
  if not UidApi or type(UidApi.parse) ~= "function" then
    state.pendingUidRead = false
    return true
  end

  state.pendingUidRead = false
  state.queue:add({
    client = HOUSEKEEPING_CLIENT,
    command = UidApi.command,
    simulatorResponse = UidApi.simulatorResponse,
    timeout = 1.5,
    maxRetries = 2,
    processReply = function(_, buf)
      local parsed = UidApi.parse(buf)
      if parsed and parsed.mcuId and parsed.mcuId ~= "" then
        state.consecutiveUidFailures = 0
        state.values.mcuId = tostring(parsed.mcuId)
        applyModelPreferencesForMcu(state.values.mcuId)
      end
      publish()
    end,
    errorHandler = function(msg, reason)
      if reason == "cleared" then return end
      state.consecutiveUidFailures = (state.consecutiveUidFailures or 0) + 1
      local backoff = math.min(30, 2 + state.consecutiveUidFailures * 2)
      state.requestBackoffUntil = nowSeconds() + backoff
      state.pendingUidRead = true
      log("UID read failed (cmd=2); backoff " .. tostring(backoff) .. "s", "warn")
      publish()
    end
  })
  
  return true
end

-- `keepLink` is for a refusal rather than a loss: everything a disconnect does to the runtime's
-- own state still happens, but the link is NOT reported as gone.
--
-- Reporting it as gone while it is up is what made the unsupported-API path cycle. `tick`
-- compares `isConnected()` against `lastConnected`, so setting the latter to false on a live
-- link makes the very next tick a fresh CONNECT edge -- and that edge resets `unsupportedApi`,
-- `unsupportedApiLogged` and `_disconnectHandled`, i.e. exactly the three latches this path
-- depends on. The version is then read again, parses fine, is refused again, and the whole thing
-- repeats at MSP round-trip period with a queue clear and a warning every lap. Backoff cannot
-- catch it either: the read SUCCEEDS, so `processReply` zeroes the failure counters first.
local function doDisconnect(now, reason, keepLink)
  -- Make disconnect idempotent to avoid log spam when called repeatedly.
  if state._disconnectHandled then
    return
  end
  state._disconnectHandled = true
  -- Ensure runtime reflects disconnected state.
  if not keepLink then
    state.lastConnected = false
    state.mspLastError = nil
    state.mspLastErrorAt = 0
    state.mspErrorKind = nil
    state.consecutiveApiVersionFailures = 0
    state.requestBackoffUntil = 0
  else
    if type(reason) == "string" and reason ~= "" then
      setMspError(reason, now)
    end
  end

  if type(reason) == "string" and reason ~= "" then
    log("MSP link disconnected (" .. tostring(reason) .. ")", "info")
  else
    log("MSP link disconnected", "info")
  end
  if state.queue and type(state.queue.clear) == "function" then
    state.queue:clear()
  end
  -- Nothing read from the previous link may answer for the next one: a reconnect can be the
  -- same board after a reboot, a different profile, or a different board entirely.
  local cache = loadModule("tasks/msp/cache.lua")
  if type(cache) == "table" and type(cache.clear) == "function" then
    cache.clear()
  end
  state.pendingVersionRead = true
  state.pendingUidRead = true
  state.versionReadCompleted = false
  state.limitedApi = false
  state.consecutiveApiVersionFailures = 0
  state.consecutiveUidFailures = 0
  state.requestBackoffUntil = 0
  state.mspLastError = nil
  state.mspLastErrorAt = 0
  state.values.apiVersion = "0"
  state.values.fcVersion = "0"
  state.values.rfVersion = "0"
  state.values.mcuId = nil
  state.values.modelPreferences = nil
  state.values.modelPreferencesFile = nil
  publish()
end

local function initIfNeeded()
  if state.initialized then
    return state.available
  end

  ensureBaseDeps()

  state.isSimulator = isSimulator()
  state.protocol = type(DetectProtocol) == "function" and DetectProtocol() or nil

  local common = nil
  if state.protocol and CommonModule and type(CommonModule.new) == "function" then
    common = CommonModule.new(state.protocol)
  end

  if not common and not state.isSimulator then
    state.available = false
    state.initialized = true
    log("MSP transport unavailable (no CRSF/GHST/SP)", "warn")
    return false
  end

  if not common then
    common = {
      sendRequest = function() end,
      processTxQ = function() end,
      pollReply = function() return nil end,
      clearTxBuf = function() end,
      clearRxBuf = function() end,
    }
  end

  if not QueueModule or type(QueueModule.new) ~= "function" then
    state.available = false
    state.initialized = true
    log("MSP queue module unavailable", "error")
    return false
  end

  state.queue = QueueModule.new(common, {
    log = log,
    logf = logf,
    wanted = logWanted,
    hex = logHex,
    isSimulator = state.isSimulator,
    maxRetries = state.protocol == "crsf" and 5 or 3,
    commandInterval = state.protocol == "crsf" and 0.15 or 0.25,
  })

  state.available = true
  state.initialized = true

  local proto = state.protocol or (state.isSimulator and "simulator") or "none"
  log("MSP runtime initialized via " .. tostring(proto), "info")
  publish()
  return true
end

--- Name the client that a request is filed under when its caller does not name one.
--
-- The pages reach the queue through getState() and queue their reads directly, and not one of
-- them says who it is. Rather than every call site having to be changed, the host names the
-- caller once when the screen changes: whatever is queued from then on belongs to the page that
-- is up, and clearing that client is enough to take its work back.
--
-- Brings the runtime up, because the queue it writes to does not exist before that.
function Runtime.setDefaultClient(clientId)
  if not initIfNeeded() then
    return false
  end
  if not state.queue then
    return false
  end
  state.queue.defaultClient = tostring(clientId or "default")
  return true
end

--- Drop a client's queued reads and leave its writes alone.
--
-- For a page that is being torn down. Its reads exist to fill widgets that are about to be
-- destroyed, and a reply arriving afterwards runs a processReply that closes over them. Its
-- writes are a different thing: those are changes asked of the flight controller, and they are
-- still wanted when nobody is looking at the page that asked for them.
function Runtime.dropClientReads(clientId)
  if clientId == nil then
    return false
  end
  if not state.queue or type(state.queue.clear) ~= "function" then
    return false
  end
  state.queue:clear(tostring(clientId), { keepWrites = true })
  return true
end

function Runtime.attach(clientId)
  local id = tostring(clientId or "unknown")
  state.clients[id] = true
  initIfNeeded()
end

function Runtime.detach(clientId)
  local id = tostring(clientId or "unknown")
  local wasAttached = state.clients[id] == true
  state.clients[id] = nil
  -- A client that has gone is not there to be told about its requests any more, and its reply
  -- handlers close over state it is in the middle of tearing down. Its queued work goes with
  -- it; work belonging to anything still attached keeps its place in the queue.
  if wasAttached and state.queue and type(state.queue.clear) == "function" then
    state.queue:clear(id)
  end
end

--- Put a message on the queue without handing out the queue itself.
--
-- Callers inside this package reach the queue through getState(), which returns the live state
-- table and everything in it. That is more than a caller outside the package should be given,
-- and more than one inside needs: queueing is the whole of what they do with it.
--
-- Returns false when the runtime could not be brought up, so a caller can tell "not sent" from
-- "sent and unanswered" instead of waiting for a reply that was never asked for.
function Runtime.enqueue(message)
  if type(message) ~= "table" then
    return false
  end
  if not initIfNeeded() then
    return false
  end
  if not state.queue or type(state.queue.add) ~= "function" then
    return false
  end
  state.queue:add(message)
  return true
end

--- Drop one queued message, named by its client and the id that client gave it.
function Runtime.cancel(clientId, requestId)
  if not state.queue or type(state.queue.cancel) ~= "function" then
    return false
  end
  return state.queue:cancel(clientId, requestId) == true
end

function Runtime.tick()
  if not initIfNeeded() then
    return false
  end

  local now = nowSeconds()
  local connected = isConnected()

  if state.lastConnected ~= connected then
    state.lastConnected = connected
    if connected then
      -- Reset disconnect guard when link becomes active again
      state._disconnectHandled = false
      -- Re-negotiate API support on each fresh connect.
      state.unsupportedApi = false
      state.limitedApi = false
      state.unsupportedApiLogged = false
      state.mspLastError = nil
      state.mspLastErrorAt = 0
      state.consecutiveApiVersionFailures = 0
      state.requestBackoffUntil = 0
      log("MSP link connected", "info")
      state.pendingVersionRead = true
      state.pendingUidRead = true
    else
      -- A real loss of the link. `lastConnected` is already false from the line above, so the
      -- refusal form is not wanted here.
      doDisconnect(now, state.unsupportedApi and "unsupported API" or nil)
    end
  end

  if not connected then
    return false
  end

  local armed = readArmedState()
  if armed then
    if state.lastArmed ~= true then
      state.lastArmed = true
      state.queue:clear()
      log("MSP paused while ARMED", "info")
    end
    state.queue:clear()
  else
    if state.lastArmed == true then
      state.lastArmed = false
      log("MSP resumed after DISARM", "info")
    end
  end

  if state.unsupportedApi then
    -- Refuse to use this board, and say so once. The link is left reported as it is: it has not
    -- gone anywhere, and claiming it has is what used to restart the negotiation every tick.
    doDisconnect(now, "unsupported API", true)
    return false
  end

  -- Core startup reads (API version + UID).
  if not armed then
    enqueueVersionReads(now)
    enqueueUidRead(now)
  end

  state.queue:processQueue(now)
  publish()
  -- If the version read cleared/marked unsupported during processing, ensure we
  -- treat the runtime as disconnected so callers see a consistent state.
  if state.unsupportedApi then
    doDisconnect(now, "unsupported API", true)
    return false
  end

  return true
end

--- Give the queue a second turn inside the same host pass, after its callers have filled it.
--
-- Every host ticks this runtime FIRST and wakes the event runners after it, so a request an
-- onconnect task enqueues is not looked at until the next pass. The connect chain is a dozen
-- round trips run strictly one after another, so that is a whole host tick lost per reply on
-- the one path a start waits for.
--
-- This is the queue half of tick() and nothing else -- no link detection, no arm handling, no
-- version re-negotiation and no enqueueing of its own -- so running it a second time in a pass
-- cannot move any state that tick() owns. It refuses on exactly the conditions under which
-- tick() would not have reached processQueue either, and it never initialises the runtime: a
-- host that has not ticked yet has nothing queued to pump.
function Runtime.pump()
  if not state.initialized or not state.available then return false end
  if not state.queue or type(state.queue.processQueue) ~= "function" then return false end
  if state.lastConnected ~= true then return false end
  if state.lastArmed == true then return false end
  if state.unsupportedApi then return false end

  state.queue:processQueue(nowSeconds())
  publish()
  return true
end

function Runtime.isFblConnected()
  return computeFblConnected(state)
end

function Runtime.setModelPreferences(prefs, filePath)
  state.values.modelPreferences = prefs
  state.values.modelPreferencesFile = filePath
  if _G and _G.rfsuite and _G.rfsuite.session then
    _G.rfsuite.session.modelPreferences = prefs
    _G.rfsuite.session.modelPreferencesFile = filePath
  end
end

function Runtime.getState()
  return state
end

function Runtime.getProgress()
  local total = 0
  local done = 0

  -- Core startup reads (API version + UID) are always tracked.
  total = total + 1
  if state.versionReadCompleted == true then
    done = done + 1
  end

  total = total + 1
  if state.values.mcuId ~= nil then
    done = done + 1
  end

  local queueIdle = true
  if state.queue and type(state.queue.isProcessed) == "function" then
    queueIdle = state.queue:isProcessed() == true
  end

  local active = (state.available == true) and ((done < total) or (queueIdle == false))
  return {
    active = active,
    done = done,
    total = total,
    queueIdle = queueIdle,
  }
end

if type(_G) == "table" then
  _G.__rfsuite_msp_runtime_module = Runtime
end

return Runtime
