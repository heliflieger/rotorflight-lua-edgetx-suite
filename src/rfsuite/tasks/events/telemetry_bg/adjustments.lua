-- Announce in-flight adjustments: which function the pilot is changing, and its new value.
--
-- The flight controller reports an active adjustment in the custom telemetry stream as a
-- function id and a value (`AdjF` / `AdjV`, published by the `ADJ` row of the sensor table).
-- Nothing read them until now, and the switch that turns this on has been in Settings since
-- before it had an effect: `audio_events.adjustment_events`.
--
-- It runs on the telemetry pass rather than as an event runner of its own, for the same reason
-- `smart.lua` beside it does: what it reads is what the decoder in `tasks.lua` has just
-- published, so any other placement would be reading one pass behind.
--
-- The word files are already in the tree -- `SOUNDS/rf/<locale>/adj/` -- and are resolved
-- through `lib/audio.lua`, which owns the locale fallback. That module is loaded LAZILY, on the
-- first announcement rather than on the first pass, so a model that never touches an adjustment
-- never pays for it.

local M = {}

local Audio = nil

-- The memoizer FIRST, so a host that has one hands over the instance it already holds -- and
-- the plain loader when it does not, or when it answers with nothing. Taking the memoizer's
-- answer as final was the first version of this and it is wrong in a way that is invisible on
-- a working card: a host without the memoizer would get nil for ever.
local function requireModule(path)
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then
    local ok, mod = pcall(req, path)
    if ok and type(mod) == "table" then return mod end
  end
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- How long the value has to stand still before it is announced. A pilot sweeping a pult would
-- otherwise start an announcement per step and finish none of them.
local SETTLE_SECONDS = 1.0

-- The function ids are the FIRMWARE's, `src/main/fc/rc_adjustments.h`, not a copy of the
-- sibling project's table -- which stops at 75 and therefore never announced the seven
-- governor and battery adjustments the firmware has carried since.
--
-- Each entry is the sequence of word files to play from `adj/`. Only words that exist in the
-- tree are used: an adjustment whose name cannot be spoken with them has NO entry, and the
-- teller then announces its value alone rather than announcing something else. The words that
-- would complete the set are `expo` (11-13), `tta` (53), `ratio` (62), `ceiling` (72), and for
-- the governor and battery block `idle`, `auto`, `throttle`, `max`, `min`, `headspeed`,
-- `battery` and `profile` (76-80, 82).
--
-- Ids 1-4 are the profile switches. They are deliberately absent: the suite already announces a
-- PID or rate profile change through its own `pid_profile` / `rate_profile` settings, and a
-- second voice for the same event is worse than none.
local ADJUSTMENTS = {
  [5]  = { "pitch", "rate" },
  [6]  = { "roll", "rate" },
  [7]  = { "yaw", "rate" },
  [8]  = { "pitch", "rc", "rate" },
  [9]  = { "roll", "rc", "rate" },
  [10] = { "yaw", "rc", "rate" },

  [14] = { "pitch", "p", "gain" },
  [15] = { "pitch", "i", "gain" },
  [16] = { "pitch", "d", "gain" },
  [17] = { "pitch", "f", "gain" },
  [18] = { "roll", "p", "gain" },
  [19] = { "roll", "i", "gain" },
  [20] = { "roll", "d", "gain" },
  [21] = { "roll", "f", "gain" },
  [22] = { "yaw", "p", "gain" },
  [23] = { "yaw", "i", "gain" },
  [24] = { "yaw", "d", "gain" },
  [25] = { "yaw", "f", "gain" },

  [26] = { "yaw", "cw", "gain" },
  [27] = { "yaw", "ccw", "gain" },
  [28] = { "yaw", "cyclic", "ff" },
  [29] = { "yaw", "collective", "ff" },
  [30] = { "yaw", "collective", "dyn" },
  [31] = { "yaw", "collective", "decay" },
  [32] = { "pitch", "collective", "ff" },

  [33] = { "pitch", "gyro", "cutoff" },
  [34] = { "roll", "gyro", "cutoff" },
  [35] = { "yaw", "gyro", "cutoff" },

  [36] = { "pitch", "dterm", "cutoff" },
  [37] = { "roll", "dterm", "cutoff" },
  [38] = { "yaw", "dterm", "cutoff" },

  [39] = { "rescue", "climb", "collective" },
  [40] = { "rescue", "hover", "collective" },
  [41] = { "rescue", "hover", "alt" },
  [42] = { "rescue", "alt", "p", "gain" },
  [43] = { "rescue", "alt", "i", "gain" },
  [44] = { "rescue", "alt", "d", "gain" },

  [45] = { "angle", "level", "gain" },
  [46] = { "horizon", "level", "gain" },
  [47] = { "acro", "gain" },

  [48] = { "gov", "gain" },
  [49] = { "gov", "p", "gain" },
  [50] = { "gov", "i", "gain" },
  [51] = { "gov", "d", "gain" },
  [52] = { "gov", "f", "gain" },
  [54] = { "gov", "cyclic", "ff" },
  [55] = { "gov", "collective", "ff" },

  [56] = { "pitch", "b", "gain" },
  [57] = { "roll", "b", "gain" },
  [58] = { "yaw", "b", "gain" },
  [59] = { "pitch", "o", "gain" },
  [60] = { "roll", "o", "gain" },

  [61] = { "crossc", "gain" },
  [63] = { "crossc", "cutoff" },

  [64] = { "acc", "pitch", "trim" },
  [65] = { "acc", "roll", "trim" },

  [66] = { "yaw", "inertia", "precomp", "gain" },
  [67] = { "yaw", "inertia", "precomp", "cutoff" },

  [68] = { "pitch", "setpoint", "boost", "gain" },
  [69] = { "roll", "setpoint", "boost", "gain" },
  [70] = { "yaw", "setpoint", "boost", "gain" },
  [71] = { "collective", "setpoint", "boost", "gain" },

  [73] = { "yaw", "dyn", "deadband", "gain" },
  [74] = { "yaw", "dyn", "deadband", "filter" },
  [75] = { "yaw", "precomp", "cutoff" },

  [81] = { "gov", "yaw", "ff" },
}

