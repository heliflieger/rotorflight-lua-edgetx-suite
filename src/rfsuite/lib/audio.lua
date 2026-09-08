local Audio = {}

-- Globaler Throttle für Low-Voltage-Alarm (reload-sicher)
local function getGlobalLowVoltageAt()
  if type(_G) == "table" then
    _G.__rfsuiteLastLowVoltageAt = _G.__rfsuiteLastLowVoltageAt or 0
    return _G.__rfsuiteLastLowVoltageAt
  end
  return 0
end

local function setGlobalLowVoltageAt(val)
  if type(_G) == "table" then
    _G.__rfsuiteLastLowVoltageAt = val
  end
end

local AUDIO_PACK_BASE = "/SOUNDS/"
local AUDIO_DEFAULT_FALLBACK = "en"
local AUDIO_ROOT_BASE = "/audio/"
local localeModule = nil

local ARM_FILE_MAP = {
  [0] = "disarm.wav",
  [1] = "armed.wav",
  [2] = "disarm.wav",
  [3] = "armed.wav"
}

-- Keyed on govState_e as the firmware numbers it (flight/governor.h, 0..9), which is what the
-- governor sensor carries. The dashboard's text object synthesises 100 and 101 for its own
-- label (widgets/dashboard/objects/text/governor.lua); neither reaches this path.
local GOVERNOR_FILE_MAP = {
  [0] = "off.wav",
  [1] = "idle.wav",
  [2] = "spoolup.wav",
  [3] = "recovery.wav",
  [4] = "active.wav",
  [5] = "thr-off.wav",
  [6] = "lost-hs.wav",
  [7] = "autorot.wav",
  [8] = "bailout.wav",
  -- GOV_STATE_BYPASS: the governor is passing the throttle straight through, which is what
  -- the pack's disabled.wav says.
  [9] = "disabled.wav"
}

-- The per-state enables under the `governor_state` master switch, one key per entry above.
-- An absent key counts as on, so a preferences.ini written before these existed announces
-- every state, as it did.
local GOVERNOR_PREF_KEYS = {
  [0] = "governor_state_off",
  [1] = "governor_state_idle",
  [2] = "governor_state_spoolup",
  [3] = "governor_state_recovery",
  [4] = "governor_state_active",
  [5] = "governor_state_thr_off",
  [6] = "governor_state_lost_hs",
  [7] = "governor_state_autorot",
  [8] = "governor_state_bailout",
  [9] = "governor_state_bypass"
}

-- How long a governor state has to stand before it is spoken. A spool-up crosses several
-- states inside a second, and the file for a state the machine has already left would
-- otherwise still be playing, or be skipped by the cooldown, when the next one is due.
local GOVERNOR_HOLD_SECONDS = 0.3

-- The `link` key's search path in lib/sensors.lua ends in 1RSS and 2RSS, and those carry an
-- RSSI in dBm rather than a link quality in percent. A percent threshold held against a
-- negative dBm reading is below itself on every sample, so the alert has to know which
-- sensor answered before it says anything.
local RSSI_LINK_SOURCES = {
  ["1RSS"] = true,
  ["2RSS"] = true
}

-- How far the link has to climb back above a threshold before that level is left again. A
-- quality resting on the threshold otherwise alternates between two levels, and each rise
-- would speak.
local LQ_HYSTERESIS = 5

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end

  if os and type(os.clock) == "function" then
    return os.clock()
  end

  return 0
end

local function isTruthy(value)
  return value == true or value == 1 or value == "1" or value == "true"
end

local function prefEnabled(events, key, defaultValue)
  local value = events and events[key]
  if value == nil then return defaultValue end
  return isTruthy(value)
end

local function roundProfileValue(value)
  if type(value) ~= "number" then
    return nil
  end
  return math.floor(value + 0.5)
end

local function normalizeCellVoltage(rawValue, fallback)
  local value = tonumber(rawValue)
  if type(value) ~= "number" then
    return fallback
  end

  -- FC config often stores per-cell voltage in centi-volts (e.g. 350 => 3.50V).
  if value > 10 then
    value = value / 100
  end

  if value < 2.0 or value > 6.0 then
    return fallback
  end

  return value
end

local function normalizeAlertVoltage(rawValue, fallback)
  local value = tonumber(rawValue)
  if type(value) ~= "number" then
    return fallback
  end

  -- Power alert values are stored as deci-volts (e.g. 65 -> 6.5V).
  if value > 20 then
    value = value / 10
  end

  if value <= 0 then
    return fallback
  end

  return value
end

local function readBatteryPrefs()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if not session or type(session.modelPreferences) ~= "table" then
    return nil
  end
  return session.modelPreferences.battery
end

-- The ESC's temperature limit describes the aircraft, so the model's own store wins over
-- the radio-wide default in preferences.ini. Reached the same way readBatteryPrefs above
-- reaches the other half of the same file.
local function readAudioEventPrefs()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if not session or type(session.modelPreferences) ~= "table" then
    return nil
  end
  return session.modelPreferences.audio_events
end

local function isArmedFromState(state)
  if type(state) ~= "table" then
    return false
  end

  local armFlags = tonumber(state.armFlags or state.armflags)
  if type(armFlags) ~= "number" then
    return false
  end

  if bit32 and type(bit32.btest) == "function" then
    return bit32.btest(armFlags, 1)
  end

  return armFlags ~= 0
end

