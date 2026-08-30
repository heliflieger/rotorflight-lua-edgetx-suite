local Runtime = {}

local SYSTEM_THEME_BASE = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/"
local USER_THEME_BASE = "/SCRIPTS/TOOLS/rfsuite.user/dashboard/"
local AUDIO_LOG_FORCE = false
local SPLASH_READY_HOLD_SECONDS = 1.0
-- The steady-state pass rate, and the faster one used only while a start is in progress.
--
-- Everything the widget does per pass is behind this gate, and during the connect chain that
-- includes advancing the chain itself: one task per pass, one queue turn per pass, a dozen
-- round trips end to end. There the pass rate IS the start duration. Once the dashboard is up
-- nothing is left that a faster pass would finish sooner -- the repaint is throttled to 2 Hz
-- of its own accord -- and this runs in the Lua state every widget on the radio shares, so the
-- steady-state rate is left exactly where it was.
local LOGIC_TICK_SECONDS = 0.1
local LOGIC_TICK_STARTING_SECONDS = 0.05
local SPLASH_SOFT_TIMEOUT_SECONDS = 25.0


local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", "t")
  if rChunk then
    requireModule = rChunk()
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")
local PreferencesModule = requireModule("lib/preferences.lua")
local DashboardAudio = requireModule("lib/audio.lua")
local DashboardSplash = requireModule("widgets/dashboard/splash.lua")
local MspRuntime = requireModule("tasks/msp/runtime.lua")
local I18nModule = requireModule("i18n/init.lua")
local Sensors = requireModule("lib/sensors.lua")
local LogSink = requireModule("lib/log_sink.lua")
if LogSink and type(LogSink.configure) == "function" then
  LogSink.configure("widget")
end

local RSS1_SOURCES = { "1RSS", "RSS1", "rssi1" }
local RSS2_SOURCES = { "2RSS", "RSS2", "rssi2" }
local THROTTLE_INFLIGHT_THRESHOLD = 35
local THROTTLE_INFLIGHT_THRESHOLD_DIRECT = 8
local RPM_INFLIGHT_THRESHOLD_DIRECT = 500
local CURRENT_INFLIGHT_THRESHOLD_DIRECT = 8

local utils = {}

local function isTruthy(value)
  return value == true or value == 1 or value == "1" or value == "true"
end

local function shouldLogAudio(self)
  if AUDIO_LOG_FORCE then return true end
  local prefs = self and self.preferences
  local general = prefs and prefs.general
  return isTruthy(general and general.developer_tools)
end

function utils.log(self, msg, level)
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.audio", msg, level, shouldLogAudio(self))
  end
end

local function audioLog(self, msg, level)
  utils.log(self, msg, level)
end

local function widgetLog(self, msg, level)
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.widget", msg, level or "debug", true)
  end
end

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

local function readValue(name, fallback)
  if not getValue then return fallback end
  local ok, value = pcall(getValue, name)
  if not ok or value == nil then return fallback end
  return value
end

local function processAudioEvents(self)
  if DashboardAudio and type(DashboardAudio.process) == "function" then
    local modelName = nil
    if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
      modelName = _G.rfsuite.session.modelName
    end
    self.modelName = modelName
    -- Built once per widget, not once per pass: this runs on every logic tick, and a fresh
    -- options table plus a fresh closure per tick is steady-state garbage in the Lua state
    -- every widget on the radio shares. Audio.process itself throttles to 0.25-0.6 s, so most
    -- of those allocations were for calls that returned immediately.
    local opts = self._audioOpts
    if not opts then
      opts = {
        log = function(msg, level)
          audioLog(self, msg, level)
        end
      }
      self._audioOpts = opts
    end
    DashboardAudio.process(self, opts)
    return
  end

  if self and self.audioState and not self.audioState.initialized then
    self.audioState.initialized = true
  end
end

local EventsRuntime = requireModule("tasks/events/runtime.lua")

-- Both widgets run in one Lua state and share the one ring in it, so exactly one of them may
-- write it out -- two writers would append to the same file from two places and interleave.
-- widgets/service/runtime.lua is the better owner, because its background() runs while it is off
-- screen, and it announces itself to the MSP runtime under this name when it attaches. Where it
-- is not on the model there is nobody to defer to and this runtime writes instead.
local function serviceWidgetOwnsTheSink()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return false end
  local runtimeState = MspRuntime.getState()
  if type(runtimeState) ~= "table" or type(runtimeState.clients) ~= "table" then return false end
  return runtimeState.clients["service-widget"] == true
end

local function tickCardSink(self)
  if not LogSink or type(LogSink.tick) ~= "function" then return end
  if serviceWidgetOwnsTheSink() then return end

  local armed = false
  if MspRuntime and type(MspRuntime.getState) == "function" then
    local runtimeState = MspRuntime.getState()
    armed = type(runtimeState) == "table" and runtimeState.lastArmed == true
  end
  pcall(LogSink.tick, armed)
end

local function tickMspRuntime(self)
  tickCardSink(self)

  if not MspRuntime then
    return
  end

  if not self.mspAttached and type(MspRuntime.attach) == "function" then
    MspRuntime.attach("dashboard-widget")
    self.mspAttached = true
  end

  if type(MspRuntime.tick) ~= "function" then
    return
  end

  MspRuntime.tick()
  
  if EventsRuntime and type(EventsRuntime.wakeup) == "function" then
    pcall(EventsRuntime.wakeup)
  end

  -- The wakeup above is what FILLS the queue while the connect chain runs. Without a second
  -- turn here every request it enqueues waits for the next host tick before it is even looked
  -- at, which on a chain of a dozen serial round trips is a dozen ticks of pure waiting.
  if type(MspRuntime.pump) == "function" then
    MspRuntime.pump()
  end
end

local function buildConnectionSplash(zone, statusLine, title)
  if DashboardSplash and type(DashboardSplash.build) == "function" then
    return DashboardSplash.build(zone, statusLine, title)
  end

  local w = (zone and zone.w) or LCD_W or 320
  local h = (zone and zone.h) or LCD_H or 172
  return {
    {
      type = "rectangle",
      x = 0,
      y = 0,
      w = w,
      h = h,
      color = COLOR_THEME_PRIMARY2,
      filled = true
    }
  }
end

local function loadPreferences()
  if not PreferencesModule or type(PreferencesModule.load) ~= "function" then
    return nil
  end
  local loadedOk, prefs = pcall(PreferencesModule.load)
  if not loadedOk or type(prefs) ~= "table" then
    return nil
  end
  return prefs
end

--- The files the tool writes when a preference changes, and how often they are looked at.
-- One second is the rate the old signal was polled at, so nothing gets slower here.
local PREFERENCES_FILE = "/SCRIPTS/TOOLS/rfsuite.user/preferences.ini"
local PREFS_STAT_INTERVAL = 1.0

local function publishPreferencesToGlobal(prefs)
  if type(_G) ~= "table" then return end
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.preferences = prefs or {}
end

local function logGv(fmt, ...)
  -- Gated the way the tool gates its own file logger. Ungated, every call here opens,
  -- appends to and closes a file on the SD card -- and the callers are on the widget's
  -- refresh and background passes rather than on anything the pilot did, so it runs for
  -- the whole flight on every model that carries the widget.
  --
  -- The message is assembled HERE, after the gate, rather than by the caller: with the
  -- test inside the function the callers still paid for a string that was then dropped,
  -- and one of them sits on the unconditional path of every background pass.
  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local general = prefs and prefs.general
  local debugLevel = general and general.debug_level
  if debugLevel ~= "debug" and debugLevel ~= "info" then return end

  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end

  local fLog = io.open("/SCRIPTS/TOOLS/rfsuite.user/gv_debug.log", "a")
  if fLog then
    local t = (getTime and getTime()) or 0
    io.write(fLog, string.format("[%.2f][Runtime] %s\n", t / 100, msg))
    io.close(fLog)
  end
  if print then pcall(print, "[Runtime] " .. msg) end
