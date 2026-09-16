-- OnConnect task: put the craft name the flight controller reports onto the radio's model,
-- when the "Synchronize Model Name" setting asks for it -- and put the model's own name back
-- when the link goes.
--
-- Runs after the `name` task in the manifest, which is what fills session.modelName.
--
-- The rename is TEMPORARY: the name the model had is remembered before it is overwritten and
-- restored when the craft goes away, so a pilot who flies one model with a craft plugged in does
-- not find it permanently renamed afterwards. The name is remembered in two places on purpose.
-- The module-local is what the in-session restore uses, so that path can never depend on a store
-- being reachable; `lib/model_name_store.lua` is the backstop for the cases the local cannot
-- cover, and it is a separate file because it has to be readable with nothing connected.
--
-- Restoring is NOT this task's job, and cannot be. M.reset() below reads as the disconnect hook
-- and is not reached: the runner drops a task's module the moment isComplete() returns true
-- (`releaseTaskModule(task, false)`), and the disconnect path, `resetQueuesAndState()`, opens with
-- `if not task.module then return end` -- so it returns before it can call the reset it came for.
-- This task completes on its first pass, every time, so that is every time. The module-local
-- below goes the same way: a second connect loads a fresh module and inherits nothing.
--
-- So the restore is a STATE rather than an event. The events runtime puts the name back from the
-- store on a tick that has established there is no craft, which covers the completed-task case
-- above, a link that drops while nothing happens to be looking, and a cold start.

local M = {}

local done = false
local taggedLog = nil
local ModelPreferences = nil
local NameStore = nil

-- Where the previous name was kept before it moved to a store of its own. Read once at rename
-- time so a rename already in effect across an update is not stranded; never written.
local LEGACY_SECTION = "model"
local LEGACY_KEY = "previous_name"

--: The name this model had before the craft name was written over it, for as long as the link
--: lasts. `nil` means nothing has been renamed and there is nothing to put back.
local previousName = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- The logging core's tagged emitter, bound on first use: the default level and the
-- console flag are lib/log.lua's, and this file states only its tag.
local function log(msg, level)
  if not taggedLog then
    local rf = _G.rfsuite
    local L = rf and rf.Log
    if type(L) ~= "table" or type(L.tagged) ~= "function" then return end
    taggedLog = L.tagged("rfsuite.tasks.model_name_sync")
  end
  taggedLog(msg, level)
end

local function isTruthy(value)
  return value == true or value == 1 or value == "1" or value == "true"
end

-- WHO decides, and it is not always the radio.
--
-- From MSP API 12.09 the flight controller carries a MODEL_SET_NAME bit in its pilot config
-- (`src/main/pg/pilot.h`), and that bit is the answer: the craft says whether it wants the
-- radio's model named after it, so the same helicopter behaves the same way on any transmitter.
-- The `model_params_sync` task reads the message one step earlier and parks it in the session.
--
-- Below 12.09 there is no such field -- `model_flags` is nil rather than zero, which is why the
-- API wrapper is careful to keep those apart -- and the radio-side setting is then the only
-- thing that can decide. It stays, as the fallback it now is.
local function syncEnabled()
  local root = _G and _G.rfsuite
  local session = type(root) == "table" and root.session or nil
  local pilot = type(session) == "table" and session.pilotConfig or nil
  local flags = type(pilot) == "table" and pilot.model_flags or nil

  if flags ~= nil then
    local Api = loadModule("tasks/msp/api/pilot_config.lua")
    if type(Api) == "table" and type(Api.flagSet) == "function" then
      local wanted = Api.flagSet(flags, Api.FLAG_SET_NAME)
      if wanted ~= nil then
        log("MODEL_SET_NAME from the flight controller: " .. tostring(wanted), "debug")
        return wanted
      end
    end
  end

  local prefs = type(root) == "table" and root.preferences or nil
  local general = type(prefs) == "table" and prefs.general or nil
  return isTruthy(general and general.syncname)
end

local function session()
  local root = _G and _G.rfsuite
  return type(root) == "table" and root.session or nil
end

local function store()
  if NameStore == nil then
    NameStore = loadModule("lib/model_name_store.lua") or false
  end
  if type(NameStore) == "table" then return NameStore end
  return nil
end

-- What the per-board file still holds from before the store moved, and the reason it is only
-- read here. Its record is addressed by the flight controller's MCU id, so it is reachable
-- exactly while a craft is connected -- which is when a rename happens and never when a restore
-- is needed. Reading it at rename time carries an in-flight rename over an update; there is
-- nothing to write back to it.
local function legacyPrevious()
  local s = session()
  local prefs = s and s.modelPreferences
  local section = type(prefs) == "table" and prefs[LEGACY_SECTION] or nil
  local name = type(section) == "table" and section[LEGACY_KEY] or nil
  if type(name) == "string" and name ~= "" then return name end
  return nil
