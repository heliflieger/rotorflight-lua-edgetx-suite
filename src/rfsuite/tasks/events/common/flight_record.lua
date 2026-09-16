-- The arm and disarm edges of the flight record.
--
-- Both manifests name this task and both name it FIRST: the runner takes the first task of the
-- list that has not finished and runs one task per wakeup, so opening or closing the record
-- happens in the edge's own wakeup, before anything else in the chain. That is what lets a task
-- behind it -- the flight log among them -- read a finished flight out of the record rather than
-- one that is still open.
--
-- Which edge it is is not passed in: it is read from the same armed state the runtime's own edge
-- detector fired on, so there is one definition of the arm edge and not two.
local M = {}

local done = false
local Record = nil
local MspRuntime = nil

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

function M.wakeup()
  if done then return end
  done = true

  if Record == nil then
    Record = loadModule("tasks/events/telemetry/flight_record.lua") or false
  end
  if MspRuntime == nil then
    MspRuntime = loadModule("tasks/msp/runtime.lua") or false
  end
  if not Record then return end

  local armed = false
  if MspRuntime and type(MspRuntime.getState) == "function" then
    local mspState = MspRuntime.getState()
    armed = type(mspState) == "table" and mspState.lastArmed == true
  end

  if armed then
    Record.open()
  else
    Record.close()
  end
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
end

return M
