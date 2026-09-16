-- Background decoder for the flight controller's custom telemetry, as a special function.
--
-- The same drain the dashboard and the service widget run, moved into the radio's script
-- state. What that buys is the billing: a widget call is cut off at a fixed instruction count,
-- while a call in the script state is yielded when it has held the interpreter for one task
-- period and resumed on the next turn. So this host decodes every frame it pops, where a
-- widget pass has to leave the older half of a backlog behind.
--
-- It publishes a moving counter in a shared-memory slot while it runs, and the suite's own
-- passes read that and step aside. Nothing here is required: a radio without the special
-- function, or one where the script has stopped, is a radio where the widget drains exactly
-- as it always did.
--
-- Install it as a special function: FUNC_PLAY_SCRIPT on a switch that is always on, with the
-- repetition set to zero so that run() is called on every cycle rather than once per switch
-- edge. tasks/events/onconnect/tasks/function_script.lua does that at connect.

local BASE_PATH = "/SCRIPTS/TOOLS/rfsuite-core/"

local Log = nil
local LogSink = nil
local Preferences = nil
local Drain = nil
local Adjustments = nil
local initialized = false

-- Tasks read their settings from rfsuite.preferences, and that table belongs to one Lua state.
-- Re-read on an interval so a setting changed in the configuration tool takes effect without a
-- restart. It is not held back while the model is armed: a read that is yielded rather than
-- killed costs nothing that matters here.
local PREFERENCES_INTERVAL_SECONDS = 30

-- How often the heap line below is written. It is the figure the whole arrangement has to be
-- judged on: the firmware sums the script state and the widget state against one Lua memory
-- ceiling, so work moved from one to the other relieves nothing by itself.
local HEAP_REPORT_INTERVAL_SECONDS = 30

-- The card sink takes the longer of its two flush cadences here, unconditionally.
--
-- Its argument only chooses between two intervals and never stops the writing, and this state
-- cannot observe arming without loading the sensor module. That is not a free read: nothing else
-- in the script state pulls lib/sensors.lua in, so asking it here would put a second module into
-- a state the firmware bills against the same Lua memory ceiling as every widget -- to choose ten
-- seconds over three. A script that is called on every radio cycle should not be the thing that
-- asks the card for more, so it takes the conservative interval always.
local USE_LONG_FLUSH_CADENCE = true

-- How long the dashboard widget's heartbeat may stand still before this script writes down that
-- it has stopped. It has to outlast the slowest legitimate gap -- a widget is not called at all
-- while another screen page is in front, and a build pass is long -- so it is generous: what is
-- being recorded is a widget that is GONE, not one that is busy.
local WIDGET_STALE_SECONDS = 3.0

local lastPreferencesLoad = nil
local lastHeapReport = nil
local widgetValue = nil
local widgetMovedAt = nil
local widgetWasMoving = false
local widgetReported = false

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  return 0
end

-- The suite's own memoizer where this state already has one, and a plain load where it does
-- not. Nothing else of the suite runs in the script state today -- the configuration tool has
-- a state of its own -- so the memoizer is normally the one init() below has just loaded.
local function loadModule(path)
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then
    local ok, mod = pcall(req, path)
    if ok and type(mod) == "table" then return mod end
  end
  local chunk = loadScript(BASE_PATH .. path, (_G.rfsuite and _G.rfsuite.loadMode) or "bt")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- One pass of its own, and no work in it. Every module below pulls in a subtree -- the decoder
-- table, the CRSF multiplexer, the logger, the audio pack resolver -- and the first turn of a
-- freshly loaded script is not the turn to drain a backlog on as well.
local function init()
  if type(_G.rfsuite) ~= "table" or type(_G.rfsuite.require) ~= "function" then
    local chunk = loadScript(BASE_PATH .. "lib/require.lua", "bt")
    if type(chunk) == "function" then pcall(chunk) end
  end

  Log = loadModule("lib/log.lua")
  Preferences = loadModule("lib/preferences.lua")
  -- This state is the radio's script state, where a call is yielded rather than cut off at an
  -- instruction count, so it is one of the two allowed to bring a card written by an earlier
  -- release across. Said before the first read below, and guarded because an older core has no
  -- such module and this script must still run against it.
  pcall(function() return loadModule("lib/config_store.lua").allowMigration() end)
  Drain = loadModule("tasks/events/telemetry_bg/drain.lua")
  Adjustments = loadModule("tasks/events/telemetry_bg/adjustments.lua")
  initialized = true
