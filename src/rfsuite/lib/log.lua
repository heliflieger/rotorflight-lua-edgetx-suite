local Log = {}

local function isTruthy(value)
  return value == true or value == 1 or value == "1" or value == "true"
end

-- The severity ladder, ordered from quietest to most verbose. This table is the single
-- definition of it: the rank comparison below and the Debug Level selector on the developer
-- settings page both derive from it, so a level is added in one place instead of several.
--
-- The names are the ones GEMINI.md documents for Log.emit and the ones
-- app/pages/tools/diagnostics/session_logs/page.lua gives a colour of its own.
-- `trace` sits below `debug` and is the level the payload dumps hang on. It is separate rather
-- than folded into `debug` so that `debug` stays exactly as loud as it has always been.
local LEVELS = { "off", "error", "warn", "info", "debug", "trace" }

local RANK = {}
for index, name in ipairs(LEVELS) do
  RANK[name] = index - 1
end

local function normalizeLevel(value)
  local text = string.lower(tostring(value or "debug"))
  if text == "warning" then return "warn" end
  if RANK[text] then return text end
  return "debug"
end

local function debugLevelRank(level)
  return RANK[normalizeLevel(level)]
end

local function configuredDebugLevel()
  local root = _G and _G.rfsuite
  local prefs = root and root.preferences
  local general = prefs and prefs.general
  local value = general and general.debug_level
  if value == nil then
    return "off"
  end
  local text = string.lower(tostring(value))
  if text == "warning" then text = "warn" end
  -- A value this build does not know stays off. normalizeLevel falls back to "debug", which is
  -- right for a message whose level is mistyped and wrong for the switch deciding whether
  -- anything is written at all -- there it would turn an unreadable setting into the loudest one.
  if RANK[text] == nil then
    return "off"
  end
  return text
end

local function shouldEmitByLevel(messageLevel)
  local configured = configuredDebugLevel()
  if configured == "off" then
    return false
  end
  return debugLevelRank(messageLevel) <= debugLevelRank(configured)
end

local function isSerialDebugEnabled()
  local root = _G and _G.rfsuite
  local prefs = root and root.preferences
  local general = prefs and prefs.general
  return isTruthy(general and general.enable_serial_debug)
end

local MAX_HISTORY = 60
local MAX_MSG_LEN = 100

-- Initialize global state once
if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.log_history = _G.rfsuite.log_history or {}
  _G.rfsuite.log_history_seq = _G.rfsuite.log_history_seq or 0
end

-- The ring is a SCREEN budget, not a buffer budget: app/pages/tools/diagnostics/session_logs is
-- its consumer, and 60 entries of 100 characters is what that page can show. Anything writing
-- the log to a card is a different consumer with a different one -- a payload dump is longer
-- than MAX_MSG_LEN by itself, and a trace fills sixty entries in well under a second. So a sink
-- is given a list of its own, untruncated and far longer, and the ring is left exactly as that
-- page expects to find it.
-- An OVERFLOW GUARD, not a working size. The sink drains this list on every write, so what it
-- normally holds is one flush interval -- a few seconds. The cap only decides how much may pile
-- up if writing stops, and it is deliberately far smaller than it looks like it could be:
-- measured in the same units the radio reports, a retained entry of a payload line costs about
-- 340 bytes, so a thousand of them is a third of a megabyte. On a small radio the whole Lua
-- budget is of that order, and a diagnostic that eats it is the problem it was built to find.
local SINK_MAX = 400

-- Whether a sink is taking lines is the EXISTENCE of the list, and not a flag in this file.
--
-- Several places load this module with a raw loadScript rather than through lib/require.lua --
-- tasks/events/common/runner.lua is one -- so more than one copy of it can be live in a single
-- Lua state, each with its own upvalues. A flag kept here is therefore true in the copy that
-- attached and false in every other, while the list itself sits in _G and is shared: the
-- symptom is a log that carries some subsystems and silently drops the rest.
local function sinkList()
  local sink = _G.rfsuite.log_sink
  return type(sink) == "table" and sink or nil