local function resetBecAverage(audioState)
  audioState.becSampleIndex = 0
  audioState.becSampleCount = 0
  audioState.becSampleSum = 0
  local samples = audioState.becSamples
  if type(samples) ~= "table" then
    samples = {}
    audioState.becSamples = samples
  end
  for i = 1, #samples do
    samples[i] = nil
  end
end

local function pushBecAverage(audioState, value)
  local samples = audioState.becSamples
  if type(samples) ~= "table" then
    samples = {}
    audioState.becSamples = samples
  end

  local size = 5
  local idx = (tonumber(audioState.becSampleIndex) or 0) + 1
  if idx > size then idx = 1 end

  local count = tonumber(audioState.becSampleCount) or 0
  local sum = tonumber(audioState.becSampleSum) or 0

  local old = samples[idx]
  if old ~= nil and count >= size then
    sum = sum - old
  elseif count < size then
    count = count + 1
  end

  samples[idx] = value
  sum = sum + value

  audioState.becSampleIndex = idx
  audioState.becSampleCount = count
  audioState.becSampleSum = sum

  if count <= 0 then
    return value
  end

  return sum / count
end

local function unitPercent()
  if type(UNIT_PERCENT) == "number" then return UNIT_PERCENT end
  return 0
end

local function unitMah()
  if type(UNIT_MAH) == "number" then return UNIT_MAH end
  return 108 -- fallback typical for OpenTX/EdgeTX
end

local function unitCelsius()
  if type(UNIT_CELSIUS) == "number" then return UNIT_CELSIUS end
  return 0
end

local function unitVolts()
  if type(UNIT_VOLTS) == "number" then return UNIT_VOLTS end
  return 0
end

-- EdgeTX speaks a fractional value by taking the number in hundredths together with the PREC2
-- attribute: radio/src/lua/api_general.cpp documents playNumber's third argument as "PREC2
-- plays a number with two decimal places (for a number 123 it plays 1.23)". On a firmware
-- that does not export the constant there are no decimals to be had, and the caller has to
-- fall back to whole units -- which is what a zero here says.
local function precTwo()
  if type(PREC2) == "number" then return PREC2 end
  return 0
end

local function emitLog(opts, msg, level)
  if opts and type(opts.log) == "function" then
    opts.log(msg, level)
  end
end

-- WHO decides that the initial fuel / capacity is announced:
-- The radio preference `preferences.audio_events.initial_fuel` (default true)
-- governs this event exclusively.
local function initialFuelWanted(events)
  return prefEnabled(events, "initial_fuel", true)
end

local function getLocaleModule()
  if localeModule then
    return localeModule
  end

  if type(_G) == "table" and type(_G.__rfsuite_system_locale_module) == "table" then
    localeModule = _G.__rfsuite_system_locale_module
    return localeModule
  end

  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then
      localeModule = mod
      return localeModule
    end
  end

  return nil
end

local resolvedEventPaths = {}

local function resolveEventPath(relativePath)
  if resolvedEventPaths[relativePath] ~= nil then
    return resolvedEventPaths[relativePath] or nil
  end

  local locale = (getLocaleModule() and type(getLocaleModule().resolveSystemLanguage) == "function") and getLocaleModule().resolveSystemLanguage("en") or AUDIO_DEFAULT_FALLBACK
  
  -- 1. Try namespaced folder (Rotorflight standard)
  local rfPath = AUDIO_PACK_BASE .. "rf/" .. locale .. "/" .. relativePath
  local f = io.open(rfPath, "r")
  if f then
    io.close(f)
    resolvedEventPaths[relativePath] = rfPath
    return rfPath
  end

  -- 2. Fallback to standard language folder
  local localePath = AUDIO_PACK_BASE .. locale .. "/" .. relativePath
  f = io.open(localePath, "r")
  if f then
    io.close(f)
    resolvedEventPaths[relativePath] = localePath
    return localePath
  end

  -- 3. If file not found in any locale, return nil to indicate failure
  resolvedEventPaths[relativePath] = false
  return nil
end

local function playResolvedEventFile(relativePath, opts)
  local path = resolveEventPath(relativePath)
  if not path then
    emitLog(opts, "playFile: file not found for " .. tostring(relativePath), "warn")
    return false
  end
  if type(playFile) == "function" then
    emitLog(opts, "playFile -> " .. tostring(path), "debug")
    local ok, err = pcall(playFile, path)
    if not ok then emitLog(opts, "playFile error: " .. tostring(err), "error") end
    return ok
  end
  return false
end

local function playRawFile(path)
  if type(playFile) == "function" then
    local ok, _ = pcall(playFile, path)
    return ok
  end
  return false
end

local function scheduleAudioCooldown(audioState, now, seconds)
  audioState.nextAllowedAt = now + (seconds or 0.25)
end

local function tryPlayEventFile(audioState, now, relativePath, opts)
  if not audioState.lastAlertAt then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0 }
  end
  if now < (audioState.nextAllowedAt or 0) then
    emitLog(opts, "cooldown active; skip " .. tostring(relativePath), "debug")
    return false
  end

  if not playResolvedEventFile(relativePath, opts) then
    emitLog(opts, "failed to play " .. tostring(relativePath), "warn")
    return false
  end

  scheduleAudioCooldown(audioState, now, 0.25)
  emitLog(opts, "played " .. tostring(relativePath), "info")
  return true
end