end

-- What this state writes to the card is a DEBUG-level record, and it is gated like one.
--
-- The step file is a diagnostic, so it belongs behind the same switch as every other diagnostic
-- in the suite rather than beside it: a subsystem that writes while the configured level says
-- `off` is a surprise, and a surprise in somebody's log directory is a defect however useful the
-- file is. `Log.wanted` is their own predicate for exactly this -- a call site that would pay to
-- build a message asks first.
local function cardRecordWanted()
  if not (Log and type(Log.wanted) == "function") then return false end
  local ok, wanted = pcall(Log.wanted, "debug")
  return ok and wanted == true
end

-- The card sink, loaded the first time it is actually wanted and never before.
--
-- Not in init() above, and that is a memory decision rather than a style one: the module and the
-- session state behind it hold tens of kilobytes in a Lua state the firmware bills against the
-- same ceiling as every widget, both switches are off on a shipped radio, and a pilot who never
-- turns them on should not be paying for it on every flight.
--
-- Once loaded it stays, and it keeps being ticked afterwards whatever the two switches then say.
-- Both are deliberate: Lua cannot give the module back, and a session already open has to be
-- closed, which is the tick's own job.
--
-- The name is this state's own, so its files sit beside the tool's and the widgets' instead of
-- three writers appending to one path.
local function ensureLogSink()
  if LogSink ~= nil then
    return LogSink or nil
  end

  local prefs = _G.rfsuite and _G.rfsuite.preferences
  local general = type(prefs) == "table" and prefs.general or nil
  if not (type(general) == "table" and general.log_to_card == true) then
    return nil
  end
  if not cardRecordWanted() then
    return nil
  end

  LogSink = loadModule("lib/log_sink.lua") or false
  if LogSink and type(LogSink.configure) == "function" then
    LogSink.configure("function")
  end
  return LogSink or nil
end

local function refreshPreferences(now)
  if not Preferences or type(Preferences.load) ~= "function" then return end
  if lastPreferencesLoad and (now - lastPreferencesLoad) < PREFERENCES_INTERVAL_SECONDS then return end
  lastPreferencesLoad = now

  local ok, prefs = pcall(Preferences.load)
  if ok and type(prefs) == "table" then
    _G.rfsuite = _G.rfsuite or {}
    _G.rfsuite.preferences = prefs
  end
end

-- collectgarbage("count") answers in kilobytes as a float, and string.format("%d", ...) refuses
-- a float that is not an exact integer in this Lua -- so it is floored here rather than left to
-- raise inside the formatter, where the message would silently come out as its own format
-- string.
local function reportHeap(now, sink)
  if lastHeapReport and (now - lastHeapReport) < HEAP_REPORT_INTERVAL_SECONDS then return end
  lastHeapReport = now

  local memKb = math.floor(collectgarbage("count"))

  if Log and type(Log.emitf) == "function" then
    Log.emitf("rfsuite.functions", "trace", "heap %d kB", memKb)
  end

  -- Once the dashboard widget has been reported gone, the routine line below keeps SAYING so.
  --
  -- The step file holds one line and is truncated on every write, so without this the most
  -- important line it will ever carry is erased by the least important one on the next interval
  -- -- measured, not feared: a run recorded the widget's stop and thirty seconds later the file
  -- said only that the decoder was running. The session file still has the history, but its
  -- promise is a loss window of one flush cadence, and the case this whole arrangement is for is
  -- the one where the radio does not survive that long.
  local tail = ""
  if widgetReported and widgetMovedAt then
    tail = string.format(", dashboard widget silent since %.0f s", now - widgetMovedAt)
  end

  -- The same figure in the step file, which is the half that survives a radio that has stopped
  -- answering: its timestamp is then the last moment this script ran, and that is a question
  -- nothing else on the card can answer once the widgets are gone. One write per interval, into
  -- a file that is truncated on every open and never grows past the line.
  --
  -- The heap figure is in the label and NOT in the key: a key that changed on every write would
  -- never look like a repeat, and the throttle that keeps this file affordable would never
  -- apply.
  -- Asked again on every write, not only at load: lowering the level has to stop the writing,
  -- and the module cannot be unloaded once it is in.
  if sink and type(sink.step) == "function" and cardRecordWanted() then
    pcall(sink.step, string.format("background decoder running, heap %d kB%s", memKb, tail),
      false, "function heap")
  end
