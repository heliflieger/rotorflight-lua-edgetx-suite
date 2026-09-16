-- The flight record: the statistics of the flight in progress and of the flight before it.
--
-- Owner. This runs from the event runtimes, in the widget context only, so the record is kept by
-- whichever widget runs the suite's background work: the dashboard, or -- on a model that does
-- not use the dashboard -- the service widget, which is there to run the runtimes and publish the
-- MSP surface for other widgets. There is no election to make and none is needed: one widget of
-- the suite runs that work, and anything else in the same Lua state reads the finished record out
-- of the session table. A model without a dashboard therefore still records its flights.
--
-- Arm edge. One definition, the event runtime's: the armed state the onarm and ondisarm chains
-- already fire on (tasks/msp/runtime.lua, the ARM sensor). The record opens on that arm edge and
-- closes on that disarm edge, as the first task of either manifest, so anything reading the
-- record at the disarm edge -- the flight log among them -- sees the finished flight in `last`.
--
-- The published schema, and this is the whole of it:
--
--   rfsuite.session.flight = {
--     current     = { <key> = number, ... },  -- the flight in progress, empty until a value lands
--     last        = { <key> = number, ... },  -- the flight that ended, empty before the first one
--     seconds     = number,   -- armed seconds of the flight in progress
--     lastSeconds = number,   -- armed seconds of the flight that ended
--     flights     = number,   -- flights the flight controller counts
--     totalSeconds= number,   -- armed seconds the flight controller counts, plus the live flight
--     armed       = boolean,  -- whether a record is open
--   }
--
-- The keys of `current` and `last` are the statistic's own, built from the table below: `maxRpm`,
-- `minVoltage`, `maxEscTemp` and so on. A key is absent until the statistic has taken a value, so
-- a reader asks `current[key]` and falls back to `last[key]`.
--
-- `current` is mutated in place while a flight runs -- every field is independently monotonic, so
-- a reader between two passes cannot see a torn value -- and is REPLACED by a fresh table on each
-- edge, which is how the dashboard's own derived snapshot is swapped for the same reason.

local Record = {}

local Sensors = nil

-- The statistics update runs on this cadence rather than on every wakeup, which is what the
-- dashboard's own telemetry read used: the sensor reads are the cost here, and sampling an
-- extreme five times as often does not make it a different number.
local UPDATE_INTERVAL = 0.5

-- What a single clock step is allowed to be worth. A widget can be suspended for a whole tool
-- session, and the wakeup after that would otherwise credit the flight with all of it.
local MAX_CLOCK_STEP = UPDATE_INTERVAL * 2

-- Receivers without an RQly sensor fall back to 1RSS/2RSS, which carry an RSSI in dBm and are
-- always negative. A value from one of those is not a link quality, whatever its sign.
local RSSI_LINK_SOURCES = {
  ["1RSS"] = true,
  ["2RSS"] = true,
}

-- One row per tracked statistic. This table is the only place that knows the set: the record's
-- keys are built from it, and so is the per-pass work.
--
--   key    the record's name suffix: current.max<key>, current.min<key>
--   source the sensor this statistic is taken from
--   min / max  which extremes are recorded
--   gate   what the value has to be for the statistic to take it at all
--   minGate  a further condition on the minimum alone
local GATE_ANY = 0        -- any number the sensor gives, which is what most of them take
local GATE_POSITIVE = 1   -- above zero
local GATE_FUEL_SEEN = 2  -- only once a fuel sensor has answered
local GATE_LINK_QUALITY = 3

