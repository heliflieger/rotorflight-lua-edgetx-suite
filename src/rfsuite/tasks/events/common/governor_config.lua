-- Shared task: governor_config auslesen
local M = {}

local done = false
local requestSent = false
local governorConfigApi = nil
local Log = nil
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- The logger and the MSP runtime are one instance per Lua state. The runner drops this module when
-- its task completes and loads it again the next time the event fires, so a bare loadScript here
-- would read and compile those files again every time; lib/require.lua hands back the loaded one.
local function loadShared(path)
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then return req(path) end
  return loadModule(path)
end

function M.wakeup(args)
  if Log == nil then
    Log = loadShared("lib/log.lua") or false
  end

  if done then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  if requestSent then return end

  -- The configuration in the session is the previous board's until this read answers, and nothing
  -- else clears it between two boards: the runner drops this module without its reset() once the
  -- task is complete. It goes as this board's read starts, so a read that fails leaves no stale
  -- governor configuration or mode behind.
  session.governor_config = nil
  session.governorMode = nil

  -- MSP governor_config API laden
  if not governorConfigApi then
    governorConfigApi = loadModule("tasks/msp/api/governor_config.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadShared("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not governorConfigApi then
    done = true
    return
  end

  local mspState = type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    done = true
    return
  end

  requestSent = true

  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.governor", "MSP request for governor_config (cmd=" .. tostring(governorConfigApi.command) .. ") via queue", "debug")
  end

  mspState.queue:add({
    command = governorConfigApi.command,
    simulatorResponse = governorConfigApi.simulatorResponse,
    timeout = 5.0,
    -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
    -- is given up by the queue before the runner re-queues the task that owns it.
    maxRetries = 2,
    processReply = function(self, buf)
      local data = governorConfigApi.parse(buf)
      if data then
        session.governor_config = data
        session.governorMode = data.gov_mode
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.governor", "governor_config received (mode=" .. tostring(data and data.gov_mode or "?") .. ")", "debug")
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
      if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks.governor", "governor_config read failed", "warn") end
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  requestSent = false
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if type(session) == "table" then
    session.governor_config = nil
    session.governorMode = nil
  end
end

return M