local function fuelThresholdList(selection)
  local sel = tonumber(selection) or 10
  if sel == 0 then return { 100, 10 } end
  if sel == 5 then return { 100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50, 45, 40, 35, 30, 25, 20, 15, 10, 5 } end
  if sel == 10 then return { 100, 90, 80, 70, 60, 50, 40, 30, 20, 10 } end
  if sel == 20 then return { 100, 80, 60, 40, 20, 10 } end
  if sel == 25 then return { 100, 75, 50, 25, 10 } end
  if sel == 50 then return { 100, 50, 10 } end
  if sel > 0 then return { sel } end
  return { 100, 90, 80, 70, 60, 50, 40, 30, 20, 10 }
end

local function resolveSmartfuelModel(self)
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
  local batteryPrefs = session and session.modelPreferences and session.modelPreferences.battery or nil
  local modelType = tonumber(batteryPrefs and batteryPrefs.smartfuel_model_type) or 0

  local cellCount = tonumber(batteryConfig and batteryConfig.batteryCellCount) or tonumber(self.state and self.state.batteryCellCount) or 0
  local hasCapacity = false
  if batteryConfig then
    local totalCap = tonumber(batteryConfig.batteryCapacity) or 0
    if totalCap > 0 then
      hasCapacity = true
    else
      for i = 0, 5 do
        if (tonumber(batteryConfig["batteryCapacity_" .. tostring(i)]) or 0) > 0 then
          hasCapacity = true
          break
        end
      end
    end
  end

  local autoElectric = (cellCount > 0) or hasCapacity
  local isElectric = autoElectric
  if modelType == 1 then
    isElectric = true
  elseif modelType == 2 then
    isElectric = false
  end
  return isElectric, modelType, cellCount, hasCapacity
end

local function getModelName()
  if type(model) ~= "table" or type(model.getInfo) ~= "function" then
    return nil
  end
  local ok, info = pcall(model.getInfo)
  if not ok or type(info) ~= "table" then
    return nil
  end
  local name = info.name
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return name
end

local function resolveModelName(modelName)
  if type(modelName) == "string" and modelName ~= "" then
    return modelName
  end
  if type(model) == "table" and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
      return info.name
    end
  end
  return nil
end

local function announceModelName(audioState, modelName, opts)
  local name = resolveModelName(modelName)
  if not name or type(name) ~= "string" or name == "" then return end

  local candidates = {
    "/SOUNDS/" .. name .. ".wav",
    "/SOUNDS/" .. string.gsub(name, " ", "_") .. ".wav",
    "SOUNDS/" .. name .. ".wav",
    "SOUNDS/" .. string.gsub(name, " ", "_") .. ".wav"
  }

  -- Als angekuendigt markieren, um endlose Fehler loops zu vermeiden
  audioState.modelAnnounced = true

  for i = 1, #candidates do
    local path = candidates[i]
    local f = io.open(path, "r")
    if f then
      io.close(f)
      emitLog(opts, "model announcement -> " .. path, "info")
      if playRawFile(path) then
        return
      end
    else
      emitLog(opts, "model announcement file not found: " .. path, "debug")
    end
  end
end

local function announceProfileEvent(self, eventKey, value, soundFile, opts)
  local rounded = roundProfileValue(value)
  if rounded == nil or rounded <= 0 then
    return
  end

  local audioState = self.audioState
  if not audioState.lastAlertAt then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0 }
  end
  if audioState.lastValues[eventKey] == rounded then
    return
  end

  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then
    return
  end

  local events = (self.preferences and self.preferences.audio_events) or nil
  if not prefEnabled(events, eventKey, true) then
    audioState.lastValues[eventKey] = rounded
    audioState.pendingValues[eventKey] = nil
    return
  end

  if audioState.initialized then
    emitLog(opts, eventKey .. " change value=" .. tostring(rounded) .. " file=" .. tostring(soundFile), "info")
    tryPlayEventFile(audioState, now, soundFile, opts)
    if type(playNumber) == "function" then
      emitLog(opts, "playNumber -> " .. tostring(rounded), "info")
      local ok, err = pcall(playNumber, rounded, 0)
      if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
    end
    audioState.lastValues[eventKey] = rounded
    audioState.pendingValues[eventKey] = nil
  else
    audioState.lastValues[eventKey] = rounded
  end
end

local function announceArmEvent(self, opts)
  local value = roundProfileValue(self.state.armFlags)
  if value == nil then return end

  local audioState = self.audioState
  if audioState.lastValues.arming_flags == value then
    return
  end

  audioState.lastValues.arming_flags = value
  if not audioState.initialized then
    return
  end

  local file = ARM_FILE_MAP[value]
  if type(file) ~= "string" then return end
  local now = nowSeconds()
  tryPlayEventFile(audioState, now, "evt/" .. file, opts)
end

local function announceGovernorEvent(self, events, opts)
  local value = roundProfileValue(self.state.governor)
  if value == nil then return false end

  local audioState = self.audioState
  if audioState.lastValues.governor_state == value then
    -- Back on the state last spoken, so whatever was seen in between was a transient.
    audioState.governorPending = nil
    return false
  end

  if not audioState.initialized then
    audioState.lastValues.governor_state = value
    return false
  end

  -- A new state is a candidate first. It is spoken once it has stood for the hold time; a
  -- state that changes again before that is replaced without a word.
  local now = nowSeconds()
  if audioState.governorPending ~= value then
    audioState.governorPending = value
    audioState.governorPendingSince = now
    return false
  end
  if now - (tonumber(audioState.governorPendingSince) or now) < GOVERNOR_HOLD_SECONDS then
    return false
  end

  audioState.lastValues.governor_state = value
  audioState.governorPending = nil

  local key = GOVERNOR_PREF_KEYS[value]
  if key and not prefEnabled(events, key, true) then
    emitLog(opts, "governor state " .. tostring(value) .. " not announced: " .. key .. " is off", "debug")
    return false
  end

  local file = GOVERNOR_FILE_MAP[value]
  if type(file) ~= "string" then return false end
  return tryPlayEventFile(audioState, now, "gov/" .. file, opts)
