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

return Stubs
