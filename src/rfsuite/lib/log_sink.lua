-- Writes the in-memory log ring to the SD card so a session can be read after the fact.
--
-- lib/log.lua keeps the last MAX_HISTORY entries in _G.rfsuite.log_history and
-- app/pages/tools/diagnostics/session_logs/page.lua renders them, but the ring is a state
-- global: it dies with the Lua state that holds it. Whatever the suite was doing when it
-- stopped responding, ran out of memory or was killed for exceeding its CPU budget is exactly
-- the part that is gone by the time anybody can look at the page.
--
-- Two files, because the Lua io library can only make one of the two promises:
--
--   * the SESSION FILE holds the ring and is written on a cadence. io.close is the only call
--     that reaches the card -- the library registers open/read/write/seek/close and no flush --
--     so "write out the pending lines" means open in append mode, write, close. That is cheap
--     at a few seconds apart and its honest promise is a loss window of one cadence, never
--     crash safety.
--
--   * the STEP FILE holds one line naming the last thing that was started, and is rewritten in
--     place at every step. It survives what the session file cannot, because it is closed
--     immediately; it stays affordable because it is truncated on every open and never grows
--     past one line, so there is no cluster chain for the filesystem to walk.
--
-- Read together they answer the question a frozen radio poses: the session file says what led
-- up to it, the step file says what was being done when it stopped.
--
-- One sink per Lua state. The suite runs in three -- the tool in its own, the dashboard widget
-- and the service widget sharing another, and the background decoder's special function in the
-- radio's script state -- and each holds a ring of its own, so each names its own pair of files
-- instead of three writers appending to one path.
--
-- The third one is the only one that keeps running when the widgets do not. A widget whose pass
-- overruns its instruction budget is not called again, so it cannot write down that it stopped;
-- the script state is yielded rather than cut off, and its step file's timestamp is what says
-- how far a radio got.

local Sink = {}

local ROOT = "/SCRIPTS/TOOLS/rfsuite.user"
local DIR = ROOT .. "/logs"

-- Bounds, and what each one bounds.
local MAX_SESSIONS = 10      -- card space: slots are reused round robin
local MAX_FILE_LINES = 5000  -- growth of a single session file
local STEP_MIN_INTERVAL = 0.25 -- seconds between step writes, unless the caller forces one

-- How long the pending lines may sit in the ring before they are written out. Longer while the
-- model is armed: appends are small, but a flight is the worst moment to ask the card for
-- anything, and the ring holds enough to bridge the gap.
local FLUSH_INTERVAL = 3.0
local FLUSH_INTERVAL_ARMED = 10.0

-- How many held lines one tick formats and writes. Formatting is the Lua cost of a write -- about
-- forty instructions a line -- and it is billed to whichever widget pass ticks the sink, so a full
-- list of SINK_MAX lines in one call would take most of that pass. A longer backlog goes out one
-- batch per tick instead, on the ticks that follow.
local FLUSH_BATCH_LINES = 50

local function nowSeconds()
  if type(getTime) ~= "function" then return 0 end
  local ok, value = pcall(getTime)
  if ok and type(value) == "number" then return value / 100 end
  return 0
end

local function preferences()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil end
  local prefs = _G.rfsuite.preferences
  return type(prefs) == "table" and prefs.general or nil
end

local function isEnabled()
  local general = preferences()
  return type(general) == "table" and general.log_to_card == true
end

local function logModule()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil end
  local mod = _G.rfsuite.Log
  return type(mod) == "table" and mod or nil
end

-- The list this drains is the logger's SINK list, not the ring behind the Session Logs page.
-- The ring is that page's budget -- sixty entries capped at a hundred characters -- and a
-- payload line is longer than the cap by itself, while a trace fills sixty entries in well
-- under a second. lib/log.lua fills the sink list only while one is attached, untruncated.
local function ring()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil, 0 end
  local list = _G.rfsuite.log_sink
  if type(list) ~= "table" then return nil, 0 end
  return list, tonumber(_G.rfsuite.log_sink_seq) or 0
end

-- Everything that touches the card goes through these two, so a card that is missing, full or
-- write protected degrades to "no log" instead of taking the caller down with it.
local function writeFile(path, mode, text)
  local ok, handle = pcall(io.open, path, mode)
  if not ok or not handle then return false end
  local okWrite, res = pcall(io.write, handle, text)
  pcall(io.close, handle)
  return okWrite and res ~= nil and res ~= false
end