end

--- What the preference files look like right now: size and mtime, as one string.
--
-- `fstat` is a global in this firmware and returns { size, attrib, time }. Comparing that
-- is a STATE comparison rather than a signal, and the difference is the whole point: a
-- signal is consumed by whoever reads it first, a state is not.
--
-- FAT stores mtime at two-second granularity and depends on the RTC, so two writes inside
-- one second can share a timestamp. That is why the size is part of the stamp.
-- `fstat` returns the modification time as a TABLE -- year, mon, day, hour, min, sec and more
-- (radio/src/lua/api_filesystem.cpp) -- not as a number. `tostring()` on it is therefore a table
-- ADDRESS, which is different on every call, so a stamp built that way never equals the previous
-- one and a comparison against it reports a change every single time.
--
-- The fields are what identify the file, so the fields are what the stamp is built from. FAT
-- stores seconds in two-second steps, which bounds how close together two writes can be and
-- still be told apart; the size is exact and carries the rest.
local function stampOf(info)
  if type(info) ~= "table" then return nil end
  local t = info.time
  if type(t) ~= "table" then
    -- Not the documented shape. Whatever it is, it is at least not an address.
    return tostring(info.size) .. ":" .. tostring(t)
  end
  return string.format("%s:%s-%s-%s.%s.%s.%s",
    tostring(info.size), tostring(t.year), tostring(t.mon), tostring(t.day),
    tostring(t.hour), tostring(t.min), tostring(t.sec))
end

local function preferencesStamp(modelPath)
  if type(fstat) ~= "function" then return nil end
  local out = ""
  local okg, g = pcall(fstat, PREFERENCES_FILE)
  if okg then
    out = stampOf(g) or ""
  end
  if modelPath then
    local okm, m = pcall(fstat, modelPath)
    if okm then
      local ms = stampOf(m)
      if ms then out = out .. "|" .. ms end
    end
  end
  return out
end

local function reloadPreferencesIfNeeded(self, force)
  local now = nowSeconds()

  -- The stamp that a completed reload will adopt. Held back on purpose -- see the armed
  -- guard below.
  local pendingStamp = nil
  local signalReload = false
  if not force and (now - (self._lastPrefsStatAt or 0)) >= PREFS_STAT_INTERVAL then
    self._lastPrefsStatAt = now
    -- The per-model file's path lives on the session rather than on `self` -- the same
    -- shape this file already uses to reach `modelPreferences` twice further down.
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local stamp = preferencesStamp(session and session.modelPreferencesFile)
    if stamp then
      if self._lastPrefsStamp == nil then
        -- First look. The preferences in hand were loaded from these very files, so this
        -- is a baseline and never a reload.
        self._lastPrefsStamp = stamp
      elseif stamp ~= self._lastPrefsStamp then
        signalReload = true
        pendingStamp = stamp
      end
    end
  end

  if not force and not signalReload then
    return
  end

  -- Safety: Do not reload files while ARMED or during periodic postflight offline to prevent CPU spikes or UI resets.
  -- Forced reloads (e.g. at connection state flips or explicit reloads) are still honored.
  --
  -- Returning here does NOT lose the change: `pendingStamp` is not adopted, so the next
  -- pass after disarming sees the same difference and reloads then. With the old signal
  -- the flag had already been read and reset above this guard, so a save made while armed
  -- was gone with nothing left to re-signal it.
  if self.state.armed or (not force and self.state.hadInflightFlight == true and not self.state.fblConnected) then
    return
  end

  logGv("reloadPreferencesIfNeeded executing (force=%s signal=%s)", tostring(force), tostring(signalReload))
  if pendingStamp then self._lastPrefsStamp = pendingStamp end

  local prefs = loadPreferences()
  if type(prefs) == "table" then
    self.preferences = prefs
    publishPreferencesToGlobal(prefs)
    
    -- Expose i18n on the runtime state so theme renderers can access it
    if self.i18n then
      if type(self.state) ~= "table" then self.state = {} end
      self.state.i18n = self.i18n
    end

    -- Reload model-specific preferences from disk if MCU ID is available
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    if session and session.mcu_id then
      local MP = requireModule("lib/model_preferences.lua")
      if MP and type(MP.loadByMcuId) == "function" then
        local mPrefs, mPath = MP.loadByMcuId(session.mcu_id)
        if mPrefs then
          session.modelPreferences = mPrefs
          session.modelPreferencesFile = mPath
          self.modelPreferences = mPrefs
          logGv("Loaded model prefs from disk: %s", tostring(mPath))
        end
      end
    else
      logGv("No session.mcu_id available during reloadPreferencesIfNeeded")
    end

    -- Invalidate current theme and force immediate reload
    self.theme = nil
    self.themePath = nil
    self.built = false
    self.renderKey = nil
    self._cachedRenderKey = nil
    self.lastModelPreferences = nil
    self._lastUIRefresh = 0
  end

  self.preferencesLastLoadedAt = now
end

