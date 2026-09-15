-- What a model must look like before the in-flight tuning overlay can drive it -- and, since the
-- pilot asked for it, how to make it look like that.
--
-- This half of the overlay is shared by two callers with very different budgets. The dashboard
-- widget needs the settings, the radio seam and the trim block; the settings page needs those
-- plus the setup check and the model write, and needs them WITHOUT the live state machine and
-- without the adjustment-function tables behind it. Keeping them in one file cost the settings
-- page the whole of `drive.lua` and `functions.lua` on entry -- measured at 114 kB of Lua on a
-- desktop interpreter, against 0.1 to 3.9 kB for the project's other settings pages -- on a radio
-- whose tool had 134 kB of heap left. So the split is not tidiness: it is the page's memory.
--
-- Everything that touches the radio goes through the small table `M.radio()` returns, so a radio
-- that does not offer one of those calls makes this file say less rather than raise.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if rChunk then
    local ok, res = pcall(rChunk)
    if ok and type(res) == "function" then
      requireModule = res
    end
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")

-- The trace of what the overlay wrote, through the logging core: the session ring takes it, and
-- the card sink when logging to card is on. The message is assembled past the gate rather than by
-- the caller, following the idiom widgets/dashboard/runtime.lua uses for its own reload trace --
-- with the test inside the function the callers still paid for a string that was then dropped.
local function logDrive(fmt, ...)
  if not (Log and type(Log.wanted) == "function" and Log.wanted("info")) then return end
  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  Log.emit("rfsuite.inflight", msg, "info")
end

-- The same trace, for the half of the overlay that lives in drive.lua: it has no logger of its
-- own now that the assembly past the gate lives here.
M.log = logDrive

-- What the two [inflight] sections hold, and what the overlay falls back to when they hold
-- nothing. One table for both of them, keyed by M.RADIO_KEYS and M.MODEL_KEYS below: a default is
-- a property of the setting rather than of the file it happens to live in, and two tables would
-- be two places to change it.
--
-- The MODEL half of this table -- the keys M.MODEL_KEYS lists -- is duplicated in
-- lib/model_preferences.lua, which seeds a new per-model store and cannot require a widget module
-- to reach these. The two MUST agree; the same note sits on the other side. The radio half is not
-- duplicated anywhere: lib/preferences.lua seeds the section and its switch, and every other radio
-- key is filled in from here when the store does not hold it.
--
-- No global variable is defaulted: a variable this overlay writes has to be one the pilot
-- declared, because writing an arbitrary one would move whatever it already drives. The channels
-- ARE defaulted, to the pair the project's own generic radio setup documents.
M.DEFAULTS = {
  -- Both sections carry a key of this name and both default to off, which is why one entry
  -- serves them. The radio's says the pilot wants the overlay on this transmitter at all; the
  -- model's says this machine is set up for it. See M.settings for how the two combine.
  enabled = false,
  switch = 0,
  bank_ch = 11,
  value_ch = 12,
  -- The two variables are DEFAULTED, and the pilot's ruling after the third radio round is what
  -- changed here. They used to default to 0 -- "none" -- and be proposed from what the model left
  -- free, on the reasoning that a defaulted variable might already drive something. Two radio
  -- rounds showed what that cost: a pilot who has not been to this page has an overlay that
  -- cannot go live at all, and a proposal that moves with the model is a setting nobody can write
  -- down or check. So the pair is fixed, high in the range where a helicopter model rarely
  -- reaches, and the model is walked to WARN that one of them is spoken for rather than to choose.
  bank_gvar = 6,
  value_gvar = 5,
  -- Long enough that the flight controller sees the channel stand still, and short enough that it
  -- does not count the stillness twice. It takes no step until the value has been steady inside
  -- one window for TRIGGER_DELAY, 100 ms, and repeats every REPEAT_DELAY, 200 ms after that
  -- (fc/rc_adjustments.c) -- so a press has to hold its plateau past 100 ms and let go before 300.
  -- What the board sees is not this number, though: it is this number plus up to one widget pass,
  -- since the pulse is cleared on the first pass at or AFTER its deadline, plus the link's own
  -- jitter -- on a receiver sending the AUX channels round-robin at 250 Hz, some 32 ms either way.
  -- 180 puts the plateau at 148..262 ms in the worst case, about 40 ms clear of both edges. The
  -- earlier default of 250 sat on the upper one at 250..332 ms, over the repeat; 150 cleared the
  -- lower by 50 ms and left nothing for a pass that ran late.
  pulse_ms = 180,
  trims = true,
  -- Walk-and-adjust with three trims is the arrangement the pilot flew and asked to keep, and it
  -- is the one that works on every radio: the six-trim layout needs six trims, and the TX15, the
  -- Boxer and the Pocket have four. Rudder walks the rows, elevator steps the bank, aileron
  -- moves the value -- three thumbs' worth of gesture, throttle left alone.
  trim_mode = "navigate",
  nav_trim = 1,
  bank_trim = 2,
  adj_trim = 4,
  row_trim_1 = 2,
  row_trim_2 = 4,
  row_trim_3 = 1,
  row_trim_4 = 3,
  row_trim_5 = 5,
  row_trim_6 = 6,
  -- The last PID profile, because a helicopter that uses several uses them from the first upwards
  -- and the undo wants the one nothing is flown on. A default and not a rule: a board with fewer
  -- profiles has the choice refused by name, and the pilot can move it.
  backup_profile = 6,
  set_mode = "standard",
  -- What one press of a step control moves a parameter by, in the flight controller's own units.
  -- It is written into every slot the setup action puts on the board except the head speed's, so
  -- a changed step means setting the flight controller up again -- which the help says and the
  -- compare verdict reports.
  step = 5,
  -- The head speed's own, because it is the one cell of the set whose range is 0..10000 while no
  -- other is bounded above 250: the step that makes a gain move by a feelable amount would take
  -- two thousand presses to cross it. Its rungs start where the general ones stop, and it reaches
  -- no other slot.
  step_headspeed = 50
}

M.PULSE_MS_MIN = 100
-- The largest setting whose own overrun cannot reach the board's SECOND step. The second step
-- lands 300 ms into a held plateau (TRIGGER_DELAY 100 ms, then REPEAT_DELAY 200 ms counted from
-- the first), and the overlay clears the pulse on the first pass at or AFTER its deadline, so a
-- plateau stands for its setting plus up to one pass. 250 leaves that overrun the whole of the
-- remaining 50 ms; anything longer would let one late pass turn a press into two steps, which is
-- the failure a pilot cannot see happening. A stored value above this is clamped on load.
M.PULSE_MS_MAX = 250

-- What one press moves a parameter by on the board. Four rungs rather than a free number: the
-- firmware stores the step in one byte per slot and the four cover the range a pilot asks for --
-- one for the parameters where a single unit is already a change worth feeling, ten for the ones
-- whose useful range is hundreds. Anything else the store happens to hold is rounded to the
-- nearest of the four rather than refused, so a hand-edited file cannot put a step on the board
-- that the compare would then report as a mismatch for ever.
M.STEP_CHOICES = { 1, 2, 5, 10 }

-- The same four rungs for the head speed, moved up the scale its own range asks for: ten thousand
-- rpm against the 250 no other cell of the set is bounded above, so the smallest rung here is the
-- largest one there and a hundred is still a hundred presses across the range.
M.HEADSPEED_STEP_CHOICES = { 10, 25, 50, 100 }
M.CHANNEL_MIN = 5
M.CHANNEL_MAX = 16
-- F4 and F7 radios carry nine global variables, H7 fifteen. Nine is what every target has.
M.GVAR_MAX_INDEX = 9
M.TRIM_COUNT = 6
M.PROFILE_MAX = 6

-- The two ways the physical trims reach the parameters.
--
-- `rows` is the reference layout: six trims, six rows, each trim's two directions moving that
-- row's parameter. `navigate` claims two trims instead -- one walks the set and one adjusts what
-- the walk has selected -- which is the route for a radio with four trims and for a pilot who
-- wants one gesture rather than six positions to remember.
--
-- `navigate` takes an optional THIRD trim, and it is the pilot's own ask after the first radio
-- round. With it the walk splits in two: the third trim steps the BANK and the walk trim then
-- moves between the rows of the bank it is in, which is the shape of the set itself -- six banks
-- of six -- rather than a strip of thirty-six the pilot has to count his way along. Left at 0 the
-- walk trim walks the whole set as it did, so the two-trim route is unchanged.
M.TRIM_MODE_ROWS = "rows"
M.TRIM_MODE_NAVIGATE = "navigate"