end

--- Watch the dashboard widget's heartbeat and record the moment it stops.
--
-- This is the half a widget cannot do for itself. Past its instruction budget the firmware stops
-- calling the widget's refresh altogether, so the pass that fails can never report itself and no
-- line in the widget's own log is the failing one. From here it is visible: the slot stops moving
-- and its last value still carries what that final pass cost.
--
-- The reader keeps no memory but the last value it saw, and works out for itself whether the
-- counter MOVES -- the value alone says nothing, because nothing ever clears the slots and what
-- stands in one at the first read may be a leftover from a previous session. So a stop is only
-- reported after the counter has been SEEN moving; a slot that was dead from the start is a radio
-- with no dashboard widget on screen, which is not a fault and is not written down.
--
-- One line per stop, not one per pass: `widgetReported` is the edge, and it is cleared when the
-- counter moves again so that a widget which comes back and dies twice is recorded twice.
local function watchWidget(now, sink)
  if type(getShmVar) ~= "function" or not Drain then return end
  local id = Drain.SHM_WIDGET_PASS_ID
  if not id then return end

  local value = getShmVar(id)
  if type(value) ~= "number" or value == 0 then return end

  if value ~= widgetValue then
    if widgetValue ~= nil then
      widgetWasMoving = true
      widgetReported = false
    end
    widgetValue = value
    widgetMovedAt = now
    return
  end

  if not (widgetWasMoving and widgetMovedAt) or widgetReported then return end
  local still = now - widgetMovedAt
  if still < WIDGET_STALE_SECONDS then return end
  widgetReported = true

  -- The low eight bits are what the widget's LAST pass cost, as a percentage of the instruction
  -- budget. Past 255 the firmware's own counter wraps, so a figure at the ceiling is reported as
  -- "at or past" rather than as an exact number it cannot be.
  local usage = value % (Drain.SHM_WIDGET_PASS_SHIFT or 256)
  local text = string.format("dashboard widget silent %.1f s, last pass %s%d %%",
    still, usage >= 255 and ">=" or "", usage)

  if Log and type(Log.emitf) == "function" then
    Log.emitf("rfsuite.functions", "warn", "%s", text)
  end
  if sink and type(sink.step) == "function" and cardRecordWanted() then
    pcall(sink.step, text, true, "widget silent")
  end
end

local function run()
  if not initialized then
    init()
    return
  end

  local now = nowSeconds()
  refreshPreferences(now)

  if Drain then
    -- After the work, and only for a pass that took frames. What the other decoders need to
    -- know is not that this script is running -- it is whether the frames are being consumed
    -- here, and those two come apart. Every permanent script on the radio shares one telemetry
    -- queue, so another one popping first leaves this pass with nothing to do while it still
    -- runs on every cycle; a counter bumped on being called would then hold the widget's own
    -- drain down for as long as the radio is on, and nothing would decode at all.
    --
    -- The cost of the other order is one stale window on a long pass, and it is not a loss:
    -- each Lua state is served its own copy of every frame, so a host that resumes early
    -- decodes what it already had rather than taking anything from this one.
    local popped = Drain.wakeup(now, true)
    if (popped or 0) > 0 then
      Drain.publishLiveness()
    end
  end

  -- After the decode, never before it: what the teller reads is what the drain has just
  -- published, so the other order would announce one pass behind.
  if Adjustments and type(Adjustments.wakeup) == "function" then
    Adjustments.wakeup()
  end

  local sink = ensureLogSink()
  watchWidget(now, sink)
  reportHeap(now, sink)

  -- Last, so the lines this pass produced go out with it rather than one pass later.
  if sink and type(sink.tick) == "function" then
    pcall(sink.tick, USE_LONG_FLUSH_CADENCE)
  end
end

return { run = run }