end

local function addToSink(tag, msg, level)
  local sink = sinkList()
  if not sink then return end

  sink[#sink + 1] = {
    tag = tostring(tag or "rfsuite"),
    msg = tostring(msg or ""),
    level = tostring(level or "debug"),
    time = getTime and getTime() or 0
  }
  if #sink > SINK_MAX then
    -- The cap is an overflow guard, not a working size: the sink empties this list every time it
    -- writes, so in normal running it holds one flush interval's worth. Dropping the oldest is
    -- still real data loss and is counted, so the file can say a gap happened.
    table.remove(sink, 1)
    _G.rfsuite.log_sink_lost = (_G.rfsuite.log_sink_lost or 0) + 1
  end
end

local function addToHistory(tag, msg, level)
  local t = tostring(tag or "rfsuite")
  local lvl = tostring(level or "debug")
  local m = tostring(msg or "")
  
  if string.len(m) > MAX_MSG_LEN then
    m = string.sub(m, 1, MAX_MSG_LEN - 3) .. "..."
  end

  local history = _G.rfsuite.log_history
  table.insert(history, {
    tag = t,
    msg = m,
    level = lvl,
    time = getTime and getTime() or 0
  })

  if #history > MAX_HISTORY then
    table.remove(history, 1)
  end
  
  _G.rfsuite.log_history_seq = _G.rfsuite.log_history_seq + 1
end

--- Emit one log line.
--
-- `enabled` is a console OPT-OUT: false keeps a line off the console while it still reaches
-- the ring, the sink and serial; nil and true both mean on. It exists for the call sites
-- that gate console output on a preference of their own, and it decides nothing else.
function Log.emit(tag, msg, level, enabled)
  local emitByLevel = shouldEmitByLevel(level)
  
  -- Always buffer important logs (info/warn/error) or if debug is enabled.
  --
  -- Written as a rank comparison rather than as "anything that is not debug": with `trace` below
  -- `debug`, the old test was true for a trace line as well, which would have put every payload
  -- dump into the ring at every setting -- `off` included -- and flooded the page the ring
  -- exists for. The behaviour for the five levels that existed before is identical.
  if emitByLevel or debugLevelRank(level) <= RANK.info then
    addToHistory(tag, msg, level)
  end

  -- A sink writing to the card is a second consumer with a different budget, and it takes the
  -- message UNTRUNCATED. See addToSink.
  --
  -- The same test as the ring above, deliberately: gating this on emitByLevel alone would mean
  -- that at `debug_level = off` -- the state every radio ships in -- a card log came out empty,
  -- because the important levels reach the ring through the second half of that test and
  -- nothing else is emitted at all. The sink takes what the ring takes, and more when a level
  -- is chosen.
  if sinkList() and (emitByLevel or debugLevelRank(level) <= RANK.info) then
    addToSink(tag, msg, level)
  end

  local emitConsole = (enabled == nil or isTruthy(enabled)) and emitByLevel
  local emitSerial = isSerialDebugEnabled() and type(serialWrite) == "function" and emitByLevel

  if not emitConsole and not emitSerial then
    return
  end

  local t = tag or "rfsuite"
  local lvl = level or "debug"

  -- The history entry already carries a timestamp and session_logs/page.lua renders it, but
  -- the console and serial line was built without one, so the same message could be read with
  -- a time on the radio and without a time everywhere else. Same clock and same format as that
  -- page, and left out when the clock is unavailable, which is what the page does too.
  local now = getTime and getTime() or 0
  local stamp = ""
  if now > 0 then
    stamp = "[" .. string.format("%0.1f", now / 100) .. "]"
  end

  local line = "[" .. tostring(t) .. "][" .. tostring(lvl) .. "]" .. stamp .. " " .. tostring(msg)

  if emitConsole and type(print) == "function" then
    print(line)
  end

  if emitSerial then
    pcall(serialWrite, line .. "\n")
  end
