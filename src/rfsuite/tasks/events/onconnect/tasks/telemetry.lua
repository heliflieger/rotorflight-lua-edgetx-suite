-- Task: Read TELEMETRY_CONFIG (MSP 73) on connect
local M = {}

local TelemetryApi = nil
local done = false
local pending = false
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function getSession()
  return _G.rfsuite and _G.rfsuite.session
end

-- The logging core's tagged emitter, bound on first use through the shared instance in
-- _G -- a loadScript here would read and compile a fresh copy of the module per message.
-- The default level and the console flag are lib/log.lua's; this file states only its tag.
local taggedLog = nil
local function log(msg, level)
  if not taggedLog then
    local rf = _G.rfsuite
    local L = rf and rf.Log
    if type(L) ~= "table" or type(L.tagged) ~= "function" then return end
    taggedLog = L.tagged("rfsuite.tasks.telemetry")
  end
  taggedLog(msg, level)
end

function M.wakeup()
  if done or pending then return end

  local session = getSession()
  if not session or session.isConnected ~= true then
    return
  end

  log("wakeup: starting telemetry config read")

  if not TelemetryApi then
    TelemetryApi = loadModule("tasks/msp/api/telemetry_config.lua")
  end

  if not TelemetryApi then
    log("wakeup: api missing, skipping", "warn")
    done = true
    return
  end

  if MspRuntime == nil then
    MspRuntime = loadModule("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    log("wakeup: msp/queue missing", "warn")
    return
  end

  pending = true
  log("wakeup: adding cmd=" .. tostring(TelemetryApi.command) .. " to queue")
  mspState.queue:add({
    command = TelemetryApi.command,
    timeout = 5.0,
    maxRetries = 2,
    simulatorResponse = TelemetryApi.simulatorResponse,
    processReply = function(_, buf)
      log("processReply: received bytes=" .. tostring(buf and #buf or 0))
      local parsed = TelemetryApi.parse(buf)
      if parsed then
        log("processReply: parsed config successfully")
        session.telemetry_config = parsed
        session.crsfTelemetryConfig = {
          mode = parsed.crsf_telemetry_mode,
          linkRate = parsed.crsf_telemetry_link_rate,
          linkRatio = parsed.crsf_telemetry_link_ratio
        }
        session.telemetryConfigBuffer = parsed.buffer
      else
        log("processReply: failed to parse config", "warn")
      end
      done = true
      pending = false
    end,
    errorHandler = function(msg, reason)
      -- "cleared" is the queue dropping this request, not the flight controller refusing it:
      -- nothing was sent, so the request is still owed. Leaving the task incomplete with its latch
      -- open is what lets the runner ask for it again on a later pass.
      if reason == "cleared" then
        pending = false
        return
      end
      log("errorHandler: MSP 73 failed", "warn")
      done = true
      pending = false
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  pending = false
end

return M
