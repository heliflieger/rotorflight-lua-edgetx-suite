-- A configuration store whose file is Lua data rather than text to be parsed.
--
-- The file is a chunk that returns a table, so reading it is a compile plus a table
-- constructor. The instruction hook the firmware bills a widget call with counts VM
-- instructions only, and the compile happens in C, so what a load costs is the constructor:
-- one to two instructions per key against the hundred or so a line-oriented parser pays. On
-- a real 88-key store that is 10136 instructions against a few hundred, out of the 20000 a
-- widget pass has.
--
-- What a store may hold is declared once, as a schema, and the saver serialises the SCHEMA
-- rather than the table it is handed:
--
--   <section> = {
--     keys     = { <key> = <default>, ... },   -- declared; written on every save
--     optional = { "<key>", ... },             -- declared without a default; written when set
--     open     = true,                         -- undeclared string keys survive load and save
--     retired  = { "<key>", ... },             -- dropped even from an open section
--   }
--
-- A key the code no longer declares is therefore not written back and the file shrinks at the
-- next save, which is the whole reason the schema exists. An `open` section is the exception
-- and is meant for the places where the key names are built at runtime rather than declared --
-- which is why an open section needs `retired` to be able to lose a key at all.
--
-- Values are booleans, numbers and strings. Nothing else can be written as a literal that
-- loads back as itself, so anything else is dropped rather than guessed at.
--
-- BRINGING A CARD ACROSS IS NOT EVERY STATE'S WORK, and the instruction limit is why. A
-- widget's create() and refresh() are cut off at a fixed VM instruction count, and parsing a
-- real settings file in the former format costs most of that count on its own -- so a pass cut
-- off inside the parse has written nothing, and the next pass starts the same parse from the
-- beginning and is cut off in the same place. That is a livelock rather than a slow start. A
-- call in the radio's script state is yielded once it has held the interpreter for one task
-- period and resumed on the next turn, so there the same work simply takes two turns.
--
-- The switch below is therefore off, and the two hosts that run in the script state turn it on:
-- the configuration tool at its entry point, and the background decoder at its first pass.
-- Until one of them has run, a state that may not migrate reads the former file INTO MEMORY on
-- every load and writes nothing. That is what the suite did before this module existed, at the
-- same cost, so nothing is lost while a card waits for its first tool session.

if type(_G) == "table" and type(_G.__rfsuite_config_store) == "table" then
  return _G.__rfsuite_config_store
end

local M = {}

-- Off until a host that is yielded rather than cut off says otherwise. It belongs to the Lua
-- state rather than to a store, because what it describes is how this state is billed.
local migrationAllowed = false

local Store = {}
Store.__index = Store

-- How much is asked for per io.read() call. It is a chunk size, not a limit: the reader below
-- keeps going until the file ends. io.read(f, "*a") is not an alternative -- on a radio it
-- returns zero bytes and the file reads as empty.
local READ_CHUNK = 2048

-- The suffix the new file is written under before it takes the real name.
--
-- One fixed suffix rather than one per Lua state, and that is a contract rather than an
-- oversight: a load that finds a store missing looks under exactly this name to finish an
-- interrupted save, and a name carrying a token of the state that wrote it could only be found
-- again by listing the directory, which costs more than the whole load.
--
-- What makes one name safe is that no two of the suite's hosts write a store at the same time,
-- and that is a property of the firmware rather than an assumption:
--
--   * every widget shares ONE Lua state, so the dashboard and the service widget are one writer
--     and not two, running one connect task between them;
--   * opening a tool turns widget refresh off for as long as it is open, so no widget pass runs
--     while the tool is on screen -- neither foreground nor background;
--   * opening a tool also pauses every permanent script, which is where the background decoder
--     runs.
--
-- The migration would have been the exception: it happened in every state that read a card in
-- the former format. The switch above is what brings it back inside the rule.
local TMP_SUFFIX = ".tmp"

-- The name the same store had in the format before this one, beside the current file. It is
-- named here rather than in each module that owns a store, because what the former files are
-- called is this module's business: it is the only thing left that reads one.
function M.legacyPath(path)
  return (string.gsub(path, "%.lua$", ".ini"))
end