end

-- Exported so the Debug Level selector on the developer settings page can offer exactly the
-- levels this module understands, instead of carrying a second list that drifts away from it.
Log.LEVELS = LEVELS

--- Would a message at this level be emitted right now?
--
-- For call sites where BUILDING the message is the expensive part -- a hex dump of a response
-- buffer is a few hundred characters that `emitf` below would still have to be handed. Those
-- sites ask first and build second.
function Log.wanted(level)
  return shouldEmitByLevel(level)
end

--- Emit, formatting only if the level passes.
--
-- The difference from Log.emit is where the string is built. `Log.emit(tag, a .. b .. c, ...)`
-- concatenates before the call, so the caller pays for a message the gate then drops -- and on
-- the MSP path that is a send and a retry apart, at `debug_level = off`, on every radio. Here
-- the caller hands over the pieces and string.format runs only on the far side of the gate.
function Log.emitf(tag, level, fmt, ...)
  if not shouldEmitByLevel(level) then
    -- The ring still wants the important levels, gate or no gate. Formatting one of those is
    -- not the cost this function exists to avoid: they are rare by definition.
    if debugLevelRank(level) <= RANK.info then
      local ok, text = pcall(string.format, fmt, ...)
      Log.emit(tag, ok and text or tostring(fmt), level, false)
    end
    return
  end

  local ok, text = pcall(string.format, fmt, ...)
  Log.emit(tag, ok and text or tostring(fmt), level)
end

--- A logger bound to one tag.
--
-- For a module that logs under a single tag: the closure carries the tag and the default
-- level, so the module states its tag once and the logging policy -- the default level,
-- the console flag, the gate -- stays in this file instead of drifting at call sites.
function Log.tagged(tag)
  return function(msg, level)
    Log.emit(tag, msg, level or "debug")
  end
end

--- A buffer as hex, for a payload line. Bounded, and it says when it truncated.
--
-- Only ever called behind Log.wanted: this allocates in proportion to the buffer and there is
-- no point paying for it on a card that is not tracing.
function Log.hex(buf, limit)
  if type(buf) ~= "string" then
    if type(buf) == "table" then
      local parts = {}
      local n = math.min(#buf, limit or #buf)
      for i = 1, n do parts[i] = string.format("%02X", (tonumber(buf[i]) or 0) % 256) end
      local text = table.concat(parts, " ")
      if #buf > n then text = text .. string.format(" ...(%d more)", #buf - n) end
      return text
    end
    return "-"
  end

  local n = #buf
  local take = limit and math.min(n, limit) or n
  local parts = {}
  for i = 1, take do parts[i] = string.format("%02X", string.byte(buf, i)) end
  local text = table.concat(parts, " ")
  if take < n then text = text .. string.format(" ...(%d more)", n - take) end
  return text
end

--- Tell the logger a card sink is taking lines, so it starts filling the sink's own list.
--
-- The list is SEEDED from the ring rather than started empty. Whatever the ring holds at this
-- moment is the part of the session that happened before anybody attached -- and on a start
-- that is the whole start-up sequence, which is when it is worth the most. Those seeded entries
-- carry the ring's truncation because that is where they were kept; everything after this call
-- does not.
function Log.attachSink()
  local sink = {}
  local history = _G.rfsuite.log_history
  if type(history) == "table" then
    for i = 1, #history do sink[i] = history[i] end
  end
  _G.rfsuite.log_sink = sink
  _G.rfsuite.log_sink_lost = 0
end

--- Stop filling it, and drop what is in it: nothing is going to read it.
function Log.detachSink()
  _G.rfsuite.log_sink = nil
  _G.rfsuite.log_sink_lost = nil
end

if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.Log = Log
end

return Log