local function updateConnectionState(self)
  local runtimeState = nil
  local mspProgress = nil
  if MspRuntime and type(MspRuntime.getState) == "function" then
    runtimeState = MspRuntime.getState()
  elseif Rf2Runtime and type(Rf2Runtime.getState) == "function" then
    runtimeState = Rf2Runtime.getState()
  end
  if MspRuntime and type(MspRuntime.getProgress) == "function" then
    mspProgress = MspRuntime.getProgress()
  end
  local connected = type(runtimeState) == "table" and runtimeState.lastConnected == true
  local hasVoltage = type(self.state.voltage) == "number" and self.state.voltage > 0
  -- The FLAG and not the value. readTelemetry sets `fuelTelemetrySeen` only once a fuel or
  -- smartfuel sensor has actually produced a number, while `state.fuel` is initialised to 0 in
  -- the widget's default state. Read off the value, the test was `0 >= 0` from the first pass,
  -- so `batteryReady` below was satisfied before any telemetry had arrived and the
  -- "waiting for battery telemetry" status line could never be reached.
  local hasFuel = self.state.fuelTelemetrySeen == true
  local hasLq = type(self.state.lq) == "number" and self.state.lq ~= 0
  local hasRss1 = type(self.state.rss1) == "number" and self.state.rss1 ~= 0
  local hasRss2 = type(self.state.rss2) == "number" and self.state.rss2 ~= 0
  local batteryReady = hasVoltage or hasFuel
  local rfReady = hasLq or hasRss1 or hasRss2
  
  local tasksDone = true
  if mspProgress and type(mspProgress.total) == "number" and type(mspProgress.done) == "number" then
    tasksDone = (mspProgress.done >= mspProgress.total)
  end

  local onconnectActive = false
  local onconnectProgress = nil
  local onconnectPendingTaskName = nil
  if EventsRuntime and type(EventsRuntime.isOnconnectActive) == "function" then
    onconnectActive = EventsRuntime.isOnconnectActive()
  end
  if EventsRuntime and type(EventsRuntime.getOnconnectProgress) == "function" then
    onconnectProgress = EventsRuntime.getOnconnectProgress()
  end
  if EventsRuntime and type(EventsRuntime.getOnconnectPendingTaskName) == "function" then
    onconnectPendingTaskName = EventsRuntime.getOnconnectPendingTaskName()
  end

  local onconnectDone = false
  if onconnectProgress and type(onconnectProgress.total) == "number" and type(onconnectProgress.done) == "number" then
    onconnectDone = (onconnectProgress.total > 0 and onconnectProgress.done >= onconnectProgress.total)
  end

  if onconnectActive and not onconnectDone then
    tasksDone = false
  end
  
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local modelPrefsResolved = (session == nil)
    or session.modelPreferencesResolved == true
    or onconnectDone

  -- What has to be true before the dashboard is DRAWN, and it deliberately no longer includes
  -- the entire connect chain. Every value those tasks fill has a themed fallback -- the flight count
  -- starts at 0, the dataflash bar is guarded on `state.dataflash`, and the cell count is
  -- inferred from the pack voltage until `battery_config` arrives -- so the chain decides how
  -- COMPLETE the dashboard is, not whether it can be shown. It is a strictly serial run of a
  -- dozen MSP round trips, and behind this gate it was the whole screen's critical path.
  --
  -- However, we must wait for UID resolution (`modelPrefsResolved`) so that model-specific theme
  -- overrides are known before dismissing the splash. This prevents theme pop-in without forcing
  -- the screen to wait for all remaining connect tasks.
  --
  -- `tasksDone` is still computed: it names the pending task in the status line below, and
  -- `startupComplete` keeps the audio on exactly the condition it had before.
  local rawReady = connected and batteryReady and rfReady and modelPrefsResolved
  local now = nowSeconds()

  if connected and not rawReady then
    if not self.pendingSince then
      self.pendingSince = now
    end
  else
    self.pendingSince = nil
  end

  if rawReady then
    if not self.readySince then
      self.readySince = now
    end
  else
    self.readySince = nil
  end

  local softTimeoutReady = connected and self.pendingSince ~= nil and (now - self.pendingSince) >= SPLASH_SOFT_TIMEOUT_SECONDS
  -- The hold steadies a gate that flickers, and a flicker is a gate that has been open and has
  -- shut again. The FIRST time the conditions come true after the widget starts is not that:
  -- they have been false since boot and are now true. Spending the hold there costs a second of
  -- splash at the one moment the screen is being waited for.
  --
  -- `everReady` is therefore set where the gate CLOSES after having been open, and not where it
  -- opens. Set on the opening, the very next pass would weigh the full hold against a
  -- `readySince` one pass old and shut the gate again for the rest of it -- the dashboard would
  -- appear for one frame, vanish, and come back a second later.
  local holdSeconds = self.everReady and SPLASH_READY_HOLD_SECONDS or 0
  local ready = (rawReady and self.readySince ~= nil and (now - self.readySince) >= holdSeconds) or softTimeoutReady
  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil

  local statusLine = nil
  if not connected then
    statusLine = (t and t("widgets.dashboard.waiting_for_msp_link")) or "Waiting for MSP link"
    self.batteryDialogState = "pending"
  elseif not tasksDone then
    local pDone = 0
    local pTotal = 0
    local showNumbers = false
    if onconnectProgress and onconnectProgress.total > 0 then
      pDone = onconnectProgress.done or 0
      pTotal = onconnectProgress.total or 0
      showNumbers = true
    end
    local loadingTasksStr = (t and t("widgets.dashboard.loading_tasks")) or "Loading data..."
    if showNumbers then
      statusLine = loadingTasksStr .. " (" .. tostring(pDone) .. "/" .. tostring(pTotal) .. ")"
    else
      statusLine = loadingTasksStr
    end
    if onconnectPendingTaskName and onconnectPendingTaskName ~= "" then
      statusLine = statusLine .. " [" .. tostring(onconnectPendingTaskName) .. "]"
    end
  elseif not rfReady then
    statusLine = (t and t("widgets.dashboard.waiting_for_receiver_telemetry")) or "Waiting for receiver telemetry (1RSS/2RSS)"
  elseif not batteryReady then
    statusLine = (t and t("widgets.dashboard.waiting_for_battery_telemetry")) or "Waiting for battery telemetry"
  elseif not ready then
    statusLine = (t and t("widgets.dashboard.connected_starting")) or "Connected, starting dashboard..."
  elseif softTimeoutReady then
    statusLine = "Connected with partial telemetry"
  end

  if self.connectionReady ~= ready then
    local wasReady = self.connectionReady == true
    self.connectionReady = ready
    self.built = false
    self.renderKey = nil
    if ready then
      widgetLog(self, "FBL connected and telemetry initialized", "info")
      if softTimeoutReady then
        widgetLog(self, "Splash soft-timeout reached; continuing without full startup prerequisites", "warn")
      end
      -- Force reload preferences when connection ready to ensure we have the latest model settings
      reloadPreferencesIfNeeded(self, true)
    else
      -- Open, and shut again: from here on there is something to steady and the hold is paid.
      if wasReady then self.everReady = true end
      widgetLog(self, "FBL not ready yet", "info")
      if self.audioState and DashboardAudio and type(DashboardAudio.resetConnectionState) == "function" then
        DashboardAudio.resetConnectionState(self.audioState)
      elseif self.audioState then
        self.audioState.initialized = false
        self.audioState.modelAnnounced = false
      end
    end
  end

  self.state.fblConnected = connected
  self.state.connectionReady = ready
  -- Kept apart from `ready` on purpose. Drawing may start before the connect chain has run;
  -- announcing the model may not, because the announcement needs the name that chain reads.
  -- This is the condition `ready` itself carried before the chain left the gate above, soft
  -- timeout included, so the audio path sees no change at all.
  self.startupComplete = ready and (tasksDone or softTimeoutReady)
  return ready, statusLine
end

local function readFirstNumber(names, fallback)
  if type(names) ~= "table" then
    return fallback
  end

  for i = 1, #names do
    local value = readValue(names[i], nil)
    if type(value) == "number" then
      return value
    end
    if type(value) == "string" then
      local numeric = tonumber(value)
      if type(numeric) == "number" then
        return numeric
      end
    end
  end

  return fallback
end

local function roundInt(value, fallback)
  if type(value) ~= "number" then
    return fallback
  end
  return math.floor(value + 0.5)
end

local function normalizeCellVoltage(value, fallback)
  local v = tonumber(value)
  if type(v) ~= "number" or v <= 0 then
    return fallback
  end
  -- Accept common storage encodings:
  -- volts (4.2), decivolts (42), centivolts (420), millivolts (4200).
  if v > 1000 then
    v = v / 1000
  elseif v > 100 then
    v = v / 100
  elseif v > 10 then
    v = v / 10
  end
  if v <= 0 then
    return fallback
  end
  return v
end