-- How far the trailing generation counter runs before it wraps. A reader that watches the
-- file's size sees a change between any two saves as long as the counter moves, which is what
-- makes two saves inside one FAT timestamp slot (2 seconds) distinguishable.
local GENERATION_MAX = 32

local function log(level, fmt, ...)
  local root = _G.rfsuite
  local L = root and root.Log
  if type(L) ~= "table" or type(L.emitf) ~= "function" then return end
  L.emitf("rfsuite.config", level, fmt, ...)
end

-- Where a call is to say anything, and it is not always the log.
--
-- The log's level gate reads rfsuite.preferences.general.debug_level, and while that field is
-- absent it answers "off" and refuses every line whatever its level. On the FIRST load of a Lua
-- state that field is absent by construction -- this call is what fetches it -- so a store had
-- no way of reporting the file it had just read, including the error saying a broken one was
-- replaced by the declared defaults. A caller in that position hands `opts.messages` a table,
-- gets the records back in it, publishes the settings and writes them out itself.
local function sinkFor(opts)
  local messages = opts and opts.messages
  if type(messages) ~= "table" then return log end
  return function(level, fmt, ...)
    messages[#messages + 1] = { level = level, text = string.format(fmt, ...) }
  end
end

local function fileExists(path)
  local f = io.open(path, "r")
  if not f then return false end
  io.close(f)
  return true
end

local function readWhole(path)
  local f = io.open(path, "r")
  if not f then return nil end

  local parts = {}
  while true do
    local chunk = io.read(f, READ_CHUNK)
    if chunk == nil or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  io.close(f)

  local content = table.concat(parts)
  if content == "" then return nil end
  return content
end

-- del() and rename() are bare globals of the firmware's filesystem library (etxdir), not
-- members of os: there is no os table in that Lua at all. Both answer with an FRESULT, where
-- 0 is success and every other value is a failure -- so a truth test on the return value says
-- the opposite of what it looks like it says. A desktop Lua has os and neither global, and
-- there os.remove/os.rename answer with true or nil.
local function canRename()
  if type(rename) == "function" then return true end
  return type(os) == "table" and type(os.rename) == "function"
end

local function removeFile(path)
  if type(del) == "function" then
    local ok, res = pcall(del, path)
    return ok and res == 0
  end
  if type(os) == "table" and type(os.remove) == "function" then
    return os.remove(path) and true or false
  end
  return false
end

local function renameFile(from, to)
  if type(rename) == "function" then
    local ok, res = pcall(rename, from, to)
    return ok and res == 0
  end
  if type(os) == "table" and type(os.rename) == "function" then
    return os.rename(from, to) and true or false
  end
  return false
end

-- ---------------------------------------------------------------------------- serialisation

local RESERVED = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
  ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
  ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
  ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

-- Keys that are not names have to be written in brackets. The composite keys an open section
-- carries -- a theme prefix, a skipped procedure -- are exactly that case.
local function keyToken(k)
  if string.match(k, "^[%a_][%w_]*$") and not RESERVED[k] then
    return k
  end
  return "[" .. string.format("%q", k) .. "]"
end

-- A number goes through tostring(), which is "%.14g" in this Lua, and that is the accepted
-- precision bound of the format: fourteen significant digits, so 1/3 comes back as
-- 0.33333333333333 rather than as the double it was. Every value a store holds is a threshold,
-- a voltage or a count, where fourteen digits is more than the sensor behind it can mean. The
-- one integer that does not survive the round trip is the smallest one there is: its text has
-- no positive counterpart, so it reads back as a float. No setting can reach it.
local function literal(v)
  local t = type(v)
  if t == "boolean" then return v and "true" or "false" end
  if t == "string" then return string.format("%q", v) end
  if t == "number" then
    -- Infinities and NaN serialise as bare names, and the loader runs the chunk in an empty
    -- environment where a name is nil. Neither can come back as itself, so neither is written.
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return tostring(v)
  end
  return nil
end

local function sortedNames(t)
  local names = {}
  local n = 0
  for k in pairs(t) do
    if type(k) == "string" then
      n = n + 1
      names[n] = k
    end
  end
  -- The bare sort, without a Lua comparator: the comparison happens in C, and a comparator
  -- would also make the order depend on the process's string-hash seed.
  table.sort(names)
  return names
end

-- ---------------------------------------------------------------------------------- loading

-- This is the one function a load spends its instructions in, so the type test is written out
-- at each of its three sites rather than called: a Lua call costs several times what the three
-- comparisons do, and there are one or two tests per key in the file.
--
-- A DECLARED key is held against its default's type rather than against that list, and the
-- difference matters: `save_confirm = "false"` is a perfectly good string, and every reader of
-- that key tests it as a boolean, where a non-empty string is true. So the file would turn the
-- setting on by writing the word for off. A key whose type does not match takes the default and
-- is named in the log; the section is then reported incomplete, so the next save writes the
-- declared value over it. Optional and open keys keep the boolean/number/string rule -- there
-- is no declaration to hold them against.
local function mergeSection(spec, fromFile, state, retired, sectionName)
  local out = {}
  local defaults = spec.keys
  local hasFile = type(fromFile) == "table"

  if hasFile then
    if spec.open then
      -- An open section's undeclared keys are its point: they are built at runtime and no
      -- schema can name them. A retired key is the one thing such a section can still lose,
      -- and without it a key that outlived its reader would be immortal here.
      for k, v in pairs(fromFile) do
        local t = type(v)
        if type(k) == "string" and (t == "boolean" or t == "number" or t == "string")
            and not (retired and retired[k]) then
          out[k] = v
        end
      end
    else
      local optional = spec.optional
      if optional then
        for i = 1, #optional do
          local k = optional[i]
          local v = fromFile[k]
          local t = type(v)
          if t == "boolean" or t == "number" or t == "string" then out[k] = v end
        end
      end
    end
  end

  if not defaults then return out end

  -- The overlay is eager rather than an __index fallback: pairs() does not see inherited keys,
  -- so a saver walking the table would drop every defaulted one.
  if spec.open then
    -- The pass above already took whatever the file held, declared keys included.
    for k, v in pairs(defaults) do
      if out[k] == nil then
        out[k] = v
        state.complete = false
      end
    end
  elseif hasFile then
    for k, v in pairs(defaults) do
      local have = fromFile[k]
      if type(have) == type(v) then
        out[k] = have
      else
        out[k] = v
        state.complete = false
        if have ~= nil then
          local ignored = state.ignored
          if not ignored then
            ignored = {}
            state.ignored = ignored
          end
          ignored[#ignored + 1] = (sectionName or "?") .. "." .. k
        end
      end
    end
  else
    for k, v in pairs(defaults) do
      out[k] = v
      state.complete = false
    end
  end

  return out
end

-- Says once per load which declared keys the file described with the wrong kind of value. One
-- line rather than one per key: this is a hand edit or a file from a suite that meant something
-- else by the name, and what the reader needs is the list.
local function reportIgnored(emit, path, state)
  local ignored = state.ignored
  if not ignored then return end
  emit("warn", "%s: ignored, the value is not of the type the key is declared with: %s",
    tostring(path), table.concat(ignored, ", "))
end

-- ------------------------------------------------------------------------------- legacy INI

local function trim(s)
  local asString = tostring(s or "")
  asString = string.gsub(asString, "^%s+", "")
  asString = string.gsub(asString, "%s+$", "")
  return asString
end

local function parseValue(v)
  local t = trim(v)
  local lower = string.lower(t)
  if lower == "true" then return true end
  if lower == "false" then return false end
  local n = tonumber(t)
  if n ~= nil then return n end
  return t
end

--- The reader for the format the stores used before this one, kept in one place and reached
--- only by the migration below and by the in-memory read beside it.
---
--- `opts.raw = true` keeps every value the text it was. The coercion is right for a settings
--- file, where `true` means the boolean and `30` the number, and wrong for a store whose values
--- are names the pilot chose: a model called `007` would come back as the number 7 and a model
--- called `1.50` as 1.5, and the leading zero cannot be put back by any later conversion.
function Store:parseLegacyIni(content, opts)
  local result = {}
  local section = nil
  local raw = opts and opts.raw

  if type(content) ~= "string" or content == "" then
    return result
  end

  for line in string.gmatch(content, "[^\r\n]+") do
    local normalized = trim(line)
    if normalized ~= "" and string.sub(normalized, 1, 1) ~= ";" and string.sub(normalized, 1, 1) ~= "#" then
      local sec = string.match(normalized, "^%[(.-)%]$")
      if sec then
        section = trim(sec)
        if result[section] == nil then
          result[section] = {}
        end
      else
        local k, v = string.match(normalized, "^([^=]+)=(.*)$")
        if k and v and section then
          result[section][trim(k)] = raw and trim(v) or parseValue(v)
        end
      end
    end
  end

  return result
end

--- The store's values as the FORMER file still holds them, read into memory and no further.
---
--- This is what a Lua state that may not migrate answers with, and it is deliberately the same
--- work the migration does minus the writing: the same parser, the same optional mapping, the
--- same schema applied to the result. Answers nil where there is no former file either, or where
--- the caller has said it will handle that case itself.
function Store:loadLegacy(path, opts, info, state)
  local emit = sinkFor(opts)
  if opts and opts.legacy == false then return nil end

  local iniPath = M.legacyPath(path)
  if iniPath == path or self.legacyGone[iniPath] then return nil end

  local src = readWhole(iniPath)
  if src == nil then
    self.legacyGone[iniPath] = true
    return nil
  end

  local parsed = self:parseLegacyIni(src, opts)
  local fromIni = opts and opts.fromIni
  if fromIni then parsed = fromIni(parsed) or {} end

  local out = {}
  for name, spec in pairs(self.schema) do
    out[name] = mergeSection(spec, parsed[name], state, self.retired[name], name)
  end

  info.found = true
  info.legacy = true
  info.complete = state.complete
  reportIgnored(emit, iniPath, state)
  return out
end

-- ----------------------------------------------------------------------------------- public

--- Lets this Lua state bring a card written by an earlier release across. Called once, by a host
--- that knows how it is billed -- see the note at the top of this file. `allowMigration(false)`
--- takes it back, which is what a test that wants to see the other half needs.
function M.allowMigration(allowed)
  migrationAllowed = (allowed ~= false)
end

--- Whether this state may write a store as a side effect of reading one. A caller that settles a
--- store on load -- the per-board one writes back what the file did not carry -- asks here
--- first, because that write is under the same limit the migration is.
function M.migrationAllowed()
  return migrationAllowed
end

--- A store over one schema. `name` names the store in the file's header and in the chunk name
--- the compiler puts in front of a syntax error.
function M.new(opts)
  local self = setmetatable({}, Store)
  self.name = (opts and opts.name) or "config"
  self.schema = (opts and opts.schema) or {}
  self.generation = 0

  -- Paths whose former file is known not to be there. Nothing in the suite creates one -- the
  -- migration only ever renames one away -- so a miss stays a miss for the life of this state,
  -- and remembering it keeps a failed open off a path that is read on a cadence.
  self.legacyGone = {}

  -- Turned into lookups once, here, rather than on every load: a store is built once per Lua
  -- state and read on every reload.
  --
  -- A key may not be both declared and retired, and the schema that says both is a mistake
  -- rather than a preference: `retired` drops a key on load and on save, `keys` writes it on
  -- every save, so the two would fight over the same name in the same file for ever. It is
  -- caught here, where a schema is built, rather than by the file coming out wrong on a radio.
  self.retired = {}
  for name, spec in pairs(self.schema) do
    local retired = spec.retired
    if retired then
      local set = {}
      local declared = spec.keys
      for i = 1, #retired do
        local key = retired[i]
        if declared and declared[key] ~= nil then
          log("error", "%s: [%s] %s is declared and retired at once; the declaration wins",
            self.name, tostring(name), tostring(key))
        else
          set[key] = true
        end
      end
      self.retired[name] = set
    end
  end

  return self
end

--- The declared defaults, as a fresh table. The one place they are declared is the schema, so
--- a caller that needs them without touching the card asks here rather than keeping a copy.
function Store:defaults()
  local out = {}
  local state = { complete = true }
  for name, spec in pairs(self.schema) do
    out[name] = mergeSection(spec, nil, state, self.retired[name], name)
  end
  return out
end

--- Reads the store. Answers the table and an info record; the table is always usable and
--- always a fresh one, so a caller may treat its identity as a generation marker.
---
--- info.found      the file was there and carried something
--- info.complete   every declared key was in the file (false also when it was not there)
--- info.recovered  the file was picked up under its temporary name (see save below)
--- info.error      the chunk did not compile, did not run, or did not return a table
---
--- info.legacy     the store is not on the card yet and the former file was read in its place
---
--- `opts.recover = false` leaves an interrupted save where it is. It is for a caller that reads
--- the store from somewhere a file must not be renamed -- a widget's reactive sweep reaches
--- lib/system_locale.lua that way -- and it costs that caller a probe it cannot use.
---
--- `opts.legacy = false` answers with the declared defaults where the store is not on the card
--- yet, instead of reading the former file in its place. It is for a caller that reads on a
--- cadence and handles that case once itself, since the former file cannot change under it.
---
--- `opts.fromIni` and `opts.raw` are the migration's, and apply to the in-memory read for the
--- same reason: it has to answer what the migration would have written.
---
--- `opts.messages` is a table this call appends {level, text} records to instead of writing
--- them to the log, and it comes back as `info.messages`. It is for the caller whose load runs
--- before the log can decide whether to print anything -- see sinkFor above.
function Store:load(path, opts)
  local emit = sinkFor(opts)
  local info = { path = path, found = false, complete = false, messages = opts and opts.messages }
  local state = { complete = true }

  local src = readWhole(path)
  if src == nil and not (opts and opts.recover == false) then
    -- A save interrupted between the delete and the rename leaves the new content under the
    -- temporary name and nothing under the real one. Finishing that rename here is what makes
    -- the write indivisible as far as a reader is concerned.
    local tmp = path .. TMP_SUFFIX
    src = readWhole(tmp)
    if src ~= nil then
      info.recovered = true
      -- The real name can still be TAKEN here even though nothing could be read from it: a
      -- file of zero bytes reads as nothing above, and that is exactly what a save interrupted
      -- while the new content was being written leaves behind. FatFs refuses a rename onto a
      -- name that exists, so the empty file goes first, as save does before its own rename.
      if fileExists(path) then removeFile(path) end
      if not renameFile(tmp, path) then
        emit("warn", "%s: could not finish the interrupted save", tostring(path))
      end
    end
  end

  if src == nil then
    -- No store on the card. A state that may not migrate still owes its caller the pilot's
    -- settings, so the former file is read here and NOTHING is written: the migration belongs
    -- to the tool and to the background decoder. It ends by itself -- the moment one of them
    -- has run, the store is there and this branch is not reached again.
    local merged = self:loadLegacy(path, opts, info, state)
    if merged then return merged, info end
    return self:defaults(), info
  end
  info.found = true

  -- The generation the file carries, so that the next save can move it on. Anchored on the
  -- file's LAST LINE rather than matched anywhere in it: the counter is a trailer this module
  -- writes, and an open section's values are strings a pilot may put anything into. One reading
  -- `generation 99` used to be found first and pin the counter at 99 for ever, which leaves two
  -- saves inside one FAT timestamp slot looking to a reader like no save at all.
  local seen = tonumber(string.match(src, "\n%-%- generation (%d+)[^\n]*\n$"))
  if seen then self.generation = seen end

  -- Text mode and an empty environment, both deliberately.
  --
  -- The firmware's own loader defaults to "bt", and in that mode it compiles a .lua that is
  -- newer than its .luac and writes the bytecode back beside it; it then prefers that bytecode
  -- whenever the two timestamps tie, which at the 2-second resolution of a FAT timestamp means
  -- a configuration saved in the same slot reads back stale. load() on the string writes
  -- nothing and reads nothing but the string.
  --
  -- The environment cannot be handed to loadScript either: the firmware clears the stack
  -- before it reads that argument, so _ENV ends up nil there. load() takes it correctly.
  local chunk, err = load(src, "=" .. self.name, "t", {})
  if not chunk then
    info.error = tostring(err)
    emit("error", "%s: %s -- the declared defaults are used instead", tostring(path), tostring(err))
    return self:defaults(), info
  end

  local ok, result = pcall(chunk)
  if not ok then
    info.error = tostring(result)
    emit("error", "%s: %s -- the declared defaults are used instead", tostring(path), tostring(result))
    return self:defaults(), info
  end
  if type(result) ~= "table" then
    info.error = "the file did not return a table"
    emit("error", "%s: the file did not return a table -- the declared defaults are used instead", tostring(path))
    return self:defaults(), info
  end

  local out = {}
  for name, spec in pairs(self.schema) do
    out[name] = mergeSection(spec, result[name], state, self.retired[name], name)
  end
  info.complete = state.complete
  reportIgnored(emit, path, state)
  return out, info
end

--- The file's text for `tbl`, schema first: every declared key, every optional key that is
--- set, and an open section's extra keys. Sections and keys are sorted, so two saves of the
--- same values produce the same text and a diff shows what actually changed.
function Store:serialize(tbl)
  local values = type(tbl) == "table" and tbl or {}
  local out = {}
  local n = 0
  local function emit(s)
    n = n + 1
    out[n] = s
  end

  emit("-- RFSuite " .. self.name .. ". This file is Lua data, not an INI: strings keep their\n")
  emit("-- quotes, booleans are true or false, and the return line stays. Rewritten whole on save.\n")
  emit("return {\n")

  local sections = sortedNames(self.schema)
  for i = 1, #sections do
    local sectionName = sections[i]
    local spec = self.schema[sectionName]
    local section = values[sectionName]
    if type(section) ~= "table" then section = {} end

    local declared = spec.keys or {}
    local written = {}
    -- The section is built into its own buffer so that one which comes out with nothing in it
    -- can be left out of the file entirely.
    local body = {}
    local b = 0
    local function put(text)
      b = b + 1
      body[b] = text
    end

    local names = sortedNames(declared)
    for j = 1, #names do
      local k = names[j]
      local lit = literal(section[k])
      if lit == nil then lit = literal(declared[k]) end
      if lit ~= nil then
        put("    " .. keyToken(k) .. " = " .. lit .. ",\n")
        written[k] = true
      end
    end

    local optional = spec.optional
    if optional then
      local opt = {}
      for j = 1, #optional do opt[j] = optional[j] end
      table.sort(opt)
      for j = 1, #opt do
        local k = opt[j]
        if not written[k] then
          local lit = literal(section[k])
          if lit ~= nil then
            put("    " .. keyToken(k) .. " = " .. lit .. ",\n")
            written[k] = true
          end
        end
      end
    end

    if spec.open then
      local extra = {}
      local m = 0
      local literals = {}
      local retired = self.retired[sectionName]
      for k, v in pairs(section) do
        if type(k) == "string" and not written[k] and not (retired and retired[k]) then
          local lit = literal(v)
          if lit ~= nil then
            m = m + 1
            extra[m] = k
            literals[k] = lit
          end
        end
      end
      table.sort(extra)
      for j = 1, #extra do
        local k = extra[j]
        put("    " .. keyToken(k) .. " = " .. literals[k] .. ",\n")
      end
    end

    -- An empty section reads back as an empty table whether it is written or not, and an open
    -- section that declares no key of its own is empty on most cards.
    if b > 0 then
      emit("  " .. keyToken(sectionName) .. " = {\n")
      for j = 1, b do emit(body[j]) end
      emit("  },\n")
    end
  end

  emit("}\n")

  -- A counter that moves on every save, padded so that the file's byte count moves with it.
  -- A reader that watches the store with one fstat compares size and time, and a FAT timestamp
  -- has 2-second resolution: without this, two saves inside one slot look like no save at all.
  local generation = (self.generation % GENERATION_MAX) + 1
  self.generation = generation
  emit("-- generation " .. generation .. " " .. string.rep(".", generation - 1) .. "\n")

  return table.concat(out)
end

--- Writes the store. The new content goes to a temporary name and then takes the real one, so
--- a reader never sees a half-written file and a card that fills up loses the temporary rather
--- than the store. Errors are returned and logged, never swallowed.
function Store:save(path, tbl, opts)
  local emit = sinkFor(opts)
  local body = self:serialize(tbl)

  local tmp = path .. TMP_SUFFIX
  local atomic = canRename()
  local target = atomic and tmp or path
  if not atomic then
    emit("warn", "%s: no rename available, so the store is written in place", tostring(path))
  end

  local f, err = io.open(target, "w")
  if not f then
    emit("error", "%s: could not be opened for writing: %s", tostring(target), tostring(err))
    return false, err or "io"
  end
  local wrote, writeErr = io.write(f, body)
  io.close(f)

  if not wrote then
    if atomic and fileExists(tmp) then
      removeFile(tmp)
    end
    emit("error", "%s: could not be written: %s", tostring(target), tostring(writeErr or "short write"))
    return false, writeErr or "write"
  end

  if atomic then
    -- FatFs refuses a rename onto a name that exists, so the old file goes first. The window
    -- between the two is what load()'s recovery above is for.
    if fileExists(path) and not removeFile(path) then
      emit("error", "%s: could not be replaced", tostring(path))
      return false, "delete"
    end
    if not renameFile(tmp, path) then
      emit("error", "%s: could not be renamed to %s", tostring(tmp), tostring(path))
      return false, "rename"
    end
  end

  -- The serialised text is the largest string this module builds. A collection here and not in
  -- load, deliberately: a save happens when the pilot presses Save, in the state that is
  -- yielded rather than cut off, whereas a load is on the widget's reload path -- where a
  -- collection is instructions taken out of the same pass that has just done the reading.
  collectgarbage("collect")
  return true
end

--- Brings a store held in the former INI format across, once. Safe to call on every load: it
--- costs one failed open where there is nothing to do, and it can be interrupted at any point
--- without losing either file.
---
--- `opts.fromIni` is for a store whose former file did not carry one INI section per section of
--- the schema. It is handed the parsed INI and answers the table the schema is then applied to,
--- which keeps every file step here rather than in a second copy of it beside this one.
function Store:migrate(luaPath, iniPath, opts)
  local emit = sinkFor(opts)
  -- Cheaper than the cheap question, and it is the one that has to come first: a state that is
  -- cut off at a fixed instruction count cannot finish the parse below, so it does not start it.
  -- Store:load reads the former file into memory for such a state instead.
  if not migrationAllowed then return false end

  -- The cheap question first. After the migration the INI is gone under that name, so this is
  -- what every later load pays and all it pays.
  if not fileExists(iniPath) then return false end

  local backup = iniPath .. ".bak"

  -- Both files present: the Lua one is what is read, so the INI is a leftover from a migration
  -- whose rename did not get through. Nothing is parsed and nothing is written.
  if readWhole(luaPath) ~= nil then
    if fileExists(backup) then removeFile(backup) end
    if not renameFile(iniPath, backup) then
      emit("warn", "%s: could not be set aside as %s", tostring(iniPath), tostring(backup))
    end
    return false
  end

  local src = readWhole(iniPath)
  if src == nil then
    -- An empty INI carries nothing, so there is nothing to bring across.
    if fileExists(backup) then removeFile(backup) end
    if not renameFile(iniPath, backup) then
      emit("warn", "%s: could not be set aside as %s", tostring(iniPath), tostring(backup))
    end
    return false
  end

  -- A stale compiled copy beside the store would be preferred by the firmware's loader on a
  -- timestamp tie. Nothing here loads it, but leaving it on the card leaves that trap armed.
  local compiled = string.gsub(luaPath, "%.lua$", ".luac")
  if compiled ~= luaPath and fileExists(compiled) then
    removeFile(compiled)
  end

  local parsed = self:parseLegacyIni(src, opts)
  local fromIni = opts and opts.fromIni
  if fromIni then parsed = fromIni(parsed) or {} end

  local state = { complete = true }
  local merged = {}
  for name, spec in pairs(self.schema) do
    merged[name] = mergeSection(spec, parsed[name], state, self.retired[name], name)
  end
  reportIgnored(emit, iniPath, state)

  local ok, err = self:save(luaPath, merged, opts)
  if not ok then
    emit("error", "%s: could not be written, so %s is kept: %s", tostring(luaPath), tostring(iniPath), tostring(err))
    return false, err
  end

  -- The former file is kept for one release rather than deleted. A failed rename leaves it
  -- where it is and is not retried by parsing again: the branch above finds both files next
  -- time and only tries the rename.
  if fileExists(backup) then removeFile(backup) end
  if not renameFile(iniPath, backup) then
    emit("warn", "%s: could not be set aside as %s", tostring(iniPath), tostring(backup))
  end

  emit("info", "%s: brought across from %s", tostring(luaPath), tostring(iniPath))
  return true
end

if type(_G) == "table" then
  _G.__rfsuite_config_store = M
end

return M