local FLIGHT_STATS = {
  { key = "ThrottlePercent", source = "throttlePercent", max = true },
  { key = "Rpm",             source = "rpm",             max = true, min = true, minGate = GATE_POSITIVE },
  { key = "Current",         source = "current",         max = true, min = true },
  { key = "Watts",           source = "watts",           max = true },
  { key = "Altitude",        source = "altitude",        max = true },
  { key = "EscTemp",         source = "escTemp",         max = true, min = true },
  { key = "McuTemp",         source = "mcuTemp",         max = true },
  { key = "Fuel",            source = "fuel",                        min = true, gate = GATE_FUEL_SEEN },
  { key = "Voltage",         source = "voltage",         max = true, min = true, gate = GATE_POSITIVE },
  { key = "BecVoltage",      source = "becVoltage",      max = true, min = true, gate = GATE_POSITIVE },
  { key = "Lq",              source = "lq",              max = true, min = true, gate = GATE_LINK_QUALITY },
  -- Consumed capacity only ever grows within a flight, so its maximum IS what the flight
  -- used. It is recorded rather than read at the disarm edge because a telemetry drop just
  -- before the edge would otherwise lose the whole figure.
  { key = "ConsumedMah",     source = "consumedMah",     max = true },
}

Record.stats = FLIGHT_STATS