local function readFile(path)
  local ok, handle = pcall(io.open, path, "r")
  if not ok or not handle then return nil end
  local okRead, text = pcall(io.read, handle, 64)
  pcall(io.close, handle)
  if okRead then return text end
  return nil
end

-- `mkdir` is a bare global, not `os.mkdir`. EdgeTX registers the filesystem library flat in the
-- global namespace -- `dir`, `fstat`, `del`, `chdir`, `mkdir`, `rename`, the same way this suite
-- already reaches `fstat` in src/widgets/rfsuite/main.lua -- and there is no `os` table in the
-- interpreter at all. It returns an FRESULT: 0 is success and 8 is "already exists", so nothing
-- here has to tell the two apart. Introduced in 2.11, which is the floor this suite already
-- requires for LVGL.
local function ensureDir()
  if type(mkdir) ~= "function" then return end
  pcall(mkdir, ROOT)
  pcall(mkdir, DIR)
end

-- The next slot, from a counter file rather than a directory scan: a scan costs a read of every
-- entry to answer a question one number already answers.
local function nextSlot(name)
  local text = readFile(DIR .. "/" .. name .. "_seq.txt")
  local previous = tonumber(text) or 0
  local slot = previous + 1
  if slot > MAX_SESSIONS or slot < 1 then slot = 1 end
  writeFile(DIR .. "/" .. name .. "_seq.txt", "w", tostring(slot))
  return slot
end

