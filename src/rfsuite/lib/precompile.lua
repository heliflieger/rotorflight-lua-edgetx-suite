-- lib/precompile.lua
-- Compiles the installed sources ahead of the first page that needs them.
--
-- Opening a page for the first time starts with EdgeTX parsing the .lua and writing the
-- .luac next to it; only then does anything run. With the suite loading in binary-or-text
-- mode (see lib/require.lua) that part can be done in advance, so this walks the installed
-- tree and compiles whatever has no usable bytecode beside it yet. It does a little of the
-- work per call, so the screen keeps drawing while it runs.
--
-- Two things make bytecode unusable, and they need different answers. A source that is newer
-- than its .luac is found per file, by comparing the two timestamps the way the loader does.
-- A source that is older cannot be found that way at all -- reinstalling an earlier release
-- is the plain case -- so the pass also keeps a stamp of the tree it last compiled and
-- rebuilds everything when that changes.

local Precompile = {}

local ROOTS = {
  "/SCRIPTS/TOOLS/rfsuite-core",
  "/WIDGETS/rfsuite"
}

local STAMP_PATH = "/SCRIPTS/TOOLS/rfsuite.user/precompiled.txt"

-- What the stamp is compared against, written by the packager over the sources it packed. It
-- changes with the content rather than with the version number, so a second install of the
-- same version -- a development build, a re-cut candidate, the other locale -- is still
-- recognised as a different tree. An install carrying no such file falls back to the version,
-- which is what this pass compared against before.
--
-- Only the first STAMP_LIMIT characters of either file take part in the comparison, which is why
-- the packager writes the digest first: what a long version pushes past that bound is then the
-- half that does not tell two trees apart.
local IDENTITY_PATH = "/SCRIPTS/TOOLS/rfsuite-core/build.txt"

-- Enough for an identity, and a bound on what a damaged file can cost to read. Both files are
-- read with it, because comparing two differently truncated strings would compare nothing.
local STAMP_LIMIT = 64

-- Listing a directory costs little next to compiling a file, so the walk is allowed to move
-- faster. Reading a timestamp sits between the two, and one directory here holds over a
-- hundred sources, so the entries of a directory are worked through across calls rather than
-- in one: all three caps apply to a single call, and whichever is reached first ends it.
-- All three are budgets rather than measured optima; they bound what one call may do. The first
-- to revisit is STATS_PER_STEP, once the cost of a timestamp on a real card has been measured.
local DIRS_PER_STEP = 8
local STATS_PER_STEP = 16
local FILES_PER_STEP = 1
local GC_EVERY = 8

-- The fields of an fstat timestamp, most significant first.
local TIME_FIELDS = { "year", "mon", "day", "hour", "min", "sec" }

local state = nil

local function loadUncached(path, mode)
  local utils = _G.rfsuite and _G.rfsuite.utils
  local loader = utils and utils.loadScriptUncached
  if type(loader) ~= "function" then
    -- Without the uncached loader every chunk read here would be held by the chunk cache of
    -- the tool state, which is the opposite of what this pass is for.
    return nil
  end
  local ok, chunk = pcall(loader, path, mode)
  if not ok then
    return nil
  end
  return chunk
end

