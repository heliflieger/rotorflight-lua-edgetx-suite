-- Centralized Profile Resolution Helper
-- Provides standardized active PID and Rate profile resolution across the suite.

local M = {}

local Sensors = nil

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function loadSensors()
  if Sensors == nil then
    if _G.rfsuite and _G.rfsuite.require then
      Sensors = _G.rfsuite.require("lib/sensors.lua") or false
    else
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/sensors.lua", "t")
      if type(chunk) == "function" then
        local ok, mod = pcall(chunk)
        Sensors = (ok and mod) or false
      else
        Sensors = false
      end
    end
  end
  return (Sensors ~= false and Sensors) or nil
end

--- Resolve active PID profile (1-indexed: 1..6)
-- Precedence:
-- 1. Live Telemetry Sensor "pid_profile" (real-time switch tracking)
-- 2. Session State "session.activeProfile" (0-indexed -> 1-indexed)
-- 3. Fallback defaultVal (nil if omitted, or caller-specified e.g. 1)
function M.getActivePidProfile(defaultVal)
  local sensors = loadSensors()
  if sensors and type(sensors.getValue) == "function" then
    local raw = tonumber(sensors.getValue("pid_profile"))
    if raw and raw > 0 then
      return math.floor(raw)
    end
  end
  local session = getSession()
  local active = tonumber(session and session.activeProfile)
  if active ~= nil then
    return math.floor(active) + 1
  end
  return defaultVal
end

--- Resolve active Rate profile (1-indexed: 1..6)
-- Precedence:
-- 1. Live Telemetry Sensor "rate_profile" (real-time switch tracking)
-- 2. Session State "session.activeRateProfile" (0-indexed -> 1-indexed)
-- 3. Fallback defaultVal (nil if omitted, or caller-specified e.g. 1)
function M.getActiveRateProfile(defaultVal)
  local sensors = loadSensors()
  if sensors and type(sensors.getValue) == "function" then
    local raw = tonumber(sensors.getValue("rate_profile"))
    if raw and raw > 0 then
      return math.floor(raw)
    end
  end
  local session = getSession()
  local active = tonumber(session and session.activeRateProfile)
  if active ~= nil then
    return math.floor(active) + 1
  end
  return defaultVal
end

--- Generic profile getter by type ("pid_profile" / "rate_profile" or "pid" / "rate")
function M.get(profileType, defaultVal)
  if profileType == "rate_profile" or profileType == "rate" then
    return M.getActiveRateProfile(defaultVal)
  end
  return M.getActivePidProfile(defaultVal)
end

--- Update session active PID profile (0-indexed)
function M.setSessionPidProfile(index0Based)
  local session = getSession()
  if session then
    session.activeProfile = tonumber(index0Based)
  end
end

--- Update session active Rate profile (0-indexed)
function M.setSessionRateProfile(index0Based)
  local session = getSession()
  if session then
    session.activeRateProfile = tonumber(index0Based)
  end
end

return M