-- Which radio and which screen wrote the file. A layout or a memory question is unanswerable
-- without it, and a log without it cannot be told from one written on a different transmitter.
local function headerLine(name, slot)
  local parts = { "-- rfsuite diagnostics log", "state=" .. tostring(name), "slot=" .. tostring(slot) }

  local w = tonumber(LCD_W)
  local h = tonumber(LCD_H)
  if w and h then parts[#parts + 1] = "lcd=" .. tostring(w) .. "x" .. tostring(h) end

  if type(getVersion) == "function" then
    local ok, version, radio = pcall(getVersion)
    if ok then
      if type(version) == "string" then parts[#parts + 1] = "fw=" .. version end
      if type(radio) == "string" then parts[#parts + 1] = "radio=" .. radio end
    end
  end

  -- Which release wrote the file, taken from lib/version.lua. This read used to go to
  -- `_G.rfsuite.config.version`, and nothing in the tree ever sets `_G.rfsuite.config`, so the
  -- field was silently absent from every log ever written -- and a log that cannot say which
  -- version produced it answers no question that depends on the code having changed. The module
  -- is a table of constants and is asked for once, on the path that builds this line.
  if type(_G) == "table" and type(_G.rfsuite) == "table" and type(_G.rfsuite.require) == "function" then
    local ok, Version = pcall(_G.rfsuite.require, "lib/version.lua")
    if ok and type(Version) == "table" and type(Version.VERSION) == "string" then
      parts[#parts + 1] = "suite=" .. Version.VERSION
    end
  end

  return table.concat(parts, " ") .. "\n"
end

local function formatEntry(entry)
  local seconds = (tonumber(entry.time) or 0) / 100
  -- The same clock and the same shape session_logs/page.lua puts in front of a line, so a file
  -- and the page read alike.
  return string.format("[%0.1f][%s][%s] %s\n",
    seconds, tostring(entry.tag or "rfsuite"), tostring(entry.level or "debug"), tostring(entry.msg or ""))
end

local state = nil

-- The watermark starts at zero and needs no carrying between sessions. The list this drains is
-- created by Log.attachSink and dropped by Log.detachSink, so a second session in the same Lua
-- state gets a fresh one -- and attachSink seeds it from the ring, so the lines that were
-- emitted before anybody attached are in it rather than lost. An earlier version of this kept a
-- watermark across sessions for that reason; with a list of its own there is nothing to carry.

local function startSession()
  -- Ask the logger to start filling the sink list BEFORE the watermark below is taken, or the
  -- first lines of the session are counted as pending without ever having been stored.
  local Log = logModule()
  if Log and type(Log.attachSink) == "function" then
    Log.attachSink()
  end

  ensureDir()
  local name = Sink.name or "state"
  local slot = nextSlot(name)
  local path = DIR .. "/" .. name .. "_" .. tostring(slot) .. ".log"

  state = {
    path = path,
    -- The header is HELD rather than written. A Lua state that has nothing to say should leave
    -- no file behind: an empty one is noise on the card, it costs a rotation slot, and it makes
    -- a pilot ask why a state they did not think was running has a log of its own. The first
    -- thing that actually has to be written opens the file and puts this at the top of it.
    pendingHeader = headerLine(name, slot),
    stepPath = DIR .. "/" .. name .. "_step.txt",
    lines = 0,
    capped = false,
    lastFlush = nowSeconds(),
    -- The first write is not made to wait for the interval. Whatever is already in the ring
    -- when a session opens is the start-up sequence, and a start is one of the things this
    -- exists to explain -- there is no point holding it back for three seconds.
    firstFlushDone = false,
    -- True while a backlog longer than one batch is being written out, one batch per tick. Only
    -- a write that reached the card sets it, so a card that refuses is asked once an interval.
    draining = false,
    lastStep = 0,
    stepCount = 0
  }
  return true
end

local function endSession()
  state = nil
  -- Nothing is going to read it now, and a list that keeps filling with nobody draining it is
  -- the diagnostic becoming the problem.
  local Log = logModule()
  if Log and type(Log.detachSink) == "function" then
    Log.detachSink()
  end
end

-- Take everything the ring has gained since the last call and hand it back as one string.
--
-- log_history_seq counts insertions and the ring drops its oldest entry when it is full, so the
-- difference between the two is data that existed and was overwritten before it could be
-- written out. A gap that does not announce itself makes every later reading of the file wrong,
-- so it is counted and it goes into the file.
-- The watermark is NOT advanced here. A write that fails must not take the lines with it, so
-- the caller commits it once the bytes are on the card.
-- Everything the logger has buffered since the last write, as one string -- and the list is NOT
-- emptied here. The caller clears it once the bytes are on the card, so a write that fails
-- leaves the lines where they are instead of taking them with it.
--
-- Draining rather than keeping a watermark is what bounds the memory: the list holds one flush
-- interval, not a cap's worth. Measured, a retained entry of a payload line is about 340 bytes,
-- so keeping two thousand of them would have been two thirds of a small radio's whole Lua
-- budget -- for lines that had already been written.
--
-- `limit` takes only the oldest that many entries; the rest keep their place for the next call.
-- Without it, everything held is taken.
local function pendingText(limit)
  local list = ring()
  if not list then return nil end

  local held = #list
  local lost = tonumber(_G.rfsuite.log_sink_lost) or 0
  if held == 0 and lost == 0 then return nil end

  local take = held
  if limit and take > limit then take = limit end

  local parts = {}
  if lost > 0 then
    parts[#parts + 1] = string.format("[----][rfsuite.log][warn] %d line(s) lost (buffer overflow before flush)\n", lost)
  end
  for index = 1, take do
    local entry = list[index]
    if type(entry) == "table" then
      parts[#parts + 1] = formatEntry(entry)
    end
  end

  if #parts == 0 then return nil end
  return table.concat(parts), #parts, take
end

--- Called only once the bytes are on the card: drop what was written, and only that much.
--
-- `written` is the count this flush took. Anything the logger appended while the write was in
-- progress keeps its place, which is why this removes from the front rather than emptying. One
-- move and a tail clear rather than table.remove(list, 1) per line, which shifts every remaining
-- entry down on each call.
local function commit(written)
  local list = ring()
  if not list then return end
  local held = #list
  local count = math.min(written or 0, held)
  table.move(list, count + 1, held, 1)
  for index = held - count + 1, held do
    list[index] = nil
  end
  _G.rfsuite.log_sink_lost = 0
end

-- Create the file, with the held header at its top, the first time anything has to go into it.
-- `w` truncates, which is what a reused rotation slot needs.
local function openIfNeeded()
  if not state.pendingHeader then return true end
  if not writeFile(state.path, "w", state.pendingHeader) then
    return false
  end
  state.pendingHeader = nil
  return true
end

-- Write out at most `limit` held lines, or all of them without one. Returns true only when the
-- write reached the card and more than `limit` lines are still held -- the one case in which the
-- next tick should not wait for the interval.
local function flush(limit)
  if state.capped then return false end

  local text, count, seq = pendingText(limit)
  if not text then return false end
  if not openIfNeeded() then return false end

  if state.lines + count > MAX_FILE_LINES then
    -- Stop rather than truncate in place: a file that keeps its beginning and says where it
    -- stopped can be read, one that silently drops its middle cannot.
    if writeFile(state.path, "a", text .. "[----][rfsuite.log][warn] session file cap reached, logging to card stopped\n") then
      commit(seq)
    end
    state.capped = true
    return false
  end

  if not writeFile(state.path, "a", text) then return false end
  commit(seq)
  state.lines = state.lines + count

  local list = ring()
  return limit ~= nil and list ~= nil and #list > limit
end

-- Bring the session up on whichever call comes first. The tick is the usual one, but a step or
-- a fault can arrive before it -- and the first build of a screen is exactly the moment worth
-- having on the card.
local function ensureSession()
  if state then return true end
  if not isEnabled() then return false end
  return startSession()
end

--- Name this state's pair of files. Called once, before the first tick.
function Sink.configure(name)
  Sink.name = tostring(name or "state")
end

--- Advance the sink. Cheap and silent while the option is off, which is its shipped state.
--
-- `armed` only lengthens the interval; it never stops the writing. A flight is when a log is
-- worth the most, and the appends are small enough to keep making them.
--
-- A tick writes at most FLUSH_BATCH_LINES. While a longer backlog is going out the interval is
-- not waited for, so it drains one batch per tick; after a write that failed it is, so a card
-- that refuses the file is asked once an interval rather than on every tick.
function Sink.tick(armed)
  if not isEnabled() then
    if state then endSession() end
    return
  end

  if not ensureSession() then return end

  local now = nowSeconds()
  local interval = armed and FLUSH_INTERVAL_ARMED or FLUSH_INTERVAL
  if state.firstFlushDone and not state.draining and (now - state.lastFlush) < interval then return end
  state.firstFlushDone = true
  state.lastFlush = now
  state.draining = flush(FLUSH_BATCH_LINES)
end

--- Record what is being started, in a file that is closed again immediately.
--
-- This is the half that survives a stop with no return: the session file's pending lines are
-- still in memory when the state freezes, this line is on the card. Keep the label short and
-- keep it a fact -- it is read next to a radio that is not responding.
--- `key` groups steps that are the SAME KIND for throttling purposes, and defaults to the label.
--
-- It exists because "a label that differs is news" is defeated by any label carrying a counter:
-- a progress line like `precompile 47/312` is new on every single call, so the interval never
-- applies and the file is rewritten as fast as the caller loops. Measured on a card: 870 writes
-- in a minute, which is the shape of exactly the defect this feature must not become. A caller
-- with a counter passes a constant key, keeps the count in the label, and is throttled like
-- anything else -- the file still says where the pass is, just not more often than the interval.
function Sink.step(label, force, key)
  if not ensureSession() then return end

  local text = tostring(label)
  local group = tostring(key or text)
  local now = nowSeconds()
  -- The interval throttles a caller repeating itself, not the arrival of a new KIND of step.
  if not force and group == state.lastKey and (now - state.lastStep) < STEP_MIN_INTERVAL then
    return
  end
  state.lastStep = now
  state.lastKey = group
  state.stepCount = state.stepCount + 1

  local memKb = 0
  if type(collectgarbage) == "function" then
    local ok, value = pcall(collectgarbage, "count")
    if ok and type(value) == "number" then memKb = math.floor(value + 0.5) end
  end

  writeFile(state.stepPath, "w", string.format("[%0.1f] #%d %s lua_kb=%d\n",
    now, state.stepCount, text, memKb))
end

--- A fault the caller has caught, written out before anything else is attempted.
--
-- Called from the places that already hold the error string. The forced flush is the point:
-- what led to the fault is in the ring, and a state that has just raised may not get another
-- tick.
function Sink.fault(context, err)
  if not ensureSession() then return end
  Sink.step("fault: " .. tostring(context), true)
  -- A fault is reason enough to create the file even if nothing else has been written yet.
  if not openIfNeeded() then return end

  local text, _, seq = pendingText()
  local line = string.format("[%0.1f][rfsuite.fault][error] %s: %s\n",
    nowSeconds(), tostring(context), tostring(err))
  if writeFile(state.path, "a", (text or "") .. line) and seq then
    commit(seq)
  end
end

--- True if the error is an EdgeTX CPU-limit kill.
function Sink.isCpuLimitError(err)
  return type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil
end

--- Last chance to write, on a shutdown the caller controls.
function Sink.shutdown()
  if not state then return end
  flush()
  endSession()
end

-- Published so any file can leave a step without taking a dependency on this module, the same
-- way lib/log.lua publishes itself. The step file is the only thing that survives a call which
-- never returns, so the places that most need to write one -- a task being started, a page being
-- built -- are exactly the leaf files that should not be loading modules.
if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.logStep = function(label, force, key)
    return Sink.step(label, force, key)
  end
  _G.rfsuite.logFault = function(context, err)
    return Sink.fault(context, err)
  end
  _G.rfsuite.isCpuLimitError = function(err)
    return Sink.isCpuLimitError(err)
  end
end

return Sink