local state = {
  functionId = nil,
  value = nil,
  functionChanged = false,
  valueChanged = false,
  changedAt = nil,
}

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  return 0
end

local function enabled()
  local root = _G and _G.rfsuite
  local prefs = root and root.preferences
  local events = prefs and prefs.audio_events
  return events ~= nil and events.adjustment_events == true
end

local function readSensor(name)
  if type(getValue) ~= "function" then return nil end
  local ok, v = pcall(getValue, name)
  if ok and type(v) == "number" then return v end
  return nil
end

-- Resolved on the first announcement rather than on the first pass, and NOT latched on a
-- failure. A latch here would trade one missed load -- the module not reachable yet on an early
-- pass -- for a teller that is silent for the rest of the session with nothing to say so. The
-- retry costs nothing that matters: it is reached once per announced adjustment, and on any host
-- with the require memoizer the second call is a table lookup.
local function ensureAudio()
  if Audio then return Audio end
  local mod = requireModule("lib/audio.lua")
  if type(mod) == "table" and type(mod.playEventFile) == "function" then
    Audio = mod
  end
  return Audio
end

local function announce()
  local words = state.functionChanged and ADJUSTMENTS[state.functionId] or nil
  if words then
    local audio = ensureAudio()
    if audio then
      for i = 1, #words do
        audio.playEventFile("adj/" .. words[i] .. ".wav")
      end
    end
  end
  if type(playNumber) == "function" then
    pcall(playNumber, state.value or 0, 0, 0)
  end
end

function M.wakeup()
  if not enabled() then return end

  local functionId = readSensor("AdjF")
  local value = readSensor("AdjV")
  if functionId == nil or value == nil then return end

  -- Nothing is being adjusted. Do not announce, and do not remember it as a change either --
  -- the flight controller reports 0 between adjustments, and announcing that would put a
  -- spurious "0" after every one of them.
  if functionId == 0 then return end

  local now = nowSeconds()

  if state.functionId == nil then
    -- The first reading is the state we join, not an adjustment the pilot just made.
    state.functionId, state.value = functionId, value
    return
  end

  if functionId ~= state.functionId then
    state.functionId = functionId
    state.functionChanged = true
    state.changedAt = now
  end
  if value ~= state.value then
    state.value = value
    state.valueChanged = true
    state.changedAt = now
  end

  if state.changedAt and (now - state.changedAt) >= SETTLE_SECONDS then
    state.changedAt = nil
    if state.functionChanged or state.valueChanged then
      announce()
    end
    state.functionChanged = false
    state.valueChanged = false
  end
end

function M.reset()
  state.functionId = nil
  state.value = nil
  state.functionChanged = false
  state.valueChanged = false
  state.changedAt = nil
end

return M