-- The two ways the overlay learns which parameter sits in which bank and row.
--
-- `standard` is a set the overlay KNOWS: the documented six-band layout with the six cells it
-- leaves empty filled in, held in inflight/functions.lua. The screen can name every cell before
-- the board has said anything, the board's own slot table is read only to be COMPARED against it,
-- and the settings page can offer to write that set onto the flight controller.
--
-- `custom` is the board's: the slot table is read and turned into whatever layout it describes,
-- nothing is ever written, and the documented layout stands only where the table yields nothing
-- the overlay can drive. It is the mode for a pilot whose adjustment configuration is his own.
M.SET_MODE_STANDARD = "standard"
M.SET_MODE_CUSTOM = "custom"

-- Which setting belongs to which file, and the whole of the ownership rule in two lists.
--
-- A setting belongs to the RADIO when it is true of the transmitter whatever is plugged into it:
-- the interlock switch, the two channels and the two global variables the mixer devotes to the
-- adjustment pair, the pulse length, and which trims stand in for the rows. One transmitter has
-- one set of those, and a pilot who set them up once should not meet them again on his next
-- model. They live in the radio's own preferences file, section [inflight].
--
-- A setting belongs to the MODEL when it describes the machine: which set of parameters its
-- flight controller offers, how far one press moves them, and which PID profile is the undo.
-- Those stay in the per-model store, section [inflight], keyed by the flight controller's MCU id.
--
-- `enabled` is in BOTH lists, and deliberately: see M.settings.
M.RADIO_KEYS = {
  "enabled", "switch", "bank_ch", "value_ch", "bank_gvar", "value_gvar", "pulse_ms",
  "trims", "trim_mode", "nav_trim", "bank_trim", "adj_trim",
  "row_trim_1", "row_trim_2", "row_trim_3", "row_trim_4", "row_trim_5", "row_trim_6"
}

M.MODEL_KEYS = { "enabled", "set_mode", "step", "step_headspeed", "backup_profile" }

--- The rung of `choices` a stored value means.
--
-- Rounded to the nearest rather than refused, and `fallback` where there is no number at all. A
-- store is a text file a pilot can edit, and a step the overlay rejected would leave the board
-- written with one number and compared against another with nothing on screen able to say why.
local function nearestChoice(value, choices, fallback)
  local wanted = tonumber(value)
  if wanted == nil then return fallback end
  local best, bestDistance = choices[1], nil
  for i = 1, #choices do
    local choice = choices[i]
    local distance = math.abs(choice - wanted)
    if bestDistance == nil or distance < bestDistance then
      best, bestDistance = choice, distance
    end
  end
  return best
end

--- The rung of M.STEP_CHOICES a stored value means.
function M.nearestStep(value)
  return nearestChoice(value, M.STEP_CHOICES, M.DEFAULTS.step)
end

--- The rung of M.HEADSPEED_STEP_CHOICES a stored value means. The head speed's step is a setting
-- of its own, so it is rounded onto its own rungs and never onto the general ones.
function M.nearestHeadspeedStep(value)
  return nearestChoice(value, M.HEADSPEED_STEP_CHOICES, M.DEFAULTS.step_headspeed)
end

-- TRIM_MODE_NONE, as model.getFlightMode reports it. A row driven from a trim needs the trim
-- switched OFF in the active flight mode, otherwise the same press also moves a stick's neutral.
local TRIM_MODE_NONE = 31

-- A mixer weight naming a global variable is stored as 1024 plus that variable's source index
-- (datastructs_private.h). This is the offset the check reads a weight back through.
local MIX_WEIGHT_GVAR_BASE = 1024
-- MLTPX_ADD, the multiplex mode a plain summed line has.
local MIX_MULTIPLEX_ADD = 0

--- The trim layout a store asks for, or the default when it asks for neither.
local function trimMode(value)
  if value == M.TRIM_MODE_NAVIGATE then return M.TRIM_MODE_NAVIGATE end
  if value == M.TRIM_MODE_ROWS then return M.TRIM_MODE_ROWS end
  return M.DEFAULTS.trim_mode
end

local function clampNumber(value, low, high, fallback)
  value = tonumber(value)
  if value == nil then return fallback end
  if value < low then return low end
  if value > high then return high end
  return math.floor(value + 0.5)
end

-- ---------------------------------------------------------------------------
-- The radio, behind functions
-- ---------------------------------------------------------------------------

local function callGlobal(name, ...)
  local fn = _G and _G[name]
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if not ok then return nil end
  return a, b, c
end

-- How many entries the switch walk is allowed to take before it gives up. The firmware's own
-- iterator ends on its own; the bound is here so a stub or a future firmware that does not
-- cannot hang the widget pass.
local SWITCH_WALK_LIMIT = 256

-- How many switch positions one WIDGET pass may take off that walk.
--
-- The whole walk does not fit in a widget pass and must not be attempted in one. `switches()`
-- yields every available position on the radio -- the physical switches, both positions of every
-- trim, the flight modes and every logical switch the model has configured -- and each one costs
-- a call into the firmware plus a table. Run in a startup pass, where the widget is already close
-- to the firmware's per-call instruction limit, the walk overruns it: the pass raises `CPU limit`,
-- the widget entry point catches it and the pass is abandoned before anything below it has run.
-- Measured on a radio: with the overlay enabled the dashboard never left its connection splash,
-- because every pass died in this walk and the build was enqueued in the part of `refresh` that
-- was never reached. The walk is therefore taken in slices and resumed, the way the runtime's own
-- scene build is chunked.
local SWITCH_SLICE = 32

local function modelApi(name)
  local m = _G and _G.model
  if type(m) ~= "table" then return nil end
  local fn = m[name]
  if type(fn) ~= "function" then return nil end
  return fn
end

-- The mixer readers again, straight off the firmware rather than through the radio table below.
--
-- The WRITE wrappers need them: api_model.cpp's luaModelInsertMix and luaModelDeleteMix return
-- nothing at all, and they do nothing -- without raising -- when the mixer table is full, when the
-- channel is out of range or when the line index is past the end of the channel. So the only thing
-- that can say whether a mixer write happened is the model read back afterwards, and a wrapper
-- inside the table cannot reach the table's own readers while that table is still being built.
local function mixesCountOf(channel0)
  local fn = modelApi("getMixesCount")
  if not fn then return nil end
  local ok, count = pcall(fn, channel0)
  if not ok then return nil end
  return tonumber(count)
end

local function mixLineOf(channel0, line0)
  local fn = modelApi("getMix")
  if not fn then return nil end
  local ok, mix = pcall(fn, channel0, line0)
  if not ok or type(mix) ~= "table" then return nil end
  return mix
end

