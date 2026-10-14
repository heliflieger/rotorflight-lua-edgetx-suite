-- The pack for the next flight, and the flight controller's battery profile that goes with it.
--
-- Two questions live here, and they are separate on purpose:
--
--   which pack     the pilot's own registry (lib/flight_log.lua, batteries.cfg) filtered to the
--                  connected model, and the pick recorded where both the flight log and the
--                  dashboard already look for it -- rfsuite.session.flightlog.batteryId for this
--                  connection, and the model's own preference store so the same pack is offered
--                  again next time.
--   which profile  the board's battery profile the pack belongs to. A registry entry states it
--                  outright with `profile=1..6`, or it is derived by matching the entry's `cap`
--                  against the capacities the board itself publishes (MSP_BATTERY_CONFIG,
--                  `batteryCapacity_0` .. `batteryCapacity_5`), and its `cells` against the
--                  per-profile cell counts where the board has them. Where neither answers, or
--                  the match names more than one profile, nothing is written: guessing a
--                  profile moves the low-voltage cut of the next flight.
--
-- Both MSP indices here are 0-based, which is the firmware's own numbering on both legs:
-- MSP_BATTERY_PROFILE answers `batteryConfig()->batteryProfile` and MSP_SET_BATTERY_PROFILE
-- accepts `index < BATTERY_PROFILE_COUNT`. The BatP telemetry sensor is 1-based and is a
-- different number; it is deliberately not used here.
--
-- The armed guard sits at the write rather than at the caller. Every route into the profile
-- write -- a press in the dashboard's picker, a theme, another widget -- goes through
-- applyProfile, so one guard covers all of them, and the MSP runtime clearing its queue while
-- armed is a second line rather than the only one.
--
-- Every exit of targetProfile and applyProfile is logged. A silent give-up is what makes this
-- kind of feature look broken rather than inapplicable: the pilot picks a pack, nothing moves,
-- and there is nothing anywhere saying which of the six reasons it was.

local M = {}

local TAG = "rfsuite.battery_pick"

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local PROFILE_COUNT = 6

local function log(msg, level)
  local Log = requireModule("lib/log.lua")
  if Log and type(Log.emit) == "function" then
    Log.emit(TAG, msg, level or "info")
  end
end

local function mspState()
  local MspRuntime = requireModule("tasks/msp/runtime.lua")
  if type(MspRuntime) ~= "table" or type(MspRuntime.getState) ~= "function" then return nil end
  local state = MspRuntime.getState()
  if type(state) ~= "table" then return nil end
  return state
end

-- ---------------------------------------------------------------------------
-- The registry side
-- ---------------------------------------------------------------------------

--- The packs the registry offers for the connected model.
--
-- A fresh table per entry rather than the registry's own: the caller extends what it gets back
-- with the resolved profile, and the registry list is read again on the next connection.
function M.candidates(session)
  local FlightLog = requireModule("lib/flight_log.lua")
  if type(FlightLog) ~= "table" or type(FlightLog.loadRegistry) ~= "function" then return {} end
  local registry = FlightLog.loadRegistry()
  local modelName = (type(session) == "table" and session.modelName) or ""
  local matched = FlightLog.forModel(registry, modelName)
  local out = {}
  for i = 1, #matched do
    local entry = matched[i]
    out[#out + 1] = {
      id = entry.id,
      name = entry.name,
      cap = entry.cap,
      cells = entry.cells,
      profile = entry.profile,
      cycles = entry.cycles,
      last = entry.last
    }
  end
  return out
end

--- The pack of this connection, else the one the model was last flown on.
function M.selectedId(session)
  local record = (type(session) == "table") and session.flightlog or nil
  if type(record) == "table" and type(record.batteryId) == "string" and record.batteryId ~= "" then
    return record.batteryId
  end
  local FlightLog = requireModule("lib/flight_log.lua")
  if type(FlightLog) ~= "table" or type(FlightLog.storedBatteryId) ~= "function" then return nil end
  return FlightLog.storedBatteryId((type(session) == "table") and session.modelPreferences or nil)
end

--- A pack id in the one form the registry and the model store use: a non-empty string, or nil.
--
-- `false` and "" are the "no battery" answer ("" is how the model store keeps "none"), and a
-- number is spelled the way the registry would spell it, so `1` and "1" are the same pack.
function M.normalizeId(id)
  if type(id) == "number" then
    if id % 1 == 0 then return tostring(math.floor(id)) end
    return tostring(id)
  end
  if type(id) ~= "string" or id == "" then return nil end
  return id