local function updateDerivedFlightState(state)
  local now = nowSeconds()
  local lastTick = state.lastTickAt or now
  local delta = now - lastTick
  if delta < 0 or delta > 5 then
    delta = 0
  end
  state.lastTickAt = now

  local wasArmed = state.wasArmed == true
  local isArmed = state.armed == true

  if isArmed and not wasArmed then
    state.currentFlightSeconds = 0
    state.currentFlightMinVoltage = nil
    state.currentFlightMinLq = nil
    state.currentFlightMaxThrottlePercent = nil
    state.currentFlightMaxRpm = nil
    state.currentFlightMinRpm = nil
    state.currentFlightMaxCurrent = nil
    state.currentFlightMinCurrent = nil
    state.currentFlightMaxWatts = nil
    state.currentFlightMaxAltitude = nil
    state.currentFlightMaxEscTemp = nil
    state.currentFlightMaxMcuTemp = nil
    state.currentFlightMinFuel = nil
    state.hadArmedFlight = true
  end

  if isArmed then
    state.currentFlightSeconds = (state.currentFlightSeconds or 0) + delta
    state.totalFlightSeconds = (state.totalFlightSeconds or 0) + delta

    if type(state.throttlePercent) == "number" then
      local currentMaxThrottle = state.currentFlightMaxThrottlePercent
      if currentMaxThrottle == nil or state.throttlePercent > currentMaxThrottle then
        state.currentFlightMaxThrottlePercent = state.throttlePercent
      end
    end

    if type(state.rpm) == "number" then
      local currentMaxRpm = state.currentFlightMaxRpm
      if currentMaxRpm == nil or state.rpm > currentMaxRpm then
        state.currentFlightMaxRpm = state.rpm
      end

      if state.rpm > 0 then
        local currentMinRpm = state.currentFlightMinRpm
        if currentMinRpm == nil or state.rpm < currentMinRpm then
          state.currentFlightMinRpm = state.rpm
        end
      end
    end

    if type(state.current) == "number" then
      local currentMaxCurrent = state.currentFlightMaxCurrent
      if currentMaxCurrent == nil or state.current > currentMaxCurrent then
        state.currentFlightMaxCurrent = state.current
      end

      local currentMinCurrent = state.currentFlightMinCurrent
      if currentMinCurrent == nil or state.current < currentMinCurrent then
        state.currentFlightMinCurrent = state.current
      end
    end

    if type(state.watts) == "number" then
      local currentMaxWatts = state.currentFlightMaxWatts
      if currentMaxWatts == nil or state.watts > currentMaxWatts then
        state.currentFlightMaxWatts = state.watts
      end
    end

    if type(state.altitude) == "number" then
      local currentMaxAltitude = state.currentFlightMaxAltitude
      if currentMaxAltitude == nil or state.altitude > currentMaxAltitude then
        state.currentFlightMaxAltitude = state.altitude
      end
    end

    if type(state.escTemp) == "number" then
      local currentMaxEscTemp = state.currentFlightMaxEscTemp
      if currentMaxEscTemp == nil or state.escTemp > currentMaxEscTemp then
        state.currentFlightMaxEscTemp = state.escTemp
      end
    end

    if type(state.mcuTemp) == "number" then
      local currentMaxMcuTemp = state.currentFlightMaxMcuTemp
      if currentMaxMcuTemp == nil or state.mcuTemp > currentMaxMcuTemp then
        state.currentFlightMaxMcuTemp = state.mcuTemp
      end
    end

    if state.fuelTelemetrySeen == true and type(state.fuel) == "number" then
      local currentMinFuel = state.currentFlightMinFuel
      if currentMinFuel == nil or state.fuel < currentMinFuel then
        state.currentFlightMinFuel = state.fuel
      end
    end

    if type(state.voltage) == "number" and state.voltage > 0 then
      local currentMinVoltage = state.currentFlightMinVoltage
      if currentMinVoltage == nil or state.voltage < currentMinVoltage then
        state.currentFlightMinVoltage = state.voltage
      end
    end

    if type(state.lq) == "number" and state.lq > 0 then
      local currentMinLq = state.currentFlightMinLq
      if currentMinLq == nil or state.lq < currentMinLq then
        state.currentFlightMinLq = state.lq
      end
    end
  elseif wasArmed then
    state.lastFlightSeconds = state.currentFlightSeconds or 0
    if (state.currentFlightSeconds or 0) >= 1 then
      state.flights = (state.flights or 0) + 1
    end
    state.lastDisarmAt = now
    state.hadArmedFlight = true
    state.lastFlightMaxThrottlePercent = state.currentFlightMaxThrottlePercent
    state.lastFlightMaxRpm = state.currentFlightMaxRpm
    state.lastFlightMinRpm = state.currentFlightMinRpm
    state.lastFlightMaxCurrent = state.currentFlightMaxCurrent
    state.lastFlightMinCurrent = state.currentFlightMinCurrent
    state.lastFlightMaxWatts = state.currentFlightMaxWatts
    state.lastFlightMaxAltitude = state.currentFlightMaxAltitude
    state.lastFlightMaxEscTemp = state.currentFlightMaxEscTemp
    state.lastFlightMaxMcuTemp = state.currentFlightMaxMcuTemp
    state.lastFlightMinFuel = state.currentFlightMinFuel
    state.lastMinVoltage = state.currentFlightMinVoltage
    state.lastMinLq = state.currentFlightMinLq
    state.currentFlightSeconds = 0
    state.currentFlightMinVoltage = nil
    state.currentFlightMinLq = nil
    state.fuelTelemetrySeen = false
    state.currentFlightMaxThrottlePercent = nil
    state.currentFlightMaxRpm = nil
    state.currentFlightMinRpm = nil
    state.currentFlightMaxCurrent = nil
    state.currentFlightMinCurrent = nil
    state.currentFlightMaxWatts = nil
    state.currentFlightMaxAltitude = nil
    state.currentFlightMaxEscTemp = nil
    state.currentFlightMaxMcuTemp = nil
    state.currentFlightMinFuel = nil
  end

  if isArmed then
    state.flightSeconds = state.currentFlightSeconds or 0
  else
    state.flightSeconds = state.lastFlightSeconds or 0
  end

  state.prevArmed = wasArmed
  state.wasArmed = isArmed
end

local function loadDashboardLib()
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/app/pages/settings/dashboard/lib.lua", "t")
  if not chunk then return nil end
  local ok, lib = pcall(chunk)
  if not ok or type(lib) ~= "table" then return nil end
  return lib
end

local function loadDashboardEngine()
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/engine.lua", "t")
  if not chunk then return nil end
  local ok, engine = pcall(chunk)
  if not ok or type(engine) ~= "table" then return nil end
  return engine
end

local function parseThemePath(raw)
  if type(raw) ~= "string" or raw == "" then
    return "system", "default"
  end
  local slash = string.find(raw, "/", 1, true)
  if not slash then
    return "system", "default"
  end
  local source = string.sub(raw, 1, slash - 1)
  local folder = string.sub(raw, slash + 1)
  if source == "" or folder == "" then
    return "system", "default"
  end
  return source, folder
end

local function loadThemeInit(themePath)
  local source, folder = parseThemePath(themePath)
  local base = source == "user" and USER_THEME_BASE or SYSTEM_THEME_BASE
  local initChunk = loadScript(base .. folder .. "/init.lua", "t")
  if not initChunk then return nil, base, folder end
  local ok, initTable = pcall(initChunk)
  if not ok or type(initTable) ~= "table" then return nil, base, folder end
  return initTable, base, folder
end

local function loadThemeModuleForState(themePath, flightMode)
  local initTable, base, folder = loadThemeInit(themePath)
  local stateKey = (flightMode == "inflight" or flightMode == "postflight") and flightMode or "preflight"

  local stateScript = nil
  if initTable and type(initTable[stateKey]) == "string" and initTable[stateKey] ~= "" then
    stateScript = initTable[stateKey]
  end

  local scriptPath = nil
  if stateScript then
    scriptPath = base .. folder .. "/" .. stateScript
  else
    scriptPath = base .. folder .. "/widget.lua"
  end

  local chunk = loadScript(scriptPath, "t")
  if chunk then
    local ok, theme = pcall(chunk)
    if ok and type(theme) == "table" and (
      type(theme.build) == "function" or
      type(theme.layout) == "table" or
      type(theme.boxes) == "table" or
      type(theme.boxes) == "function"
    ) then
      return theme
    end
  end

  local fallbackPath = SYSTEM_THEME_BASE .. "default/" .. stateKey .. ".lua"
  local fallbackChunk = loadScript(fallbackPath, "t")
  if not fallbackChunk then
    fallbackChunk = loadScript(SYSTEM_THEME_BASE .. "default/preflight.lua", "t")
  end
  if not fallbackChunk then return nil end
  local ok, theme = pcall(fallbackChunk)
  if ok and type(theme) == "table" and (
    type(theme.build) == "function" or
    type(theme.layout) == "table" or
    type(theme.boxes) == "table" or
    type(theme.boxes) == "function"
  ) then
    return theme
  end
  return nil
end

-- Shared stand-in for "no global dashboard section", so that the absence of one is a stable
-- value rather than a fresh table on every call. Without it the memo below can never hit.
local EMPTY_DASHBOARD = {}