local function listEntries(path)
  local entries = {}
  if type(dir) ~= "function" then
    return entries
  end

  local ok, iterator = pcall(dir, path)
  if not ok or type(iterator) ~= "function" then
    return entries
  end

  for name in iterator do
    if type(name) == "string" and name ~= "" and name ~= "." and name ~= ".." then
      entries[#entries + 1] = name
    end
  end

  return entries
end

local function modifiedAt(path)
  if type(fstat) ~= "function" then
    return nil
  end
  local ok, info = pcall(fstat, path)
  if not ok or type(info) ~= "table" or type(info.time) ~= "table" then
    return nil
  end
  return info.time
end

-- Compared field by field rather than as one number, because a date packed down to seconds
-- leaves the range a Lua integer is guaranteed to hold. Equal stamps are deliberately not older:
-- the loader rebuilds only where the bytecode is strictly the earlier of the two, and a fresh
-- compile leaves them equal, so the same input has to reach the same verdict here.
local function isOlder(a, b)
  for i = 1, #TIME_FIELDS do
    local key = TIME_FIELDS[i]
    local av, bv = a[key], b[key]
    if type(av) ~= "number" or type(bv) ~= "number" then
      -- fstat fills all six fields wherever it exists at all, so this cannot fire on EdgeTX. It
      -- is the default for an answer that is missing one: not older leaves the file to the loader
      -- at page open, which is also where a missing fstat leaves it.
      return false
    end
    if av ~= bv then
      return av < bv
    end
  end
  return false
end

-- EdgeTX writes a .luac carrying the timestamp of the source it was made from, and reads it
-- back only while it is not the older of the two. So bytecode standing at an earlier time
-- than its source is bytecode the loader has already given up on, and compiling it here is
-- the whole point of the pass -- otherwise that cost lands on the page that opens first.
local function isStale(source, bytecode)
  local sourceTime = modifiedAt(source)
  local bytecodeTime = modifiedAt(bytecode)
  if sourceTime == nil or bytecodeTime == nil then
    -- Nothing to compare. The loader still decides correctly when the page opens; this pass
    -- simply does not get ahead of it.
    return false
  end
  return isOlder(bytecodeTime, sourceTime)
end

local function readStampFile(path, limit)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = io.read(f, limit)
  io.close(f)
  if type(text) ~= "string" then
    return nil
  end
  text = (string.gsub(text, "%s", ""))
  if text == "" then
    return nil
  end
  return text
end

local function writeStamp(identity)
  local f = io.open(STAMP_PATH, "w")
  if not f then
    return
  end
  io.write(f, identity)
  io.close(f)
end

local function beginDirectory(path)
  local entries = listEntries(path)

  local hasBytecode = {}
  for i = 1, #entries do
    local name = entries[i]
    if string.sub(name, -5) == ".luac" then
      hasBytecode[string.sub(name, 1, -6)] = true
    end
  end

  return { path = path, entries = entries, index = 1, hasBytecode = hasBytecode }
end

-- Takes one entry of the directory being read, and returns how many timestamps that cost.
local function takeEntry(cursor)
  local name = cursor.entries[cursor.index]
  cursor.index = cursor.index + 1

  if string.find(name, ".", 1, true) == nil then
    -- No directory in the installed tree carries a dot and every file has an extension, so
    -- this tells the two apart without a stat call per entry. The fourth argument makes it a
    -- plain search: as a pattern the dot would match any character and every entry would look
    -- like a file.
    state.dirs[#state.dirs + 1] = cursor.path .. "/" .. name
    return 0
  end

  if string.sub(name, -4) ~= ".lua" then
    return 0
  end

  local stem = string.sub(name, 1, -5)
  local source = cursor.path .. "/" .. name

  if state.force or not cursor.hasBytecode[stem] then
    state.files[#state.files + 1] = source
    return 0
  end

  if isStale(source, cursor.path .. "/" .. stem .. ".luac") then
    state.files[#state.files + 1] = source
  end
  return 2
end

local function walk()
  local dirsTaken = 0
  local statsTaken = 0

  while true do
    local cursor = state.cursor

    if cursor == nil then
      if dirsTaken >= DIRS_PER_STEP then
        return
      end
      local path = table.remove(state.dirs)
      if not path then
        state.walking = false
        return
      end
      cursor = beginDirectory(path)
      state.cursor = cursor
      dirsTaken = dirsTaken + 1
    end

    while cursor.index <= #cursor.entries do
      statsTaken = statsTaken + takeEntry(cursor)
      if statsTaken >= STATS_PER_STEP then
        return
      end
    end

    state.cursor = nil
  end
end

local function compile()
  for _ = 1, FILES_PER_STEP do
    local path = state.files[state.done + 1]
    if not path then
      return
    end

    -- "c" compiles even when the bytecode looks newer than the source. The chunk is of no
    -- use here and is dropped, so the collector can take it back.
    loadUncached(path, state.force and "tc" or "t")

    state.done = state.done + 1
    if state.done % GC_EVERY == 0 then
      collectgarbage("collect")
    end
  end
end

-- version is what the stamp is compared against where the install carries no build identity
-- of its own; without either the pass still fills in missing and outdated bytecode but never
-- forces a rebuild.
function Precompile.start(version)
  local identity = readStampFile(IDENTITY_PATH, STAMP_LIMIT) or version
  local stamp = readStampFile(STAMP_PATH, STAMP_LIMIT)

  state = {
    identity = identity,
    force = identity ~= nil and stamp ~= identity,
    dirs = {},
    cursor = nil,
    files = {},
    done = 0,
    walking = true,
    finished = false
  }

  for i = #ROOTS, 1, -1 do
    state.dirs[#state.dirs + 1] = ROOTS[i]
  end
end

-- One unit of work: a few directories while the tree is still being read, one file after
-- that. Call it once per run cycle.
function Precompile.step()
  if state == nil or state.finished then
    return
  end

  if state.walking then
    walk()
    return
  end

  if state.done < #state.files then
    compile()
    return
  end

  state.finished = true
  collectgarbage("collect")
  if state.force and state.identity ~= nil then
    writeStamp(state.identity)
  end
end

function Precompile.getProgress()
  if state == nil then
    return 0, 0, true
  end
  return state.done, #state.files, state.finished
end

return Precompile
