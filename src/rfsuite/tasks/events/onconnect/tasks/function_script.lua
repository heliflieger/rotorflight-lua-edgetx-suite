-- OnConnect task: give this model the special function that runs the background decoder.
--
-- SCRIPTS/FUNCTIONS/rfsbg.lua only runs if a special function calls it, and a pilot cannot be
-- expected to add one by hand for a script the suite installed. So the suite adds it when the
-- model does not have it.
--
-- **The slots are the answer, and nothing is remembered.** Whether this model already carries the
-- special function is readable directly -- `model.getCustomFunction` over the 64 slots, which is
-- what `walk` below does -- and it is a fact about the model on this transmitter. Any record of
-- it would be a cache of something already legible, and this task used to keep one: a list of
-- model file names in the per-model preferences, saved through the ordinary preference writer.
-- That cost more than it saved, in two ways worth naming so the cache does not come back.
--
-- One: the ordinary preference writer signals a preference RELOAD to every running dashboard
-- widget -- `lib/model_preferences.lua`'s `saveByMcuId` bumps the reload counter -- so
-- bookkeeping that no pilot ever set announced itself as a settings change, and a widget answered
-- it with a full reload at connect time.
--
-- Two: those preferences are keyed by the FLIGHT CONTROLLER's id, and which special functions a
-- model has is a fact about the TRANSMITTER. Recording one under the other made the decision wait
-- for a board to answer before it could be taken at all, and made the same model on a second
-- board look untouched.
--
-- The slot becomes active the next time the model is loaded, because the firmware reads the
-- special functions when it loads a model. That is the whole reason there is no on-screen
-- notice here: there is nothing for the pilot to do, and the next model load is free.
--
-- `widget` context, like the two tasks beside it in the manifest that reach outside the suite:
-- writing to the pilot's model is background work, not something a configuration tool should do
-- because somebody opened a settings page.

local M = {}

-- The base name EdgeTX stores in the special function, and the file it looks for under
-- SCRIPTS/FUNCTIONS. The firmware's field holds eight characters.
local SCRIPT_NAME = "rfsbg"

-- radio/src/dataconstants.h, MAX_SPECIAL_FUNCTIONS.
local SPECIAL_FUNCTION_COUNT = 64

-- Background decoders that are not ours and pop the same wire. A special-function script has no
-- script manager of its own, so the firmware serves every one of them from a SINGLE telemetry
-- queue (`lua/api_general.cpp`, getTelemetryQueue -- a script manager gets a private queue, a
-- permanent script gets the shared one). The first script whose drain empties it leaves the rest
-- with nothing at all, so a model that already carries one of these has no use for a second: it
-- would take one of the radio's scarce script slots to run and decode nothing.
--
-- Rotorflight's own earlier Lua suite installs `rf2bg`, which reads the same frames.
local COMPETING_DECODERS = { rf2bg = true }

-- How many slots one wakeup reads. The whole connect chain runs inside a single widget pass and
-- that pass is the closest any pass comes to the firmware's per-call instruction limit, so the
-- walk is spread: the runner calls this task again on the next pass while it says it is not
-- complete, and eight passes cover every slot.
local SLOTS_PER_WAKEUP = 8

-- The switch position that is always on. Resolved by NAME, and the name is translated on the
-- radio -- so a radio in a language that spells it differently resolves nothing, and then this
-- task writes nothing at all rather than guessing an index.
local ALWAYS_ON_SWITCH = "ON"

local done = false
local started = false
local nextSlot = 0
local firstFreeSlot = nil
local competingDecoder = nil
local taggedLog = nil

-- The logging core's tagged emitter, bound on first use: the default level and the
-- console flag are lib/log.lua's, and this file states only its tag.
local function log(msg, level)
  if not taggedLog then
    local rf = _G.rfsuite
    local L = rf and rf.Log
    if type(L) ~= "table" or type(L.tagged) ~= "function" then return end
    taggedLog = L.tagged("rfsuite.tasks.function_script")
  end
  taggedLog(msg, level)
