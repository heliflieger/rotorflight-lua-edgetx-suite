-- What the setup assistant says about itself.
--
-- The assistant walks a path, derives a criterion per procedure and writes to two machines, and
-- until now it said nothing about any of it. When a pilot reports that it stopped responding, the
-- only evidence is what the last screen happened to show -- which is the state BEFORE whatever went
-- wrong, and says nothing about where it went.
--
-- The levels are chosen so that a card left at the default is silent and a card set to trace can be
-- read afterwards:
--
--   info   a WRITE. Rare, irreversible from the pilot's side, and the thing a report is usually
--          about. Never in a loop.
--   debug  the shape of the run: which procedure was entered, what its criterion turned into, a
--          step forward or back, an MSP request and its answer. One line per event, not per frame.
--   trace  per-frame work -- the screen that was built, the geometry it was built into, a sample
--          from the live channel poll. This is the level that answers *where did it stop*, and it
--          is also the only one that costs anything, so every call site here goes through `emitf`
--          and the format string is not built unless the level passes.
--
-- A CHANGE is worth a line and a repetition is not. The derived criteria are asked on every build
-- of the overview, so logging each answer would bury the run in lines that all say the same thing;
-- `M.changed` keeps the last value per key and speaks only when it moves.

local M = {}

local TAG = "rfsuite.wizard"

local function core()
  local root = _G and _G.rfsuite
  local log = root and root.Log
  if type(log) ~= "table" then return nil end
  return log
end

--- Would a line at this level be emitted at all? For a call site whose MESSAGE is the expensive
--- part -- a loop over the channel table -- ask first and build second.
function M.wanted(level)
  local log = core()
  if log == nil or type(log.wanted) ~= "function" then return false end
  local ok, value = pcall(log.wanted, level)
  return ok and value == true
end

--- One line. The format string is handed over in pieces, so nothing is concatenated for a level
--- that is switched off.
function M.emit(level, fmt, ...)
  local log = core()
  if log == nil then return end
  if type(log.emitf) == "function" then
    pcall(log.emitf, TAG, level, fmt, ...)
    return
  end
  -- An older core without the formatting entry point still gets the line, and pays for it.
  if type(log.emit) == "function" then
    local ok, text = pcall(string.format, fmt, ...)
    pcall(log.emit, TAG, ok and text or tostring(fmt), level, true)
  end
end

-- The last value seen per key, so a criterion that is asked on every build is reported once per
-- transition. Deliberately not cleared with the page: a value that survives a close and comes back
-- the same is not news either.
local seen = {}

--- Emit only where the value has MOVED. Returns true when it spoke, so a caller can hang a second
--- line off the same transition.
function M.changed(level, key, value, fmt, ...)
  local text = tostring(value)
  if seen[key] == text then return false end
  local before = seen[key]
  seen[key] = text
  M.emit(level, fmt, ...)
  return true, before
end

function M.forget(key)
  if key == nil then
    for k in pairs(seen) do seen[k] = nil end
    return
  end
  seen[key] = nil
end

return M
