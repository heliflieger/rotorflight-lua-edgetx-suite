-- Writes the flight the arm edge opened.
--
-- Runs in the widget context, like the two ondisarm tasks beside it: the tool cannot be open
-- while the craft is armed, so a flight that lands is only ever seen by a widget.
--
-- The duration is the ARMED time -- the span between the two edges by getTime() -- and not the
-- time the rotor was turning. This suite has no rotor clock, and a second definition of "flight"
-- that nothing else here agrees with would be worse than the plainer one.

local M = {}

local done = false

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function logLine(message, level)
  local Log = loadModule("lib/log.lua")
  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.flight_log", message, level or "info")
  end
end

-- The widget runtimes publish the settings into the global table on every pass, so the file is
-- only read on a state that has not got round to it yet.
local function preferences()
  local root = _G and _G.rfsuite
  if type(root) == "table" and type(root.preferences) == "table" then
    return root.preferences
  end
  local Preferences = loadModule("lib/preferences.lua")
  if type(Preferences) == "table" and type(Preferences.load) == "function" then
    local ok, prefs = pcall(Preferences.load)
    if ok and type(prefs) == "table" then return prefs end
  end
  return nil
end

local function settings()
  local prefs = preferences()
  local section = type(prefs) == "table" and prefs.flightlog or nil
  local enabled = false
  local minSeconds = 30
  if type(section) == "table" then
    enabled = section.enabled == true
    local configured = tonumber(section.min_seconds)
    if configured ~= nil and configured >= 0 then minSeconds = configured end
  end
  return enabled, minSeconds
end

-- Which pack this flight belongs to.
--
-- A pick made in the session wins, and everything else comes from the model's own store. The
-- store is re-read here rather than taken from the copy the session is carrying, because the
-- page that writes it runs as a tool while this runs as a widget, and the copy this side holds
-- was loaded when the craft connected. Reading it at the disarm edge costs nothing that the
-- line about to be appended does not cost anyway, and it is the same answer the arm edge would
-- have given: the page is locked while the craft is armed, so the choice cannot have moved
-- since take-off.
local function resolveBattery(FlightLog, session, record)
  if type(record.batteryId) == "string" and record.batteryId ~= "" then
    return record.batteryId
  end

  if session.mcu_id ~= nil then
    local ModelPreferences = loadModule("lib/model_preferences.lua")
    if type(ModelPreferences) == "table" and type(ModelPreferences.loadByMcuId) == "function" then
      local ok, store = pcall(ModelPreferences.loadByMcuId, session.mcu_id, true)
      if ok then
        local id = FlightLog.storedBatteryId(store)
        if id ~= nil then return id end
      end
    end
  end

  return FlightLog.storedBatteryId(session.modelPreferences)
end

-- The flight record onto the log's statistics columns.
--
-- The record is closed by the first task of this manifest, which runs a wakeup before this one, so
-- `last` here is the flight that has just ended and `current` is already the empty one waiting for
-- the next arm. Reading `current` would log nothing.
--
-- The columns this cannot fill are left out, and `statField` writes an empty field for each: the
-- headspeed extrema are per PID profile and the record keeps one set for the whole flight, and the
-- suite has no voltage-sag detector at all. The header carries all 22 columns either way, so a
-- partly filled row is a valid row of the format rather than a new one.
--
-- Per-cell voltage needs a cell count, and the one already published in this Lua state is the
-- flight controller's battery configuration, which the `battery_config` event task keeps on the
-- session. Where that has not been read, the two per-cell columns stay empty rather than being
-- divided by a guess.
local function flightStats(session)
  local flight = type(session) == "table" and session.flight or nil
  local record = type(flight) == "table" and flight.last or nil
  if type(record) ~= "table" then return nil end

  local stats = {}
  local any = false
  local function put(column, value)
    if type(value) == "number" then
      stats[column] = value
      any = true
    end
  end

  put("mah", record.maxConsumedMah)
  put("curr_min", record.minCurrent)
  put("curr_max", record.maxCurrent)
  put("tesc_min", record.minEscTemp)
  put("tesc_max", record.maxEscTemp)
  put("vbec_min", record.minBecVoltage)
  put("vbec_max", record.maxBecVoltage)

  local config = session.batteryConfig or session.battery_config
  local cells = type(config) == "table" and tonumber(config.batteryCellCount) or nil
  if cells ~= nil and cells > 0 then
    if type(record.minVoltage) == "number" then put("vcel_min", record.minVoltage / cells) end
    if type(record.maxVoltage) == "number" then put("vcel_max", record.maxVoltage / cells) end
  end

  -- Nothing was recorded -- telemetry was gone for the whole armed window. `nil` rather than a
  -- table of nils, so the line stays the five-column form it has always been rather than becoming
  -- seventeen empty columns that say the same thing at more length.
  if not any then return nil end
  return stats
end

function M.wakeup()
  if done then return end
  done = true

  local root = _G and _G.rfsuite
  local session = type(root) == "table" and root.session or nil
  if type(session) ~= "table" then return end

  local record = session.flightlog
  if type(record) ~= "table" or record.open ~= true then return end
  record.open = false

  local seconds = nil
  if type(record.startTicks) == "number" and type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" and ticks >= record.startTicks then
      seconds = math.floor((ticks - record.startTicks) / 100 + 0.5)
    end
  end
  if seconds == nil or record.startDate == nil then return end

  local enabled, minSeconds = settings()
  if not enabled then return end

  -- An arm that never became a flight -- a spool-up check, an arming test -- reaches neither the
  -- log nor a battery's cycle count, so the two stay consistent with each other. A minimum of
  -- zero logs every arm.
  if seconds < minSeconds then
    logLine(string.format("flight of %ds is below the %ds minimum, not logged", seconds, minSeconds), "debug")
    return
  end

  local FlightLog = loadModule("lib/flight_log.lua")
  if type(FlightLog) ~= "table" then
    logLine("flight not logged: the data core did not load", "warn")
    return
  end

  local batteryId = resolveBattery(FlightLog, session, record)

  local ok, written = pcall(FlightLog.appendFlight, record.startDate, record.model or "",
    batteryId or "", seconds, flightStats(session))
  if not ok or written ~= true then
    -- The append verifies by the bytes the file grew, so this is a line that did not land -- a
    -- full or a missing card. Said out loud, because the gap it leaves explains nothing.
    logLine("flight NOT logged: " .. ((not ok) and tostring(written) or "the card did not take the line"), "warn")
  else
    logLine(string.format("flight logged: %ds, battery=%s", seconds, tostring(batteryId or "-")), "info")
  end

  -- One count per pack per connection, on the first flight that was long enough to be one.
  -- Choosing a pack is not using it, and a second flight on the same charge is not a second
  -- cycle. The id is remembered rather than a flag, so swapping to another pack counts again.
  if batteryId ~= nil and record.countedFor ~= batteryId then
    record.countedFor = batteryId
    local okMark, marked = pcall(FlightLog.markUsed, batteryId, record.startDate)
    if not okMark or marked ~= true then
      logLine("battery cycle not counted for " .. tostring(batteryId) .. ": "
        .. ((not okMark) and tostring(marked) or "registry unchanged or the replace failed"), "warn")
    end
  end

  if type(collectgarbage) == "function" then
    collectgarbage("collect")
  end
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
end

return M