-- The answer depends on three things that change rarely: the flight mode, the global dashboard
-- preferences and the model's own. Both preference tables are replaced wholesale when their
-- file is reloaded, so table identity is a generation marker -- the same one the background
-- pass already uses to decide whether the model preferences have changed. Without this memo the
-- resolver runs on every background pass, and so does the log line at the end of it.
local themePathMemo = {}

local function resolveThemePathForState(dashboard, modelPrefs, flightMode)
  if themePathMemo.dashboard == dashboard
    and themePathMemo.modelPrefs == modelPrefs
    and themePathMemo.flightMode == flightMode then
    return themePathMemo.chosen
  end

  local modelDashboard = modelPrefs and modelPrefs.dashboard or {}
  local modelOverride = modelDashboard.model_override == true
  local key = "theme_preflight"
  local modelKey = "model_theme_preflight"

  if flightMode == "inflight" then
    key = "theme_inflight"
    modelKey = "model_theme_inflight"
  elseif flightMode == "postflight" then
    key = "theme_postflight"
    modelKey = "model_theme_postflight"
  end

  local chosen = nil
  local reason = nil
  if modelOverride then
    local modelValue = modelDashboard[modelKey]
    if modelValue and modelValue ~= "" and modelValue ~= "nil" then
      chosen = modelValue
      reason = "model_" .. modelKey
    end
  end

  if not chosen then
    local globalValue = dashboard and dashboard[key] or nil
    if globalValue and globalValue ~= "" and globalValue ~= "nil" then
      chosen = globalValue
      reason = "global_" .. key
    else
      local globalPreflight = dashboard and dashboard["theme_preflight"] or nil
      if globalPreflight and globalPreflight ~= "" and globalPreflight ~= "nil" then
        chosen = globalPreflight
        reason = "global_preflight_fallback"
      else
        chosen = "system/default"
        reason = "default_fallback"
      end
    end
  end

  logGv("resolveTheme: mode=%s, modelOverride=%s, modelKey=%s, modelValue=%s, globalKey=%s, globalValue=%s => chosen=%s (%s)",
    tostring(flightMode), tostring(modelOverride), tostring(modelKey), tostring(modelDashboard[modelKey]),
    tostring(key), tostring(dashboard and dashboard[key]), tostring(chosen), tostring(reason))

  themePathMemo.dashboard = dashboard
  themePathMemo.modelPrefs = modelPrefs
  themePathMemo.flightMode = flightMode
  themePathMemo.chosen = chosen

  return chosen
end

-- Hoisted out of readTelemetry, which runs on every background pass: the per-pass cache and the
-- two helpers below were rebuilt each time, and they are almost everything the pass allocates.
-- The cache is emptied in place rather than replaced, and it keeps the original rule that a nil
-- reading is read again within the same pass.
--
-- Module state is safe here because a pass runs to completion without yielding, so readTelemetry
-- is never entered again while it is running.
local sensorCache = {}
local telemetryTarget = nil
local telemetryChanged = false

local function getSensor(name)
  if sensorCache[name] == nil then sensorCache[name] = Sensors.getValue(name) end
  return sensorCache[name]
end

local function setField(field, value)
  if value ~= nil and value ~= telemetryTarget[field] then
    telemetryTarget[field] = value
    telemetryChanged = true
  end
end

local function readTelemetry(state)
  if not (Sensors and type(Sensors.getValue) == "function") then return end
  telemetryTarget = state
  telemetryChanged = false
  for name in pairs(sensorCache) do sensorCache[name] = nil end

  setField("rpm", getSensor("rpm"))
  setField("lq", getSensor("link"))
  setField("profile", roundInt(getSensor("pid_profile") or state.profile, state.profile or 1))
  setField("rateProfile", roundInt(getSensor("rate_profile") or state.rateProfile, state.rateProfile or 1))
  setField("batteryProfile", roundInt(getSensor("battery_profile") or state.batteryProfile, state.batteryProfile or 1))
  setField("armFlags", roundInt(getSensor("armflags") or state.armFlags, state.armFlags or 0))
  local armDisableFlagsValue = getSensor("armdisableflags")
  if type(armDisableFlagsValue) == "number" then
    setField("armDisableFlags", math.max(0, math.floor(armDisableFlagsValue + 0.5)))
  end
  setField("governor", roundInt(getSensor("governor") or state.governor, state.governor or 0))
  setField("mcuTemp", roundInt(getSensor("temp_mcu") or state.mcuTemp, state.mcuTemp or 0))
  setField("escTemp", roundInt(getSensor("temp_esc") or state.escTemp, state.escTemp or 0))
  setField("bec_voltage", getSensor("bec_voltage") or state.bec_voltage)
  setField("throttlePercent", roundInt(getSensor("throttle_percent") or state.throttlePercent, state.throttlePercent or 0))
  local currentValue = getSensor("current")
  local voltageValue = getSensor("voltage")
  local wattsValue = getSensor("watts")
  if type(wattsValue) ~= "number" and type(currentValue) == "number" and type(voltageValue) == "number" then
    wattsValue = voltageValue * currentValue
  end

  setField("current", currentValue or state.current)
  setField("watts", wattsValue or state.watts)
  setField("altitude", getSensor("altitude") or state.altitude)
  setField("consumedMah", getSensor("smartconsumption") or state.consumedMah)

  local fuel = getSensor("smartfuel") or getSensor("fuel")
  if type(fuel) == "number" then
    local f = fuel
    if f < 0 then f = 0 end
    if f > 100 then f = 100 end
    state.fuelTelemetrySeen = true
    setField("fuel", f)
  end

  if type(voltageValue) == "number" then
    setField("voltage", voltageValue)
  end

  local batteryCellCountValue = getSensor("battery_cell_count")
  if type(batteryCellCountValue) == "number" and batteryCellCountValue > 0 then
    setField("batteryCellCount", roundInt(batteryCellCountValue, state.batteryCellCount or 0))
  elseif type(voltageValue) == "number" and voltageValue > 0 then
    -- Try to infer cell count from battery config's max cell voltage
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
    local maxCellVoltage = normalizeCellVoltage(batteryConfig and batteryConfig.vbatmaxcellvoltage, 4.2)

    local inferredCells = math.max(1, math.floor((voltageValue / maxCellVoltage) + 0.5))
    local existingCells = tonumber(state.batteryCellCount)
    if not existingCells or existingCells <= 0 then
      setField("batteryCellCount", inferredCells)
    else
      local perCell = voltageValue / existingCells
      -- Reconnect-safe: replace stale cell count if implied per-cell voltage is implausible.
      if perCell < 2.5 or perCell > 4.5 then
        setField("batteryCellCount", inferredCells)
      end
    end
  end

  local armState = getSensor("armflags")
  if type(armState) == "number" and bit32 then
    setField("armed", bit32.btest(armState, 1))
  elseif type(armState) == "number" then
    setField("armed", armState ~= 0)
  end

  local rss1 = readFirstNumber(RSS1_SOURCES, state.rss1)
  setField("rss1", rss1)
  local rss2 = readFirstNumber(RSS2_SOURCES, state.rss2)
  setField("rss2", rss2)

  if telemetryChanged then updateDerivedFlightState(state) end
end