end

local function finish(msg, level)
  if msg then log(msg, level or "info") end
  done = true
end

--- Read up to SLOTS_PER_WAKEUP slots; true if the script is already in one of them.
--
-- An EMPTY slot is one whose switch is unset. The function number cannot say it: a cleared slot
-- reads back as function 0, which is a real function (override a channel), so a test on the
-- function would take the first cleared slot for one the pilot had configured.
local function walk()
  local last = math.min(nextSlot + SLOTS_PER_WAKEUP, SPECIAL_FUNCTION_COUNT) - 1
  for i = nextSlot, last do
    local ok, fn = pcall(model.getCustomFunction, i)
    if ok and type(fn) == "table" then
      if fn.func == FUNC_PLAY_SCRIPT and fn.name == SCRIPT_NAME then
        return true
      end
      -- Only an ENABLED slot runs: the firmware tests `CFN_ACTIVE` before it calls a permanent
      -- script and skips it entirely where that is 0 (`lua/interface.cpp`). A slot the pilot has
      -- unticked therefore competes for nothing, and is not one.
      if fn.func == FUNC_PLAY_SCRIPT and fn.active == 1 and COMPETING_DECODERS[fn.name] then
        competingDecoder = fn.name
      end
      if firstFreeSlot == nil and fn.switch == 0 then
        firstFreeSlot = i
      end
    end
  end
  nextSlot = last + 1
  return false
end

local function install()
  local switch = getSwitchIndex(ALWAYS_ON_SWITCH)
  if type(switch) ~= "number" or switch == 0 then
    finish("no always-on switch under the name '" .. ALWAYS_ON_SWITCH ..
      "'; the background decoder's special function was not created")
    return
  end

  local ok = pcall(model.setCustomFunction, firstFreeSlot, {
    switch = switch,
    func = FUNC_PLAY_SCRIPT,
    name = SCRIPT_NAME,
    active = 1,
    -- Zero is what makes the firmware call the script on every cycle. Any other value makes it
    -- a one-shot on the switch going true, which for an always-on switch is once per model load.
    repetition = 0
  })
  if not ok then
    finish("could not write the background decoder's special function")
    return
  end

  finish("background decoder installed in special function " .. tostring(firstFreeSlot + 1) ..
    ", active the next time this model is loaded")
end

function M.wakeup()
  if done then return end

  if not started then
    started = true

    -- Nothing here asks the flight controller anything. What this task decides is which special
    -- functions the model on this transmitter has, which the radio answers on its own -- so the
    -- task neither waits for a board nor reads a session field.
    if type(model) ~= "table" or type(model.getCustomFunction) ~= "function"
      or type(model.setCustomFunction) ~= "function" or type(FUNC_PLAY_SCRIPT) ~= "number"
      or type(getSwitchIndex) ~= "function" then
      finish("this radio has no special-function scripting; the background decoder was not " ..
        "installed", "debug")
      return
    end
  end

  local present = walk()
  if present then
    -- Already there -- whether this task put it there on an earlier connect or the pilot did.
    -- Either way the slot is the answer and there is nothing to write.
    done = true
    return
  end
  if nextSlot < SPECIAL_FUNCTION_COUNT then return end

  if competingDecoder then
    -- Said out loud rather than passed over. Nothing here is broken by the other script -- the
    -- widget keeps its own copy of every frame and decodes as it always did -- but a pilot who
    -- expects this model to run the suite's decoder should know why it is not there.
    finish("this model already runs '" .. tostring(competingDecoder) .. "', which reads the same "
      .. "telemetry frames; every special-function script shares one queue, so a second decoder "
      .. "would take a script slot and receive nothing. The background decoder was not installed "
      .. "and the dashboard decodes for itself, as it does on a radio without it")
    return
  end

  if firstFreeSlot == nil then
    finish("every special function slot on this model is in use; the background decoder was " ..
      "not installed")
    return
  end

  install()
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  started = false
  nextSlot = 0
  firstFreeSlot = nil
  competingDecoder = nil
end

return M