--- The radio surface the drive uses, and the only place in this file that touches a global.
--
-- Every member answers nil when the firmware does not provide it, so a radio without one of them
-- makes the overlay say less rather than raise inside the widget pass.
function M.radio()
  return {
    now = function()
      return tonumber((callGlobal("getTime"))) or 0
    end,

    -- true while the position is the one the switch rests in, false when it is not, and nil when
    -- this radio does not have that position at all -- which is how a trim the radio lacks is
    -- told apart from a trim nobody is pressing.
    switchValue = function(swsrc)
      return callGlobal("getSwitchValue", swsrc)
    end,

    -- Every switch POSITION the radio offers, in the firmware's own order, as { swsrc, name }.
    -- The trim block is found by walking this rather than by computing an index: the first trim's
    -- position number is not a constant Lua is ever told.
    -- `from` resumes the walk after that position and `budget` bounds what one call takes; with
    -- neither it walks the lot, which is what a Lua PAGE wants and what a widget pass must not do.
    -- Resuming needs no state on this side: the firmware's iterator is a plain function of (last,
    -- index), so handing it back the last position seen continues exactly where it stopped.
    --
    -- Returns the slice and the position to resume AFTER, or nil for "that was the end".
    switchList = function(from, budget)
      local iter, last, first = callGlobal("switches")
      if type(iter) ~= "function" then return nil end
      local list = {}
      local index = from or first
      for _ = 1, (budget or SWITCH_WALK_LIMIT) do
        local ok, nextIndex, name = pcall(iter, last, index)
        if not ok or nextIndex == nil then return list, nil end
        list[#list + 1] = { swsrc = nextIndex, name = name }
        index = nextIndex
      end
      return list, index
    end,

    -- The only member that needs the adjustment-function tables, and it is one the settings page
    -- never calls. Requiring them here rather than at the top of the file is what keeps a page
    -- that only wants the check from paying for functions.lua as well.
    channelUs = function(channel)
      local fns = requireModule("widgets/dashboard/inflight/functions.lua")
      if type(fns) ~= "table" then return nil end
      return fns.channelRawToUs(callGlobal("getValue", "ch" .. tostring(channel)))
    end,

    sensor = function(name)
      return tonumber((callGlobal("getValue", name)))
    end,

    -- The radio's own wall clock, as "HH:MM", or nil where the firmware does not offer one.
    --
    -- The ground surface says WHEN it read the board and when the backup was made, and a tick
    -- count cannot say that: getTime() counts from power-on, so "1470" is a number the pilot has
    -- to subtract something from. It is read once per event and stored as the string, never per
    -- frame -- a reactive closure that called into the firmware for a clock would be exactly the
    -- probe the surface is forbidden.
    clock = function()
      local dt = callGlobal("getDateTime")
      if type(dt) ~= "table" then return nil end
      local hour, minute = tonumber(dt.hour), tonumber(dt.min)
      if hour == nil or minute == nil then return nil end
      return string.format("%02d:%02d", hour, minute)
    end,

    -- getFlightMode() answers with the mode number AND its name, and getSourceIndex and
    -- getValue may grow a second return the same way, so every one of these calls is truncated to
    -- its first value before tonumber sees it. Unparenthesised, the second return lands on
    -- tonumber's BASE argument and the call raises inside the widget pass.
    flightMode = function()
      return tonumber((callGlobal("getFlightMode"))) or 0
    end,

    setGlobalVariable = function(index0, fm, value)
      local fn = modelApi("setGlobalVariable")
      if not fn then return false end
      return pcall(fn, index0, fm, value)
    end,

    globalVariableDetails = function(index0)
      local fn = modelApi("getGlobalVariableDetails")
      if not fn then return nil end
      local ok, details = pcall(fn, index0)
      if not ok or type(details) ~= "table" then return nil end
      return details
    end,

    mixesCount = function(channel)
      local fn = modelApi("getMixesCount")
      if not fn then return nil end
      local ok, count = pcall(fn, channel - 1)
      if not ok then return nil end
      return tonumber(count) or 0
    end,

    mix = function(channel, line0)
      local fn = modelApi("getMix")
      if not fn then return nil end
      local ok, mix = pcall(fn, channel - 1, line0)
      if not ok or type(mix) ~= "table" then return nil end
      return mix
    end,

    -- The INPUT lines, which encode a source reference in a weight or an offset exactly as a mixer
    -- line does. A radio whose firmware does not offer these answers nil and the walk that uses
    -- them says less rather than raising.
    inputsCount = function(input0)
      local fn = modelApi("getInputsCount")
      if not fn then return nil end
      local ok, count = pcall(fn, input0)
      if not ok then return nil end
      return tonumber(count) or 0
    end,

    input = function(input0, line0)
      local fn = modelApi("getInput")
      if not fn then return nil end
      local ok, line = pcall(fn, input0, line0)
      if not ok or type(line) ~= "table" then return nil end
      return line
    end,

    flightModeData = function(fm)
      local fn = modelApi("getFlightMode")
      if not fn then return nil end
      local ok, data = pcall(fn, fm)
      if not ok or type(data) ~= "table" then return nil end
      return data
    end,

    sourceIndex = function(name)
      return tonumber((callGlobal("getSourceIndex", name)))
    end,

    mixsrcMax = function()
      return tonumber(_G and _G.MIXSRC_MAX)
    end,

    -- The names the pilot reads on the radio's own mixer page, so that a line this file offers to
    -- DELETE is named the way the screen it will disappear from names it. Both answer nil rather
    -- than raise, and a plan that cannot name a line still counts it.
    sourceName = function(index)
      local name = callGlobal("getSourceName", index)
      return type(name) == "string" and name or nil
    end,

    switchName = function(swsrc)
      if swsrc == nil or swsrc == 0 then return nil end
      local name = callGlobal("getSwitchName", swsrc)
      return type(name) == "string" and name or nil
    end,

    -- The write half. Every one of these is wrapped where it is CALLED as well, because a plan
    -- reports which of its steps went through and a false here is one of the two ways a step can
    -- fail -- the other being a firmware that does not offer the call at all.
    --
    -- What a true from these means is the point, and it is not "the call did not raise". None of
    -- the four writers raises on a refusal: luaModelInsertMix, luaModelDeleteMix and
    -- luaModelSetGlobalVariableDetails return nothing and do nothing when an index is out of range
    -- or the mixer table is full, and luaModelSetFlightMode answers 0 for done and 2 for a flight
    -- mode this model does not have. So the firmware's own answer is returned where it gives one,
    -- and where it gives none the write is READ BACK -- and a write that cannot be read back is
    -- reported as not made rather than as made.
    setGlobalVariableDetails = function(index0, details)
      local fn = modelApi("setGlobalVariableDetails")
      if not fn then return false, "unsupported" end
      local ok, err = pcall(fn, index0, details)
      if not ok then return false, tostring(err) end
      local read = modelApi("getGlobalVariableDetails")
      if not read then return false, "unverified" end
      local okRead, have = pcall(read, index0)
      if not okRead or type(have) ~= "table" then return false, "unverified" end
      -- Every key that was handed over, and only those: the writer walks the table it is given, so
      -- a key it was not given is a field the caller never claimed anything about.
      for key, wanted in pairs(details) do
        local got = have[key]
        if type(wanted) == "number" then got = tonumber(got) end
        if got ~= wanted then return false, "not written: " .. tostring(key) end
      end
      return true
    end,

    insertMix = function(channel, line0, value)
      local fn = modelApi("insertMix")
      if not fn then return false, "unsupported" end
      local before = mixesCountOf(channel - 1)
      local ok, err = pcall(fn, channel - 1, line0, value)
      if not ok then return false, tostring(err) end
      if before == nil then return false, "unverified" end
      if mixesCountOf(channel - 1) ~= before + 1 then return false, "not inserted" end
      local have = mixLineOf(channel - 1, line0)
      if have == nil then return false, "unverified" end
      if tonumber(have.source) ~= tonumber(value.source)
          or tonumber(have.weight) ~= tonumber(value.weight) then
        return false, "wrong line"
      end
      return true
    end,

    deleteMix = function(channel, line0)
      local fn = modelApi("deleteMix")
      if not fn then return false, "unsupported" end
      local before = mixesCountOf(channel - 1)
      local ok, err = pcall(fn, channel - 1, line0)
      if not ok then return false, tostring(err) end
      if before == nil then return false, "unverified" end
      if mixesCountOf(channel - 1) ~= before - 1 then return false, "not deleted" end
      return true
    end,

    -- Only the keys handed over are written (api_model.cpp walks the table it is given), so a
    -- table carrying nothing but trimsModes leaves the flight mode's name, switch and fades
    -- exactly as they were.
    setFlightMode = function(fm, data)
      local fn = modelApi("setFlightMode")
      if not fn then return false, "unsupported" end
      local ok, answer = pcall(fn, fm, data)
      if not ok then return false, tostring(answer) end
      -- 0 is done, 2 is a flight mode this model does not have. A firmware that answers nothing is
      -- taken at its word, there being nothing here to read back that the caller did not send.
      local code = tonumber(answer)
      if code ~= nil and code ~= 0 then return false, "refused " .. tostring(code) end
      return true
    end,

    -- Whether the firmware offers the mixer WRITERS at all. A radio that does not is told from
    -- one that does before a plan is built, so the button can say so instead of failing halfway.
    canWrite = function()
      return modelApi("insertMix") ~= nil and modelApi("deleteMix") ~= nil
    end
  }
end
-- How many switch positions one WIDGET pass may take off the walk; the drive reads it from here.
M.SWITCH_SLICE = SWITCH_SLICE
-- and the ceiling the resumed walk is bounded by, for the same caller.
M.SWITCH_WALK_LIMIT = SWITCH_WALK_LIMIT

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

--- The [inflight] section of one of the two stores, or an empty table where there is none.
--
-- Reading is deliberately forgiving -- a store written by an older build is missing keys rather
-- than wrong -- and the two halves are read STRICTLY from their own file: a radio key found in a
-- per-model store is left where it is and never read, and neither half falls back to the other.
local function section(store)
  if type(store) == "table" and type(store.inflight) == "table" then return store.inflight end
  return {}
end