--- The record keys, for a reader that wants to enumerate them without knowing the table.
function Record.keys()
  local out = {}
  for i = 1, #FLIGHT_STATS do
    local stat = FLIGHT_STATS[i]
    if stat.max then out[#out + 1] = "max" .. stat.key end
    if stat.min then out[#out + 1] = "min" .. stat.key end
  end
  return out
end

-- The sampled values, kept here rather than read twice: a sensor that answers nothing this pass
-- leaves the previous reading standing, which is what the dashboard's own telemetry read does.
local values = {
  throttlePercent = 0,
  rpm = 0,
  current = 0,
  watts = 0,
  altitude = 0,
  consumedMah = 0,
  escTemp = 0,
  mcuTemp = 0,
  fuel = 0,
  voltage = 0,
  becVoltage = 0,
  lq = 0,
  lqSource = nil,
  fuelSeen = false,
}

--- The trackers. One per shape a row can declare; the compile loop picks between them by reading
--- the row's own columns, and none of them names a statistic.
local function trackMax(src, maxKey)
  return function(rec)
    local v = values[src]
    if type(v) == "number" then
      local b = rec[maxKey]
      if b == nil or v > b then rec[maxKey] = v end
    end
  end
end

local function trackMaxMin(src, maxKey, minKey)
  return function(rec)
    local v = values[src]
    if type(v) == "number" then
      local b = rec[maxKey]
      if b == nil or v > b then rec[maxKey] = v end
      b = rec[minKey]
      if b == nil or v < b then rec[minKey] = v end
    end
  end
end

--- A maximum that takes any number beside a minimum that only takes one above zero: rpm, whose
--- minimum has never recorded the spool-down to zero.
local function trackMaxMinPositiveMin(src, maxKey, minKey)
  return function(rec)
    local v = values[src]
    if type(v) == "number" then
      local b = rec[maxKey]
      if b == nil or v > b then rec[maxKey] = v end
      if v > 0 then
        b = rec[minKey]
        if b == nil or v < b then rec[minKey] = v end
      end
    end
  end
end

local function trackMaxMinPositive(src, maxKey, minKey)
  return function(rec)
    local v = values[src]
    if type(v) == "number" and v > 0 then
      local b = rec[maxKey]
      if b == nil or v > b then rec[maxKey] = v end
      b = rec[minKey]
      if b == nil or v < b then rec[minKey] = v end
    end
  end
end

local function trackMinPositive(src, minKey)
  return function(rec)
    local v = values[src]
    if type(v) == "number" and v > 0 then
      local b = rec[minKey]
      if b == nil or v < b then rec[minKey] = v end
    end
  end
end

--- Fuel, recorded only once a fuel sensor has answered at least once this flight.
local function trackMinFuel(src, minKey)
  return function(rec)
    local v = values[src]
    if type(v) == "number" and values.fuelSeen == true then
      local b = rec[minKey]
      if b == nil or v < b then rec[minKey] = v end
    end
  end
end

--- Link quality: only for a 0-100 % value from a sensor that is not a known RSSI source.
local function trackLink(src, maxKey, minKey)
  return function(rec)
    local v = values[src]
    if type(v) == "number" and v > 0 and v <= 100
       and not (type(values.lqSource) == "string" and RSSI_LINK_SOURCES[values.lqSource]) then
      local b = rec[maxKey]
      if b == nil or v > b then rec[maxKey] = v end
      b = rec[minKey]
      if b == nil or v < b then rec[minKey] = v end
    end
  end
end

-- Compile the rows once: resolve every key, and pick each row's tracker from the shape it
-- declares. Nothing below builds a string or reads the table again.
local TRACK = {}
local TRACK_COUNT = #FLIGHT_STATS

for i = 1, TRACK_COUNT do
  local stat = FLIGHT_STATS[i]
  local maxKey = stat.max and ("max" .. stat.key) or nil
  local minKey = stat.min and ("min" .. stat.key) or nil
  local gate = stat.gate or GATE_ANY
  local minGate = stat.minGate or GATE_ANY
  local src = stat.source
  local built
  if gate == GATE_LINK_QUALITY then
    built = trackLink(src, maxKey, minKey)
  elseif gate == GATE_FUEL_SEEN then
    built = trackMinFuel(src, minKey)
  elseif gate == GATE_POSITIVE and maxKey and minKey then
    built = trackMaxMinPositive(src, maxKey, minKey)
  elseif gate == GATE_POSITIVE then
    built = trackMinPositive(src, minKey)
  elseif maxKey and minKey and minGate == GATE_POSITIVE then
    built = trackMaxMinPositiveMin(src, maxKey, minKey)
  elseif maxKey and minKey then
    built = trackMaxMin(src, maxKey, minKey)
  else
    built = trackMax(src, maxKey)
  end
  TRACK[i] = built
end

local lastSampleAt = nil
local lastTickAt = nil

-- What this record has seen itself, for a board that has not answered with its own totals: an
-- older firmware, a read that failed, a flight controller whose statistics counter is switched
-- off. The dashboard counted this way before the record had an owner, so falling back to it is
-- what keeps a tile showing the same number rather than zero.
local closedFlights = 0
local closedSeconds = 0

-- What was last read off the board, so that a wakeup with nothing running can tell "nothing new"
-- from "the board has answered" without redoing the arithmetic ten times a second.
local lastCount = nil
local lastTotal = nil

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

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
  return 0
end

local function roundInt(value, fallback)
  if type(value) ~= "number" then return fallback end
  return math.floor(value + 0.5)
end

--- The record, created on first use. This is the one place it is brought into being, and the
--- comment at the top of this file is its schema.
local function ensureFlight()
  _G.rfsuite = _G.rfsuite or {}
  local session = _G.rfsuite.session
  if type(session) ~= "table" then
    session = {}
    _G.rfsuite.session = session
  end
  local flight = session.flight
  if type(flight) ~= "table" then
    flight = {
      current = {},
      last = {},
      seconds = 0,
      lastSeconds = 0,
      flights = 0,
      totalSeconds = 0,
      armed = false,
    }
    session.flight = flight
  end
  return flight
end

Record.ensure = ensureFlight

--- Read the tracked sensors. A sensor that answers nothing leaves the previous reading standing,
--- which is what the dashboard's telemetry read has always done, and the derivations below --
--- rounding the two temperatures and the throttle, inferring watts, clamping fuel -- are that
--- read's, moved rather than rewritten.
local function readSources()
  if Sensors == nil then Sensors = loadModule("lib/sensors.lua") or false end
  if not Sensors or type(Sensors.getValue) ~= "function" then return false end
  local get = Sensors.getValue

  values.rpm = get("rpm") or values.rpm
  values.lq = get("link") or values.lq
  values.lqSource = Sensors.active_paths and Sensors.active_paths.link or values.lqSource
  values.mcuTemp = roundInt(get("temp_mcu"), values.mcuTemp)
  values.escTemp = roundInt(get("temp_esc"), values.escTemp)
  values.becVoltage = get("bec_voltage") or values.becVoltage
  values.throttlePercent = roundInt(get("throttle_percent"), values.throttlePercent)

  local current = get("current")
  local voltage = get("voltage")
  local watts = get("watts")
  if type(watts) ~= "number" and type(current) == "number" and type(voltage) == "number" then
    watts = voltage * current
  end
  values.current = current or values.current
  values.watts = watts or values.watts
  values.altitude = get("altitude") or values.altitude
  values.consumedMah = get("smartconsumption") or values.consumedMah
  if type(voltage) == "number" then values.voltage = voltage end

  local fuel = get("smartfuel") or get("fuel")
  if type(fuel) == "number" then
    if fuel < 0 then fuel = 0 end
    if fuel > 100 then fuel = 100 end
    values.fuelSeen = true
    values.fuel = fuel
  end
  return true
end

--- What the flight controller counts, published with the flight in progress added to it.
---
--- The board counts the flights and the armed seconds. Until it has answered -- an older
--- firmware, a read that failed, the counter switched off on the board -- this record's own
--- totals stand in, which is how the dashboard counted before the record had an owner. The board
--- adds a flight only once its armed time passes the board's own minimum, so this sum can fall by
--- a short flight at the moment the board is read again after a disarm.
local function publishTotals(flight, session)
  local count = session.flightcount
  if type(count) ~= "number" or count <= 0 then count = closedFlights end
  flight.flights = count

  local total = session.totalflighttime
  if type(total) ~= "number" then total = closedSeconds end
  flight.totalSeconds = total + (flight.armed and flight.seconds or 0)
end

--- Open a record. The arm edge of the event runtime, through the onarm manifest.
function Record.open()
  local flight = ensureFlight()
  flight.current = {}
  flight.seconds = 0
  flight.armed = true
  values.fuelSeen = false
  lastSampleAt = nil
  lastTickAt = nil
end

--- Close a record: the flight that just ended becomes `last`, and a fresh one takes its place.
--- The disarm edge of the event runtime, through the ondisarm manifest, first in the list, so a
--- task behind it reads the finished flight rather than a record still open.
function Record.close()
  local flight = ensureFlight()
  flight.last = flight.current
  flight.lastSeconds = flight.seconds
  if flight.seconds >= 1 then
    closedFlights = closedFlights + 1
  end
  closedSeconds = closedSeconds + flight.seconds
  flight.current = {}
  flight.seconds = 0
  flight.armed = false
  values.fuelSeen = false
  lastSampleAt = nil
  lastTickAt = nil
end

--- One wakeup of the record. Called from the event runtime in the widget context.
---
--- The clock runs on every wakeup so that a flight's duration does not depend on how often the
--- statistics are sampled; the statistics themselves run on UPDATE_INTERVAL.
function Record.wakeup(armed)
  local flight = ensureFlight()
  local session = _G.rfsuite.session

  -- Nothing is running: no clock to advance and nothing to sample. This is every wakeup of a
  -- radio that is switched on and not flying, so it is kept to the two comparisons that decide
  -- it, plus the board's totals where the board has said something new.
  if armed ~= true and flight.armed ~= true then
    if session.flightcount ~= lastCount or session.totalflighttime ~= lastTotal then
      lastCount, lastTotal = session.flightcount, session.totalflighttime
      publishTotals(flight, session)
    end
    lastTickAt = nil
    return
  end

  if armed == true and flight.armed == true then
    local now = nowSeconds()
    local last = lastTickAt or now
    lastTickAt = now
    local delta = now - last
    if delta < 0 then
      delta = 0
    elseif delta > MAX_CLOCK_STEP then
      delta = MAX_CLOCK_STEP
    end
    flight.seconds = flight.seconds + delta

    if lastSampleAt == nil or (now - lastSampleAt) >= UPDATE_INTERVAL then
      lastSampleAt = now
      if readSources() then
        local rec = flight.current
        for i = 1, TRACK_COUNT do
          TRACK[i](rec)
        end
      end
    end
  else
    lastTickAt = nil
  end

  lastCount, lastTotal = session.flightcount, session.totalflighttime
  publishTotals(flight, session)
end

--- Drop everything. The link going down ends the session the record belongs to.
function Record.reset()
  local flight = ensureFlight()
  closedFlights = 0
  closedSeconds = 0
  lastCount = nil
  lastTotal = nil
  flight.current = {}
  flight.last = {}
  flight.seconds = 0
  flight.lastSeconds = 0
  flight.armed = false
  values.fuelSeen = false
  lastSampleAt = nil
  lastTickAt = nil
end

return Record