local function computeFlightMode(state)
  local isArmed = state.armed == true
  local wasArmed = state.prevArmed == true

  -- Match Ethos behavior: after arming, stay in preflight until governor becomes active
  -- (or throttle rises above a safety threshold).
  if isArmed and not wasArmed then
    state.hadInflightFlight = false
    return "preflight"
  end

  if isArmed then
    local governor = tonumber(state.governor)
    local throttle = tonumber(state.throttlePercent) or 0
    local rpm = tonumber(state.rpm) or 0
    local current = tonumber(state.current) or 0
    local governorActive = (type(governor) == "number" and governor >= 4 and governor <= 8)
    local governorDisabled = (governor == 100 or governor == 0)
    local directModeActive = governorDisabled
      and (
        rpm >= RPM_INFLIGHT_THRESHOLD_DIRECT
        or current >= CURRENT_INFLIGHT_THRESHOLD_DIRECT
        or throttle >= THROTTLE_INFLIGHT_THRESHOLD_DIRECT
      )
    if governorActive or throttle > THROTTLE_INFLIGHT_THRESHOLD or directModeActive then
      state.hadInflightFlight = true
    end

    -- Once we reached inflight in this armed session, stay inflight until disarm.
    if state.hadInflightFlight == true then
      return "inflight"
    end

    return "preflight"
  end

  if state.hadInflightFlight == true then
    return "postflight"
  end

  return "preflight"
end