end

--- Record the pick, in both places that read it.
--
-- The session is where the arm edge looks, and the model's store is what survives the
-- disconnect. The session table is created when it is missing: the event runtime drops it on
-- every link loss, so a pick made before the next arm has nothing to write into otherwise.
--
-- `id` nil clears the choice, which is the "no battery" answer rather than a failure.
function M.select(session, id)
  id = M.normalizeId(id)
  if type(session) ~= "table" then
    log("select refused: no session", "warn")
    return false
  end

  if type(session.flightlog) ~= "table" then session.flightlog = {} end
  session.flightlog.batteryId = id

  if type(session.modelPreferences) ~= "table" or session.mcu_id == nil then
    log("select kept for this connection only: no model store yet", "info")
    return false
  end
  if type(session.modelPreferences.flightlog) ~= "table" then
    session.modelPreferences.flightlog = {}
  end
  session.modelPreferences.flightlog.battery = id or ""

  local ModelPreferences = requireModule("lib/model_preferences.lua")
  if type(ModelPreferences) ~= "table" or type(ModelPreferences.saveByMcuId) ~= "function" then
    log("select not stored: model preferences unavailable", "warn")
    return false
  end
  local ok, saved = pcall(ModelPreferences.saveByMcuId, session.mcu_id, session.modelPreferences)
  if not ok or saved == false then
    log("select not stored: the card refused the write", "warn")
    return false
  end
  return true
end

--- Which preference switches are on, out of the flight log's section.
function M.settings(prefs)
  local section = (type(prefs) == "table") and prefs.flightlog or nil
  if type(section) ~= "table" then return false, false end
  return section.ask_on_connect == true, section.set_fc_profile == true
end

-- ---------------------------------------------------------------------------
-- The profile side
-- ---------------------------------------------------------------------------