end

local function announceBatteryCapacityEvent(self, opts)
  local profile = roundProfileValue(self.state.batteryProfile)
  if profile == nil or profile < 1 or profile > 6 then
    return
  end

  local configIndex = profile

  local audioState = self.audioState
  if not audioState.lastAlertAt then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0 }
  end

  if audioState.lastValues.battery_profile == profile and audioState.batteryCapacityAnnounced then
    return
  end

  local capacity = nil
  local configReady = false
  if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
    local bConf = _G.rfsuite.session.battery_config
    if type(bConf) == "table" then
      capacity = bConf["batteryCapacity_" .. tostring(configIndex - 1)]
      configReady = true
    end
  end

  if not configReady then
    return
  end

  -- The battery configuration arrives over MSP, so it cannot be here on the first pass, and
  -- by the time it is `initialized` is already true. `lastValues.battery_profile` is still
  -- nil at that point, which makes a value that has just ARRIVED indistinguishable from one
  -- the pilot has CHANGED. A caller whose audio state is built fresh for reasons of its own,
  -- rather than because the craft reconnected, sets this flag so the first configuration it
  -- sees is recorded instead of announced. It clears itself, so a later reconnect announces.
  if audioState.seedBatteryCapacity then
    audioState.seedBatteryCapacity = nil
    audioState.lastValues.battery_profile = profile
    audioState.batteryCapacityAnnounced = true
    return
  end

  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then
    return
  end

  local events = (self.preferences and self.preferences.audio_events) or nil
  if not prefEnabled(events, "battery_profile", true) then
    audioState.lastValues.battery_profile = profile
    audioState.batteryCapacityAnnounced = true
    return
  end

  if not audioState.initialized then
    audioState.batteryCapacityAnnounced = false
    return
  end

  if capacity and capacity > 0 then
    emitLog(opts, "battery capacity change profile=" .. tostring(profile) .. " capacity=" .. tostring(capacity), "info")
    tryPlayEventFile(audioState, now, "evt/battery.wav", opts)
    if type(playNumber) == "function" then
      emitLog(opts, "playNumber -> " .. tostring(capacity) .. " mAh", "info")
      local ok, err = pcall(playNumber, capacity, unitMah())
      if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
    end
  else
    emitLog(opts, "battery profile change value=" .. tostring(profile) .. " file=evt/battery.wav", "info")
    tryPlayEventFile(audioState, now, "evt/battery.wav", opts)
    if type(playNumber) == "function" then
      local ok, err = pcall(playNumber, configIndex, 0)
      if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
    end
  end

  audioState.lastValues.battery_profile = profile
  audioState.batteryCapacityAnnounced = true
end

-- The pack the model came up with is not full. Judged once per connection and then latched:
-- in flight the per-cell voltage falls past any margin, and without the latch this would turn
-- from one warning at power-up into a running commentary on the discharge.
--
-- Nothing is judged until everything it needs is there -- a pack voltage, a cell count and a
-- battery configuration to take the full-cell voltage from -- so a missing piece costs a pass
-- and not a wrong answer. The battery configuration arrives over MSP, which is the same
-- reason the voltage alert skips until it is available.
local function announcePackNotFullEvent(self, events, opts)
  local audioState = self.audioState
  if audioState.packCheckDone then
    return
  end
  if not prefEnabled(events, "pack_not_full", false) then
    return
  end

  local voltage = tonumber(self.state and self.state.voltage)
  if type(voltage) ~= "number" or voltage <= 0 then
    return
  end

  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local bc = session and (session.batteryConfig or session.battery_config) or nil
  if type(bc) ~= "table" then
    return
  end

  -- A configured cell count of 0 means auto-detect, so telemetry answers instead.
  local cells = tonumber(bc.batteryCellCount)
  if not cells or cells <= 0 then
    cells = tonumber(self.state and self.state.batteryCellCount)
  end
  if type(cells) ~= "number" then
    return
  end
  cells = math.floor(cells + 0.5)
  if cells <= 0 then
    return
  end

  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then
    return
  end

  -- The reasoning of seedInitialFuel further down, applied to this check: a caller that
  -- rebuilt its audio state has not reconnected, and the pack it would report on was judged
  -- when the craft actually came up. The flag clears itself, so a real reconnect judges again.
  if audioState.seedPackCheck then
    audioState.seedPackCheck = nil
    audioState.packCheckDone = true
    return
  end

  local fullCell = normalizeCellVoltage(bc.vbatmaxcellvoltage, 4.2)
  local margin = tonumber(events.pack_not_full_margin) or 100
  if margin < 0 then margin = 0 end
  local perCell = voltage / cells

  audioState.packCheckDone = true

  if perCell >= fullCell - (margin / 1000) then
    emitLog(opts, "pack check: full at " .. tostring(perCell) .. " V/cell over " .. tostring(cells) .. " cells", "debug")
    return
  end

  emitLog(opts, "pack not full: " .. tostring(perCell) .. " V/cell against " .. tostring(fullCell)
    .. " V less a " .. tostring(margin) .. " mV margin", "info")

  -- notfull.wav is the one file this announcement would like the sound packs to gain. Every
  -- pack ships voltage.wav, so one without it still says something rather than nothing, and
  -- resolveEventPath caches the answer, so the probe costs one open per session.
  local soundFile = "stat/alerts/notfull.wav"
  if not resolveEventPath(soundFile) then
    soundFile = "stat/alerts/voltage.wav"
  end

  if tryPlayEventFile(audioState, now, soundFile, opts) and type(playNumber) == "function" then
    local attribute = precTwo()
    local spoken = math.floor((perCell * 100) + 0.5)
    if attribute == 0 then
      spoken = math.floor(perCell + 0.5)
    end
    local ok, err = pcall(playNumber, spoken, unitVolts(), attribute)
    if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
  end
