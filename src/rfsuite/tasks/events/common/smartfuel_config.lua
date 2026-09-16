-- Shared task: smartfuel_config read
local M = {}

local done = false
local requestSent = false
local smartfuelConfigApi = nil
local Log = nil
local ApiVersion = nil
local waitingLogged = false

local function apiVersionReady(v)
  return v ~= nil and v ~= "" and tostring(v) ~= "0"
end
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

function M.wakeup()
  if Log == nil then
    Log = loadModule("lib/log.lua") or false
  end
  if ApiVersion == nil then
    ApiVersion = loadModule("lib/api_version.lua") or false
  end

  if done or requestSent then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  -- Do not block the onconnect pipeline when API version is still unknown.
  -- SmartFuel page itself can read/write once API becomes available.
  if not apiVersionReady(session.apiVersion) then
    done = true
    if (not waitingLogged) and type(Log) == "table" and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.tasks.smartfuel", "skip smartfuel_config (api unknown)", "debug")
      waitingLogged = true
    end
    return
  end

  -- Ethos parity: SMARTFUEL_CONFIG is available from API >= 12.0.9.
  local apiVersion = ApiVersion and ApiVersion.parse and ApiVersion.parse(session.apiVersion)
  if not (ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(apiVersion, { 12, 0, 9 })) then
    done = true
    if type(Log) == "table" and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.tasks.smartfuel", "skip smartfuel_config (api=" .. tostring(session.apiVersion) .. " < 12.0.9)", "debug")
    end
    return
  end

  requestSent = true

  if not smartfuelConfigApi then
    smartfuelConfigApi = loadModule("tasks/msp/api/smartfuel_config.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadModule("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not smartfuelConfigApi then
    done = true
    return
  end

  local mspState = type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    done = true
    return
  end

  mspState.queue:add({
    command = smartfuelConfigApi.command,
    simulatorResponse = smartfuelConfigApi.simulatorResponse,
    timeout = 5.0,
    -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
    -- is given up by the queue before the runner re-queues the task that owns it.
    maxRetries = 2,
    processReply = function(self, buf)
      local data = smartfuelConfigApi.parse(buf)
      if type(data) == "table" then
        session.smartfuel_config = data
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.smartfuel", "smartfuel_config received", "debug")
      end
    end,
    errorHandler = function(msg, reason)
      -- "cleared" is the queue dropping this request, not the flight controller refusing it:
      -- nothing was sent, so the request is still owed. Leaving the task incomplete with its latch
      -- open is what lets the runner ask for it again on a later pass.
      if reason == "cleared" then
        requestSent = false
        return
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.smartfuel", "smartfuel_config read failed", "warn")
      end
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  requestSent = false
  waitingLogged = false
end

return M
