-- Master Volume Bridge (Layer B)
--
-- Drives a global variable on the radio's model to override the master volume
-- during flight and boost it during sustained critical alerts. When disabled or
-- disconnected, the GVAR carries -1024, a sentinel that a logical switch on the
-- model uses to hand control back to the pilot's volume pot.
--
-- The module writes only on actual value change (read-modify-write) to avoid
-- marking the model dirty on every frame. See Issue #172 for the full design.

local M = {}

local SENTINEL = -1024

-- State held across calls. Reset on disconnect or when the feature is toggled off.
local state = {
  activeGvar = 0,       -- The GVAR slot currently being driven (1..9), or 0 if off.
  lastWritten = nil,    -- The value last written, to avoid redundant writes.
  criticalUp = false,   -- Whether a sustained critical alert is currently active.
}

-- Read the current GVAR value from the radio model. Returns the value or nil.
local function readGvar(index)
  if type(model) ~= "table" or type(model.getGlobalVariable) ~= "function" then
    return nil
  end
  local ok, val = pcall(model.getGlobalVariable, index - 1, 0)  -- 0-indexed, flight mode 0
  if ok then return val end
  return nil
end

-- Write a value to the GVAR, but only if it differs from what is stored.
local function writeGvar(index, value)
  if type(model) ~= "table" or type(model.setGlobalVariable) ~= "function" then
    return false
  end
  local current = readGvar(index)
  if current == value then
    state.lastWritten = value
    return true  -- Already at the desired value.
  end
  local ok, err = pcall(model.setGlobalVariable, index - 1, 0, value)  -- 0-indexed, flight mode 0
  if ok then
    state.lastWritten = value
  end
  return ok
end

-- Release the currently active GVAR back to sentinel. Called when the feature is
-- disabled, the GVAR slot changes, or the connection is lost (and no critical hold).
local function releaseGvar()
  if state.activeGvar > 0 then
    writeGvar(state.activeGvar, SENTINEL)
  end
  state.activeGvar = 0
  state.lastWritten = nil
end

--- Update the master volume bridge. Called from lib/audio.lua on each audio pass.
---
--- @param prefs table  The full preferences table (_G.rfsuite.preferences)
--- @param connected boolean  Whether a model is currently connected
--- @param critical boolean  Whether a sustained critical alert is active
function M.update(prefs, connected, critical)
  local audio = prefs and prefs.audio
  local gvarSlot = audio and tonumber(audio.master_gvar) or 0

  -- Feature off: release any previously active GVAR.
  if gvarSlot < 1 or gvarSlot > 9 then
    if state.activeGvar > 0 then
      releaseGvar()
    end
    state.criticalUp = false
    return
  end

  -- GVAR slot changed: release old, adopt new.
  if gvarSlot ~= state.activeGvar then
    if state.activeGvar > 0 then
      releaseGvar()
    end
    state.activeGvar = gvarSlot
    state.lastWritten = nil
  end

  state.criticalUp = critical

  -- Determine the target value.
  local target
  if critical then
    target = tonumber(audio.master_alert) or 100
  elseif connected then
    target = tonumber(audio.master_normal) or 80
  else
    target = SENTINEL
  end

  -- Write only on change.
  if target ~= state.lastWritten then
    writeGvar(state.activeGvar, target)
  end
end

--- Reset all state. Called on disconnect (from publishConnected(false)).
--- If a critical alert is still active, the boost is held and not released.
function M.reset(holdCritical)
  if holdCritical and state.criticalUp then
    -- Keep the boost: the alert is still sounding, and dropping the volume
    -- during a link loss is the one thing this feature exists to prevent.
    return
  end
  releaseGvar()
  state.criticalUp = false
end

--- Explicitly release the GVAR. Called when the module is unloaded.
function M.release()
  releaseGvar()
  state.criticalUp = false
end

return M
