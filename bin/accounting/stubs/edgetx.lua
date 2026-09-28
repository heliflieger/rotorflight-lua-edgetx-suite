-- The minimal EdgeTX surface the measured sources touch. Deterministic by construction:
-- the clock advances a fixed step per call, every sensor/model/telemetry answer comes from
-- a scripted table, and lvgl records node trees instead of drawing. Stubs answer; they
-- never compute -- anything clever here is a measurement error waiting to be found.
--
-- A missing surface must fail the run loudly: the suite's own sources wrap everything in
-- pcall, and in a measurement a swallowed load error is a zero that reads as "cheap".

local Stubs = {}

local SRC_PREFIX = "/SCRIPTS/TOOLS/rfsuite-core/"
local WIDGET_PREFIX = "/SCRIPTS/TOOLS/"
local FUNCTION_PREFIX = "/SCRIPTS/FUNCTIONS/"

-- Repo-relative remap targets; measure.lua chdir-independence comes from passing the
-- repo root in.
local repoRoot = "."

-- ---------------------------------------------------------------------------
-- The card this run is given, in place of the host's.
--
-- The suite opens its settings by absolute card path -- /SCRIPTS/TOOLS/rfsuite.user/...,
-- spelled SCRIPTS:/TOOLS/rfsuite.user/... in two modules -- so under the stubs those opens
-- went to the host's root filesystem: a run read whatever settings file the machine had,
-- and wrote its own into the machine's card. That made a local --check and the CI job
-- disagree over a file outside the repository, and made a run leave something behind.
--
-- So every card path is remapped here, the way loadScript is remapped onto the repository
-- below: the sources still spell paths the way they spell them on a radio, and the run
-- reads and writes a card of its own in the system temp directory, emptied when the run
-- starts and again when the last measurement is done. A path outside the card is left
-- exactly as it was, so measure.lua's own file access -- which is repo-relative -- is
-- untouched.
-- ---------------------------------------------------------------------------
local CARD_PREFIX = "/SCRIPTS"
local CARD_VOLUME_PREFIX = "SCRIPTS:"

-- mkdir and rmdir are the two commands this needs, and both spell the same in the two shells
-- it runs under. A directory is made once and then remembered, so an open on a path whose
-- parent is already there costs a table lookup rather than a process.
--
-- The null device is named per platform on purpose: `2>NUL` under a POSIX shell is a redirect
-- to a file called NUL, which would drop one into the working directory on every run.
local NULL_DEVICE = package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null"

-- The card is taken by mkdir as the test: mkdir fails when the directory is already there, on
-- both of the two shells this runs under, so it is a portable test-and-set. That is the only
-- way to tell two runs apart here -- Lua 5.3 does not seed math.random at startup, os.time()
-- resolves to a second, and nothing in stock Lua reports a process id. Naming the card after
-- the time alone would let two runs started in the same second share one card, and the second
-- one's startup empty would land in the middle of the first one's measurement.
local function takeCardRoot()
  local base = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local stamp = tostring(os.time())
  for attempt = 1, 64 do
    local candidate = string.format("%s/rfsuite-accounting-card-%s-%d", base, stamp, attempt)
    if os.execute(string.format('mkdir "%s" 2>%s', candidate, NULL_DEVICE)) then
      return candidate
    end
  end
  return base .. "/rfsuite-accounting-card-" .. stamp
end

Stubs.cardRoot = takeCardRoot()