--- The board profile a registry entry belongs to: a 0-based index and the reason, or nil.
--
-- `profile=` in the registry wins outright, because it is the pilot saying it. The capacity
-- match is the convenience below it and it is exact: a near match would be a different pack.
--
-- Where the board keeps one cell count for all profiles, two profiles of the same capacity are
-- the same battery as far as it is concerned, so the first one is taken. Where every profile
-- has its own cell count (the reply carries the per-profile blocks, `hasProfileCells`), the
-- same capacity can be two different batteries: the entry's `cells=` then has to agree with
-- the profile's own count as well, and a capacity that still names more than one profile is
-- refused as a tie rather than settled by order. The per-profile count is read, never the
-- single `batteryCellCount`, which follows whichever profile is active.
function M.targetProfile(entry, cfg)
  if type(entry) ~= "table" then
    log("no target profile: no registry entry", "debug")
    return nil, "noentry"
  end

  local explicit = tonumber(entry.profile)
  if explicit ~= nil then
    explicit = math.floor(explicit)
    if explicit >= 1 and explicit <= PROFILE_COUNT then
      log(string.format("target profile %d from the entry's own profile field", explicit), "info")
      return explicit - 1, "profile"
    end
    log(string.format("entry declares profile %d, which the board does not have", explicit), "warn")
    return nil, "badprofile"
  end

  if type(cfg) ~= "table" then
    log("no target profile: the board's battery configuration has not been read", "info")
    return nil, "noconfig"
  end
  if cfg.batteryCapacity_0 == nil then
    log("no target profile: this flight controller publishes no per-profile capacities", "info")
    return nil, "nocapacities"
  end

  local cap = tonumber(entry.cap)
  if cap == nil or cap <= 0 then
    log("no target profile: the entry carries no capacity to match", "info")
    return nil, "nocap"
  end

  if cfg.hasProfileCells ~= true then
    for i = 0, PROFILE_COUNT - 1 do
      if tonumber(cfg["batteryCapacity_" .. i]) == cap then
        log(string.format("target profile %d matched on %d mAh", i + 1, math.floor(cap)), "info")
        return i, "capacity"
      end
    end
    log(string.format("no target profile: no board profile is set to %d mAh", math.floor(cap)), "info")
    return nil, "nomatch"
  end

  local cells = tonumber(entry.cells)
  if cells ~= nil then
    cells = math.floor(cells)
    if cells < 1 then cells = nil end
  end
  -- `%s`, not `%d`: a hand-written value too large for an integer stays a float after
  -- math.floor, and `%d` would raise on it instead of reporting that nothing matched.
  local wanted = cells and string.format("%s mAh %sS", tostring(math.floor(cap)), tostring(cells))
    or string.format("%s mAh", tostring(math.floor(cap)))

  local found = {}
  for i = 0, PROFILE_COUNT - 1 do
    if tonumber(cfg["batteryCapacity_" .. i]) == cap
      and (cells == nil or tonumber(cfg["batteryCellCount_" .. i]) == cells) then
      found[#found + 1] = i
    end
  end
  if #found == 1 then
    log(string.format("target profile %d matched on %s", found[1] + 1, wanted), "info")
    return found[1], "capacity"
  end
  if #found == 0 then
    log(string.format("no target profile: no board profile is set to %s", wanted), "info")
    return nil, "nomatch"
  end
  -- `cells=` settles a tie only where one of the tied profiles has a cell count no other one has;
  -- otherwise only `profile=` can.
  local names, seen, advice = {}, {}, "profile="
  for k = 1, #found do
    names[k] = tostring(found[k] + 1)
    local count = tonumber(cfg["batteryCellCount_" .. found[k]]) or 0
    seen[count] = (seen[count] or 0) + 1
  end
  for count, n in pairs(seen) do
    if cells == nil and count >= 1 and n == 1 then advice = "cells= or profile=" end
  end
  log(string.format("no target profile: a tie, profiles %s are all set to %s; give the entry %s",
    table.concat(names, ", "), wanted, advice), "warn")
  return nil, "tie"
end

--- Ask the board which battery profile it is on. `callback(index0)` on the reply.
function M.readProfile(callback)
  local state = mspState()
  if state == nil or type(state.queue) ~= "table" or type(state.queue.add) ~= "function" then
    log("profile read refused: no MSP queue", "info")
    return false, "noqueue"
  end
  local api = requireModule("tasks/msp/api/battery_profile.lua")
  if type(api) ~= "table" or type(api.parse) ~= "function" then
    log("profile read refused: the battery profile API is missing", "warn")
    return false, "noapi"
  end
  state.queue:add({
    command = api.command,
    simulatorResponse = api.simulatorResponse,
    processReply = function(_, buf)
      local parsed = api.parse(buf)
      local index0 = parsed and tonumber(parsed.batteryProfile) or nil
      if type(callback) == "function" then callback(index0) end
    end
  })
  return true
end

--- Move the board onto a battery profile: MSP_SET_BATTERY_PROFILE, then the EEPROM write that
--- makes the board apply and broadcast it.
--
-- The armed guard is here and nowhere else. `opts.reason` only reaches the log line, so that a
-- write in the log can be told from the quick menu's.
function M.applyProfile(index0, opts)
  local reason = (type(opts) == "table" and type(opts.reason) == "string") and opts.reason or "battery pick"

  local index = tonumber(index0)
  if index == nil then
    log("profile write refused (" .. reason .. "): no target profile", "info")
    return false, "notarget"
  end
  index = math.floor(index)
  if index < 0 or index >= PROFILE_COUNT then
    log(string.format("profile write refused (%s): profile %d is out of range", reason, index), "warn")
    return false, "range"
  end

  local state = mspState()
  if state == nil then
    log("profile write refused (" .. reason .. "): the MSP runtime is not up", "info")
    return false, "noqueue"
  end
  if state.lastArmed == true then
    log("profile write refused (" .. reason .. "): the model is armed", "warn")
    return false, "armed"
  end
  if type(state.queue) ~= "table" or type(state.queue.add) ~= "function" then
    log("profile write refused (" .. reason .. "): no MSP queue", "info")
    return false, "noqueue"
  end

  local api = requireModule("tasks/msp/api/battery_profile.lua")
  local eeprom = requireModule("tasks/msp/api/eeprom_write.lua")
  if type(api) ~= "table" or type(api.buildWritePayload) ~= "function"
    or type(eeprom) ~= "table" or type(eeprom.buildWritePayload) ~= "function" then
    log("profile write refused (" .. reason .. "): an MSP API is missing", "warn")
    return false, "noapi"
  end

  state.queue:add({
    command = api.writeCommand,
    payload = api.buildWritePayload({ batteryProfile = index }),
    simulatorResponse = {}
  })
  state.queue:add({
    command = eeprom.writeCommand,
    payload = eeprom.buildWritePayload({}),
    simulatorResponse = {},
    isWrite = true
  })
  log(string.format("profile write queued (%s): profile %d", reason, index + 1), "info")
  return true, "queued"
end

return M
