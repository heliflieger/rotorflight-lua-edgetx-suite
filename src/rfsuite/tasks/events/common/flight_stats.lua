-- Shared task: flight_stats auslesen
local M = {}

local done = false
local requestSent = false
local flightStats = nil
local Log = nil
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

function M.wakeup(args)
  if Log == nil then
    Log = loadModule("lib/log.lua") or false
  end

  if done then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  if requestSent then return end

  -- MSP flight_stats API laden
  if not flightStats then
    flightStats = loadModule("tasks/msp/api/flight_stats.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadModule("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not flightStats then
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
    pcall(Log.emit, "rfsuite.tasks.flight_stats", "MSP request for flight_stats (cmd=" .. tostring(flightStats.command) .. ") via queue", "debug")
  end

  mspState.queue:add({
    command = flightStats.command,
    simulatorResponse = flightStats.simulatorResponse,
    timeout = 5.0,
    -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
    -- is given up by the queue before the runner re-queues the task that owns it.
    maxRetries = 2,
    processReply = function(self, buf)
      local stats = flightStats.parse(buf)
      if stats and stats.flightcount then
        session.flightcount = stats.flightcount
        -- Armed seconds the board has counted. The flight record publishes it as the total,
        -- with the flight in progress added to it.
        session.totalflighttime = stats.totalflighttime
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.flight_stats", "flight_stats received: " .. tostring(stats and stats.flightcount), "debug")
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
      if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks.flight_stats", "flight_stats read failed", "warn") end
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  requestSent = false
end

return M