--- The path a card path is answered at, or nil when the path is not on the card.
local function cardPath(path)
  if type(path) ~= "string" then return nil end
  local rest
  if string.sub(path, 1, #CARD_PREFIX) == CARD_PREFIX then
    rest = string.sub(path, #CARD_PREFIX + 1)
  elseif string.sub(path, 1, #CARD_VOLUME_PREFIX) == CARD_VOLUME_PREFIX then
    rest = string.sub(path, #CARD_VOLUME_PREFIX + 1)
  else
    return nil
  end
  -- Both spellings leave separators behind -- the volume one leaves the one that follows its
  -- colon -- so the remainder is stripped to a clean relative path and rejoined with exactly
  -- one. Cutting at #CARD_PREFIX rather than #CARD_PREFIX + 1 kept the prefix's last character
  -- and answered the two spellings at two different directories, one of them a *sibling* of
  -- the card root, which nothing ever emptied.
  rest = rest:gsub("^[/\\]+", "")
  if rest == "" then return Stubs.cardRoot end
  return Stubs.cardRoot .. "/" .. rest
end

local madeDirs = {}

local function ensureDir(path)
  if madeDirs[path] then return end
  madeDirs[path] = true
  -- Every prefix that ends in a separator, shortest first, so "C:\" on Windows and "/" on a
  -- desktop are both kept: the path is cut at its own separators, never re-joined with one.
  local at = 1
  while true do
    local _, e = string.find(path, "[/\\]", at)
    if not e then break end
    if e < #path then
      os.execute(string.format('mkdir "%s" 2>%s', string.sub(path, 1, e), NULL_DEVICE))
    end
    at = e + 1
  end
  -- The loop above can only ever issue a prefix that ends in a separator, and a directory
  -- name is not followed by one -- so the directory the caller actually asked for was never
  -- made. The wrapper hands this the parent of a file it is about to open, and on a fresh
  -- card that parent is one level below where the loop stops, which is why an open of
  -- TOOLS/rfsuite.user/<mcu>.lua made TOOLS and then failed on the one directory it is
  -- there for. One more mkdir for the full path closes it.
  os.execute(string.format('mkdir "%s" 2>%s', path, NULL_DEVICE))
end

-- The tree walk for the cleanup uses the same `ls -1` the rest of the instrument lists
-- with, for the same reason: one listing means two hosts enumerate in one order.
local function listDir(path)
  local pipe = io.popen(string.format('ls -1 "%s" 2>%s', path, NULL_DEVICE))
  if not pipe then return {} end
  local names = {}
  for name in pipe:lines() do names[#names + 1] = name end
  pipe:close()
  table.sort(names)
  return names
end

-- madeDirs is a cache of what has been made, and it is the one thing here that can be
-- wrong without any visible error: forget an entry and the cost is a few extra mkdirs,
-- keep one for a directory that is gone and the next write into it skips the mkdir and
-- fails. Two ways that used to happen, both platform-dependent -- on Linux os.remove on
-- an *empty* directory succeeds, so emptyDir took a subdirectory away on the branch meant
-- for files and never forgot it, and removeTree only ever forgot its own path, never its
-- children's. So both hand the whole table over rather than reason about which entries the
-- walk happened to touch. Nothing in the measured run writes to the card, so re-issuing the
-- mkdirs costs nothing there; in the self-test it is a handful of processes.
local function forgetMadeDirs()
  for path in pairs(madeDirs) do madeDirs[path] = nil end
end

-- Remove a directory and everything under it. os.remove is asked first and the recursion is
-- the fallback, because telling a file from a directory by opening it is a question with two
-- answers: fopen on a directory succeeds on Linux and fails on Windows, so the same card
-- emptied on the machine that wrote it and not on the CI runner, and a subdirectory was
-- treated as a file there and left behind with its contents in place. os.remove fails on a
-- directory on both platforms, which is the one answer that holds everywhere.
local function removeTree(path)
  forgetMadeDirs()
  for _, name in ipairs(listDir(path)) do
    local child = path .. "/" .. name
    if not os.remove(child) then
      removeTree(child)
    end
  end
  os.execute(string.format('rmdir "%s" 2>%s', path, NULL_DEVICE))
end

-- Empty a directory without removing it. Stubs.clearCard() uses this rather than
-- removeTree() so the card root survives the call: that root is what takeCardRoot() claimed
-- with mkdir, and handing it back would let a second run take a card this one is still using.
local function emptyDir(path)
  forgetMadeDirs()
  for _, name in ipairs(listDir(path)) do
    local child = path .. "/" .. name
    if not os.remove(child) then
      removeTree(child)
    end
  end
end

--- Empty the card this run was given.
--
-- Called once when the run starts and once when it ends. The startup call is the one that
-- matters: a run that died on a control it could not satisfy leaves its card behind, and
-- the next run must not read it. A directory that is not there is not an error -- the
-- common case is a run that never wrote anything.
function Stubs.clearCard()
  emptyDir(Stubs.cardRoot)
end

--- Empty the card and hand the directory itself back.
--
-- The last thing a run that got all the way through does. takeCardRoot() claims the name so
-- no second run can take a card this one is measuring with, and a name nobody reclaims is
-- litter: every run of the instrument would leave an empty directory in the temp folder,
-- forever. measure.lua calls this from the same point its old clearCard() stood, so it runs
-- on every exit from there on, os.exit in the self-test included. A run killed outright
-- still leaks its card, which is the price of not letting a second run step on the first.
function Stubs.releaseCard()
  emptyDir(Stubs.cardRoot)
  os.execute(string.format('rmdir "%s" 2>%s', Stubs.cardRoot, NULL_DEVICE))
  madeDirs[Stubs.cardRoot] = nil
end

-- Installed once, at load: the remap is a property of the interpreter, not of a world, and
-- a per-world install would wrap the wrapper again on every scenario.
local realOpen, realRemove, realRename = io.open, os.remove, os.rename

io.open = function(path, mode)
  local card = cardPath(path)
  if not card then return realOpen(path, mode) end
  -- io.open does not create a missing directory, and the firmware's card layout has the
  -- user directory below two that may not be there -- lib/preferences.lua:335 says as much.
  if mode and string.find(mode, "[wa+]") then ensureDir(card:match("^(.*)[/\\][^/\\]*$") or card) end
  return realOpen(card, mode)
end

os.remove = function(path)
  local card = cardPath(path)
  return realRemove(card or path)
end

os.rename = function(from, to)
  return realRename(cardPath(from) or from, cardPath(to) or to)
end

-- Fixed-step clock, advanced once per PASS by the caller rather than once per call. getTime is
-- in 10 ms units on the radio, and a widget pass is about 100 ms, so one pass is ten ticks.
--
-- It used to advance on every call, which is deterministic but makes a second worth however many
-- times the code under test happens to ask the time. Anything the suite does on a cadence -- a
-- read every 0.5 s, a cooldown, a throttle -- then fires almost every pass or almost never
-- depending on that count, and cannot be priced. Never the wall clock either way: determinism is
-- what makes two runs comparable.
local clockTicks = 0
local CLOCK_STEP_TICKS = 10

-- Scripted answers, settable per scenario by measure.lua.
Stubs.sensors = {}          -- name -> number (getValue / lib/sensors path)
Stubs.modelInfo = { name = "Bench", bitmap = "", filename = "bench.bin" }
Stubs.telemetryFrames = {}  -- queue of { command, data } served to crossfireTelemetryPop
Stubs.published = {}        -- what setTelemetryValue was called with, recorded
Stubs.prefsStat = nil       -- what fstat answers for the preference files, or nil for absent

-- The firmware's shared-memory slots: integers that live outside every Lua state and that
-- nothing on the radio ever clears. reset() clears them here, so one scenario cannot inherit
-- another's liveness -- on the radio that inheritance is the case the drain has to survive.
Stubs.shmVars = {}

-- The model's special functions. The connect chain installs one for the background decoder, so
-- without this surface the task that does it would be measured returning on its first line.
Stubs.customFunctions = {}  -- 0..MAX-1 -> the table model.getCustomFunction answers with
Stubs.customFunctionWrites = {}

local SPECIAL_FUNCTION_COUNT = 64

-- What getSwitchIndex answers for the always-on switch. Nothing measured here depends on the
-- value, only on its being a number other than zero.
local ALWAYS_ON_SWITCH_INDEX = 121
-- The switch positions the radio offers, indexed by their switch source number, and which of them
-- are held. The names matter: the in-flight tuning drive finds the trim block by walking this list
-- for the run of positions ending in plus and minus, so the arrows in front of it are spelled the
-- way the firmware spells them (getSwitchPositionName, radio/src/strhelpers.cpp) and the middle
-- position of a three-way switch carries the hyphen that must not be swallowed into the run.
Stubs.switchNames = {
  "SA\226\134\145", "SA-", "SA\226\134\147",
  "Rud-", "Rud+", "Ele-", "Ele+", "Thr-", "Thr+",
  "Ail-", "Ail+", "T5-", "T5+", "T6-", "T6+",
}
Stubs.switchValues = {}     -- switch source -> true / false, absent for a position this radio lacks

-- The model's global variables, as written. A stub records; nothing here recomputes a channel.
Stubs.gvars = {}

-- The far side of the link. stubs/fc.lua replaces this with a scripted flight controller;
-- on its own the link accepts every frame and answers nothing, which is a radio with no
-- board attached.
Stubs.onPush = function() return true end

--- Queue one frame for crossfireTelemetryPop, in arrival order.
function Stubs.pushFrame(command, data)
  Stubs.telemetryFrames[#Stubs.telemetryFrames + 1] = { command = command, data = data }
end

-- lvgl recorder: `build` keeps the node list and collects every function field as a
-- reactive ref, so the sweep can be replayed by the runner in a plain loop.
Stubs.lvgl = {
  trees = {},
  refs = {},
}

local function collectRefs(node, refs)
  for _, v in pairs(node) do
    if type(v) == "function" then
      refs[#refs + 1] = v
    elseif type(v) == "table" then
      collectRefs(v, refs)
    end
  end
end

--- One pass of the host clock. Called by measure.lua once per measured pass.
function Stubs.tick()
  clockTicks = clockTicks + CLOCK_STEP_TICKS
end

function Stubs.reset()
  clockTicks = 0
  clockTicks = 0
  Stubs.sensors = {}
  Stubs.telemetryFrames = {}
  Stubs.published = {}
  Stubs.prefsStat = nil
  Stubs.shmVars = {}
  Stubs.customFunctions = {}
  Stubs.customFunctionWrites = {}
  for i = 0, SPECIAL_FUNCTION_COUNT - 1 do
    -- An unused slot as the firmware hands it back: switch unset, and function zero, which is
    -- a real function rather than "none".
    Stubs.customFunctions[i] = { switch = 0, func = 0, active = 0, repetition = 0 }
  end
  Stubs.lvgl.trees = {}
  Stubs.lvgl.refs = {}
  Stubs.switchValues = {}
  Stubs.gvars = {}
end

function Stubs.install(root)
  repoRoot = root or "."

  _G.LCD_W = 800
  _G.LCD_H = 480

  -- Colors, fonts, alignment: numeric constants, values irrelevant to the count.
  local consts = {
    WHITE = 0xFFFF, BLACK = 0x0000, RED = 0xF800, GREEN = 0x07E0, YELLOW = 0xFFE0,
    BLUE = 0x001F, MAGENTA = 0xF81F, CYAN = 0x07FF,
    COLOR_THEME_PRIMARY1 = 1, COLOR_THEME_PRIMARY2 = 2, COLOR_THEME_PRIMARY3 = 3,
    COLOR_THEME_SECONDARY1 = 4, COLOR_THEME_SECONDARY2 = 5, COLOR_THEME_SECONDARY3 = 6,
    COLOR_THEME_WARNING = 7, COLOR_THEME_DISABLED = 8, COLOR_THEME_FOCUS = 9,
    COLOR_THEME_ACTIVE = 10, COLOR_THEME_EDIT = 11,
    DBLSIZE = 0x400, MIDSIZE = 0x300, SMLSIZE = 0x100, XXLSIZE = 0x800,
    CENTER = 0x10, LEFT = 0x20, RIGHT = 0x40, TOP = 0x01, BOTTOM = 0x02,
  }
  for k, v in pairs(consts) do _G[k] = v end

  -- Lua 5.3 dropped bit32; the firmware's build provides it. Only what the sources use.
  if not _G.bit32 then
    _G.bit32 = {
      band = function(a, b) return a & b end,
      bor = function(a, b) return a | b end,
      bxor = function(a, b) return a ~ b end,
      lshift = function(a, n) return (a << n) & 0xFFFFFFFF end,
      rshift = function(a, n) return a >> n end,
      extract = function(n, f, w) return (n >> f) & ((1 << (w or 1)) - 1) end,
    }
  end

  _G.getTime = function()
    return clockTicks
  end

  _G.getVersion = function()
    return "bench", "EdgeTX-accounting-stub", 2, 12, 0
  end

  _G.getUsage = function() return 0 end

  -- radio/src/lua/api_general.cpp, the etxcst constant table.
  _G.FUNC_PLAY_SCRIPT = 24
  -- A mixer weight naming a global variable is 1024 plus that variable's source index
  -- (radio/src/datastructs_private.h); the index itself is whatever the target's source table
  -- happens to number GV1 at. Any fixed base answers, as long as both ends here agree.
  local GVAR_SOURCE_BASE = 263

  _G.model = {
    getInfo = function()
      return {
        name = Stubs.modelInfo.name,
        bitmap = Stubs.modelInfo.bitmap,
        filename = Stubs.modelInfo.filename
      }
    end,
    getCustomFunction = function(index)
      return Stubs.customFunctions[index]
    end,
    setCustomFunction = function(index, value)
      Stubs.customFunctions[index] = value
      Stubs.customFunctionWrites[#Stubs.customFunctionWrites + 1] = { index = index, value = value }
    end,
    getGlobalVariable = function(index, phase)
      return Stubs.gvars[index .. ":" .. phase] or 0
    end,
    setGlobalVariable = function(index, phase, value)
      Stubs.gvars[index .. ":" .. phase] = value
    end,
    getGlobalVariableDetails = function(_index)
      return { name = "GV", min = -1024, max = 1024, prec = 0, unit = 0, popup = false }
    end,
    -- One line per channel, and the channels the in-flight overlay is measured on carry the two
    -- variables it declares: CH11 (zero based 10) the enable, CH12 the value.
    getMixesCount = function(_channel)
      return 1
    end,
    getMix = function(channel, _line)
      local gvar = (channel == 10) and 1 or 2
      return {
        source = _G.MIXSRC_MAX,
        weight = 1024 + GVAR_SOURCE_BASE + gvar,
        multiplex = 0,
        switch = 0
      }
    end,
    -- 31 is TRIM_MODE_NONE: no trim of this flight mode moves a stick's neutral.
    getFlightMode = function(_mode)
      return { trimsModes = { 31, 31, 31, 31, 31, 31 } }
    end,
  }

  _G.getSwitchIndex = function(name)
    if name == "ON" then return ALWAYS_ON_SWITCH_INDEX end
    return nil
  end

  _G.setShmVar = function(id, value)
    Stubs.shmVars[id] = value
  end

  -- Zero for a slot nothing has written, which is what the firmware's static array holds.
  _G.getShmVar = function(id)
    return Stubs.shmVars[id] or 0
  end

  _G.MIXSRC_MAX = 4242

  _G.getSourceIndex = function(name)
    local index = tonumber(string.match(tostring(name), "^GV(%d+)$"))
    if index == nil then return nil end
    return GVAR_SOURCE_BASE + index
  end

  _G.getFlightMode = function()
    return 0, "FM0"
  end

  _G.getSwitchValue = function(swsrc)
    return Stubs.switchValues[swsrc]
  end

  -- The firmware's iterator: `for swsrc, name in switches() do`. It yields the positions this
  -- radio has, in order, and skips the ones it does not.
  _G.switches = function()
    local function nextSwitch(last, index)
      index = index + 1
      while index <= last do
        local name = Stubs.switchNames[index]
        if name ~= nil then return index, name end
        index = index + 1
      end
      return nil
    end
    return nextSwitch, #Stubs.switchNames, 0
  end

  _G.getValue = function(name)
    return Stubs.sensors[name]
  end

  _G.getFieldInfo = function(name)
    if Stubs.sensors[name] ~= nil then
      return { id = name, name = name }
    end
    return nil
  end

  _G.getSensor = function(name)
    local v = Stubs.sensors[name]
    if v == nil then return nil end
    return { value = v }
  end

  _G.setTelemetryValue = function(id, sub, instance, value, unit, prec, name)
    Stubs.published[#Stubs.published + 1] = { id = id, value = value, name = name }
    return true
  end

  _G.crossfireTelemetryPop = function()
    local frame = table.remove(Stubs.telemetryFrames, 1)
    if frame == nil then return nil end
    -- The firmware returns (command, data); the suite's crsf lib re-assembles from both.
    return frame.command, frame.data
  end

  _G.crossfireTelemetryPush = function(command, data)
    return Stubs.onPush(command, data)
  end

  -- The radio's own file stat. Answers for the preference files only: the widget entry
  -- point and the dashboard runtime both watch them, and a stat that changes between two
  -- passes would enqueue a reload nobody asked for.
  _G.fstat = function(_path)
    return Stubs.prefsStat
  end

  local realIoRead = io.read
  local realIoWrite = io.write
  io.read = function(f, n)
    if type(f) == "userdata" or type(f) == "table" then
      return f:read(n)
    end
    return realIoRead(f, n)
  end
  io.write = function(f, str)
    if type(f) == "userdata" or type(f) == "table" then
      return f:write(str)
    end
    return realIoWrite(f, str)
  end

  _G.system = {
    getVersion = function()
      return { version = "2.12.0", simulation = false }
    end,
  }

  _G.playFile = function() end
  _G.playTone = function() end
  _G.playNumber = function() end
  _G.killEvents = function() end

  _G.lcd = {
    RGB = function(r, g, b)
      return ((r // 8) << 11) | ((g // 4) << 5) | (b // 8)
    end,
  }

  _G.lvgl = {
    clear = function()
      Stubs.lvgl.trees = {}
      Stubs.lvgl.refs = {}
    end,
    build = function(children)
      Stubs.lvgl.trees[#Stubs.lvgl.trees + 1] = children
      local refs = Stubs.lvgl.refs
      collectRefs(children, refs)
      return true
    end,
    onEvent = function() end,
    -- Present as a function, not called: the tuning screen asks the lvgl table whether this
    -- firmware offers a momentary button and emits a different node type either way. Asking here
    -- is what makes the measured tree the one a colour radio builds.
    momentaryButton = function() end,
  }

  -- loadScript remap: the deploy prefix -> src/rfsuite, widget entry prefix -> src/widgets,
  -- special-function prefix -> src/functions -- each of them the path the installed tree uses,
  -- so a source is reached here by the name it is reached by on a radio.
  -- Loads fail LOUDLY through the returned nil only when the file truly does not exist;
  -- a syntax error raises, exactly as measure.lua wants it to.
  _G.loadScript = function(path, mode)
    local rel
    if string.sub(path, 1, #SRC_PREFIX) == SRC_PREFIX then
      rel = repoRoot .. "/src/rfsuite/" .. string.sub(path, #SRC_PREFIX + 1)
    elseif string.sub(path, 1, #FUNCTION_PREFIX) == FUNCTION_PREFIX then
      rel = repoRoot .. "/src/functions/" .. string.sub(path, #FUNCTION_PREFIX + 1)
    elseif cardPath(path) then
      -- Under /SCRIPTS/TOOLS/ but not the suite's own: the user's directory, so the card this
      -- run was given, not the repository. Checked before the widget prefix below, which would
      -- otherwise read it as src/rfsuite.user/... -- a path that exists in neither.
      rel = cardPath(path)
    elseif string.sub(path, 1, #WIDGET_PREFIX) == WIDGET_PREFIX then
      rel = repoRoot .. "/src/" .. string.sub(path, #WIDGET_PREFIX + 1)
    else
      rel = repoRoot .. "/" .. path
    end
    local f = io.open(rel, "r")
    if not f then return nil end
    f:close()
    local chunk, err = loadfile(rel)
    if not chunk then
      error("stub loadScript: " .. tostring(err))
    end
    return chunk
  end

  -- lib/require.lua is the suite's OWN memoizer and it is used as it ships: a hand-written
  -- one here would answer differently from the radio's -- it returns nil for a module that
  -- is not there, and several objects probe for optional submodules exactly that way.
  --
  -- It reports both failure modes through print(), outside its own pcall, so the wrapper
  -- below records them and measure.lua prints them: a stub surface that is missing shows up
  -- as a module that would not execute, instead of as a pass that came out cheap.
  local realPrint = print
  Stubs.requireFailures = {}
  _G.print = function(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    local line = table.concat(parts, "	")
    if string.sub(line, 1, 10) == "[require] " then
      Stubs.requireFailures[#Stubs.requireFailures + 1] = line
    end
    realPrint(line)
  end

  -- Module singletons parked in _G, cleared so every world starts where a cold boot does.
  --
  -- Several modules survive a reload by keeping themselves in a global: tasks/msp/runtime.lua and
  -- tasks/events/runtime.lua hand back _G.__rfsuite_msp_runtime_module and _G.__rfsuite_events_module
  -- when those are set, and the config store, the MSP service, the environment, the locale, the
  -- model name store and the object and theme commons do the same. Replacing the rfsuite root below
  -- does not reach them, so without this the second world's require answers with the first world's
  -- runtimes: the new session is never told the link is up, the connect chain stops on the
  -- telemetry task, the telemetry drain never starts, and every scenario after the first is
  -- measured on a widget that never finished connecting. Matched by prefix rather than listed:
  -- a list here would go stale, silently, the next time a module parks itself in a global.
  for key in pairs(_G) do
    if type(key) == "string" and string.find(key, "^__rfsuite") then _G[key] = nil end
  end

  _G.rfsuite = { session = {}, preferences = {} }
  -- tasks/msp/cache.lua hangs its store off this root and creates it in its own top-level, which
  -- runs ONCE per interpreter: this file replaces the root on every world, and a chunk that was
  -- loaded in an earlier one then reads a store that is no longer there. On the radio there is
  -- one root and the question does not arise; here the store is laid down with the root, which
  -- also means one world's cached reply can never be served to the next.
  _G.rfsuite.mspResponseCache = {}
  local requireChunk = loadfile(repoRoot .. "/src/rfsuite/lib/require.lua")
  if not requireChunk then
    error("accounting: lib/require.lua not found under " .. tostring(repoRoot))
  end
  requireChunk()
end

--- The card's own self-test, called by measure.lua --self-test so CI runs it.
--
-- Each of these was a live defect in this file rather than a thought experiment, and each one
-- is invisible in the report: a card written to the wrong directory, a card whose deepest
-- directory was never made, and a card that is not emptied all leave the 51 rows exactly as
-- they were. The report cannot catch them, so something here has to.
--
-- Returns a list of failures, empty when the card behaves.
function Stubs.selfTest()
  local failures = {}
  local function expect(label, ok, detail)
    if not ok then failures[#failures + 1] = label .. (detail and (": " .. detail) or "") end
  end

  local function write(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
  end
  local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
  end

  Stubs.clearCard()

  -- 1. A write to a nested card path has to make every directory on the way, the deepest one
  --    included. On a fresh card this is the write that used to fail, because the mkdir loop
  --    could only ever issue a prefix ending in a separator.
  local slash = "/SCRIPTS/TOOLS/rfsuite.user/deep.lua"
  local volume = "SCRIPTS:/TOOLS/rfsuite.user/deep.lua"
  expect("a nested card write succeeds", write(slash, "slash"))
  expect("a nested card write creates the deepest directory", read(slash) == "slash",
    "the file is not readable back: " .. tostring(read(slash)))

  -- 2. The two spellings are one file. On a radio they are, and a run that wrote one and read
  --    the other was reading nothing while its numbers said it had read something.
  expect("the volume spelling reaches the file the slash spelling wrote", read(volume) == "slash",
    "volume spelling read " .. tostring(read(volume)))
  expect("the slash spelling reaches the file the volume spelling wrote",
    write(volume, "volume") and read(slash) == "volume",
    "slash spelling read " .. tostring(read(slash)))
  expect("the two spellings answer at one path", cardPath(slash) == cardPath(volume),
    tostring(cardPath(slash)) .. " vs " .. tostring(cardPath(volume)))

  -- 3. Nothing may land outside the card root. The off-by-one answered the slash spelling at a
  --    directory that is a *sibling* of the card root, which no empty ever reached.
  local escaped = Stubs.cardRoot:gsub("(%W)", "%%%1")
  expect("the slash spelling stays inside the card root",
    cardPath(slash):find("^" .. escaped) == 1, tostring(cardPath(slash)))
  expect("the volume spelling stays inside the card root",
    cardPath(volume):find("^" .. escaped) == 1, tostring(cardPath(volume)))

  -- 4. clearCard() has to empty a card holding a subdirectory, and has to keep the root: that
  --    root is the directory takeCardRoot() claimed, and handing it back would let a second run
  --    take a card this one is still using. The subdirectory is the case that only failed on
  --    Linux, where fopen on a directory succeeds -- so this case is the one that needs CI to
  --    mean anything, and it is why the empty asks os.remove first.
  write("/SCRIPTS/TOOLS/other/vol.lua", "x")
  Stubs.clearCard()
  expect("clearCard() empties a nested file", read(volume) == nil,
    "the file survived: " .. tostring(read(volume)))
  expect("clearCard() empties a nested directory", read("/SCRIPTS/TOOLS/other/vol.lua") == nil,
    "a file below a subdirectory survived the empty")
  -- The root is probed by writing into it rather than by shelling out: os.execute writes to
  -- the report's own stdout, and a self-test that prints is a self-test nobody reads past.
  expect("clearCard() keeps the card root", write(Stubs.cardRoot .. "/.probe", "x"),
    "the card root is gone, so a second run could claim it")
  os.remove(Stubs.cardRoot .. "/.probe")

  -- 5. Writing into a directory again after the card was emptied must work. The sequence is
  --    the one from the review: write a file, remove it, empty the card, then write into the
  --    same directory again. On Linux os.remove on an *empty* directory succeeds, so the
  --    subdirectory used to go on the branch meant for files and the madeDirs entry for it
  --    survived -- and the next write skipped its mkdir and failed. A directory not made
  --    before is written alongside it as the control, so the case says which of the two it
  --    is that fails rather than that "writing fails".
  --
  --    Like the case above, this one needs Linux to mean anything: on Windows os.remove fails
  --    on any directory, so the recursion runs and the entry is dropped either way.
  Stubs.clearCard()
  expect("a first write into a card directory succeeds",
    write(volume, "a"), "the first write already failed")
  expect("a first remove of that file succeeds",
    (os.remove(cardPath(volume)) or false) == true, "the remove did not report success")
  Stubs.clearCard()
  expect("a write into the same directory after the card was emptied succeeds",
    write(volume, "b"), "the directory was made before, the card was emptied, and the " ..
    "write did not re-make it")
  expect("a write into a directory never made before still succeeds",
    write("/SCRIPTS/TOOLS/other/c.lua", "c"), "the control write failed, so the case " ..
    "above is not saying what it means to say")

  return failures
end

return Stubs