end

-- Whether the value under `lq` may be read as a link quality in percent. Two independent
-- tests, because either can be the only one available: the caller reports which sensor the
-- search settled on, and the value has to fall inside the range a percentage has. A receiver
-- without an `RQly` sensor answers with an RSSI in dBm, which is negative and would put the
-- alert below any threshold for the whole flight.
--
-- Declining is logged once per connection. Repeating it would be several lines a second, and
-- a receiver that reports no quality does not start reporting one later in the same session.
local function linkIsQuality(self, audioState, lq, opts)
  local source = self.state and self.state.lqSource
  -- 0 is left out on purpose: it is what both callers read as "no link" -- the tool's
  -- readiness test is `lq ~= 0`, the widget's telemetry latch the same -- and it is what
  -- the link sensor reads once it has aged out, which on the widget happens while the MSP
  -- side still counts as connected. Accepting it would announce a lost link as a quality
  -- of nought, with the haptic, which is another announcement's job.
  local usable = lq > 0 and lq <= 100
  if type(source) == "string" and RSSI_LINK_SOURCES[source] then
    usable = false
  end
  if usable then
    return true
  end

  if not audioState.lqNotQualityLogged then
    audioState.lqNotQualityLogged = true
    emitLog(opts, "link quality alert off: link resolved to an RSSI rather than a percentage"
      .. " (source=" .. tostring(source) .. " value=" .. tostring(lq) .. ")", "debug")
  end
  return false
end

--- Play one file out of the audio pack, by its path below `SOUNDS/rf/<locale>/`.
--
-- Exported because the locale fallback lives here and should live in exactly one place. The
-- adjustment teller runs on the telemetry pass, where none of the rest of this module is
-- reachable, and a second copy of `resolveEventPath` is the thing worth avoiding.
--
-- Returns true when a file was found and handed to playFile.
function Audio.playEventFile(relativePath, opts)
  if type(relativePath) ~= "string" or relativePath == "" then return false end
  return playResolvedEventFile(relativePath, opts) == true
end

function Audio.resetConnectionState(audioState)
  if type(audioState) ~= "table" then
    return
  end

  audioState.initialized = false
  audioState.modelAnnounced = false
  audioState.governorPending = nil
  audioState.governorPendingSince = nil
  audioState.batteryCapacityAnnounced = false
  audioState.initialFuelAnnounced = false
  audioState.nextAllowedAt = 0
  audioState.nextProcessAt = 0
  audioState.fuelSeenPositive = false
  audioState.lowFuelActive = false
  audioState.lowFuelLastAt = 0
  audioState.lowFuelRepeatCount = 0
  audioState.lastFuelCallout = nil
  audioState.smartfuelModelType = nil
  audioState.smartfuelCellCount = nil
  audioState.smartfuelHasCapacity = nil
  audioState.smartfuelIsElectric = nil
  audioState.smartfuelEmptySound = nil
  audioState.lqLevel = nil
  audioState.lqNotQualityLogged = nil
  audioState.packCheckDone = false

  if type(audioState.lastValues) == "table" then
    for k in pairs(audioState.lastValues) do
      audioState.lastValues[k] = nil
    end
  else
    audioState.lastValues = {}
  end

  if type(audioState.pendingValues) == "table" then
    for k in pairs(audioState.pendingValues) do
      audioState.pendingValues[k] = nil
    end
  else
    audioState.pendingValues = {}
  end

  if type(audioState.lastAlertAt) == "table" then
    audioState.lastAlertAt.voltage = 0
    audioState.lastAlertAt.esc_temperature = 0
    audioState.lastAlertAt.bec_voltage = 0
    audioState.lastAlertAt.rx_voltage = 0
    audioState.lastAlertAt.flight_time = 0
    audioState.lastAlertAt.lq = 0
    audioState.lastAlertAt.mcu_temperature = 0
  end
end