--- The radio's half of the [inflight] section, filled in and bounded.
--
-- Bounding is not forgiving: a channel or a variable index outside what the radio has would be a
-- write into something else entirely.
function M.loadRadioSettings(preferences)
  local src = section(preferences)

  local settings = {
    enabled = src.enabled == true,
    switch = clampNumber(src.switch, -1024, 1024, M.DEFAULTS.switch),
    bank_ch = clampNumber(src.bank_ch, M.CHANNEL_MIN, M.CHANNEL_MAX, M.DEFAULTS.bank_ch),
    value_ch = clampNumber(src.value_ch, M.CHANNEL_MIN, M.CHANNEL_MAX, M.DEFAULTS.value_ch),
    bank_gvar = clampNumber(src.bank_gvar, 0, M.GVAR_MAX_INDEX, M.DEFAULTS.bank_gvar),
    value_gvar = clampNumber(src.value_gvar, 0, M.GVAR_MAX_INDEX, M.DEFAULTS.value_gvar),
    pulse_ms = clampNumber(src.pulse_ms, M.PULSE_MS_MIN, M.PULSE_MS_MAX, M.DEFAULTS.pulse_ms),
    trims = src.trims ~= false,
    -- Named explicitly in both directions, so that the DEFAULT is what an unset store gets. Read
    -- as "navigate or else rows" this silently pinned every store that had never been saved to
    -- the layout that happened to be the fallback, and moving the default would have moved
    -- nothing at all.
    trim_mode = trimMode(src.trim_mode),
    -- The upper bound is the switch-position range and not the trim count: since the pilot's
    -- third radio round these hold the POSITION of a trim's `+`, which is a number well above six
    -- on every radio. A store written before that still holds an index of 1..6, and M.migrateTrims
    -- turns it into a position once the radio has said what its trims are.
    nav_trim = clampNumber(src.nav_trim, 0, 1024, M.DEFAULTS.nav_trim),
    bank_trim = clampNumber(src.bank_trim, 0, 1024, M.DEFAULTS.bank_trim),
    adj_trim = clampNumber(src.adj_trim, 0, 1024, M.DEFAULTS.adj_trim)
  }

  settings.rowTrim = {}
  for row = 1, M.TRIM_COUNT do
    local key = "row_trim_" .. tostring(row)
    settings.rowTrim[row] = clampNumber(src[key], 0, 1024, M.DEFAULTS[key])
  end

  return settings
end

--- The model's half of the [inflight] section, filled in and bounded.
function M.loadModelSettings(modelPreferences)
  local src = section(modelPreferences)

  return {
    enabled = src.enabled == true,
    -- Anything that is not the word `custom` is the standard set, which is what a store written
    -- by a build that did not have this setting yet reads as -- and is the right way round: the
    -- standard set names every cell without a round trip, while the custom one shows nothing at
    -- all until the board has been read.
    set_mode = (src.set_mode == M.SET_MODE_CUSTOM) and M.SET_MODE_CUSTOM or M.SET_MODE_STANDARD,
    step = M.nearestStep(src.step),
    -- A store written before the head speed had a step of its own holds nothing here and reads as
    -- the default, which is the number that build wrote into the slot anyway only if the pilot
    -- had left the general step alone -- so the compare may report the head speed's slot as
    -- differing on the step until the flight controller is set up again. That is the verdict
    -- doing its job: the board really does carry the other number.
    step_headspeed = M.nearestHeadspeedStep(src.step_headspeed),
    backup_profile = clampNumber(src.backup_profile, 0, M.PROFILE_MAX, M.DEFAULTS.backup_profile)
  }
end

--- Both halves in one table, plus the answer to the only question the drive asks of them.
--
-- TWO switches have to be on, and neither implies the other. The radio's says the pilot wants the
-- overlay on this transmitter; with it off nothing happens on any model, and the model's switch
-- has no effect at all. The model's says this machine is set up for it; a transmitter that flies
-- six helicopters drives the one whose switch is on and leaves the other five alone. `active` is
-- the conjunction, and it is what everything downstream tests -- the two flags travel beside it
-- so that a surface can say WHICH of them is the one that is off.
function M.settings(preferences, modelPreferences)
  local radio = M.loadRadioSettings(preferences)
  local model = M.loadModelSettings(modelPreferences)
  local radioEnabled = radio.enabled == true

  for i = 1, #M.MODEL_KEYS do
    local key = M.MODEL_KEYS[i]
    if key ~= "enabled" then radio[key] = model[key] end
  end

  -- No merged key called `enabled`. The name means one thing in each file and nothing at all in
  -- the union of them, so the drive is given the two it can tell apart and the answer it wants.
  radio.enabled = nil
  radio.radio_enabled = radioEnabled
  radio.model_enabled = model.enabled == true
  radio.active = radioEnabled and radio.model_enabled
  return radio
end

--- Write the radio's half back into the shape its store keeps. Scalars only, like the model's.
--
-- Each writer touches ONLY the keys of its own half. One writer for both was what let the flight
-- controller page rewrite the radio's keys and the radio page rewrite the board's, which is
-- harmless while there is one file and a silent clobber once there are two.
function M.storeRadioSettings(target, settings)
  if type(target) ~= "table" or type(settings) ~= "table" then return end
  target.enabled = settings.enabled == true
  target.switch = settings.switch or 0
  target.bank_ch = settings.bank_ch
  target.value_ch = settings.value_ch
  target.bank_gvar = settings.bank_gvar
  target.value_gvar = settings.value_gvar
  target.pulse_ms = settings.pulse_ms
  target.trims = settings.trims == true
  target.trim_mode = settings.trim_mode or M.TRIM_MODE_ROWS
  target.nav_trim = settings.nav_trim or 0
  target.bank_trim = settings.bank_trim or 0
  target.adj_trim = settings.adj_trim or 0
  for row = 1, M.TRIM_COUNT do
    target["row_trim_" .. tostring(row)] = (settings.rowTrim and settings.rowTrim[row]) or 0
  end
end

--- Write the model's half back into the shape the per-model store keeps. Scalars only:
-- lib/model_preferences.lua serialises one level of tables and nothing below it.
function M.storeModelSettings(target, settings)
  if type(target) ~= "table" or type(settings) ~= "table" then return end
  target.enabled = settings.enabled == true
  target.set_mode = settings.set_mode or M.SET_MODE_STANDARD
  target.step = M.nearestStep(settings.step)
  target.step_headspeed = M.nearestHeadspeedStep(settings.step_headspeed)
  target.backup_profile = settings.backup_profile
end

-- ---------------------------------------------------------------------------
-- The trim block
-- ---------------------------------------------------------------------------

local function endsWith(name, char)
  if type(name) ~= "string" or name == "" then return false end
  return string.sub(name, -1) == char
end

--- The radio's trim positions, resolved by walking the switch list.
--
-- The firmware names a trim position `<trim label><+|->`, the label being the localised and
-- renameable short label of the stick it belongs to (strhelpers.cpp), so no stem can be
-- hard-coded. The positions come in pairs, the even one decrementing; a radio with four trims
-- simply does not offer the last two, and they are absent from the list rather than false.
--
-- The middle position of a three-position switch is also spelled with a hyphen, which is why a
-- run is accepted only when it is at least one whole pair long and alternates minus, plus from
-- its start -- a lone `SA-` between two arrow-spelled positions can never satisfy that.
function M.resolveTrims(radio)
  local list = radio and type(radio.switchList) == "function" and radio.switchList() or nil
  return M.trimsFromList(list)
end