function Runtime.new(zone, options)
  local dashboardLib = loadDashboardLib()
  local dashboardEngine = loadDashboardEngine()
  local prefs = loadPreferences() or {}
  publishPreferencesToGlobal(prefs)
  local dashboard = (prefs and prefs.dashboard) or {}

  local widget = {
    zone = zone,
    options = options,
    dashboardLib = dashboardLib,
    dashboardEngine = dashboardEngine,
    preferences = prefs,
    preferencesLastLoadedAt = 0,
    themePath = "system/default",
    flightMode = "preflight",
    theme = nil,
    built = false,
    renderKey = nil,
    boxSources = {},
    state = {
      armed = false,
      hadArmedFlight = false,
      hadInflightFlight = false,
      prevArmed = false,
      wasArmed = false,
      fblConnected = false,
      connectionReady = false,
      rpm = 0,
      profile = 1,
      rateProfile = 1,
      batteryProfile = 1,
      armFlags = 0,
      armDisableFlags = 0,
      governor = 0,
      throttlePercent = 0,
      mcuTemp = 0,
      escTemp = 0,
      bec_voltage = 0,
      current = 0,
      watts = 0,
      altitude = 0,
      consumedMah = 0,
      currentFlightMaxThrottlePercent = nil,
      currentFlightMaxRpm = nil,
      currentFlightMinRpm = nil,
      currentFlightMaxCurrent = nil,
      currentFlightMinCurrent = nil,
      currentFlightMaxWatts = nil,
      currentFlightMaxAltitude = nil,
      currentFlightMaxEscTemp = nil,
      currentFlightMaxMcuTemp = nil,
      currentFlightMinFuel = nil,
      flights = 0,
      lq = 0,
      rss1 = 0,
      rss2 = 0,
      fuel = 0,
      voltage = 0,
      batteryCellCount = 0,
      flightSeconds = 0,
      lastFlightSeconds = 0,
      totalFlightSeconds = 0,
      fuelTelemetrySeen = false,
      lastMinVoltage = nil,
      lastMinLq = nil,
      lastFlightMinCurrent = nil,
      lastFlightMaxCurrent = nil,
      lastFlightMaxThrottlePercent = nil,
      lastFlightMaxRpm = nil,
      lastFlightMinRpm = nil,
      lastFlightMaxWatts = nil,
      lastFlightMaxAltitude = nil,
      lastFlightMaxEscTemp = nil,
      lastFlightMaxMcuTemp = nil,
      lastFlightMinFuel = nil,
      lastDisarmAt = nil,
      themeConfig = { v_min = 18.0, v_max = 25.2 }
    },
    audioState = {
      initialized = false,
      nextAllowedAt = 0,
      modelAnnounced = false,
      lastFuelCallout = nil,
      lowFuelActive = false,
      lowFuelLastAt = 0,
      lowFuelRepeatCount = 0,
      lastValues = {
        arming_flags = nil,
        governor_state = nil,
        pid_profile = nil,
        rate_profile = nil,
        battery_profile = nil
      },
      pendingValues = {
        pid_profile = nil,
        rate_profile = nil,
        battery_profile = nil
      },
      lastEnabled = {
        governor_state = nil
      }
    },
    connectionReady = false,
    lastFblConnected = false,
    statusLine = "Waiting for MSP link",
    readySince = nil,
    mspAttached = false,
    mspLastTick = 0
  }

  -- Initialize i18n context for the widget using system locale
  if I18nModule and type(I18nModule.new) == "function" then
    local locale = nil
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", "t")
    if chunk then
      local ok, localeMod = pcall(chunk)
      if ok and type(localeMod) == "table" and type(localeMod.resolveSystemLanguage) == "function" then
        local okResolve, resolved = pcall(localeMod.resolveSystemLanguage, "en")
        if okResolve and type(resolved) == "string" and resolved ~= "" then
          locale = resolved
        end
      end
    end
    local ok, ctx = pcall(I18nModule.new, locale)
    if ok and type(ctx) == "table" then
      widget.i18n = ctx
    end
  end
  -- ensure renderers can access the same i18n via state
  if widget.i18n then
    widget.state.i18n = widget.i18n
  end

  local function resolveVoltageCellCount(state)
    local cells = tonumber(state and state.batteryCellCount)
    if cells and cells > 0 then
      return math.floor(cells + 0.5)
    end

    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
    local sessionCells = tonumber(batteryConfig and batteryConfig.batteryCellCount)
    if sessionCells and sessionCells > 0 then
      return math.floor(sessionCells + 0.5)
    end

    local voltage = tonumber(state and state.voltage)
    local maxCellVoltage = tonumber(batteryConfig and batteryConfig.vbatmaxcellvoltage) or 4.2
    if type(voltage) == "number" and voltage > 0 and maxCellVoltage > 0 then
      return math.max(1, math.floor((voltage / maxCellVoltage) + 0.5))
    end

    return nil
  end

  -- Defined once per widget rather than once per updateVoltageThemeConfig call: that function
  -- runs on every logic tick, and two fresh closures per tick is steady-state garbage in the
  -- shared Lua state.
  local function applyThemeConfig(self, nextConfig)
    local prev = self.state.themeConfig or {}
    local prevMin = tonumber(prev.v_min)
    local prevMax = tonumber(prev.v_max)
    local nextMin = tonumber(nextConfig and nextConfig.v_min)
    local nextMax = tonumber(nextConfig and nextConfig.v_max)

    self.state.themeConfig = nextConfig

    local changed = (
      type(prevMin) ~= "number" or type(prevMax) ~= "number" or
      type(nextMin) ~= "number" or type(nextMax) ~= "number" or
      math.abs(prevMin - nextMin) > 0.01 or math.abs(prevMax - nextMax) > 0.01
    )
    if changed then
      self.built = false
      self.renderKey = nil
      self._cachedRenderKey = nil
    end
  end

  local function logVoltageThemeDecision(self, reason, cells, inMin, inMax, outMin, outMax)
    if not shouldLogAudio(self) then return end
    local key = table.concat({
      tostring(reason or "?"),
      tostring(cells or "x"),
      tostring(inMin or "x"),
      tostring(inMax or "x"),
      tostring(outMin or "x"),
      tostring(outMax or "x")
    }, "|")
    if self._lastVoltageThemeDebugKey == key then return end
    self._lastVoltageThemeDebugKey = key
    widgetLog(
      self,
      "voltage theme normalize reason=" .. tostring(reason)
        .. " cells=" .. tostring(cells)
        .. " in=" .. tostring(inMin) .. "/" .. tostring(inMax)
        .. " out=" .. tostring(outMin) .. "/" .. tostring(outMax),
      "debug"
    )
  end

  local function updateVoltageThemeConfig(self)
    local currentConfig = self.state.themeConfig or {}

    -- The steady-state pass allocates nothing. When the bounds in hand are already numeric,
    -- the three branches below that would end in a value-identical config -- custom bounds,
    -- no cell count, or plausible bounds kept -- are decided here on the numbers alone, the
    -- existing table is kept, and only the (deduplicated, developer-gated) log line is still
    -- offered. Every path that can CHANGE a value falls through to the full copy below, so
    -- what the function computes is exactly what it computed before.
    local curMin = tonumber(currentConfig.v_min)
    local curMax = tonumber(currentConfig.v_max)
    if curMin ~= nil and curMax ~= nil then
      if currentConfig._customVoltage == true then
        logVoltageThemeDecision(self, "custom-config", nil, currentConfig.v_min, currentConfig.v_max, curMin, curMax)
        return
      end
      local cells = resolveVoltageCellCount(self.state)
      if not cells or cells <= 0 then
        logVoltageThemeDecision(self, "no-cells", cells, currentConfig.v_min, currentConfig.v_max, curMin, curMax)
        return
      end
      local isExactDefault = math.abs(curMin - 18.0) <= 0.01 and math.abs(curMax - 25.2) <= 0.01
      local perCellMin = curMin / cells
      local perCellMax = curMax / cells
      local looksInvalidForCells = (
        perCellMin < 2.0 or perCellMin > 5.0 or
        perCellMax < 3.0 or perCellMax > 5.2 or
        perCellMax <= perCellMin
      )
      if (not isExactDefault) and (not looksInvalidForCells) then
        logVoltageThemeDecision(self, "keep", cells, currentConfig.v_min, currentConfig.v_max, curMin, curMax)
        return
      end
    end
    local nextConfig = {}
    for k, v in pairs(currentConfig) do
      nextConfig[k] = v
    end
    nextConfig.v_min = tonumber(currentConfig.v_min) or 18.0
    nextConfig.v_max = tonumber(currentConfig.v_max) or 25.2

    -- If the user configured custom voltage values (in model or global preferences), respect them!
    if currentConfig._customVoltage == true then
      applyThemeConfig(self, nextConfig)
      logVoltageThemeDecision(self, "custom-config", nil, currentConfig.v_min, currentConfig.v_max, nextConfig.v_min, nextConfig.v_max)
      return
    end

    local defaultMin = 18.0
    local defaultMax = 25.2
    local cells = resolveVoltageCellCount(self.state)
    if not cells or cells <= 0 then
      applyThemeConfig(self, nextConfig)
      logVoltageThemeDecision(self, "no-cells", cells, currentConfig.v_min, currentConfig.v_max, nextConfig.v_min, nextConfig.v_max)
      return
    end

    local isExactDefault = math.abs(nextConfig.v_min - defaultMin) <= 0.01 and math.abs(nextConfig.v_max - defaultMax) <= 0.01
    local perCellMin = nextConfig.v_min / cells
    local perCellMax = nextConfig.v_max / cells
    -- Reconnect-safe: if configured bounds are implausible for detected cell count,
    -- treat them as stale defaults and re-derive from battery config.
    local looksInvalidForCells = (
      perCellMin < 2.0 or perCellMin > 5.0 or
      perCellMax < 3.0 or perCellMax > 5.2 or
      perCellMax <= perCellMin
    )
    if (not isExactDefault) and (not looksInvalidForCells) then
      applyThemeConfig(self, nextConfig)
      logVoltageThemeDecision(self, "keep", cells, currentConfig.v_min, currentConfig.v_max, nextConfig.v_min, nextConfig.v_max)
      return
    end

    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
    local minCellVoltage = normalizeCellVoltage(batteryConfig and batteryConfig.vbatmincellvoltage, 3.3)
    local maxCellVoltage = normalizeCellVoltage(batteryConfig and batteryConfig.vbatmaxcellvoltage, 4.2)

    nextConfig.v_min = cells * minCellVoltage
    nextConfig.v_max = cells * maxCellVoltage
    applyThemeConfig(self, nextConfig)
    logVoltageThemeDecision(self, "normalize", cells, currentConfig.v_min, currentConfig.v_max, nextConfig.v_min, nextConfig.v_max)
  end

  local function reloadActiveTheme(self)
    local modelPrefs = self.modelPreferences or (type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session.modelPreferences) or nil
    local selectedTheme = resolveThemePathForState((self.preferences and self.preferences.dashboard) or EMPTY_DASHBOARD, modelPrefs, self.flightMode)
    local nextConfig = {}
    if self.dashboardLib and self.dashboardLib.getThemeConfig then
      nextConfig = self.dashboardLib.getThemeConfig(self.preferences, selectedTheme, {}, modelPrefs)
    end

    local hasCustomVoltage = (nextConfig.v_min ~= nil or nextConfig.v_max ~= nil)
    nextConfig.v_min = tonumber(nextConfig.v_min) or 18.0
    nextConfig.v_max = tonumber(nextConfig.v_max) or 25.2
    nextConfig._customVoltage = hasCustomVoltage

    self.themePath = selectedTheme
    self.state.themeConfig = nextConfig
    updateVoltageThemeConfig(self)
    self.theme = loadThemeModuleForState(selectedTheme, self.flightMode)
    self.built = false
    self.renderKey = nil

    logGv("reloadActiveTheme: flightMode=%s, selectedTheme=%s, loadedTheme=%s, v_min=%.1f, v_max=%.1f, customV=%s",
      tostring(self.flightMode), tostring(selectedTheme), tostring(self.theme ~= nil),
      nextConfig.v_min, nextConfig.v_max, tostring(hasCustomVoltage))

    local sources = {}
    if self.theme then
      local parsedBoxes = nil
      if type(self.theme.boxes) == "function" then
        local ok, b = pcall(self.theme.boxes, nil, self.state)
        if ok and type(b) == "table" then parsedBoxes = b end
      elseif type(self.theme.boxes) == "table" then
        parsedBoxes = self.theme.boxes
      end
      if parsedBoxes then
        local seen = {}
        for i = 1, #parsedBoxes do
          local box = parsedBoxes[i]
          local src = box and box.source
          if type(src) ~= "string" and box and box.type == "text" and box.subtype == "governor" then
            src = "governor"
          end
          if type(src) == "string" and not seen[src] then
            seen[src] = true
            sources[#sources + 1] = src
          end
        end
      end
    end
    self.boxSources = sources
  end

  local function performBackgroundWork(self)
    local now = nowSeconds()
    if self._lastWorkTick == now then return self.connectionReady end
    self._lastWorkTick = now

    if not self._lastLogicTick then self._lastLogicTick = 0 end
    -- A start, and not merely "not ready": with no flight controller present the gate below is
    -- false for as long as the radio is on, and paying the faster rate for that would be the
    -- whole steady state of a bench radio.
    local starting = (self.state.fblConnected == true) and (self.connectionReady ~= true)
    local logicTick = starting and LOGIC_TICK_STARTING_SECONDS or LOGIC_TICK_SECONDS
    if (now - self._lastLogicTick) < logicTick then return self.connectionReady end
    self._lastLogicTick = now

    -- Set event context to 'widget' before events wakeup
    if type(_G) == "table" then
      _G.rfsuite = _G.rfsuite or {}
      _G.rfsuite.session = _G.rfsuite.session or {}
      _G.rfsuite.session.event_context = "widget"
    end
    tickMspRuntime(self)
    
    reloadPreferencesIfNeeded(self, false)
    self.state.zoneW = self.zone and self.zone.w or 0
    self.state.zoneH = self.zone and self.zone.h or 0
    local wasFblConnected = self.lastFblConnected == true
    local ready, statusLine = updateConnectionState(self)
    local isFblConnected = self.state.fblConnected == true
    
    -- Preserve postflight statistics when disconnected:
    -- Skip telemetry updates when we had an inflight flight and connection is lost,
    -- so that lastFlightMaxCurrent, lastMinVoltage, consumedMah etc. remain visible.
    -- Use hadInflightFlight instead of flightMode, because flightMode can jump to preflight
    -- when sensors go offline, while hadInflightFlight stays true until next session.
    local isPostflightOffline = (self.state.hadInflightFlight == true) and not isFblConnected
    if not isPostflightOffline then
      readTelemetry(self.state)
    end
    
    -- Update session values if available (from MSP)
    if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
      if type(_G.rfsuite.session.flightcount) == "number" then
        self.state.flights = _G.rfsuite.session.flightcount
      end
      if type(_G.rfsuite.session.dataflash) == "table" then
        self.state.dataflash = _G.rfsuite.session.dataflash
      end
      if type(_G.rfsuite.session.battery_config) == "table" then
        self.state.battery_config = _G.rfsuite.session.battery_config
      end
      if type(_G.rfsuite.session.modelPreferences) == "table" then
        self.modelPreferences = _G.rfsuite.session.modelPreferences
      end
    end
    updateVoltageThemeConfig(self)
    if isFblConnected and not wasFblConnected then
      -- New FBL session detected: clear stale postflight state and rebuild theme/UI.
      self.state.hadArmedFlight = false
      self.state.hadInflightFlight = false
      self.state.prevArmed = false
      self.state.wasArmed = false
      self.state.armed = false
      self.state.batteryCellCount = 0
      self.state.currentFlightSeconds = 0
      self.state.lastFlightSeconds = 0
      self.state.flightSeconds = 0
      self.state.lastDisarmAt = nil
      self.state.profile = nil
      self.state.rateProfile = nil
      self.state.batteryProfile = nil
      self.modelPreferences = nil
      self.lastModelPreferences = nil
      self.flightMode = "preflight"
      self.theme = nil
      self.built = false
      self.renderKey = nil
      self._cachedRenderKey = nil
      if self.audioState and DashboardAudio and type(DashboardAudio.resetConnectionState) == "function" then
        DashboardAudio.resetConnectionState(self.audioState)
      end
      -- Recalculate voltage theme config now that batteryCellCount is reset to 0
      -- This ensures gauge bounds are computed fresh, not with stale cell count from previous session
      updateVoltageThemeConfig(self)
      widgetLog(self, "FBL reconnect edge: reset dashboard session state", "info")
    elseif not isFblConnected and wasFblConnected then
      if self.audioState and DashboardAudio and type(DashboardAudio.resetConnectionState) == "function" then
        DashboardAudio.resetConnectionState(self.audioState)
      end
    end
    self.lastFblConnected = isFblConnected

    local nextMode = computeFlightMode(self.state)
    if statusLine ~= nil then self.statusLine = statusLine end

    if self.startupComplete then
      processAudioEvents(self)
    end

    local modelPrefs = self.modelPreferences or (type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session.modelPreferences) or nil
    local selectedTheme = resolveThemePathForState((self.preferences and self.preferences.dashboard) or EMPTY_DASHBOARD, modelPrefs, nextMode)

    local modelPrefsChanged = (modelPrefs ~= self.lastModelPreferences)
    self.lastModelPreferences = modelPrefs

    if nextMode ~= self.flightMode then
      self.flightMode = nextMode
      reloadActiveTheme(self)
    elseif selectedTheme ~= self.themePath or modelPrefsChanged then
      reloadActiveTheme(self)
    elseif not self.theme then
      reloadActiveTheme(self)
    end
    
    -- Clear event_context immediately after all widget background logic
    if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
      _G.rfsuite.session.event_context = nil
    end

    return ready
  end

  function widget.update(self, newOptions)
    self.options = newOptions
    self.built = false
  end

  function widget.reload(self, force)
    logGv("widget.reload called with force=%s", tostring(force))
    reloadPreferencesIfNeeded(self, force ~= false)
    reloadActiveTheme(self)
    self.built = false
    self.renderKey = nil
    self._cachedRenderKey = nil
    self._lastUIRefresh = 0
  end


  function widget.refresh(self, event, touchState)
    -- Route touch/key events to LVGL engine when active (e.g. fullscreen)
    if lvgl and type(lvgl.onEvent) == "function" and event ~= nil then
       -- On some EdgeTX versions, touchState coordinates are global.
       -- We need to ensure LVGL knows the widget's offset if it doesn't handle it.
       -- However, in Fullscreen, offset is usually 0,0.
       lvgl.onEvent(event, touchState)
    end

    local ready = performBackgroundWork(self)

    if self.zone then
      self.state.zoneW = self.zone.w or 0
      self.state.zoneH = self.zone.h or 0
      self.state.zoneX = self.zone.x or 0
      self.state.zoneY = self.zone.y or 0
    end
    self.state.flightMode = self.flightMode

    if not ready and self.flightMode ~= "postflight" then
      local statusLine = self.statusLine or "Please wait..."
      local splashKey = "splash|" .. tostring(statusLine) .. "|" .. tostring(self.state.zoneW) .. "x" .. tostring(self.state.zoneH)
      if self.renderKey ~= splashKey then
        self.renderKey = splashKey
        self.built = false
      end

      if not self.built then
        local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
        local title = (t and t("widgets.dashboard.connecting_fbl")) or "Connecting FBL..."
        lvgl.clear()
        lvgl.build(buildConnectionSplash(self.zone, statusLine, title))
        self.built = true
      end
      return
    end

    if not self.theme then return end

    -- In EdgeTX, `event` is nil in normal widget mode, and an integer (including 0 for idle) in fullscreen.
    local isInteractive = (event ~= nil)
    local nextRenderKey = nil
    if isInteractive then
      nextRenderKey = "fullscreen_menu"
    else
      -- Throttle dashboard rendering to max 2Hz (0.5s) to save CPU
      if not self._lastUIRefresh then self._lastUIRefresh = 0 end
      local now = nowSeconds()
      if (now - self._lastUIRefresh) >= 0.5 then
        self._lastUIRefresh = now
        local newKey = nil
        if type(self.theme.renderKey) == "function" then
          newKey = self.theme.renderKey(self.zone, self.state)
        elseif self.dashboardEngine and (type(self.theme.layout) == "table" or type(self.theme.boxes) == "table" or type(self.theme.boxes) == "function") then
          newKey = self.dashboardEngine.renderKey(self.state, self.boxSources)
        end
        self._cachedRenderKey = newKey
      end
      nextRenderKey = self._cachedRenderKey
    end

    if nextRenderKey ~= self.renderKey then
      self.renderKey = nextRenderKey
      self.built = false
      -- Ausführung auf den nächsten Tick verschieben, um das CPU Limit beim Zeichnen zu umgehen
      return
    end

    if not self.built then
      local children = {}
      
      if isInteractive then
        local menu = requireModule("widgets/dashboard/fullscreen_menu.lua")
        if menu and type(menu.build) == "function" then
          menu.build(children, self)
        end
      else
        if type(self.theme.build) == "function" then
          children = self.theme.build(self.zone, self.state)
        elseif self.dashboardEngine and (type(self.theme.layout) == "table" or type(self.theme.boxes) == "table" or type(self.theme.boxes) == "function") then
          children = self.dashboardEngine.build(self.zone, self.state, self.theme)
        end
        if type(children) ~= "table" then return end
      end

      -- No forced full collection here. This block runs whenever the render key changes, i.e.
      -- whenever a displayed telemetry value moves, and every widget on the radio shares one
      -- Lua state -- so a full collect walks every other widget's live set as well. The
      -- firmware already runs an incremental collection on that state on every GUI pass.
      -- GEMINI.md asks for an explicit collect after large I/O or JSON work; a repaint is
      -- neither.
      lvgl.clear()
      lvgl.build(children)
      self.built = true
      logGv("LVGL BUILD SUCCESS: themePath=%s, #children=%d", tostring(self.themePath), #children)
    end
  end

  function widget.background(self)
    performBackgroundWork(self)
    return 0
  end

  reloadActiveTheme(widget)
  return widget
end

return Runtime