function Audio.process(self, opts)
  if type(self) ~= "table" or type(self.audioState) ~= "table" then
    return
  end

  local audioState = self.audioState
  local now = nowSeconds()
  local zoneH = tonumber(self.state and self.state.zoneH) or tonumber(LCD_H) or 0
  local processInterval = audioState.initialized and ((zoneH > 0 and zoneH <= 176) and 0.40 or 0.25)
    or ((zoneH > 0 and zoneH <= 176) and 0.60 or 0.35)
  local nextProcessAt = tonumber(audioState.nextProcessAt) or 0
  if now < nextProcessAt then
    return
  end
  audioState.nextProcessAt = now + processInterval

  if type(audioState.lastAlertAt) ~= "table" then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0, bec_voltage = 0, rx_voltage = 0, flight_time = 0 }
  end
  audioState.lastAlertAt.bec_voltage = tonumber(audioState.lastAlertAt.bec_voltage) or 0
  audioState.lastAlertAt.rx_voltage = tonumber(audioState.lastAlertAt.rx_voltage) or 0
  audioState.lastAlertAt.flight_time = tonumber(audioState.lastAlertAt.flight_time) or 0
  audioState.lastAlertAt.lq = tonumber(audioState.lastAlertAt.lq) or 0
  audioState.lastAlertAt.mcu_temperature = tonumber(audioState.lastAlertAt.mcu_temperature) or 0
  if type(audioState.lastValues) ~= "table" then
    audioState.lastValues = {
      arming_flags = nil,
      governor_state = nil,
      pid_profile = nil,
      rate_profile = nil,
      battery_profile = nil
    }
  end
  if type(audioState.pendingValues) ~= "table" then
    audioState.pendingValues = {
      pid_profile = nil,
      rate_profile = nil,
      battery_profile = nil
    }
  end
  if type(audioState.lastEnabled) ~= "table" then
    audioState.lastEnabled = { governor_state = nil }
  end
  if audioState.fuelSeenPositive ~= true then
    audioState.fuelSeenPositive = false
  end

  local events = (self.preferences and self.preferences.audio_events) or {}

  local governorEnabled = prefEnabled(events, "governor_state", true)
  if audioState.lastEnabled.governor_state ~= governorEnabled then
    audioState.lastEnabled.governor_state = governorEnabled
    emitLog(opts, "governor_state enabled=" .. tostring(governorEnabled), "info")
  end

  if not audioState.modelAnnounced and prefEnabled(events, "model_announcement", false) then
    announceModelName(audioState, self.modelName, opts)
  end

  if prefEnabled(events, "arming_flags", true) then
    announceArmEvent(self, opts)
  end

  if governorEnabled then
    announceGovernorEvent(self, events, opts)
  end

  announceProfileEvent(self, "pid_profile", self.state.profile, "evt/profile.wav", opts)
  announceProfileEvent(self, "rate_profile", self.state.rateProfile, "evt/rates.wav", opts)
  announceBatteryCapacityEvent(self, opts)
  -- Deliberately not gated on `initialized`: the first pass after a connect carries the pack's
  -- resting voltage, which is the reading this check is about.
  announcePackNotFullEvent(self, events, opts)

  if prefEnabled(events, "voltage_alert", true) then
    -- Resolve cell count: prefer MSP batteryConfig, fall back to telemetry state,
    -- then refuse to fire (no valid cell count known yet).
    local warnBase
    do
      local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session
      local bc = session and (session.batteryConfig or session.battery_config)
      local warnV = normalizeCellVoltage(bc and bc.vbatwarningcellvoltage, nil)
      -- MSP batteryCellCount == 0 means auto-detect; use telemetry Cel# in that case
      local cells = bc and tonumber(bc.batteryCellCount)
      if not cells or cells <= 0 then
        cells = tonumber(self.state and self.state.batteryCellCount)
      end
      if type(cells) == "number" then
        cells = math.floor(cells + 0.5)
      end
      if warnV and warnV > 0 and cells and cells > 0 then
        warnBase = warnV * cells
      elseif bc and cells and cells > 0 then
        -- batteryConfig is available, use safe per-cell default (3.5V * cells)
        warnBase = 3.5 * cells
      end
      -- warnBase stays nil if batteryConfig not loaded yet → skip the alert until config available
    end
    if warnBase then
      local warn = warnBase
      local reset = warn + 0.5
      local voltage = tonumber(self.state.voltage)
      if type(voltage) == "number" and voltage > 0 then
        if voltage <= warn then
          local lastAt = audioState.lastAlertAt.voltage or 0
          local globalLast = getGlobalLowVoltageAt()
          -- globaler Throttle (reload-sicher)
          if now - globalLast >= 10 and now - lastAt >= 10 then
            if tryPlayEventFile(audioState, now, "evt/lowvbat.wav", opts) then
              audioState.lastAlertAt.voltage = now
              setGlobalLowVoltageAt(now)
            end
          end
        elseif voltage >= reset then
          audioState.lastAlertAt.voltage = 0
        end
      end
    end
  end

  if prefEnabled(events, "esc_temperature", false) then
    local modelEvents = readAudioEventPrefs()
    local threshold = tonumber(modelEvents and modelEvents.esc_threshold)
      or tonumber(events.esc_threshold) or 90
    local escTemp = tonumber(self.state.escTemp)
    if type(escTemp) == "number" then
      if escTemp >= threshold then
        local lastAt = audioState.lastAlertAt.esc_temperature or 0
        if now - lastAt >= 10 then
          if tryPlayEventFile(audioState, now, "evt/esctemp.wav", opts) then
            if type(playHaptic) == "function" then
              pcall(playHaptic, 15, 10, 3)
            end
            audioState.lastAlertAt.esc_temperature = now
          end
        end
      else
        -- kein hartes Rücksetzen, damit Cooldown erhalten bleibt
      end
    end
  end

  -- The same shape as the ESC alert above, with one difference: no `scope = "model"`. The
  -- ESC's limit describes one aircraft's hardware, while the flight controller's MCU is the
  -- same silicon with the same rating in every model, so this threshold is radio-wide and
  -- is read out of the global table only.
  if prefEnabled(events, "mcu_temperature", false) then
    local threshold = tonumber(events.mcu_threshold) or 80
    local mcuTemp = tonumber(self.state.mcuTemp)
    if type(mcuTemp) == "number" and mcuTemp >= threshold then
      local lastAt = audioState.lastAlertAt.mcu_temperature or 0
      if now - lastAt >= 10 then
        if tryPlayEventFile(audioState, now, "stat/alerts/mcu.wav", opts) then
          if type(playNumber) == "function" then
            local ok, err = pcall(playNumber, math.floor(mcuTemp + 0.5), unitCelsius())
            if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
          end
          if type(playHaptic) == "function" then
            pcall(playHaptic, 15, 10, 3)
          end
          audioState.lastAlertAt.mcu_temperature = now
        end
      end
    end
  end

  if prefEnabled(events, "lq_alert", false) then
    local lq = tonumber(self.state.lq)
    if type(lq) == "number" and linkIsQuality(self, audioState, lq, opts) then
      local warn = tonumber(events.lq_warn) or 70
      local critical = tonumber(events.lq_critical) or 50
      -- A critical level above the warning level cannot be crossed second, so the lower of
      -- the two is the critical one. Nothing is refused over it; the pair is just ordered.
      if critical > warn then critical = warn end

      local spoken = tonumber(audioState.lqLevel) or 0
      local level = 0
      if lq <= critical then
        level = 2
      elseif lq <= warn then
        level = 1
      end

      -- Leaving a level costs LQ_HYSTERESIS points more than entering it.
      if level < spoken then
        if spoken >= 2 and lq <= critical + LQ_HYSTERESIS then
          level = 2
        elseif level < 1 and spoken >= 1 and lq <= warn + LQ_HYSTERESIS then
          level = 1
        end
      end

      if level < spoken then
        -- Recovering is not announced; the next fall is.
        audioState.lqLevel = level
      elseif level > 0 and (level > spoken or now - (audioState.lastAlertAt.lq or 0) >= 10) then
        if tryPlayEventFile(audioState, now, "stat/alerts/lq.wav", opts) then
          if type(playNumber) == "function" then
            local ok, err = pcall(playNumber, math.floor(lq + 0.5), unitPercent())
            if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
          end
          if level >= 2 and type(playHaptic) == "function" then
            pcall(playHaptic, 15, 10, 3)
          end
          audioState.lqLevel = level
          audioState.lastAlertAt.lq = now
        end
      end
    end
  end

  do
    local batteryPrefs = readBatteryPrefs()
    local armed = isArmedFromState(self.state)
    if audioState.flightArmed ~= armed then
      audioState.flightArmed = armed
      if armed then
        audioState.flightTimerTriggered = false
        audioState.flightTimerStartAt = nil
      else
        audioState.flightTimerTriggered = false
        audioState.flightTimerStartAt = nil
        audioState.lastAlertAt.flight_time = 0
        resetBecAverage(audioState)
      end
    end

    if armed then
      local bec = tonumber(self.state and (self.state.bec_voltage or self.state.becVoltage))
      local alertType = tonumber(batteryPrefs and batteryPrefs.alert_type) or 0
      if type(bec) == "number" and bec > 0 and (alertType == 1 or alertType == 2) then
        local avgBEC = pushBecAverage(audioState, bec)
        local interval = 10

        if alertType == 1 then
          local threshold = normalizeAlertVoltage(batteryPrefs and batteryPrefs.becalertvalue, 6.5)
          if avgBEC < threshold then
            local lastAt = audioState.lastAlertAt.bec_voltage or 0
            if now - lastAt >= interval and tryPlayEventFile(audioState, now, "evt/becvolt.wav", opts) then
              if type(playHaptic) == "function" then
                pcall(playHaptic, 15, 10, 3)
              end
              audioState.lastAlertAt.bec_voltage = now
            end
          else
            audioState.lastAlertAt.bec_voltage = 0
          end
          audioState.lastAlertAt.rx_voltage = 0
        elseif alertType == 2 then
          local threshold = normalizeAlertVoltage(batteryPrefs and batteryPrefs.rxalertvalue, 7.4)
          if avgBEC < threshold then
            local lastAt = audioState.lastAlertAt.rx_voltage or 0
            if now - lastAt >= interval and tryPlayEventFile(audioState, now, "evt/rxvolt.wav", opts) then
              if type(playHaptic) == "function" then
                pcall(playHaptic, 15, 10, 3)
              end
              audioState.lastAlertAt.rx_voltage = now
            end
          else
            audioState.lastAlertAt.rx_voltage = 0
          end
          audioState.lastAlertAt.bec_voltage = 0
        end
      else
        audioState.lastAlertAt.bec_voltage = 0
        audioState.lastAlertAt.rx_voltage = 0
      end

      local targetSeconds = tonumber(batteryPrefs and batteryPrefs.flighttime) or 0
      if targetSeconds > 0 then
        local elapsed = tonumber(self.state and self.state.flightSeconds)
        if type(elapsed) ~= "number" then
          if type(audioState.flightTimerStartAt) ~= "number" then
            audioState.flightTimerStartAt = now
          end
          elapsed = now - audioState.flightTimerStartAt
        else
          if type(audioState.flightTimerStartAt) ~= "number" then
            audioState.flightTimerStartAt = now - elapsed
          end
        end

        if elapsed >= targetSeconds then
          if audioState.flightTimerTriggered ~= true then
            local sound = "evt/elapsed.wav"
            if tryPlayEventFile(audioState, now, sound, opts) then
              audioState.flightTimerTriggered = true
              audioState.lastAlertAt.flight_time = now
            end
          end
        else
          audioState.flightTimerTriggered = false
        end
      else
        audioState.flightTimerTriggered = false
      end
    else
      audioState.lastAlertAt.bec_voltage = 0
      audioState.lastAlertAt.rx_voltage = 0
    end
  end

  if prefEnabled(events, "fuel_alerts", true) then
    if self.state.fuelTelemetrySeen ~= true then
      -- Skip fuel/empty alerts until we have seen at least one real fuel telemetry sample.
      audioState.lowFuelActive = false
      audioState.lowFuelLastAt = 0
      audioState.lowFuelRepeatCount = 0
      audioState.lastFuelCallout = nil
      audioState.fuelSeenPositive = false
      goto fuel_alerts_done
    end

    local fuelValue = tonumber(self.state.fuel)
    if type(fuelValue) == "number" then
      if fuelValue < 0 then fuelValue = 0 end
      if fuelValue > 100 then fuelValue = 100 end
      if fuelValue > 0 then
        audioState.fuelSeenPositive = true
      end

      local isElectricModel, modelType, cellCount, hasCapacity = resolveSmartfuelModel(self)
      local emptyFuelSound = isElectricModel and "stat/alerts/lowbat.wav" or "stat/alerts/lowfuel.wav"
      if audioState.smartfuelModelType ~= modelType
        or audioState.smartfuelCellCount ~= cellCount
        or audioState.smartfuelHasCapacity ~= hasCapacity
        or audioState.smartfuelIsElectric ~= isElectricModel
        or audioState.smartfuelEmptySound ~= emptyFuelSound then
        audioState.smartfuelModelType = modelType
        audioState.smartfuelCellCount = cellCount
        audioState.smartfuelHasCapacity = hasCapacity
        audioState.smartfuelIsElectric = isElectricModel
        audioState.smartfuelEmptySound = emptyFuelSound
        emitLog(
          opts,
          "smartfuel classify modelType=" .. tostring(modelType)
            .. " cells=" .. tostring(cellCount)
            .. " hasCapacity=" .. tostring(hasCapacity)
            .. " isElectric=" .. tostring(isElectricModel)
            .. " emptySound=" .. tostring(emptyFuelSound),
          "debug"
        )
      end

      local repeats = tonumber(events.fuel_repeat_below_zero) or 1
      if repeats < 1 then repeats = 1 end
      if repeats > 10 then repeats = 10 end

      if fuelValue <= 0 and audioState.fuelSeenPositive == true then
        local canRepeat = (now - (audioState.lowFuelLastAt or 0)) >= 10
        if (not audioState.lowFuelActive) or (audioState.lowFuelRepeatCount < repeats and canRepeat) then
          if tryPlayEventFile(audioState, now, emptyFuelSound, opts) then
            if events.fuel_haptic_below_zero == true and type(playHaptic) == "function" then
              pcall(playHaptic, 15, 10, 3)
            end
            audioState.lowFuelActive = true
            audioState.lowFuelLastAt = now
            audioState.lowFuelRepeatCount = (audioState.lowFuelRepeatCount or 0) + 1
          end
        end
      else
        audioState.lowFuelActive = false
        audioState.lowFuelLastAt = 0
        audioState.lowFuelRepeatCount = 0

        local currentRounded = roundProfileValue(fuelValue)
        if currentRounded and currentRounded >= 0 then
          local lastCallout = audioState.lastFuelCallout
          if lastCallout == nil then
            audioState.lastFuelCallout = currentRounded
          else
            local thresholds = fuelThresholdList(events.fuel_callout_percent)
            local lowestCrossed = nil
            for i = 1, #thresholds do
              local threshold = thresholds[i]
              if currentRounded <= threshold and lastCallout > threshold then
                lowestCrossed = threshold
              end
            end
            if lowestCrossed then
              local calloutSound = isElectricModel and "evt/battery.wav" or "stat/alerts/fuel.wav"
              if tryPlayEventFile(audioState, now, calloutSound, opts) then
                if type(playNumber) == "function" then
                  emitLog(opts, "fuel callout playNumber -> " .. tostring(lowestCrossed), "info")
                  local ok, err = pcall(playNumber, lowestCrossed, unitPercent())
                  if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
                end
              end
              audioState.lastFuelCallout = currentRounded
            elseif currentRounded > lastCallout then
              audioState.lastFuelCallout = currentRounded
            end
          end
        end
      end
    end
    ::fuel_alerts_done::
  else
    audioState.lowFuelActive = false
    audioState.lowFuelLastAt = 0
    audioState.lowFuelRepeatCount = 0
    audioState.lastFuelCallout = nil
    audioState.fuelSeenPositive = false
  end

  -- Once the callout has fired it stays fired for the session.
  if not audioState.initialFuelAnnounced and audioState.initialized and initialFuelWanted(events) then
    local fuel = tonumber(self.state and self.state.fuel)
    -- Same reason as the battery capacity above: this announcement is meant once per
    -- connection, and a caller that rebuilds its audio state for its own reasons has not
    -- reconnected. The flag clears itself, so a real reconnect still speaks.
    if type(fuel) == "number" and audioState.seedInitialFuel then
      audioState.seedInitialFuel = nil
      audioState.initialFuelAnnounced = true
    elseif type(fuel) == "number" then
      local now = nowSeconds()
      if now >= (audioState.nextAllowedAt or 0) then
        local isElectricModel = resolveSmartfuelModel(self)
        local calloutSound = isElectricModel and "evt/battery.wav" or "stat/alerts/fuel.wav"
        if tryPlayEventFile(audioState, now, calloutSound, opts) then
          if type(playNumber) == "function" then
            local ok, err = pcall(playNumber, fuel, unitPercent())
            if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
          end
          audioState.initialFuelAnnounced = true
        end
      end
    end
  end

  if not audioState.initialized then
    audioState.initialized = true
  end
end

return Audio
