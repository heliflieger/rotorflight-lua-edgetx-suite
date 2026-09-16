-- OnConnect task: mirror the flight controller's three model parameters onto the radio, when the
-- "Synchronize Model Parameters" setting asks for it.
--
-- Each parameter is a (type, value) pair. The type selects what on the radio the value belongs to:
-- nothing, one of the three timers, or one of the nine global variables.

local M = {}

local done = false
local requestSent = false
local taggedLog = nil
local PilotConfigApi = nil

local PARAM_TYPE_NONE = 0
local PARAM_TYPE_TIMER_FIRST = 1
local PARAM_TYPE_TIMER_LAST = 3
local PARAM_TYPE_GV_FIRST = 4
local PARAM_TYPE_GV_LAST = 12

-- Global variables are written for the first flight mode; the radio's own inheritance carries
-- them to the others.
local GV_FLIGHT_MODE = 0
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- The logging core's tagged emitter, bound on first use: the default level and the
-- console flag are lib/log.lua's, and this file states only its tag.
local function log(msg, level)
  if not taggedLog then
    local rf = _G.rfsuite
    local L = rf and rf.Log
    if type(L) ~= "table" or type(L.tagged) ~= "function" then return end
    taggedLog = L.tagged("rfsuite.tasks.model_params_sync")
  end
  taggedLog(msg, level)
end

local function isTruthy(value)
  return value == true or value == 1 or value == "1" or value == "true"
end

-- Does this board's MSP_PILOT_CONFIG carry the flags word at all? Only 12.09 and later.
local function boardHasFlags()
  local root = _G and _G.rfsuite
  local s = type(root) == "table" and root.session or nil
  local v = tonumber(s and s.apiVersion)
  return v ~= nil and v >= 12.09
end

local function syncEnabled()
  local root = _G and _G.rfsuite
  local prefs = type(root) == "table" and root.preferences or nil
  local general = type(prefs) == "table" and prefs.general or nil
  return isTruthy(general and general.syncparams)
end

-- The timer's start value is what the pilot configured, so that is what a parameter from the
-- flight controller sets. The running value is deliberately left alone: this task also runs on a
-- reconnect, and writing there would clear a timer that is counting a flight.
local function applyTimer(index, value)
  if type(model) ~= "table" or type(model.getTimer) ~= "function" or type(model.setTimer) ~= "function" then
    return false
  end
  local ok, timer = pcall(model.getTimer, index)
  if not ok or type(timer) ~= "table" then return false end
  if timer.start == value then return false end
  -- ONLY `start`, and never the table `getTimer` handed over. A missing key leaves its field
  -- alone (`model.setTimer`'s own contract), while the full table carries `value` back with it
  -- -- and `value` is the RUNNING count: setTimer assigns it to `timersStates[idx].val`
  -- (`radio/src/lua/api_model.cpp`). Writing the whole table therefore rewinds a running timer
  -- to whatever it read a moment earlier, by up to one tick of the timer task, which is the
  -- very thing this task takes care not to do on a reconnect.
  return pcall(model.setTimer, index, { start = value })
end

local function applyGlobalVariable(index, value)
  if type(model) ~= "table" or type(model.setGlobalVariable) ~= "function" then
    return false
  end
  if type(model.getGlobalVariable) == "function" then
    local ok, current = pcall(model.getGlobalVariable, index, GV_FLIGHT_MODE)
    if ok and current == value then return false end
  end
  return pcall(model.setGlobalVariable, index, GV_FLIGHT_MODE, value)
end

local function applyParameter(paramType, value)
  paramType = tonumber(paramType)
  value = tonumber(value)
  if paramType == nil or value == nil or paramType == PARAM_TYPE_NONE then return end

  if paramType >= PARAM_TYPE_TIMER_FIRST and paramType <= PARAM_TYPE_TIMER_LAST then
    if applyTimer(paramType - PARAM_TYPE_TIMER_FIRST, value) then
      log("timer " .. tostring(paramType) .. " set to " .. tostring(value), "info")
    end
  elseif paramType >= PARAM_TYPE_GV_FIRST and paramType <= PARAM_TYPE_GV_LAST then
    if applyGlobalVariable(paramType - PARAM_TYPE_GV_FIRST, value) then
      log("global variable " .. tostring(paramType - PARAM_TYPE_GV_FIRST + 1) .. " set to " .. tostring(value), "info")
    end
  end
end

function M.wakeup()
  if done then return end

  local root = _G and _G.rfsuite
  local session = type(root) == "table" and root.session or nil
  if type(session) ~= "table" then return end

  -- The READ is not gated on the setting, and the APPLY is. From MSP API 12.09 the reply also
  -- carries the model flags, and one of them decides whether the name task runs at all -- so a
  -- radio-side switch being off must not suppress the read that another consumer depends on.
  -- Below 12.09 there are no flags in the message and nobody but this task wants it, so the
  -- read is skipped there when the setting is off, and no connect pays for nothing.
  if not syncEnabled() and not boardHasFlags() then
    done = true
    return
  end

  if requestSent then return end
  requestSent = true

  if not PilotConfigApi then
    PilotConfigApi = loadModule("tasks/msp/api/pilot_config.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadModule("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not PilotConfigApi then
    done = true
    return
  end

  local mspState = type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    done = true
    return
  end

  mspState.queue:add({
    command = PilotConfigApi.command,
    simulatorResponse = PilotConfigApi.simulatorResponse,
    timeout = 5.0,
    -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
    -- is given up by the queue before the runner re-queues the task that owns it.
    maxRetries = 2,
    processReply = function(self, buf)
      local data = PilotConfigApi.parse(buf)
      if type(data) == "table" then
        -- Parked for the tasks that run after this one. `model_flags` is nil below API 12.09,
        -- and a consumer must be able to tell that from both bits being off.
        local root = _G and _G.rfsuite
        if type(root) == "table" and type(root.session) == "table" then
          root.session.pilotConfig = data
        end
        if syncEnabled() then
          applyParameter(data.model_param1_type, data.model_param1_value)
          applyParameter(data.model_param2_type, data.model_param2_value)
          applyParameter(data.model_param3_type, data.model_param3_value)
        end
      end
      done = true
    end,
    errorHandler = function(msg, reason)
      -- "cleared" is the queue dropping this request, not the flight controller refusing it:
      -- nothing was sent, so the request is still owed. Leaving the task incomplete with its latch
      -- open is what lets the runner ask for it again on a later pass.
      if reason == "cleared" then
        requestSent = false
        return
      end
      log("pilot config read failed", "warn")
      done = true
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  requestSent = false
  local root = _G and _G.rfsuite
  if type(root) == "table" and type(root.session) == "table" then
    root.session.pilotConfig = nil
  end
end

return M
