if type(_G) == "table" and type(_G.__rfsuiteObjectsCommonModule) == "table" then
  return _G.__rfsuiteObjectsCommonModule
end

local Utils = {}

local i18nModule = nil
local i18nContext = nil
local i18nLocale = nil
local resolvedLocale = nil
local resolvedGeneration = nil
local sensorsModule = nil
local linkRatesModule = nil
local crsfModule = nil
local escStatusModule = nil
local escStatusModuleMissing = false
local localeModule = nil
local titleCache = {}

local function rgb(hex, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local r = math.floor(hex / 65536) % 256
    local g = math.floor(hex / 256) % 256
    local b = hex % 256
    local ok, col = pcall(lcd.RGB, r, g, b)
    if ok and col then return col end
  end
  return fallback
end

local COLOR_NAME_MAP = {
  black = BLACK,
  white = WHITE,
  red = RED,
  green = GREEN,
  yellow = YELLOW,
  grey = COLOR_THEME_SECONDARY2,
  gray = COLOR_THEME_SECONDARY2,
  orange = rgb(0xFF8000, 0xFF8000),
  blue = rgb(0x3399FF, 0x3399FF)
}

local function detectSimulator()
  if type(getVersion) ~= "function" then return false end
  local ok, _, fw = pcall(getVersion)
  if not ok or type(fw) ~= "string" then return false end
  return string.sub(string.lower(fw), -4) == "simu"
end

local IS_SIMULATOR = detectSimulator()

local function getLocaleModule()
  if localeModule then
    return localeModule
  end

  if type(_G) == "table" and type(_G.__rfsuite_system_locale_module) == "table" then
    localeModule = _G.__rfsuite_system_locale_module
    return localeModule
  end

  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("lib/system_locale.lua")
    if mod and type(mod) == "table" then
      localeModule = mod
      return localeModule
    end
  end

  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then
      localeModule = mod
      if type(_G) == "table" then
        _G.__rfsuite_system_locale_module = mod
      end
    end
  end

  return localeModule
end

-- This memo was here before the theme commons had one, and it is why the layer was the reference
-- for the fix in #253 rather than a place the fix had to reach. What it lacked was an
-- invalidation: nothing in the tree ever set resolvedLocale back to nil, so a language changed in
-- Settings > Localization did not reach the dashboard until the widget's Lua state was rebuilt.
-- The generation counter is that missing half -- the preferences reload calls
-- system_locale.invalidateLanguage(), and the next call here re-resolves.
--
-- A module without the field cannot signal a change, and then nothing is memoised, which is the
-- per-call behaviour this file had before.
local function resolveLocale()
  local mod = getLocaleModule()
  local generation = mod and mod.localeGeneration or nil
  if resolvedLocale and resolvedLocale ~= "" and generation ~= nil and generation == resolvedGeneration then
    return resolvedLocale
  end

  if mod and type(mod.resolveSystemLanguage) == "function" then
    local ok, locale = pcall(mod.resolveSystemLanguage, "en")
    if ok and type(locale) == "string" and locale ~= "" then
      resolvedLocale = locale
      resolvedGeneration = generation
      return resolvedLocale
    end
  end

  resolvedLocale = "en"
  resolvedGeneration = generation
  return resolvedLocale
end

local function getI18nContext()
  local locale = resolveLocale()
  if i18nContext and i18nLocale == locale then
    return i18nContext
  end

  if not i18nModule then
    if _G.rfsuite and type(_G.rfsuite.require) == "function" then
      local mod = _G.rfsuite.require("i18n/init.lua")
      if mod and type(mod) == "table" and type(mod.new) == "function" then
        i18nModule = mod
      end
    end
    if not i18nModule then
      local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/i18n/init.lua", mode)
      if chunk then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" and type(mod.new) == "function" then
          i18nModule = mod
        end
      end
    end
  end

  if i18nModule and type(i18nModule.new) == "function" then
    local ok, ctx = pcall(i18nModule.new, locale)
    if ok and type(ctx) == "table" then
      i18nContext = ctx
      i18nLocale = locale
      return i18nContext
    end
  end

  return nil
end

function Utils.clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

function Utils.resolveValue(value, box, state)
  if type(value) == "function" then
    local ok, resolved = pcall(value, box, state)
    if ok then return resolved end
    return nil
  end
  return value
end

function Utils.normalizeTitle(raw, i18nCtx)
  if type(raw) ~= "string" or raw == "" then return nil end

  local ctxLocale = nil
  if type(i18nCtx) == "table" and type(i18nCtx.getLocale) == "function" then
    local ok, v = pcall(i18nCtx.getLocale)
    if ok and type(v) == "string" then ctxLocale = v end
  end

  local cacheLocale = ctxLocale or i18nLocale or resolveLocale()
  local cacheKey = cacheLocale .. "|" .. raw
  local cached = titleCache[cacheKey]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end

  if string.find(raw, "@i18n(", 1, true) then
    if i18nCtx and type(i18nCtx.resolve) == "function" then
      local ok, resolved = pcall(i18nCtx.resolve, raw)
      if ok and type(resolved) == "string" and resolved ~= "" then
        titleCache[cacheKey] = resolved
        return resolved
      end
    end

    if not IS_SIMULATOR then
      local i18n = getI18nContext()
      if i18n and type(i18n.resolve) == "function" then
        local ok, resolved = pcall(i18n.resolve, raw)
        if ok and type(resolved) == "string" and resolved ~= "" then
          titleCache[cacheKey] = resolved
          return resolved
        end
      end
    end
  end

  local token = string.match(raw, "@i18n%(([^)]+)%)")
  if token then
    local key = string.match(token, "([^.]+)$") or token
    if string.find(raw, ":upper%(", 1, false) then
      local out = string.upper(key)
      titleCache[cacheKey] = out
      return out
    end
    titleCache[cacheKey] = key
    return key
  end

  titleCache[cacheKey] = raw
  return raw
end

function Utils.toNumber(value, fallback)
  if type(value) == "number" then return value end
  return fallback
end

-- A core module, through the loader if there is one and off the card if there is not. Lifted
-- out of mapTelemetrySource unchanged, because the link sources below need the sensor module
-- on a pass that never reaches the sensor fall-through at the end of it.
local function loadCoreModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require(path)
    if mod and type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local function getSensorsModule()
  if not sensorsModule then sensorsModule = loadCoreModule("lib/sensors.lua") end
  return sensorsModule
end

local function getLinkRatesModule()
  if not linkRatesModule then linkRatesModule = loadCoreModule("lib/link_rates.lua") end
  return linkRatesModule
end

-- One sensor read per widget pass, shared by the link sources that want the same field.
--
-- `getTime` is the radio's 10 ms tick and a pass that spans no tick boundary reads the same
-- value twice, which is the test lib/sensors.lua and widgets/dashboard/runtime.lua already
-- throttle their own per-pass work with. Where the clock is not there the memo never hits, so
-- each source reads for itself -- more instructions, the same answer.
--
-- Nothing here runs for a theme that declares none of these sources: they are resolved from
-- the derived snapshot's own list, so an absent name costs the comparisons below and no more.
local function passTick()
  if type(getTime) ~= "function" then return nil end
  local ok, ticks = pcall(getTime)
  if ok and type(ticks) == "number" then return ticks end
  return nil
end

--- The `RFMD` reading this pass, memoised on the state.
local function linkRfMode(state)
  if type(state) ~= "table" then return nil end
  local tick = passTick()
  if tick ~= nil and state.linkRfModeTick == tick then return state.linkRfMode end
  local sensors = getSensorsModule()
  local mode = nil
  if sensors and type(sensors.getValue) == "function" then
    local value = sensors.getValue("RFMD")
    if type(value) == "number" then mode = value end
  end
  state.linkRfModeTick = tick
  state.linkRfMode = mode
  return mode
end

local function getCrsfModule()
  if not crsfModule then crsfModule = loadCoreModule("lib/crsf.lua") end
  return crsfModule
end

--- The ExpressLRS generation of the transmitter module -- 3, 4, or 0 for anything else -- or
--- nil while it is not known.
---
--- The `RFMD` byte means different rates on ExpressLRS 3.x and 4.x and does not say which, so
--- the module is asked: one device ping, and the device-information frame it answers with names
--- the release (lib/link_rates.lua). Only a theme that declares one of the two rate sources ever
--- gets here, and only once the link is up and `RFMD` has a reading, so a theme without them, a
--- link that is down and a link that carries no link statistics send nothing.
---
--- lib/crsf.lua is the one frame multiplexer of this Lua state: asking it for 0x29 before the
--- ping is what makes it keep the answer when another consumer drains the queue first, and it
--- keeps every other consumer's frames while this one drains.
local function linkGeneration(state, rates)
  if state.linkGeneration ~= nil then return state.linkGeneration end
  local crsf = getCrsfModule()
  if not (crsf and type(crsf.popFrame) == "function") then return nil end
  while true do
    local data = crsf.popFrame(rates.FRAME_DEVICE_INFO)
    if data == nil then break end
    local generation = rates.generationFromDeviceInfo(data)
    if generation ~= nil then
      state.linkGeneration = generation
      return generation
    end
  end
  local push = _G.crossfireTelemetryPush
  if state.linkPingSent or type(push) ~= "function" then return nil end
  local ok, queued = pcall(push, rates.FRAME_DEVICE_PING, rates.PING_PAYLOAD)
  if not ok then return nil end
  -- Nil is EdgeTX saying no module runs the CRSF protocol, so nothing will answer and nothing
  -- ExpressLRS is there. False is a full output buffer, which the next pass tries again.
  if queued == nil then
    state.linkGeneration = 0
    return 0
  end
  if queued == true then state.linkPingSent = true end
  return nil
end

--- What the link is running, as a row of lib/link_rates.lua, or nil.
---
--- Nil while the link is down, too: EdgeTX answers `getValue` with 0 for every telemetry source
--- while telemetry is not streaming, and 0 is an air rate in both tables.
local function packetRateRow(state)
  if type(state) ~= "table" or state.rfConnected ~= true then return nil end
  local rates = getLinkRatesModule()
  if not (rates and type(rates.forMode) == "function") then return nil end
  local mode = linkRfMode(state)
  if mode == nil then return nil end
  local generation = linkGeneration(state, rates)
  if generation == nil then return nil end
  return rates.forMode(mode, generation)
end

--- 1 once the readings have proved a second antenna, 0 while they have not, nil until the
--- receiver has reported the fields at all.
---
--- Latched for the session and never lowered: a switched-diversity receiver spends most of its
--- packets on one antenna, so a pass that sees only the first one is not evidence against the
--- second. The runtime clears it where it starts a new flight-controller session, which is the
--- point at which the receiver may be a different one.
local function linkDiversity(state)
  if type(state) ~= "table" then return nil end
  if state.linkDiversity == 1 then return 1 end
  local tick = passTick()
  if tick ~= nil and state.linkDiversityTick == tick then return state.linkDiversity end
  state.linkDiversityTick = tick
  local sensors = getSensorsModule()
  local rates = getLinkRatesModule()
  if not (sensors and type(sensors.getValue) == "function") then return state.linkDiversity end
  if not (rates and type(rates.latchDiversity) == "function") then return state.linkDiversity end
  -- `ANT` is in every link-statistics frame, so it answering is what says the receiver reports
  -- these fields at all. The rule that turns the pair into the flag is lib/link_rates.lua's,
  -- where it can be checked without a radio.
  state.linkDiversity = rates.latchDiversity(state.linkDiversity, sensors.getValue("2RSS"), sensors.getValue("ANT"))
  return state.linkDiversity
end

-- A string a library produced carries its translation as a build marker, because a library has
-- no route to the locale bundle. Packaging rewrites the marker, so on a radio this is one search
-- that finds nothing; an unpackaged tree still gets the wording from the widget's own context.
local function resolveBuildMarker(state, raw)
  if type(raw) ~= "string" then return raw end
  if not string.find(raw, "@i18n(", 1, true) then return raw end
  local i18n = state and state.i18n
  if i18n and type(i18n.resolve) == "function" then
    local ok, resolved = pcall(i18n.resolve, raw)
    if ok and type(resolved) == "string" and resolved ~= "" then return resolved end
  end
  return raw
end

-- The speed controller's health: the one box source that is two sensors rather than one.
-- lib/esc_status.lua holds the per-protocol layouts; what is here is when to read them, when to
-- decode again, and how long a fault is remembered. Three things it has to get right, and each
-- of them costs something if it does not:
--
--   * one decode answers four sources. `esc_status`/`esc_status_level` are the worst reading on
--     file, `esc_status_live`/`esc_status_live_level` what the controller is saying on this pass;
--     each name is a text and a severity, and all four come out of the same snapshot build, so
--     the pair of sensor reads is keyed on the radio's own tick and every source after the first
--     pays a comparison.
--   * the layout is read again only when a byte moved. The status word is identical on almost
--     every pass of a healthy flight, and walking a 24-bit layout for an answer that cannot have
--     changed is exactly the cost that stays invisible until a theme declares the source.
--   * the worst the controller has reported since the flight controller answered is kept. A
--     fault the controller has since cleared is still the reason a flight ended early, and a
--     pass is slower than a fault. The latch is dropped where the runtime starts a new session
--     with a flight controller (widgets/dashboard/runtime.lua clears `state.escStatusCache`).
--
-- Both readings exist because they answer different questions and neither substitutes for the
-- other: a status line is read as "what is wrong now" and would lie if it held a fault the
-- controller has cleared, while a value row is read as "what has this flight seen" and would
-- lose the fault that ended it. A surface picks the one its own wording promises.
local function resolveEscStatus(state, sensors)
  if type(state) ~= "table" then return nil end
  if type(sensors) ~= "table" or type(sensors.getValue) ~= "function" then return nil end

  if escStatusModule == nil and not escStatusModuleMissing then
    if _G.rfsuite and type(_G.rfsuite.require) == "function" then
      local mod = _G.rfsuite.require("lib/esc_status.lua")
      if type(mod) == "table" then escStatusModule = mod end
    end
    if escStatusModule == nil then
      local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/esc_status.lua", mode)
      if chunk then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" then escStatusModule = mod end
      end
    end
    if escStatusModule == nil then escStatusModuleMissing = true end
  end
  if escStatusModule == nil or type(escStatusModule.decode) ~= "function" then return nil end

  local cache = state.escStatusCache
  if cache == nil then
    cache = {}
    state.escStatusCache = cache
  end

  local tick = (type(getTime) == "function") and getTime() or nil
  if tick ~= nil and cache.sampled and cache.tick == tick then
    return cache.verdict
  end
  cache.tick = tick
  cache.sampled = true

  local signature = sensors.getValue("Esc#")
  local word = sensors.getValue("EscF")
  if cache.decoded and signature == cache.signature and word == cache.word then
    return cache.verdict
  end
  cache.decoded = true
  cache.signature = signature
  cache.word = word

  local ok, decoded = pcall(escStatusModule.decode, signature, word)
  if not ok then decoded = nil end

  if decoded == nil then
    -- Nothing answered for the speed controller, or neither sensor is on this radio. A box draws
    -- `--` for it; the latch is kept rather than cleared, so a link that drops and comes back
    -- does not lose what it had already seen.
    cache.verdict = nil
    return nil
  end

  -- What the controller says on this pass, taken before the latch is consulted. A request to
  -- restart the controller belongs here: it is withdrawn by the next telemetry frame, which is
  -- exactly what an unlatched reading is for, and a surface that shows it while it stands is
  -- showing the truth about this second.
  local liveText, liveLevel = decoded.text, decoded.level

  local text, level = decoded.text, decoded.level
  if decoded.transient then
    -- Withdrawn by the next telemetry frame, so it is never written into the latch -- and it
    -- gives way to a fault already on file, which is the worse news of the two.
    if cache.latchLevel ~= nil and cache.latchLevel > level then
      text, level = cache.latchText, cache.latchLevel
    end
  elseif decoded.word == nil then
    -- No status word behind the reading: the model byte has arrived and the word has not, or
    -- has stopped arriving, or the signature is not one we can read a word against. That says
    -- nothing about the controller's health, so it is never written into the latch either --
    -- written there at the same severity as OK, the first healthy word could never replace it.
    -- A record already on file stands; without one, the reading is shown as it is.
    if cache.latchLevel ~= nil then
      text, level = cache.latchText, cache.latchLevel
    end
  elseif cache.latchLevel == nil or level > cache.latchLevel then
    cache.latchText, cache.latchLevel = text, level
  else
    text, level = cache.latchText, cache.latchLevel
  end

  cache.verdict = {
    text = resolveBuildMarker(state, text), level = level,
    liveText = resolveBuildMarker(state, liveText), liveLevel = liveLevel,
  }
  return cache.verdict
end

function Utils.mapTelemetrySource(source, state)
  if type(source) ~= "string" then return nil end

  if source == "model_name" then
    if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
      local name = _G.rfsuite.session.modelName
      if type(name) == "string" and name ~= "" then
        return name
      end
    end
    if model and type(model.getInfo) == "function" then
      local info = model.getInfo()
      if info and type(info.name) == "string" and info.name ~= "" then
        return info.name
      end
    end
    return "--"
  end

  -- Fast-path hot dashboard values from runtime state to avoid file/telemetry
  -- lookups in every refresh.
  if source == "pid_profile" then return state and state.profile end
  if source == "rate_profile" then return state and state.rateProfile end
  if source == "battery_profile" then return state and state.batteryProfile end
  if source == "link" then return state and state.lq end
  if source == "voltage" then return state and state.voltage end
  if source == "bec_voltage" then return state and state.bec_voltage end
  if source == "rpm" then return state and state.rpm end
  if source == "fuel" then return state and state.fuel end
  if source == "governor" then return state and state.governor end
  if source == "esc_temp" then return state and state.escTemp end
  if source == "mcu_temp" then return state and state.mcuTemp end
  if source == "throttle_percent" then return state and state.throttlePercent end
  if source == "current" then return state and state.current end
  if source == "watts" then return state and state.watts end
  if source == "altitude" then return state and state.altitude end
  if source == "smartfuel" then return state and state.fuel end
  if source == "smartconsumption" then return state and state.consumedMah end
  -- Derived rather than measured: the current as a percentage of the speed controller's own
  -- current limit. Nil where no limit is on file for the model, which a box draws as `--`.
  if source == "esc_load" then return state and state.escLoad end

  -- The link's own three, derived from the CRSF link-statistics frame rather than read as a
  -- value. They sit at the end of this chain on purpose: the comparisons are paid by the
  -- sources that fall through to a sensor, and by none of the ones above.
  --
  -- The air rate the link runs at, as the name ExpressLRS gives it. Nil while the link is down,
  -- while the transmitter module has not yet said which ExpressLRS generation it runs, where it
  -- is not ExpressLRS 3.x or 4.x, and where the byte is one that generation leaves unused.
  --
  -- "packet rate" and not "link rate": `session.crsfTelemetryConfig.linkRate` is already the
  -- flight controller's telemetry link rate in hertz, off MSP telemetry_config, and
  -- app/pages/tools/diagnostics/elrs_link reads the air rate under the name `packetRate`. This
  -- is the same quantity as that one, off the link-statistics frame rather than off the module's
  -- parameter list, so it takes the same word.
  if source == "link_packet_rate" then
    local row = packetRateRow(state)
    return row and row.rate
  end
  -- The receiver sensitivity that rate is specified down to, in dBm and negative. Nil wherever
  -- the rate is, and also for a rate whose figure is not a function of the byte -- configured by
  -- no radio target, or on 3.x given a different figure per band -- so a box can draw a rate
  -- whose floor is unknown.
  if source == "link_floor" then
    local row = packetRateRow(state)
    return row and row.floor
  end
  if source == "link_diversity" then return linkDiversity(state) end
  -- `state.mainPowerLost` as a flag a box can draw and colour: 1 while the main pack is gone
  -- and the flight controller still answers, 0 otherwise. A number rather than the boolean,
  -- because threshold limits and the gauge take numbers and strings only. Never nil: the field
  -- is false before the first read, so no telemetry reads as 0, not as lost.
  if source == "main_power_lost" then return (state and state.mainPowerLost) and 1 or 0 end

  local sensors = getSensorsModule()

  -- Derived, and from two sensors rather than one, so it is resolved here where the sensors
  -- module is already in hand rather than in the fast-path block above. A theme that names none
  -- of the four reaches none of this and reads neither sensor.
  if source == "esc_status" or source == "esc_status_level"
    or source == "esc_status_live" or source == "esc_status_live_level" then
    local verdict = resolveEscStatus(state, sensors)
    if verdict == nil then return nil end
    if source == "esc_status" then return verdict.text end
    if source == "esc_status_level" then return verdict.level end
    if source == "esc_status_live" then return verdict.liveText end
    return verdict.liveLevel
  end

  if sensors and type(sensors.getValue) == "function" then
    local value = sensors.getValue(source)
    if type(value) == "number" then return value end
  end

  return nil
end

-- Flight statistics: the per-flight extremes widgets/dashboard/runtime.lua records, and the
-- one place a box source is resolved to them. One row per statistic, mirroring the FLIGHT_STATS
-- table that produces them -- `key` is the same name suffix, `sources` are the box sources that
-- mean that statistic, and a direction is readable when its column is present.
--
-- Both consumers go through Utils.statFields, so a source resolves to the same statistic
-- everywhere rather than to whichever of two hand-written chains happens to be asked. The record
-- the key is read from is tasks/events/telemetry/flight_record.lua's, under rfsuite.session.flight.
local FLIGHT_STATS = {
  { key = "ThrottlePercent", sources = { "throttle_percent" }, max = true },
  { key = "Rpm",             sources = { "rpm" },              max = true, min = true },
  { key = "Current",         sources = { "current" },          max = true, min = true },
  { key = "Watts",           sources = { "watts" },            max = true },
  { key = "Altitude",        sources = { "altitude" },         max = true },
  { key = "EscTemp",         sources = { "esc_temp", "temp_esc" }, max = true },
  { key = "McuTemp",         sources = { "mcu_temp", "temp_mcu" }, max = true },
  { key = "Fuel",            sources = { "fuel", "smartfuel" }, min = true },
  { key = "Voltage",         sources = { "voltage" },          max = true, min = true },
  { key = "BecVoltage",      sources = { "bec_voltage" },      min = true },
  { key = "Lq",              sources = { "link" },             max = true, min = true },
}

-- source -> stattype -> the record's key for that statistic. Built once, at load time.
local STAT_SOURCES = {}
for i = 1, #FLIGHT_STATS do
  local stat = FLIGHT_STATS[i]
  local entry = {}
  if stat.max then entry.max = "max" .. stat.key end
  if stat.min then entry.min = "min" .. stat.key end
  for _, source in ipairs(stat.sources) do
    STAT_SOURCES[source] = entry
  end
end

--- The record key a box source and stattype resolve to, or nil when the pair is not a recorded
--- extreme.
---
--- `stattype` is the box's own wording: "min" and "max" are the recorded extremes, and every
--- other stattype a box may carry (a consumed total, a per-cell derivation, a live count) is not
--- a flight statistic and is resolved by the object that understands it.
---
--- Objects resolve the key ONCE, where the box is rendered, and the value closure the reactive
--- sweep calls per frame then reads the record with a key it already holds.
function Utils.statFields(source, stattype)
  local entry = STAT_SOURCES[source]
  return entry and entry[stattype] or nil
end

--- The value of one statistic out of a flight record: the flight in progress if it has taken a
--- value for it, the flight that ended otherwise. `flight` is rfsuite.session.flight, which the
--- dashboard also publishes on its own state.
function Utils.statFromRecord(flight, key)
  if key == nil or type(flight) ~= "table" then return nil end
  local record = flight.current
  local value = record and record[key]
  if value ~= nil then return value end
  record = flight.last
  return record and record[key]
end

--- The flight statistic a box asks for, for a caller that has a state rather than a key. Same
--- mapping, one read.
function Utils.statValue(state, source, stattype)
  if type(state) ~= "table" then return nil end
  return Utils.statFromRecord(state.flight, Utils.statFields(source, stattype))
end

function Utils.applyTransform(value, transform)
  if value == nil then return value end
  if transform == "floor" and type(value) == "number" then
    return math.floor(value)
  end
  if transform == "ceil" and type(value) == "number" then
    return math.ceil(value)
  end
  if transform == "round" and type(value) == "number" then
    return math.floor(value + 0.5)
  end
  if type(transform) == "number" and type(value) == "number" then
    return value * transform
  end
  return value
end

function Utils.formatDisplayValue(value, decimals)
  if value == nil then return "--" end
  if type(value) == "number" then
    if type(decimals) == "number" then
      return string.format("%." .. tostring(decimals) .. "f", value)
    end
    return tostring(math.floor(value + 0.5))
  end
  return tostring(value)
end

function Utils.appendUnit(valueText, unit)
  if unit == nil or unit == "" then return valueText end
  return valueText .. tostring(unit)
end

function Utils.normalizeAlign(align, fallback)
  if type(align) == "function" then
    return function()
      local a = align()
      if type(a) == "number" then return a end
      if type(a) == "string" then
        local token = string.lower(a)
        if token == "left" then return LEFT end
        if token == "right" then return RIGHT end
        if token == "center" or token == "centre" then return CENTER end
      end
      return fallback or CENTER
    end
  end
  if type(align) == "number" then return align end
  if type(align) ~= "string" then return fallback or CENTER end

  local token = string.lower(align)
  if token == "left" then return LEFT end
  if token == "right" then return RIGHT end
  if token == "center" or token == "centre" then return CENTER end
  return fallback or CENTER
end

function Utils.normalizeColor(color, fallback)
  if type(color) == "function" then
    return function()
      local c = color()
      if type(c) == "number" then return c end
      if type(c) == "string" then
        local mapped = COLOR_NAME_MAP[string.lower(c)]
        if type(mapped) == "number" then
          return mapped
        end
      end
      return fallback or WHITE
    end
  end
  if type(color) == "number" then return color end
  if type(color) == "string" then
    local mapped = COLOR_NAME_MAP[string.lower(color)]
    if type(mapped) == "number" then
      return mapped
    end
  end
  if type(fallback) == "number" then return fallback end
  return WHITE
end

function Utils.cToF(c)
  if type(c) == "number" then
    return (c * 9 / 5) + 32
  end
  return c
end

local thresholdCache = setmetatable({}, { __mode = "k" })

local function hasTextThresholds(thresholds)
  if type(thresholds) ~= "table" then return false end
  for i = 1, #thresholds do
    local t = thresholds[i]
    if type(t) == "table" and (t.textcolor ~= nil or t.color ~= nil) then
      return true
    end
  end
  return false
end

function Utils.hasTextThresholds(thresholds)
  return hasTextThresholds(thresholds)
end

function Utils.compiledThresholds(box, thresholds, isFahrenheit, state)
  local cached = box and thresholdCache[box] or nil
  if cached and cached.src == thresholds and cached.fahrenheit == isFahrenheit then
    return cached.list
  end
  local list = {}
  local dynamic = false
  for i = 1, #thresholds do
    local threshold = thresholds[i]
    if type(threshold) == "table" then
      local limit = threshold.value
      if type(limit) == "function" then
        dynamic = true
        limit = Utils.resolveValue(limit, box, state)
      end
      local rawFill = threshold.fillcolor or threshold.color
      local rawText = threshold.textcolor or threshold.color
      if type(rawFill) == "function" then
        dynamic = true
        rawFill = Utils.resolveValue(rawFill, box, state)
      end
      if type(rawText) == "function" then
        dynamic = true
        rawText = Utils.resolveValue(rawText, box, state)
      end
      local fillCol = nil
      if rawFill ~= nil then
        fillCol = Utils.normalizeColor(rawFill, nil)
      end
      local textCol = nil
      if rawText ~= nil then
        textCol = Utils.normalizeColor(rawText, nil)
      end
      if type(limit) == "number" then
        list[#list + 1] = {
          value = (isFahrenheit == true) and Utils.cToF(limit) or limit,
          fillcolor = fillCol,
          textcolor = textCol,
          color = textCol or fillCol
        }
      elseif type(limit) == "string" then
        local normalizedLimit = Utils.normalizeTitle(limit, state and state.i18n) or limit
        list[#list + 1] = {
          value = normalizedLimit,
          isString = true,
          fillcolor = fillCol,
          textcolor = textCol,
          color = textCol or fillCol
        }
      end
    end
  end
  if box and not dynamic then
    thresholdCache[box] = { src = thresholds, fahrenheit = isFahrenheit, list = list }
  end
  return list
end

function Utils.resolveThresholdColor(value, thresholds, defaultColor, isFahrenheit, box, state, colorKey, compiled)
  if value == nil or type(thresholds) ~= "table" or #thresholds == 0 then
    return defaultColor
  end

  -- `compiled` is what Utils.renderThresholds produced for this box when the scene was built. It
  -- is used only while it still describes this very threshold table under this temperature unit,
  -- so a caller that hands over the wrong one, or none at all, compiles here exactly as before.
  local fahrenheit = isFahrenheit == true
  local list
  if type(compiled) == "table" and compiled.src == thresholds and compiled.fahrenheit == fahrenheit then
    list = compiled.list
  else
    list = Utils.compiledThresholds(box, thresholds, fahrenheit, state)
  end
  for i = 1, #list do
    local item = list[i]
    local matched = false
    if type(value) == "number" and type(item.value) == "number" then
      if value <= item.value then
        matched = true
      end
    elseif item.isString or type(value) == "string" or type(item.value) == "string" then
      if tostring(value) == tostring(item.value) then
        matched = true
      end
    end

    if matched then
      local col
      if colorKey == "fillcolor" or colorKey == "fill" then
        col = item.fillcolor
      elseif colorKey == "textcolor" or colorKey == "text" then
        col = item.textcolor
      else
        col = item.textcolor or item.fillcolor or item.color
      end
      return col or defaultColor
    end
  end

  return defaultColor
end

function Utils.resolveTextColor(box, state, fallback, value, isFahrenheit, compiled)
  if value ~= nil and type(box) == "table" and type(box.thresholds) == "table" and #box.thresholds > 0 then
    local threshColor =
      Utils.resolveThresholdColor(value, box.thresholds, nil, isFahrenheit == true, box, state, "textcolor", compiled)
    if threshColor ~= nil then
      return threshColor
    end
  end

  -- The colour no threshold decides, where this render has already resolved it: renderThresholds
  -- fills that in only when box.textcolor and box.bgcolor are both literals, so the chain below
  -- cannot answer differently for as long as this scene is the one on screen.
  if type(compiled) == "table" and compiled.default ~= nil then
    return compiled.default
  end

  local color = Utils.resolveValue(box and box.textcolor, box, state)
  if color ~= nil then
    local normalized = Utils.normalizeColor(color, nil)
    if type(normalized) == "number" then
      return normalized
    end
  end

  local bgColor = Utils.resolveValue(box and box.bgcolor, box, state)
  if bgColor == BLACK or bgColor == COLOR_THEME_SECONDARY2 then
    return WHITE
  end

  if type(fallback) == "number" then
    return fallback
  end

  return WHITE
end

-- Colour and font handed to lvgl as a VALUE rather than as a getter, wherever the box cannot
-- change them.
--
-- lvgl takes a number or a function for `color`, `font` and `align`. A function is kept as a
-- reactive reference and EdgeTX calls it for every object on every foreground pass; a number is
-- applied once when the object is built and costs nothing afterwards. That sweep and the
-- widget's own refresh() share one instruction budget, so a getter that can only ever return
-- the same number is paid for on every pass for an answer that was already known when the scene
-- was built.
--
-- Both helpers return nil when the property is not fixed, which is the caller's signal to keep
-- its getter. A resolved colour or font is never nil, so nil is unambiguous.

--- The text colour, resolved once, or nil if it can move.
--
-- resolveTextColor reads box.textcolor and box.bgcolor and evaluates box.thresholds if present.
-- When neither textcolor nor bgcolor is a function and no thresholds are declared, the answer holds
-- for as long as that table is the one being drawn.
function Utils.staticTextColor(box, state, fallback)
  if type(box) == "table" and (
    type(box.textcolor) == "function" or
    type(box.bgcolor) == "function" or
    (type(box.thresholds) == "table" and hasTextThresholds(box.thresholds))
  ) then
    return nil
  end
  return Utils.resolveTextColor(box, state, fallback)
end

--- The font, resolved once, or nil if either the font or its low-resolution variant is dynamic.
--
-- resolveFont reads the zone size as well, through isLowResolution(state), and that is not a
-- literal. It is still fixed for the lifetime of the scene: the zone size is part of the render
-- key (Engine.renderKey), so a zone that changes size tears the scene down and every object is
-- built again from the current state. A font resolved at build time cannot outlive the size it
-- was resolved for.
function Utils.staticFont(box, state, defaultFont, fontProp, lowResFontProp)
  local mainKey = fontProp or "font"
  local lowKey = lowResFontProp or "font_lowres"
  if type(box) == "table" and (type(box[mainKey]) == "function" or type(box[lowKey]) == "function") then
    return nil
  end
  return Utils.resolveFont(box, state, defaultFont, fontProp, lowResFontProp)
end

--- Everything a box's colours need that a drawn scene cannot change, resolved once, where the box
--- is rendered.
--
-- Returns nil when the box declares no thresholds -- Utils.staticTextColor already answers that
-- case with a plain number -- and otherwise a record the object holds in the closure it gives
-- lvgl and hands back to resolveTextColor / resolveThresholdColor on every frame:
--
--   list        the compiled thresholds
--   src         the threshold table they were compiled from
--   fahrenheit  the temperature unit they were compiled under
--   default     the colour a value falls back to when no threshold matches it, left nil while
--               box.textcolor or box.bgcolor is a function and so can still move
--
-- Utils.compiledThresholds caches its result on the box, but only while every limit and every
-- colour in the list is a literal: one threshold whose `value` is a function marks the list
-- dynamic, the cache is skipped, and the whole list is rebuilt and re-normalised on every value
-- change -- in the reactive sweep, on whatever instruction budget refresh() left over. What such a
-- function reads is the theme's own configuration, and nothing can change that under a scene that
-- is already drawn: widgets/dashboard/runtime.lua's reloadActiveTheme is the only writer that can
-- put a different configuration on the state, and it clears `built` and `renderKey` in the same
-- call; applyThemeConfig, the one other writer, is reached only from updateVoltageThemeConfig,
-- whose next configuration is a copy of the current one with v_min and v_max rewritten, and it
-- clears those same two fields whenever either of them moves.
--
-- Compiling here also takes the FIRST resolution of a string threshold and of a named colour out
-- of the sweep that follows the swap, which is the pass with the least budget left.
function Utils.renderThresholds(box, state, isFahrenheit, fallback)
  local thresholds = type(box) == "table" and box.thresholds or nil
  if type(thresholds) ~= "table" or #thresholds == 0 then return nil end

  local fahrenheit = isFahrenheit == true
  local compiled = {
    src = thresholds,
    fahrenheit = fahrenheit,
    list = Utils.compiledThresholds(box, thresholds, fahrenheit, state)
  }
  if type(box.textcolor) ~= "function" and type(box.bgcolor) ~= "function" then
    compiled.default = Utils.resolveTextColor(box, state, fallback)
  end
  return compiled
end

function Utils.pushLabel(nodes, x, y, w, text, color, align, font)
  nodes[#nodes + 1] = {
    type = "label",
    x = x,
    y = y,
    w = w,
    text = text,
    color = Utils.normalizeColor(color, WHITE),
    align = Utils.normalizeAlign(align, CENTER),
    font = font
  }
end

function Utils.isLowResolution(state)
  local w = tonumber(state and state.zoneW) or tonumber(LCD_W) or 0
  local h = tonumber(state and state.zoneH) or tonumber(LCD_H) or 0
  return (w > 0 and w <= 480) or (h > 0 and h <= 176)
end

function Utils.truncateText(text, maxChars)
  if type(text) ~= "string" then return text end
  local limit = tonumber(maxChars)
  if not limit or limit <= 0 then return text end
  if #text <= limit then return text end
  if limit <= 3 then
    return string.sub(text, 1, limit)
  end
  return string.sub(text, 1, limit - 3) .. "..."
end

function Utils.applyLowResMaxChars(text, box, state, prop)
  if not Utils.isLowResolution(state) then return text end
  local key = prop or "max_chars_lowres"
  local limit = Utils.resolveValue(box and box[key], box, state)
  return Utils.truncateText(text, limit)
end

function Utils.resolveFont(box, state, defaultFont, fontProp, lowResFontProp)
  local mainKey = fontProp or "font"
  local lowKey = lowResFontProp or "font_lowres"

  local font = Utils.resolveValue(box and box[mainKey], box, state)
  if Utils.isLowResolution(state) then
    local lowFont = Utils.resolveValue(box and box[lowKey], box, state)
    if lowFont ~= nil then
      return lowFont
    end
  end

  return font or defaultFont
end

function Utils.defaultValueY(rect, box)
  local titlePos = box and box.titlepos or "top"
  local valueY = rect.y + math.max(14, math.floor(rect.h * 0.45))
  if titlePos == "bottom" then
    valueY = rect.y + math.max(8, math.floor(rect.h * 0.35)) - 4
  end
  local valueOffsetY = Utils.toNumber(Utils.resolveValue(box and box.value_offset_y, box, nil), 0)
  valueY = valueY + valueOffsetY
  return valueY
end

function Utils.drawContainer(nodes, rect, box, state)
  nodes[#nodes + 1] = {
    type = "rectangle",
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
    color = box.bgcolor or WHITE,
    filled = true
  }

  -- Titel-Cache pro Box
  box._lastTitleRaw = box._lastTitleRaw or nil
  box._lastTitle = box._lastTitle or nil
  local rawTitle = Utils.resolveValue(box.title, box, state)
  if box._lastTitleRaw ~= rawTitle then
    box._lastTitle = Utils.normalizeTitle(rawTitle, state and state.i18n)
    box._lastTitleRaw = rawTitle
  end
  local title = box._lastTitle
  if not title then return end

  if Utils.isLowResolution(state) then
    local lowTitle = Utils.resolveValue(box.title_lowres, box, state)
    if type(lowTitle) == "string" and lowTitle ~= "" then
      title = lowTitle
    end
  end

  title = Utils.applyLowResMaxChars(title, box, state, "title_max_chars_lowres")

  local titlePos = box.titlepos or "top"
  local titleY = titlePos == "bottom" and (rect.y + rect.h - 24) or (rect.y + 4)
  local titleOffsetY = Utils.toNumber(Utils.resolveValue(box and box.title_offset_y, box, state), 0)
  if Utils.isLowResolution(state) then
    titleOffsetY = Utils.toNumber(
      Utils.resolveValue(box and box.title_offset_y_lowres, box, state),
      titleOffsetY
    )
  end
  titleY = titleY + titleOffsetY
  Utils.pushLabel(
    nodes,
    rect.x + 4,
    titleY,
    rect.w - 8,
    title,
    box.titlecolor or COLOR_THEME_DISABLED,
    box.titlealign or CENTER,
    Utils.resolveFont(box, state, SMLSIZE, "titlefont", "titlefont_lowres")
  )
end

if type(_G) == "table" then _G.__rfsuiteObjectsCommonModule = Utils end
return Utils