end

local function legacyClear()
  local s = session()
  local prefs = s and s.modelPreferences
  local section = type(prefs) == "table" and prefs[LEGACY_SECTION] or nil
  if type(section) ~= "table" or section[LEGACY_KEY] == nil then return end
  if type(s.mcu_id) ~= "string" or s.mcu_id == "" then return end
  section[LEGACY_KEY] = ""
  if ModelPreferences == nil then
    ModelPreferences = loadModule("lib/model_preferences.lua") or false
  end
  if type(ModelPreferences) == "table" and type(ModelPreferences.saveByMcuId) == "function" then
    pcall(ModelPreferences.saveByMcuId, s.mcu_id, prefs)
  end
end

local function storeSet(name)
  local s = store()
  if not s then return false end
  local ok, written
  if name == nil or name == "" then
    ok, written = pcall(s.forget)
  else
    ok, written = pcall(s.remember, name)
  end
  return ok and written == true
end

local function setModelName(name)
  if type(model) ~= "table" or type(model.getInfo) ~= "function" or type(model.setInfo) ~= "function" then
    return false
  end
  local ok, info = pcall(model.getInfo)
  if not ok or type(info) ~= "table" then return false end
  if info.name == name then return true end
  info.name = name
  return pcall(model.setInfo, info) == true
end

function M.wakeup()
  if done then return end

  local root = _G and _G.rfsuite
  local session = type(root) == "table" and root.session or nil
  if type(session) ~= "table" then return end

  -- Every exit below sets done: this task waits for nothing of its own, and a task that never
  -- completes holds the whole connect chain behind it.
  done = true

  if not syncEnabled() then return end

  local craftName = session.modelName
  if type(craftName) ~= "string" or craftName == "" then
    log("no craft name to synchronize", "debug")
    return
  end

  if type(model) ~= "table" or type(model.getInfo) ~= "function" or type(model.setInfo) ~= "function" then
    return
  end

  local ok, info = pcall(model.getInfo)
  if not ok or type(info) ~= "table" then return end

  -- A name already in the store is a rename that never got its restore. It, and not what the
  -- model is called right now, is what this model is really called; taking the current name here
  -- would write the craft name in as the original and lose the pilot's own for good.
  --
  -- The per-board file is consulted only where the store has nothing, and it is MIGRATED rather
  -- than merely read: left in place it would answer for a later rename too, long after the name
  -- it holds stopped being this model's own. The write comes before the clear, so a store that
  -- refuses leaves the old record standing rather than dropping the name between the two.
  previousName = nil
  local s = store()
  if s then previousName = s.pending() end
  if previousName == nil then
    local legacy = legacyPrevious()
    if legacy ~= nil then
      previousName = legacy
      if storeSet(legacy) then legacyClear() end
    end
  end
  previousName = previousName or info.name

  if info.name == craftName then
    log("model is already called " .. tostring(craftName), "debug")
    return
  end

  if previousName == craftName then
    -- Nothing to put back that is not what is being written. Do not remember it.
    previousName = nil
    storeSet(nil)
  else
    storeSet(previousName)
  end

  local written = setModelName(craftName)
  log("model name set from craft name: " .. tostring(craftName) .. " (ok=" .. tostring(written) ..
      ", was " .. tostring(previousName) .. ")", "info")
end

function M.isComplete()
  return done
end

-- `reset` looks like the disconnect hook and is kept as one, but nothing here may depend on it
-- being called: see the note at the top of the file -- a task that has reported itself complete
-- has had its module dropped, and the disconnect path returns on that before it reaches this.
-- What makes the restore happen is the events runtime, on a tick with no craft. This stays
-- because it is correct where it does run, and because it is the cheaper path when it does.
--
-- The guard is still needed for the case that is NOT a disconnect: `Events.rerunOnconnect()`
-- reaches the same reset after a reboot, with the link up and coming back, and restoring there
-- would make the name flap. The session is the one thing that tells the two apart.
function M.reset()
  done = false

  local s = session()
  if s and s.isConnected == true then return end

  if previousName ~= nil then
    local written = setModelName(previousName)
    log("model name put back: " .. tostring(previousName) .. " (ok=" .. tostring(written) .. ")", "info")
    previousName = nil
    storeSet(nil)
    return
  end

  -- Nothing in this Lua state, which is the ordinary case for whichever of the tool and the
  -- widgets did not do the rename. The store crosses that boundary; it also answers after a
  -- restart, and it is the same call the events runtime makes on a tick with no craft.
  local nameStore = store()
  if not nameStore then return end
  local ok, restored = pcall(nameStore.restore)
  if ok and restored then
    log("model name put back from the store: " .. tostring(restored), "info")
  end
end

return M