--- The same analysis over a list that has already been read, in one slice or in several.
--
-- Kept apart from the walk above because the two have different budgets: a Lua page reads the
-- whole list in one call and analyses it there, while a widget pass reads it a slice at a time
-- and analyses it once, on the pass that completes it.
function M.trimsFromList(list)
  if type(list) ~= "table" or #list == 0 then return nil end

  local bestStart, bestLength = nil, 0
  local index = 1
  while index <= #list do
    local length = 0
    while index + length <= #list do
      local name = list[index + length].name
      local wanted = (length % 2 == 0) and "-" or "+"
      if not endsWith(name, wanted) then break end
      length = length + 1
    end
    if length >= 2 then
      local pairs2 = length - (length % 2)
      if pairs2 > bestLength then
        bestStart, bestLength = index, pairs2
      end
      index = index + length
    else
      index = index + 1
    end
  end

  if bestStart == nil then return nil end

  local trims = {}
  for trim = 1, bestLength // 2 do
    local entry = list[bestStart + (trim - 1) * 2]
    local plus = list[bestStart + (trim - 1) * 2 + 1]
    local name = entry.name
    if type(name) == "string" and #name > 1 then
      name = string.sub(name, 1, #name - 1)
    end
    trims[trim] = { name = name, minus = entry.swsrc, plus = plus.swsrc }
  end
  -- A lookup from either position of a trim straight to its entry, built once here rather than
  -- walked per read. The drive resolves up to eight settings against this block on every pass --
  -- three navigate jobs, six rows, the row mask -- and a linear scan of both positions of six
  -- trims for each of them is a hundred comparisons a pass for an answer that never moves.
  -- Kept OFF the numeric part of the table, so `trims[1..6]` is still the semantic order and
  -- everything that walks it is unchanged.
  local byPosition = {}
  for trim = 1, #trims do
    byPosition[trims[trim].minus] = trims[trim]
    byPosition[trims[trim].plus] = trims[trim]
  end
  trims.byPosition = byPosition
  return trims
end

-- ---------------------------------------------------------------------------
-- Which trim a setting names
-- ---------------------------------------------------------------------------

-- A stored trim used to be a SEMANTIC INDEX, 1..6 in the firmware's own trim order, and is now
-- the switch POSITION of the trim's `+`, which is what the radio's switch picker hands over and
-- what getSwitchValue takes. Both forms are read.
--
-- The two cannot be confused, and it is worth saying why rather than hoping. A trim's position
-- number is SWSRC_FIRST_TRIM or above (dataconstants.h), and everything below that is the
-- physical switches and the multi-position pots -- three positions per switch, so the lowest a
-- trim can sit on any radio with a single switch is 4. So 1..6 is never a trim position, and a
-- number in that range is the old form.
M.TRIM_LEGACY_MAX = 6

--- The resolved trim a stored setting names, or nil for "off" and for one this radio lacks.
--
-- Resolved through the walked block rather than by arithmetic on the position number. The
-- firmware spells a trim's two positions consecutively with the DECREMENT first
-- (strhelpers.cpp: `idx & 1 ? '+' : '-'`, the index being relative to SWSRC_FIRST_TRIM), so the
-- parity that decides it is the block's and not the number's -- and the block's start is not a
-- constant Lua is ever told. The walk knows both positions of every trim by name, so it is asked.
function M.trimEntry(trims, stored)
  if type(trims) ~= "table" then return nil end
  local value = tonumber(stored)
  if value == nil or value == 0 then return nil end
  if value >= 1 and value <= M.TRIM_LEGACY_MAX then return trims[value] end
  local byPosition = trims.byPosition
  if type(byPosition) == "table" then return byPosition[value] end
  -- A block assembled by hand rather than by the walk -- which is what a probe hands in -- has no
  -- index, and the scan is what it falls back to.
  for index = 1, M.TRIM_COUNT do
    local entry = trims[index]
    if entry ~= nil and (entry.plus == value or entry.minus == value) then return entry end
  end
  return nil
end

--- The value a setting should hold for a trim the pilot has just picked.
--
-- The picker offers both positions of every trim and the overlay stores one of them: the `+`,
-- because the drive derives the other from the same entry and a setting that could hold either
-- would make two spellings of one choice. A picked `-` is normalised to its own `+`.
function M.normaliseTrim(trims, picked)
  local value = tonumber(picked)
  if value == nil or value == 0 then return 0 end
  local entry = M.trimEntry(trims, value)
  if entry == nil then return 0 end
  return entry.plus or 0
end

-- Every trim-valued key of the settings table, in one place: the migration below and the double
-- claim check both walk it, and a key named in one and not the other is a trim nothing watches.
local TRIM_KEYS = { "nav_trim", "bank_trim", "adj_trim" }

--- Turn every trim setting into the position form, once the radio has said what its trims are.
--
-- Runs where the walk finishes -- the widget's drive and the settings page both -- and changes the
-- table in place. The widget writes no store, so there it is an in-memory reading of an old file;
-- the page's next save is what puts the new form on the card, which is what the pilot asked for.
--
-- Answers whether anything moved, so a caller that cares can say so.
function M.migrateTrims(settings, trims)
  if type(settings) ~= "table" or type(trims) ~= "table" then return false end
  local moved = false
  local function convert(value)
    local number = tonumber(value) or 0
    if number <= 0 or number > M.TRIM_LEGACY_MAX then return number end
    local entry = trims[number]
    -- A legacy index this radio has no trim for becomes OFF rather than staying a number that
    -- would be read as a position on the next radio the card is put in.
    if entry == nil or entry.plus == nil then return 0 end
    return entry.plus
  end
  for i = 1, #TRIM_KEYS do
    local key = TRIM_KEYS[i]
    local converted = convert(settings[key])
    if converted ~= settings[key] then
      settings[key] = converted
      moved = true
    end
  end
  if type(settings.rowTrim) == "table" then
    for row = 1, M.TRIM_COUNT do
      local converted = convert(settings.rowTrim[row])
      if converted ~= settings.rowTrim[row] then
        settings.rowTrim[row] = converted
        moved = true
      end
    end
  end
  return moved
end

-- ---------------------------------------------------------------------------
-- The setup check
-- ---------------------------------------------------------------------------

local function checkGvarDetails(radio, index, faults, prefix)
  local details = radio.globalVariableDetails(index - 1)
  if details == nil then return end
  if tonumber(details.prec) ~= 0 then
    -- With one decimal the mixer divides the weight by ten (mixer.cpp), so every step lands at a
    -- tenth of the window it was aimed at and nothing ever fires.
    faults[#faults + 1] = prefix .. "_gvar_prec"
  end
  local min = tonumber(details.min)
  local max = tonumber(details.max)
  if (min ~= nil and min > -100) or (max ~= nil and max < 100) then
    faults[#faults + 1] = prefix .. "_gvar_range"
  end
end

local function checkMixLine(radio, channel, gvarIndex, faults, prefix)
  local count = radio.mixesCount(channel)
  if count == nil then return false end
  if count == 0 then
    faults[#faults + 1] = prefix .. "_mix_missing"
    return true
  end
  if count > 1 then
    faults[#faults + 1] = prefix .. "_mix_count"
  end
  local mix = radio.mix(channel, 0)
  if type(mix) ~= "table" then
    faults[#faults + 1] = prefix .. "_mix_missing"
    return true
  end
  local mixsrcMax = radio.mixsrcMax()
  if mixsrcMax ~= nil and tonumber(mix.source) ~= mixsrcMax then
    faults[#faults + 1] = prefix .. "_mix_source"
  end
  local sourceIndex = radio.sourceIndex("GV" .. tostring(gvarIndex))
  if sourceIndex ~= nil and tonumber(mix.weight) ~= (MIX_WEIGHT_GVAR_BASE + sourceIndex) then
    faults[#faults + 1] = prefix .. "_mix_weight"
  end
  if tonumber(mix.multiplex) ~= MIX_MULTIPLEX_ADD then
    faults[#faults + 1] = prefix .. "_mix_multiplex"
  end
  if tonumber(mix.switch) ~= 0 then
    faults[#faults + 1] = prefix .. "_mix_switch"
  end
  -- Three more fields the line has to carry, each held against it only where the reader answered at
  -- all -- the same terms the source and the weight above are read on. An offset shifts every code
  -- away from the window the board decodes; a curve reshapes them; and flightModes is a mask of the
  -- modes the line is DISABLED in (mixer.cpp), so anything but zero is a mode in which a press
  -- moves nothing at all -- the mode being flown among them, whenever its own bit is set.
  local offset = tonumber(mix.offset)
  if offset ~= nil and offset ~= 0 then
    faults[#faults + 1] = prefix .. "_mix_offset"
  end
  local curveType = tonumber(mix.curveType)
  if curveType ~= nil and curveType ~= 0 then
    faults[#faults + 1] = prefix .. "_mix_curve"
  end
  local flightModes = tonumber(mix.flightModes)
  if flightModes ~= nil and flightModes ~= 0 then
    faults[#faults + 1] = prefix .. "_mix_modes"
  end
  return true
end

--- What is missing between this model and a working overlay.
--
-- Answers "ok", a list of named faults, or nil for UNCHECKED -- and the third is not the same as
-- the first. A radio whose Lua does not offer the mixer reader cannot be told apart from a
-- correct model by anything here, and reporting that as correct is the failure this return value
-- exists to prevent.
--
-- Nothing is written. The overlay reports what a model lacks and leaves authoring it to the
-- pilot, because a mixer line written behind a pilot's back is a control surface moving for a
-- reason nobody can find later.
--- Which of the radio's trims this configuration actually claims, and under what name a fault
-- against one of them would be reported.
--
-- In `navigate` mode two trims do the work and every other one is inert, so the six row
-- assignments describe trims nothing reads; reporting on them -- or switching them off in the
-- model -- would be acting on a claim this configuration never makes.
--
-- Answers the list, and whether one trim was claimed TWICE. In rows mode a trim assigned to two
-- rows was de-duplicated here without a word, and the row that lost is unreachable on the radio
-- for the rest of the model's life -- silently, because the row list still shows it. Which of the
-- two rows a press then moves is the one thing the pilot cannot read off the screen.
--- Which semantic trim, 1..6, a stored setting resolves to on this radio.
--
-- The de-duplication and the flight-mode check both need it: two settings holding DIFFERENT
-- numbers can name the same trim once one of them is an old index and the other a position, and
-- the firmware's trimsModes table is indexed by the semantic number and by nothing else. Falls
-- back to the stored number where the radio has said nothing, which is the old behaviour on a
-- radio that cannot answer.
local function semanticTrim(trims, stored)
  local value = tonumber(stored) or 0
  if value <= 0 then return 0 end
  if type(trims) ~= "table" then return value end
  for index = 1, M.TRIM_COUNT do
    local entry = trims[index]
    if entry ~= nil and (entry.plus == value or entry.minus == value) then return index end
  end
  if value <= M.TRIM_LEGACY_MAX then return value end
  -- A position this radio does not carry: claimed by the settings, present on no thumb. It is not
  -- a double claim and it has no trim mode to check, so it drops out here.
  return 0
end

function M.claimedTrims(settings, trims)
  local claimed = {}
  if type(settings) ~= "table" then return claimed, false end

  --- One job's trim, added to the list unless another job already holds the same one.
  local seen = {}
  local twice = false
  local function claim(stored, code)
    local index = semanticTrim(trims, stored)
    if index <= 0 then return end
    if seen[index] then
      twice = true
      return
    end
    seen[index] = true
    claimed[#claimed + 1] = { index = index, stored = tonumber(stored) or 0, code = code }
  end

  if settings.trim_mode == M.TRIM_MODE_NAVIGATE then
    -- Up to three, and each of them has to be its own. The bank trim is optional -- 0 means the
    -- walk trim walks the whole set -- but a bank trim that repeats one of the other two is the
    -- same fault as any other double claim: whichever job runs first decides, and which one that
    -- is cannot be read off the screen.
    claim(settings.nav_trim, "trim_mode_nav")
    claim(settings.bank_trim, "trim_mode_bank")
    claim(settings.adj_trim, "trim_mode_adj")
    return claimed, twice
  end
  for row = 1, M.TRIM_COUNT do
    claim(settings.rowTrim and settings.rowTrim[row], "trim_mode_" .. tostring(row))
  end
  return claimed, twice
end

function M.check(drive, settings, trims)
  if type(drive) ~= "table" then return nil end
  settings = settings or drive.settings
  if type(settings) ~= "table" then return nil end
  local radio = drive.radio
  if type(radio) ~= "table" then return nil end
  -- The resolved trim block, where the caller has one. Without it a stored position cannot be
  -- turned into the semantic number the firmware's trim-mode table is indexed by, and the two
  -- trim faults below simply are not raised -- which is the right answer, not a guess.
  if trims == nil then trims = drive.trimsResolved == true and drive.trims or nil end

  local faults = {}
  if (settings.switch or 0) == 0 then faults[#faults + 1] = "no_switch" end
  if (settings.bank_gvar or 0) <= 0 then faults[#faults + 1] = "no_bank_gvar" end
  if (settings.value_gvar or 0) <= 0 then faults[#faults + 1] = "no_value_gvar" end

  -- The two halves have to be two variables and two channels. Pointed at one, the bank the pilot
  -- selects and the step he asks for land on the same wire, and the flight controller reads the
  -- step as a bank change and the bank change as a step -- a configuration that is not merely
  -- broken but actively dangerous, since the parameter that moves is not the one on the screen.
  -- M.plan has always refused this; the check said nothing, so a pilot who never pressed the
  -- setup button was told his model was fine.
  if (settings.bank_gvar or 0) > 0 and settings.bank_gvar == settings.value_gvar then
    faults[#faults + 1] = "same_gvar"
  end
  if settings.bank_ch == settings.value_ch then
    faults[#faults + 1] = "same_channel"
  end

  local looked = false
  if (settings.bank_gvar or 0) > 0 then
    checkGvarDetails(radio, settings.bank_gvar, faults, "bank")
    looked = checkMixLine(radio, settings.bank_ch, settings.bank_gvar, faults, "bank") or looked
  end
  if (settings.value_gvar or 0) > 0 then
    checkGvarDetails(radio, settings.value_gvar, faults, "value")
    looked = checkMixLine(radio, settings.value_ch, settings.value_gvar, faults, "value") or looked
  end

  -- A trim driving a row must be OFF as a trim in the active flight mode. Left on, the same press
  -- moves the stick neutral the flight controller was calibrated against.
  if settings.trims == true then
    -- Which trims this configuration actually claims, and under what name a fault would be
    -- reported. In navigate mode two trims do the work and every other one is inert, so checking
    -- the six row assignments there would report on trims nothing reads.
    local claimed, twice = M.claimedTrims(settings, trims)
    if settings.trim_mode == M.TRIM_MODE_NAVIGATE then
      local nav = settings.nav_trim or 0
      local adj = settings.adj_trim or 0
      if nav == 0 or adj == 0 then
        faults[#faults + 1] = "no_nav_trim"
      end
    end
    -- One trim cannot do two jobs, in either layout. In navigate mode it would both walk the set
    -- and move the parameter; in rows mode it stands for two rows and one of them is unreachable
    -- for good. Either way whichever job runs first decides, and which one that is nobody could
    -- tell from the screen -- so it is named rather than resolved.
    if twice then
      faults[#faults + 1] = "trim_claimed_twice"
    end

    local data = radio.flightModeData(radio.flightMode())
    if type(data) == "table" and type(data.trimsModes) == "table" then
      looked = true
      for i = 1, #claimed do
        local mode = tonumber(data.trimsModes[claimed[i].index])
        if mode ~= nil and mode ~= TRIM_MODE_NONE then
          faults[#faults + 1] = claimed[i].code
        end
      end
    end
  end

  if #faults > 0 then return faults end
  if not looked then return nil end
  return "ok"
end


-- ---------------------------------------------------------------------------
-- What the model is missing, proposed rather than assumed
-- ---------------------------------------------------------------------------

-- How far up the channel list the search for a free global variable looks. EdgeTX carries 32
-- output channels; walking all of them is a one-off cost of one getMixesCount per channel plus
-- one getMix per line, paid when a page is opened and never in a widget pass.
local MIX_SCAN_CHANNELS = 32

-- And how many INPUTS. EdgeTX carries 32 of those as well, each with its own lines, and an input
-- line's weight and offset use the same source encoding a mixer line's do -- so a global variable
-- scaling an expo curve is a variable this model has spoken for just as firmly as one on a mixer
-- line, and one the overlay must not be handed. Same one-off cost, on the same page entry.
local INPUT_SCAN_COUNT = 32

-- A weight or an offset at or above this magnitude is not a number, it is a SOURCE reference
-- (datastructs_private.h, sourceNumValToLuaInt), and a global variable used as one is a variable
-- this model has already spoken for.
local SOURCE_REF_MIN = MIX_WEIGHT_GVAR_BASE

--- Which global variables no mixer line of this model refers to.
--
-- The overlay pulses its variables several times a second while a pilot is tuning. Handing it one
-- the model already uses as a mixer weight would move a control surface every time a parameter is
-- stepped, and the pilot would have no way of connecting the two. So the proposal is made from
-- what the model demonstrably does NOT reference, and it is only a proposal: it is shown in the
-- fields and written nowhere until the pilot saves.
--
-- Answers the list of free numbers, in ascending order, and how many lines it had to read to say
-- so -- which is the figure a probe bounds.
function M.freeGvars(radio, wanted)
  if type(radio) ~= "table" then return nil, 0 end
  if type(radio.mixesCount) ~= "function" or type(radio.mix) ~= "function" then return nil, 0 end

  -- The source index of every variable, resolved once: getSourceIndex is a name lookup, and doing
  -- it per mixer line would make the walk cost the layout's length times the variable count.
  local indexOfGvar = {}
  for n = 1, M.GVAR_MAX_INDEX do
    local sourceIndex = radio.sourceIndex("GV" .. tostring(n))
    if sourceIndex ~= nil then indexOfGvar[SOURCE_REF_MIN + sourceIndex] = n end
  end

  local used = {}
  local lines = 0

  --- Both magnitudes of one line, read for a source reference. A negated reference is spelled with
  -- the sign on the whole number rather than on the index, so both signs are looked up.
  --
  -- `where` names the line the reference was found on, and it is the whole point of the walk now
  -- that the two variables are defaulted rather than proposed: a warning that says a variable is
  -- taken and not where would send the pilot through thirty-two channels to find out.
  local function readLine(line, where)
    if type(line) ~= "table" then return end
    local weight = tonumber(line.weight) or 0
    local offset = tonumber(line.offset) or 0
    local byWeight = indexOfGvar[weight] or indexOfGvar[-weight]
    local byOffset = indexOfGvar[offset] or indexOfGvar[-offset]
    if byWeight ~= nil and used[byWeight] == nil then used[byWeight] = where end
    if byOffset ~= nil and used[byOffset] == nil then used[byOffset] = where end
  end

  for channel = 1, MIX_SCAN_CHANNELS do
    local count = radio.mixesCount(channel)
    if count == nil then break end
    local where = "CH" .. tostring(channel)
    for line0 = 0, count - 1 do
      lines = lines + 1
      readLine(radio.mix(channel, line0), where)
    end
  end

  -- The inputs, on the same terms. An input line encodes a source in its weight and its offset
  -- exactly as a mixer line does, so a variable scaling a rate or an expo is spoken for -- and a
  -- proposal that overlooked it would hand the overlay a variable it pulses several times a second
  -- while a pilot is tuning, moving a control surface for a reason nobody could connect to it.
  -- A firmware without the input readers answers nil and this half is simply not walked.
  if type(radio.inputsCount) == "function" and type(radio.input) == "function" then
    for input = 1, INPUT_SCAN_COUNT do
      local count = radio.inputsCount(input - 1)
      if count == nil then break end
      local where = "IN" .. tostring(input)
      for line0 = 0, count - 1 do
        lines = lines + 1
        readLine(radio.input(input - 1, line0), where)
      end
    end
  end

  local free = {}
  for n = 1, M.GVAR_MAX_INDEX do
    if used[n] == nil then
      free[#free + 1] = n
      if wanted ~= nil and #free >= wanted then break end
    end
  end
  return free, lines, used
end

--- Which of the two configured variables this model already refers to, and on which line.
--
-- The half of the old proposal that survives the fixed defaults. The overlay no longer CHOOSES a
-- variable off this walk -- a setting that moves with the model is one nobody can write down --
-- but a variable the model already drives something with is still a variable the overlay must not
-- pulse, and the pilot has to be told which and where.
--
-- Answers a list of { index, where } in the order value, bank, and an empty list when the walk
-- found nothing. nil means the walk could not be made at all.
function M.gvarConflicts(radio, settings)
  if type(radio) ~= "table" or type(settings) ~= "table" then return nil end
  local _, _, used = M.freeGvars(radio, nil)
  if type(used) ~= "table" then return nil end
  local out = {}
  local seen = {}
  local wanted = { settings.value_gvar or 0, settings.bank_gvar or 0 }
  for i = 1, #wanted do
    local index = wanted[i]
    if index > 0 and used[index] ~= nil and not seen[index] then
      seen[index] = true
      out[#out + 1] = { index = index, where = used[index] }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Making the model match, on the pilot's word and not before
-- ---------------------------------------------------------------------------

-- The three-character field the firmware keeps a variable's name in: api_model.cpp copies into
-- g_model.gvars[idx].name and truncates, so a longer name is not an error, it is a silent cut.
local GVAR_NAME_VALUE = "VAL"
local GVAR_NAME_BANK = "BNK"

-- What a variable driving this overlay has to be. The precision is the one that matters: with one
-- decimal the mixer divides the weight by ten and every step lands at a tenth of the window it was
-- aimed at, so nothing ever fires.
local GVAR_DETAIL_MIN = -100
local GVAR_DETAIL_MAX = 100
local GVAR_DETAIL_PREC = 0
local GVAR_DETAIL_UNIT = 1

-- EdgeTX carries nine flight modes. A model using fewer answers nil past its last one.
local MAX_FLIGHT_MODES = 9

--- Which OTHER global variables carry one of the two names this setup writes.
--
-- A model that was set up once against a different pair keeps VAL and BNK on the variables it used
-- then, and nothing takes them off: the radio's own mixer and global-variable pages show two of
-- each name, only one pair of which drives anything. The reference walk cannot see it -- a variable
-- nothing refers to any more has no reference to find -- so the name is the only trace left.
--
-- A warning and never a refusal: a name is cosmetic, and which of the two the pilot renames is his
-- business. Answers a list of { index, name }, empty where there is nothing to say, and nil where
-- the details could not be read at all.
function M.gvarNameClashes(radio, settings)
  if type(radio) ~= "table" or type(settings) ~= "table" then return nil end
  if type(radio.globalVariableDetails) ~= "function" then return nil end
  local bank = settings.bank_gvar or 0
  local value = settings.value_gvar or 0
  local out = {}
  local looked = false
  for n = 1, M.GVAR_MAX_INDEX do
    if n ~= bank and n ~= value then
      local details = radio.globalVariableDetails(n - 1)
      if type(details) == "table" then
        looked = true
        local name = tostring(details.name or "")
        if name == GVAR_NAME_VALUE or name == GVAR_NAME_BANK then
          out[#out + 1] = { index = n, name = name }
        end
      end
    end
  end
  if not looked then return nil end
  return out
end

--- One mixer line, spelled the way the radio's own mixer page spells it, so that a line this plan
-- offers to delete can be recognised on the screen it will disappear from.
local function describeMix(radio, mix)
  if type(mix) ~= "table" then return "?" end
  local parts = {}
  parts[#parts + 1] = radio.sourceName(tonumber(mix.source)) or ("src " .. tostring(mix.source))

  local weight = tonumber(mix.weight)
  if weight ~= nil then
    if weight >= SOURCE_REF_MIN or weight <= -SOURCE_REF_MIN then
      local referenced = radio.sourceName(math.abs(weight) - SOURCE_REF_MIN)
      parts[#parts + 1] = (weight < 0 and "-" or "") .. (referenced or "src")
    else
      parts[#parts + 1] = tostring(weight) .. "%"
    end
  end

  local multiplex = tonumber(mix.multiplex)
  if multiplex == 1 then
    parts[#parts + 1] = "*"
  elseif multiplex == 2 then
    parts[#parts + 1] = "="
  else
    parts[#parts + 1] = "+"
  end

  local switchLabel = radio.switchName(tonumber(mix.switch))
  if switchLabel ~= nil then parts[#parts + 1] = switchLabel end
  return table.concat(parts, " ")
end

--- The line the overlay needs on a channel: full deflection, scaled by the variable, added, always
-- on.
--
-- The weight is the variable's source index offset by 1024, which is the SAME encoding the reader
-- answers in: api_model.cpp puts an inserted weight through luaIntToSourceNumval and reads it back
-- through sourceNumValToLuaInt, and those two are inverses. So a line written from this table is a
-- line the check reads back as correct, with no second convention in between.
local function gvarMixLine(radio, gvarIndex)
  local sourceIndex = radio.sourceIndex("GV" .. tostring(gvarIndex))
  if sourceIndex == nil then return nil end
  local mixsrcMax = radio.mixsrcMax()
  if mixsrcMax == nil then return nil end
  return {
    name = "",
    source = mixsrcMax,
    weight = MIX_WEIGHT_GVAR_BASE + sourceIndex,
    offset = 0,
    switch = 0,
    multiplex = MIX_MULTIPLEX_ADD,
    curveType = 0,
    curveValue = 0,
    flightModes = 0,
    carryTrim = false,
    mixWarn = 0,
    delayUp = 0,
    delayDown = 0,
    speedUp = 0,
    speedDown = 0
  }
end

--- Whether a variable already carries exactly the details the setup would write.
--
-- Compared on every field the write sets, which is more than the check looks at. The two questions
-- are different ones: the check asks whether the overlay can WORK, so it reads the precision and
-- the range; this asks whether there is anything left to write, so a variable with the right range
-- under a different name is still one write -- offered once, and then never again.
local function gvarDetailsAlreadySet(radio, index, details)
  if type(radio.globalVariableDetails) ~= "function" then return false end
  local have = radio.globalVariableDetails(index - 1)
  if type(have) ~= "table" then return false end
  if tostring(have.name or "") ~= details.name then return false end
  if tonumber(have.min) ~= details.min then return false end
  if tonumber(have.max) ~= details.max then return false end
  if tonumber(have.prec) ~= details.prec then return false end
  if tonumber(have.unit) ~= details.unit then return false end
  return true
end

--- Whether a channel already carries nothing but the line the overlay needs.
--
-- The fields M.check's own checkMixLine compares, read on the same terms: a field the reader does
-- not answer is not held against the line. That is what keeps the check and the plan from
-- disagreeing about a model neither of them can see all of -- a plan that demanded more than the
-- check reads would offer a rewrite of a model the screen above the button had just called correct.
local function channelAlreadySet(radio, channel, mix)
  if radio.mixesCount(channel) ~= 1 then return false end
  local have = radio.mix(channel, 0)
  if type(have) ~= "table" then return false end
  if tonumber(have.source) ~= tonumber(mix.source) then return false end
  if tonumber(have.weight) ~= tonumber(mix.weight) then return false end
  if tonumber(have.multiplex) ~= MIX_MULTIPLEX_ADD then return false end
  if tonumber(have.switch) ~= 0 then return false end
  if (tonumber(have.offset) or 0) ~= 0 then return false end
  if (tonumber(have.curveType) or 0) ~= 0 then return false end
  if (tonumber(have.flightModes) or 0) ~= 0 then return false end
  return true
end

--- Everything the write would do, as a list, before any of it is done.
--
-- The plan exists so that the destructive half can be READ before it is agreed to. The overlay
-- needs each of its two channels to carry nothing but its own line, and a pilot who has the
-- reference layout on those channels is about to lose thirty mixer lines -- which is a reasonable
-- thing to agree to and never a reasonable thing to discover afterwards. So the lines that would
-- go are listed one by one, named as the mixer page names them, and counted in the sentence the
-- confirmation asks its question with.
--
-- The plan is also a COMPARATOR, and that is what keeps it from being a rewrite. Everything it
-- queues is something this model does not already carry: a variable whose details differ, a channel
-- that does not carry exactly the one line, a flight mode that still trims a claimed trim. A plan
-- that queued them unconditionally asked the pilot to confirm a delete-and-reinsert of the very
-- line its last run had written, on every press, on a model the check beside the button had just
-- called correct. When nothing is left to queue it says so through plan.nothing.
--
-- `trims` is the resolved trim block, the same one M.check takes: without it a stored trim SETTING
-- is a switch position that cannot be turned into the semantic number the firmware's trim-mode
-- table is indexed by, so no trim fault could be answered -- which is how the trim half of this
-- plan came to be unreachable for every trim the check can raise a fault about.
--
-- Nothing here writes. M.applyPlan does, and only what this returned.
function M.plan(radio, settings, trims)
  if type(radio) ~= "table" or type(settings) ~= "table" then return nil end

  local plan = { gvars = {}, deletions = {}, insertions = {}, trims = {}, channels = {} }

  local bankGvar = settings.bank_gvar or 0
  local valueGvar = settings.value_gvar or 0
  if bankGvar <= 0 or valueGvar <= 0 then
    plan.refused = "no_gvar"
    return plan
  end
  if bankGvar == valueGvar then
    plan.refused = "same_gvar"
    return plan
  end
  if settings.bank_ch == settings.value_ch then
    plan.refused = "same_channel"
    return plan
  end
  if type(radio.canWrite) ~= "function" or not radio.canWrite() then
    plan.refused = "unsupported"
    return plan
  end

  -- The value variable first, and only where a write would change something.
  local wantedGvars = {
    { index = valueGvar, role = "value", name = GVAR_NAME_VALUE },
    { index = bankGvar, role = "bank", name = GVAR_NAME_BANK }
  }
  for i = 1, #wantedGvars do
    local entry = wantedGvars[i]
    entry.details = {
      name = entry.name, min = GVAR_DETAIL_MIN, max = GVAR_DETAIL_MAX,
      prec = GVAR_DETAIL_PREC, unit = GVAR_DETAIL_UNIT
    }
    if not gvarDetailsAlreadySet(radio, entry.index, entry.details) then
      plan.gvars[#plan.gvars + 1] = entry
    end
  end

  -- The two configured channels, and nothing else on this model is looked at, let alone written.
  -- Within a channel the deletions are listed HIGHEST INDEX FIRST, which is the order they have to
  -- be carried out in: deleting a line renumbers every line above it.
  local wanted = {
    { channel = settings.bank_ch, gvar = bankGvar, role = "bank" },
    { channel = settings.value_ch, gvar = valueGvar, role = "value" }
  }
  for i = 1, #wanted do
    local entry = wanted[i]
    local count = radio.mixesCount(entry.channel)
    if count == nil then
      plan.refused = "unsupported"
      return plan
    end
    local mix = gvarMixLine(radio, entry.gvar)
    if mix == nil then
      plan.refused = "unsupported"
      return plan
    end
    -- A channel already carrying nothing but this line is not touched, and does not appear among
    -- the channels the question counts removals from either.
    if not channelAlreadySet(radio, entry.channel, mix) then
      plan.channels[#plan.channels + 1] = {
        channel = entry.channel, role = entry.role, removed = count
      }
      for line0 = count - 1, 0, -1 do
        plan.deletions[#plan.deletions + 1] = {
          channel = entry.channel,
          line0 = line0,
          text = describeMix(radio, radio.mix(entry.channel, line0))
        }
      end
      plan.insertions[#plan.insertions + 1] = {
        channel = entry.channel,
        line0 = 0,
        gvar = entry.gvar,
        role = entry.role,
        mix = mix,
        text = describeMix(radio, mix)
      }
    end
  end

  -- A trim that still trims is a trim that moves the stick neutral the flight controller was
  -- calibrated against, with the very press that is meant to move a parameter. It has to be off in
  -- EVERY flight mode, not only the active one, because the pilot will fly in the others.
  if settings.trims == true then
    local claimed = M.claimedTrims(settings, trims)
    for fm = 0, MAX_FLIGHT_MODES - 1 do
      local data = radio.flightModeData(fm)
      if type(data) ~= "table" or type(data.trimsModes) ~= "table" then break end
      local modes, indexes = nil, {}
      for i = 1, #claimed do
        local index = claimed[i].index
        local mode = tonumber(data.trimsModes[index])
        if mode ~= nil and mode ~= TRIM_MODE_NONE then
          modes = modes or {}
          modes[index] = TRIM_MODE_NONE
          indexes[#indexes + 1] = index
        end
      end
      if modes ~= nil then
        plan.trims[#plan.trims + 1] = { fm = fm, modes = modes, indexes = indexes }
      end
    end
  end

  -- Nothing queued means the model already is what the write would make it, and the button says so
  -- instead of putting up a confirmation for a write with no content in it.
  if #plan.gvars == 0 and #plan.deletions == 0 and #plan.insertions == 0 and #plan.trims == 0 then
    plan.nothing = true
  end

  plan.ok = true
  return plan
end

--- Carry out exactly what the plan listed, in the order that keeps every intermediate state safe.
--
-- The order is the point. The variables are given their range and precision FIRST, so that the
-- moment a line referring to one exists it already scales the way it is meant to. Then the channel
-- is emptied, which parks it at centre -- a channel with no mixer line is a channel at centre,
-- which is exactly where an adjustment channel belongs when nothing is being adjusted. Only then
-- is the overlay's own line inserted. The other way round would leave the old lines and the new
-- one summed on the same channel for as long as the writes take.
--
-- Every call is separate and every result is recorded, so a firmware that refuses one of them
-- leaves a report behind rather than a half-configured model nobody can see into.
function M.applyPlan(radio, plan)
  local report = { steps = {}, written = 0, failed = 0 }
  if type(radio) ~= "table" or type(plan) ~= "table" or plan.ok ~= true then
    report.refused = (type(plan) == "table" and plan.refused) or "no_plan"
    return report
  end

  local function step(kind, detail, ok, err)
    report.steps[#report.steps + 1] = { kind = kind, detail = detail, ok = ok == true, err = err }
    if ok == true then
      report.written = report.written + 1
    else
      report.failed = report.failed + 1
    end
  end

  for i = 1, #plan.gvars do
    local entry = plan.gvars[i]
    local ok, err = radio.setGlobalVariableDetails(entry.index - 1, entry.details)
    step("gvar", entry.index, ok, err)
    logDrive("setup: GV%d named %s, %d..%d prec %d -> %s", entry.index, entry.name,
      GVAR_DETAIL_MIN, GVAR_DETAIL_MAX, GVAR_DETAIL_PREC, tostring(ok))
  end

  for i = 1, #plan.deletions do
    local entry = plan.deletions[i]
    local ok, err = radio.deleteMix(entry.channel, entry.line0)
    step("delete", entry.channel .. ":" .. entry.line0, ok, err)
    logDrive("setup: CH%d line %d removed (%s) -> %s", entry.channel, entry.line0 + 1,
      entry.text or "?", tostring(ok))
  end

  for i = 1, #plan.insertions do
    local entry = plan.insertions[i]
    local ok, err = radio.insertMix(entry.channel, entry.line0, entry.mix)
    step("insert", entry.channel .. ":GV" .. entry.gvar, ok, err)
    logDrive("setup: CH%d gets MAX x GV%d added -> %s", entry.channel, entry.gvar, tostring(ok))
  end

  for i = 1, #plan.trims do
    local entry = plan.trims[i]
    local ok, err = radio.setFlightMode(entry.fm, { trimsModes = entry.modes })
    step("trim", entry.fm, ok, err)
    logDrive("setup: flight mode %d trims off -> %s", entry.fm, tostring(ok))
  end

  return report
end

return M
