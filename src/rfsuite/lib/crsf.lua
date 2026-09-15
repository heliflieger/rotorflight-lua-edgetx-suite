-- Centralized CRSF frame multiplexer for EdgeTX
-- Ensures multiple background tasks and UI pages can consume different CRSF frame types without race conditions.

local M = {}

if type(_G) == "table" and _G.rfsuite and _G.rfsuite.crsf_manager then
  return _G.rfsuite.crsf_manager
end

local queues = {}
local MAX_QUEUE_SIZE = 10

-- Frame types some consumer has asked for, learned from popFrame itself.
-- Draining the system queue means taking frames of every type on the link, and only a
-- few of them have a consumer here: MSP responses, the custom telemetry frame, and --
-- while that diagnostics page is open -- ELRS device info and parameter entries.
-- Everything else was filed into a queue of ten that nothing ever pops, so link
-- statistics, battery, attitude, GPS and RPM frames each left ten stale payload tables
-- behind for as long as the Lua state lives -- in a widget, that is until power-off.
local wanted = {}

-- The logging core's tagged emitter, bound on first use: the default level and the
-- console flag are lib/log.lua's, and this file states only its tag.
local taggedLog = nil
local function log(msg, level)
  if not taggedLog then
    local rf = _G.rfsuite
    local L = rf and rf.Log
    if type(L) ~= "table" or type(L.tagged) ~= "function" then return end
    taggedLog = L.tagged("rfsuite.crsf")
  end
  taggedLog(msg, level)
end

function M.popFrame(frameType)
  if type(crossfireTelemetryPop) ~= "function" then return nil end

  if frameType ~= nil then wanted[frameType] = true end

  -- 1. Check local buffer for this type
  if queues[frameType] and #queues[frameType] > 0 then
    return table.remove(queues[frameType], 1)
  end

  -- 2. Drain system queue and categorize frames
  local pops = 0
  while pops < 50 do
    local cmd, data = crossfireTelemetryPop()
    if cmd == nil then break end
    pops = pops + 1

    if cmd == frameType then
      return data
    elseif wanted[cmd] then
      -- Store for another consumer that has asked for this type
      queues[cmd] = queues[cmd] or {}
      if #queues[cmd] < MAX_QUEUE_SIZE then
        table.insert(queues[cmd], data)
      else
        -- Optional: log overflow
      end
    end
  end

  return nil
end

-- Compatibility wrapper for the sensor-object pattern
function M.getSensor()
  return {
    popFrame = function(self, ...)
      local types = {...}
      if #types == 0 then
        -- This is tricky as we don't know what they want.
        -- But usually called with types.
        return nil
      end
      -- Try to find any of the requested types in our queues
      for _, t in ipairs(types) do
        local data = M.popFrame(t)
        if data then return t, data end
      end
      return nil
    end,
    pushFrame = function(self, command, payload)
      if type(crossfireTelemetryPush) == "function" then
        return crossfireTelemetryPush(command, payload)
      end
      return false
    end
  }
end

if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.crsf_manager = M
end

return M
