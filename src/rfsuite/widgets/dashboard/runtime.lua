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
-- Boxes rendered per JOB pass by the stepped scene build. Provisional -- to be calibrated
-- by offline instruction accounting; what matters structurally is that it is a constant,
-- so a pass's build cost no longer scales with the theme's object count.
local BUILD_BOXES_PER_PASS = 8
-- The telemetry read runs on the display's own cadence rather than on every logic tick:
-- ~25 sensor reads per call, and the render key that consumes them already updates at 2 Hz,
-- so reading faster only spends the pass budget. The state machine downstream reads values
-- up to half a second old, which the audio events tolerate.
local TELEMETRY_READ_SECONDS = 0.5


local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if rChunk then
    local ok, res = pcall(rChunk)
    if ok and type(res) == "function" then
      requireModule = res
    end
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")
local PreferencesModule = requireModule("lib/preferences.lua")
local ModelPreferences = requireModule("lib/model_preferences.lua")
local DashboardAudio = requireModule("lib/audio.lua")
local DashboardSplash = requireModule("widgets/dashboard/splash.lua")
local MspRuntime = requireModule("tasks/msp/runtime.lua")
local I18nModule = requireModule("i18n/init.lua")
local Sensors = requireModule("lib/sensors.lua")
local DerivedSnapshot = requireModule("widgets/dashboard/derived.lua")
local LogSink = requireModule("lib/log_sink.lua")
if LogSink and type(LogSink.configure) == "function" then
  LogSink.configure("widget")
end

local RSS1_SOURCES = { "1RSS", "RSS1", "rssi1" }
local RSS2_SOURCES = { "2RSS", "RSS2", "rssi2" }
local RSSI_LINK_SOURCES = {
  ["1RSS"] = true,
  ["2RSS"] = true,
}
local THROTTLE_INFLIGHT_THRESHOLD = 35
local THROTTLE_INFLIGHT_THRESHOLD_DIRECT = 8
local RPM_INFLIGHT_THRESHOLD_DIRECT = 500
local CURRENT_INFLIGHT_THRESHOLD_DIRECT = 8

-- The connect chain reports the step it is on by its module name -- an identifier, not
-- something to put in front of a pilot. Those names already have wording of their own under
-- `app.onconnect.*`, which is what the tool's own start screen shows (ONCONNECT_TEXT in
-- ui/home.lua), so the splash reads the same strings and the two screens say the same thing.
--
-- The text is taken through the build marker rather than by concatenating the task name onto a
-- prefix and asking i18n.t() for it. Translation here happens when the install is packaged: the
-- precompile step rewrites a call whose key is a literal into the translated string, and
-- bin/package/build_package.py then copies i18n/init.lua alone, without a locale bundle behind
-- it. A computed key is the one shape that step cannot rewrite, and at runtime there is nothing
-- left to resolve it against, so "app.onconnect.<name>" would reach the screen as it stands.
--
-- The names come from tasks/events/onconnect/manifest.lua. One added there without an entry
-- here keeps the generic line, which is the right way round: a missing step name costs wording,
-- a missing string would cost the sentence.
local ONCONNECT_STEP_TEXT = {
  apiversion        = "@i18n(app.onconnect.apiversion)@",
  uid               = "@i18n(app.onconnect.uid)@",
  rtc               = "@i18n(app.onconnect.rtc)@",
  status            = "@i18n(app.onconnect.status)@",
  telemetry         = "@i18n(app.onconnect.telemetry)@",
  flight_stats      = "@i18n(app.onconnect.flight_stats)@",
  dataflash_summary = "@i18n(app.onconnect.dataflash_summary)@",
  battery_config    = "@i18n(app.onconnect.battery_config)@",
  governor_config   = "@i18n(app.onconnect.governor_config)@",
  esc_sensor_config = "@i18n(app.onconnect.esc_sensor_config)@",
  smartfuel_config  = "@i18n(app.onconnect.smartfuel_config)@",
  name              = "@i18n(app.onconnect.name)@",
  model_params_sync = "@i18n(app.onconnect.model_params_sync)@",
  model_name_sync   = "@i18n(app.onconnect.model_name_sync)@"
}

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
    Log.emit("rfsuite.widget", msg, level or "debug")
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

-- How often the usage line below is written, in seconds.
--
-- Reporting only when the figure RISES was the obvious shape and it is the wrong one: a widget
-- whose very first pass is also its worst -- which is exactly the widget a bug report is about --
-- states its number once and is then silent for the rest of the session. A fixed interval keeps a
-- current figure in the log for as long as the widget is alive, and it gives the end of the lines
-- a meaning they otherwise do not have: a widget that has stopped reporting has stopped
-- refreshing.
local USAGE_REPORT_INTERVAL = 5

--- Report how much of the per-pass instruction ceiling this widget is consuming.
--
-- EdgeTX gives the widget Lua state a fixed instruction budget per pass, and
-- LuaWidget::foreground (radio/src/lua/lua_widget.cpp) runs this widget's refresh() AND the
-- LVGL reactive-reference sweep callRefs() inside one protected block on that one budget. It
-- stores the share consumed once both have returned, and getUsage() hands exactly that value
-- back for an LVGL widget (luaGetUsage, radio/src/lua/api_general.cpp). So the figure readable
-- here is the PREVIOUS pass's, refresh and sweep together -- which is why it is sampled at the
-- top of a pass, where the object count still describes the tree that sweep walked.
--
-- Past the budget the firmware raises "CPU limit" from inside the sweep, paints its own message
-- over the widget and stops calling refresh() altogether, so the pass that fails can never
-- report itself and no line here can be the failing one. What this gives a bug report is the
-- approach to it, and the point at which the reporting stopped.
--
-- Three figures, because each of them alone misleads. The current sample says what a settled
-- widget costs. The peak over the interval says how close the worst pass in that stretch came,
-- which is the number that decides whether the ceiling gets crossed on a busier screen. The peak
-- since load keeps the worst pass of a session from scrolling out of a card log.
--
-- The value is not bounded by 100: the firmware's hook switches to a per-line mask once the count
-- is up and keeps counting until the raise lands, so an overrunning pass reports what it cost.
-- It is held in a uint8_t, though, so a pass past 255 wraps and reads low -- one more reason to
-- report a stream of figures rather than a single worst one, since a wrapped sample stands out
-- among its neighbours and would silently become the record on its own.
--
-- Nothing here tests the debug level. Log.emitf does that, and below "trace" the line is neither
-- printed, nor put in the session ring, nor written to the card.
local function traceInstructionUsage(self)
  if type(getUsage) ~= "function" then return end
  local ok, percent = pcall(getUsage)
  if not ok then return end
  percent = tonumber(percent)
  if percent == nil then return end

  -- The cheap path, taken on all but one pass in fifty: two comparisons and a clock read.
  -- Sampling has to happen on every pass, because the peak is the point of the line.
  if percent > self._usageWindowPeak then self._usageWindowPeak = percent end
  if percent > self._usagePeak then self._usagePeak = percent end

  local now = nowSeconds()
  if now < self._usageReportAt then return end
  self._usageReportAt = now + USAGE_REPORT_INTERVAL

  if Log and type(Log.emitf) == "function" then
    Log.emitf("rfsuite.widget", "trace",
      "instruction budget %d%% now, %d%% peak/%ds, %d%% peak since load, %d objects, theme=%s",
      percent, self._usageWindowPeak, USAGE_REPORT_INTERVAL, self._usagePeak,
      self._lastChildCount, tostring(self.themePath))
  end

  self._usageWindowPeak = -1
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
local PREFERENCES_FILE  = "/SCRIPTS/TOOLS/rfsuite.user/preferences.ini"
-- Rotating sequence file written by lib/preferences.lua and lib/model_preferences.lua.
-- The file contains between 1 and 32 bytes ('x'). Each save cycles the size by 1.
-- The widget inspects fstat(RELOAD_REQ_FILE).size without modifying or deleting the file.
-- This ensures multi-reader safety (all widgets see the change) and armed safety
-- (updates occurring while armed are not consumed prematurely and remain pending until disarm).
local RELOAD_REQ_FILE   = "/SCRIPTS/TOOLS/rfsuite.user/reload.req"
local PREFS_STAT_INTERVAL = 1.0

local function preferencesFile()
  if ModelPreferences and type(ModelPreferences.preferencesPath) == "function" then
    return ModelPreferences.preferencesPath()
  end
  if PreferencesModule and type(PreferencesModule.getPath) == "function" then
    return PreferencesModule.getPath()
  end
  return PREFERENCES_FILE
end

local function reloadRequestPaths()
  if ModelPreferences and type(ModelPreferences.reloadRequestPaths) == "function" then
    return ModelPreferences.reloadRequestPaths()
  end
  return { RELOAD_REQ_FILE }
end

local function publishPreferencesToGlobal(prefs)
  if type(_G) ~= "table" then return end
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.preferences = prefs or {}
end

-- Shared stand-in for "no global dashboard section", so that the absence of one is a stable
-- value rather than a fresh table on every call. Without it the memo below can never hit.
local EMPTY_DASHBOARD = {}

-- The answer depends on three things that change rarely: the flight mode, the global dashboard
-- preferences and the model's own. Both preference tables are replaced wholesale when their
-- file is reloaded, so table identity is a generation marker -- the same one the background
-- pass already uses to decide whether the model preferences have changed. Without this memo the
-- resolver runs on every background pass, and so does the log line at the end of it.
-- Declared here at file level so that reloadPreferencesIfNeeded can clear it on reload.
local themePathMemo = {}


local function logGv(fmt, ...)
  -- The reload trace, through the logging core: the ring (Session Logs) takes it, and --
  -- when logging to card is on -- the sink's session file, which is bounded, rotated and
  -- loss-counted.
  --
  -- The message is assembled HERE, after the gate, rather than by the caller: with the
  -- test inside the function the callers still paid for a string that was then dropped,
  -- and one of them sits on the unconditional path of every background pass. Log.wanted
  -- asks the same question the emit path asks, so a level added to the ladder later
  -- cannot leave this gate behind.
  if not (Log and type(Log.wanted) == "function" and Log.wanted("info")) then return end

  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end

  Log.emit("rfsuite.reload", msg, "info")
end

-- The job slot. At most one job is pending per widget, held in `self._job` as
-- { kind, step }: `kind` names the job for the log line, `step(self)` runs the work
-- against the CURRENT state (never a snapshot taken at enqueue time) and returns true
-- when the job is complete. The splash and menu jobs complete in one step; the scene job
-- returns false to keep the slot and spread its build over several passes -- prepare,
-- a bounded chunk per pass, then the swap. The STATE pass enqueues, the JOB pass
-- executes -- see the dispatcher in widget.refresh.

local function splashJobStep(self)
  local statusLine = self.statusLine or "Please wait..."
  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local title = (t and t("widgets.dashboard.connecting_fbl")) or "Connecting FBL..."
  local splash = buildConnectionSplash(self.zone, statusLine, title)
  lvgl.clear()
  lvgl.build(splash)
  self.built = true
  -- What the reactive sweep walks from the next pass on. Kept up to date here as well as
  -- at the scene build below, so the usage line never reports a count belonging to a
  -- tree that has already been cleared.
  self._lastChildCount = #splash
  return true
end

-- The scene job in three phases, carried as fields on the job table. The old LVGL tree
-- stands until the swap, so a stepped rebuild shows the previous frame, never a blank one.
local function sceneJobStep(self)
  local job = self._job

  -- Swap: hand the finished node table over in a pass of its own. Two C calls, so the
  -- pass carries almost nothing beyond the reactive sweep of the new tree.
  --
  -- No forced full collection here. This job runs whenever the render key changes, i.e.
  -- whenever a displayed telemetry value moves, and every widget on the radio shares one
  -- Lua state -- so a full collect walks every other widget's live set as well. The
  -- firmware already runs an incremental collection on that state on every GUI pass.
  -- GEMINI.md asks for an explicit collect after large I/O or JSON work; a repaint is
  -- neither.
  if job.swap then
    lvgl.clear()
    lvgl.build(job.build.nodes)
    self.built = true
    self._lastChildCount = #job.build.nodes
    logGv("LVGL BUILD SUCCESS: themePath=%s, #children=%d", tostring(self.themePath), #job.build.nodes)
    return true
  end

  -- Chunk: render a bounded slice of boxes into plain Lua tables. No theme revalidation
  -- here or at the swap: every path that tears the theme down clears the job slot, so a
  -- job cannot outlive its theme, and rects and nodes are self-contained.
  if job.build then
    if self.dashboardEngine.stepBuild(job.build, self.state, BUILD_BOXES_PER_PASS) then
      job.swap = true
    end
    return false
  end

  -- Prepare: bind structure once. The theme can be gone by the time the job runs: while
  -- the widget is off screen, widget.background keeps mutating state, and a reconnect
  -- edge clears the theme. Drop the job; the next STATE pass re-detects and re-enqueues
  -- against the new state.
  if not self.theme then return true end

  if type(self.theme.build) == "function" then
    -- A free-form theme builds in one step, exactly as before -- the engine cannot chunk
    -- what it does not render.
    local children = self.theme.build(self.zone, self.state)
    if type(children) ~= "table" then return true end
    lvgl.clear()
    lvgl.build(children)
    self.built = true
    self._lastChildCount = #children
    logGv("LVGL BUILD SUCCESS: themePath=%s, #children=%d", tostring(self.themePath), #children)
    return true
  end

  if self.dashboardEngine and (type(self.theme.layout) == "table" or type(self.theme.boxes) == "table" or type(self.theme.boxes) == "function") then
    job.build = self.dashboardEngine.beginBuild(self.zone, self.state, self.theme)
    return false
  end

  -- Neither free-form nor declarative: hand LVGL an empty scene, exactly as the
  -- single-step build did.
  lvgl.clear()
  lvgl.build({})
  self.built = true
  self._lastChildCount = 0
  logGv("LVGL BUILD SUCCESS: themePath=%s, #children=%d", tostring(self.themePath), 0)
  return true
end

local function menuJobStep(self)
  local menu = requireModule("widgets/dashboard/fullscreen_menu.lua")
  if not (menu and type(menu.build) == "function") then return true end
  local children = {}
  menu.build(children, self)
  lvgl.clear()
  lvgl.build(children)
  self.built = true
  self._lastChildCount = #children
  return true
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
  local okg, g = pcall(fstat, preferencesFile())
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

local function reloadPreferencesIfNeeded(self, force, isBackground)
  local now = nowSeconds()

  -- The stamp and sequences that a completed reload will adopt. Held back on purpose -- see the armed
  -- guard below.
  local currentStamp = nil
  local currentSeqs = nil
  local signalReload = false
  if not force and (now - (self._lastPrefsStatAt or 0)) >= PREFS_STAT_INTERVAL then
    self._lastPrefsStatAt = now
    -- The per-model file's path lives on the session rather than on `self` -- the same
    -- shape this file already uses to reach `modelPreferences` twice further down.
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local stamp = preferencesStamp(session and session.modelPreferencesFile)
    if stamp then
      currentStamp = stamp
      if self._lastPrefsStamp == nil then
        -- First look. The preferences in hand were loaded from these very files, so this
        -- is a baseline and never a reload.
        self._lastPrefsStamp = stamp
        logGv("reloadPreferencesIfNeeded: baseline stamp set: '%s'", tostring(stamp))
      elseif stamp ~= self._lastPrefsStamp then
        logGv("reloadPreferencesIfNeeded: stamp changed ('%s' -> '%s')", tostring(self._lastPrefsStamp), tostring(stamp))
        signalReload = true
      end
    end

    -- Rotating sequence file written by preference writers on every save. Detected here
    -- as a second, independent path: where fstat is available, even when the RTC is absent
    -- (frozen mtime) or the new INI happens to be the same byte-size as the old one,
    -- the sequence size will have changed.
    --
    -- We inspect reload.req under every known user root and treat any of them moving as
    -- the signal. This removes any assumption that reader and writer agree on a single root.
    --
    -- Readers only inspect info.size using fstat and NEVER write, truncate, or unlink
    -- the file. This ensures:
    -- 1) Multiple widgets can all observe the change (no single widget steals/consumes it).
    -- 2) If the helicopter is armed, the reload is deferred until disarm without losing
    --    the trigger.
    if type(fstat) == "function" then
      local reqPaths = reloadRequestPaths()
      for i = 1, #reqPaths do
        local reqPath = reqPaths[i]
        local ok, info = pcall(fstat, reqPath)
        local seq = (ok and type(info) == "table" and (info.size or 0) > 0) and info.size or 0
        if not currentSeqs then currentSeqs = {} end
        currentSeqs[reqPath] = seq

        if not self._lastReloadSeqs then self._lastReloadSeqs = {} end
        local lastSeq = self._lastReloadSeqs[reqPath]
        if lastSeq == nil then
          self._lastReloadSeqs[reqPath] = seq
          logGv("reloadPreferencesIfNeeded: baseline seq for %s is %d (fstat_ok=%s)", reqPath, seq, tostring(ok))
        elseif seq ~= lastSeq then
          logGv("reloadPreferencesIfNeeded: %s sequence changed (%s -> %s)", reqPath, tostring(lastSeq), tostring(seq))
          signalReload = true
        end
      end
    else
      logGv("reloadPreferencesIfNeeded: fstat unavailable")
    end
  end

  if signalReload then
    self._reloadPending = true
  end

  if not force and not signalReload and not self._reloadPending then
    return
  end

  -- Safety: Do not reload files while ARMED or during periodic postflight offline to prevent CPU spikes or UI resets.
  -- Forced reloads (e.g. at connection state flips or explicit reloads) are still honored --
  -- the armed clause is gated on `force` like the offline one, which is what this line has
  -- always claimed. A forced caller asks for the reload outright and carries no `pendingStamp`
  -- to re-signal itself with, so dropping it here dropped it for good.
  --
  -- Returning here does NOT lose the change: `self._reloadPending` is kept until the reload
  -- actually executes, so the next pass after disarming sees the pending reload and reloads then.
  if not force and (self.state.armed or (self.state.hadInflightFlight == true and not self.state.fblConnected)) then
    logGv("reloadPreferencesIfNeeded: deferred due to armed/offline (armed=%s, hadInflightFlight=%s, fblConnected=%s)", tostring(self.state.armed), tostring(self.state.hadInflightFlight), tostring(self.state.fblConnected))
    return
  end

  if isBackground and not force then
    -- During background passes (when widget is off-screen), defer heavy file I/O and theme
    -- compilation until widget returns to screen (refresh pass) to avoid EdgeTX CPU limit faults.
    logGv("reloadPreferencesIfNeeded: deferred due to background pass (pending=%s)", tostring(self._reloadPending))
    return
  end

  logGv("reloadPreferencesIfNeeded executing (force=%s signal=%s pending=%s armed=%s)", tostring(force), tostring(signalReload), tostring(self._reloadPending), tostring(self.state and self.state.armed))

  -- Invalidate current theme and memoization state BEFORE heavy disk reads.
  -- If EdgeTX aborts execution mid-load (e.g. CPU limit fault), all stale
  -- references are already cleared, so the next tick is forced to retry
  -- the full reload rather than rendering with leftover stale data.
  self.theme = nil
  self.themePath = nil
  self.built = false
  self.renderKey = nil
  self._cachedRenderKey = nil
  self.lastModelPreferences = nil
  self.lastModelPrefsSignature = nil
  -- Clear self.modelPreferences NOW, before the disk reads below. reloadActiveTheme
  -- reads self.modelPreferences with priority over session.modelPreferences. If a
  -- CPU-limit fault fires between here and the assignment on line ~690, this nil
  -- prevents reloadActiveTheme from picking up the previous stale model prefs and
  -- rendering the wrong theme on the next pass.
  self.modelPreferences = nil
  themePathMemo = {}

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
      local MP = ModelPreferences or requireModule("lib/model_preferences.lua")
      if MP and type(MP.loadByMcuId) == "function" then
        local mPrefs, mPath = MP.loadByMcuId(session.mcu_id, true)
        if mPrefs then
          session.modelPreferences = mPrefs
          session.modelPreferencesFile = mPath
          self.modelPreferences = mPrefs
          if MspRuntime and type(MspRuntime.setModelPreferences) == "function" then
            MspRuntime.setModelPreferences(mPrefs, mPath)
          end
          local d = mPrefs.dashboard or {}
          logGv("Loaded model prefs from disk: %s (override=%s preflight=%s inflight=%s postflight=%s)", tostring(mPath), tostring(d.model_override), tostring(d.model_theme_preflight), tostring(d.model_theme_inflight), tostring(d.model_theme_postflight))
        else
          logGv("MP.loadByMcuId(%s, true) returned nil", tostring(session.mcu_id))
        end
      end
    else
      logGv("No session.mcu_id available during reloadPreferencesIfNeeded")
    end

    self._lastUIRefresh = 0
  end

  -- Adopt both the stamp and sequences together when reloading succeeds so their baselines advance synchronously.
  if currentStamp then
    self._lastPrefsStamp = currentStamp
  else
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local stamp = preferencesStamp(session and session.modelPreferencesFile)
    if stamp then self._lastPrefsStamp = stamp end
  end

  if currentSeqs then
    if not self._lastReloadSeqs then self._lastReloadSeqs = {} end
    for path, seq in pairs(currentSeqs) do
      self._lastReloadSeqs[path] = seq
    end
  elseif type(fstat) == "function" then
    local reqPaths = reloadRequestPaths()
    if not self._lastReloadSeqs then self._lastReloadSeqs = {} end
    for i = 1, #reqPaths do
      local reqPath = reqPaths[i]
      local ok, info = pcall(fstat, reqPath)
      self._lastReloadSeqs[reqPath] = (ok and type(info) == "table" and (info.size or 0) > 0) and info.size or 0
    end
  end

  self._reloadPending = nil
  self.preferencesLastLoadedAt = now
  return true
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
  local fblConnected = false
  if MspRuntime and type(MspRuntime.isFblConnected) == "function" then
    fblConnected = MspRuntime.isFblConnected()
  elseif type(runtimeState) == "table" then
    fblConnected = (runtimeState.lastConnected == true)
      and (runtimeState.versionReadCompleted == true)
      and (not runtimeState.unsupportedApi)
      and (type(runtimeState.values) == "table" and type(runtimeState.values.apiVersion) == "string" and runtimeState.values.apiVersion ~= "" and runtimeState.values.apiVersion ~= "0")
  end
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
  -- Latched, and four of the five tests above are why: they are instantaneous sensor reads, and a
  -- telemetry value that has gone stale reads 0 rather than nil. `readTelemetry` writes `lq`
  -- straight from the sensor, `rss1`/`rss2` keep their previous value only when no source answers
  -- at all, and `voltage` is written whenever the read is a number -- so a value that is present
  -- and one beat late is indistinguishable from a value that was never there, and the gate can
  -- open and shut again on a single missed beat.
  --
  -- Shutting it is not cosmetic: the scene is invalidated and rebuilt, the reopening pays the full
  -- SPLASH_READY_HOLD_SECONDS because `everReady` is set by then, and the audio's connection state
  -- is reset, so the model is announced a second time.
  --
  -- A real loss of the link is `connected` going false, and that term is unlatched and still
  -- carries it. `fuelTelemetrySeen` is already this shape, but it is cleared at the end of every
  -- flight because the flight statistics own it; the gate's question is whether this session has
  -- ever had telemetry, so these two are cleared on the FBL DISCONNECT edge instead, and a new
  -- craft re-earns them. The two assignments below are what makes that safe: they run before the
  -- reads, so the first pass of a returning session earns its latches from its own sensors.
  if hasVoltage or hasFuel then self.state.batteryTelemetrySeen = true end
  if hasLq or hasRss1 or hasRss2 then self.state.rfTelemetrySeen = true end
  local batteryReady = self.state.batteryTelemetrySeen == true
  local rfReady = self.state.rfTelemetrySeen == true
  
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

  -- What has to be true before the dashboard is DRAWN:
  -- We require connection, battery telemetry, RF telemetry, UID resolution (`modelPrefsResolved`),
  -- and completion of onconnect tasks (`tasksDone`).
  -- Requiring `tasksDone` ensures the initial dashboard build is held until all onconnect tasks
  -- have completed and are no longer loading scripts via `loadScript()`. This prevents concurrent
  -- script loads from colliding with the LVGL scene build and blowing the instruction budget.
  --
  -- `startupComplete` keeps the audio on exactly the condition it had before.
  local rawReady = connected and batteryReady and rfReady and modelPrefsResolved and tasksDone
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
    local headline = onconnectPendingTaskName and ONCONNECT_STEP_TEXT[onconnectPendingTaskName]
    if not headline then
      headline = (t and t("widgets.dashboard.loading_tasks")) or "Loading data..."
    end
    if showNumbers then
      local currentStep = math.min(pDone + 1, pTotal)
      statusLine = headline .. " (" .. tostring(currentStep) .. "/" .. tostring(pTotal) .. ")"
    else
      statusLine = headline
    end
  elseif not rfReady then
    statusLine = (t and t("widgets.dashboard.waiting_for_receiver_telemetry")) or "Waiting for receiver telemetry (1RSS/2RSS)"
  elseif not batteryReady then
    statusLine = (t and t("widgets.dashboard.waiting_for_battery_telemetry")) or "Waiting for battery telemetry"
  elseif not ready then
    statusLine = (t and t("widgets.dashboard.connected_starting")) or "Connected, starting dashboard..."
  elseif softTimeoutReady then
    statusLine = (t and t("widgets.dashboard.connected_partial_telemetry")) or "Connected with partial telemetry"
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
      -- NOTE: do NOT call reloadPreferencesIfNeeded() here. The FBL
      -- reconnect-edge handler already cleared self.theme and self.built,
      -- which is sufficient to trigger a single fresh theme load in the
      -- next refresh() pass.  A redundant forced-reload here allocates a
      -- new modelPreferences table instance that races the concurrent MSP
      -- publisher reads, defeating the content-signature guard and causing
      -- multiple full scene teardowns in rapid succession (CPU limit crash).
      --
      -- The first dashboard build lands in a pass of its own: the invalidation
      -- above only marks the scene dirty, and the next STATE pass enqueues the
      -- build as a job -- see the dispatcher in widget.refresh.
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

  self.state.rfConnected = connected
  self.state.fblConnected = fblConnected
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
    state.currentFlightMaxVoltage = nil
    state.currentFlightMinLq = nil
    state.currentFlightMaxLq = nil
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
    state.currentFlightMinBecVoltage = nil
    state.lastFlightEndingVoltage = nil
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
      local currentMaxVoltage = state.currentFlightMaxVoltage
      if currentMaxVoltage == nil or state.voltage > currentMaxVoltage then
        state.currentFlightMaxVoltage = state.voltage
      end
    end

    if type(state.bec_voltage) == "number" and state.bec_voltage > 0 then
      local currentMinBecVoltage = state.currentFlightMinBecVoltage
      if currentMinBecVoltage == nil or state.bec_voltage < currentMinBecVoltage then
        state.currentFlightMinBecVoltage = state.bec_voltage
      end
    end

    -- Track link quality only when the active sensor reports a 0–100 % value.
    -- Receivers without an RQly sensor fall back to 1RSS/2RSS (RSSI in dBm, always
    -- negative); if the sensor is known to be an RSSI source or the value falls
    -- outside 0 < lq <= 100 (e.g. 0 on sensor age-out), skip tracking.
    -- Using lqSource as the discriminator matches linkIsQuality() in lib/audio.lua.
    local lq = state.lq
    local lqIsQuality = type(lq) == "number" and lq > 0 and lq <= 100
    if lqIsQuality and type(state.lqSource) == "string" and RSSI_LINK_SOURCES[state.lqSource] then
      lqIsQuality = false
    end
    if lqIsQuality then
      local currentMinLq = state.currentFlightMinLq
      if currentMinLq == nil or lq < currentMinLq then
        state.currentFlightMinLq = lq
      end
      local currentMaxLq = state.currentFlightMaxLq
      if currentMaxLq == nil or lq > currentMaxLq then
        state.currentFlightMaxLq = lq
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
    state.lastFlightMaxVoltage = state.currentFlightMaxVoltage
    state.lastMinBecVoltage = state.currentFlightMinBecVoltage
    state.lastFlightMinBecVoltage = state.currentFlightMinBecVoltage
    state.lastMinLq = state.currentFlightMinLq
    state.lastFlightMaxLq = state.currentFlightMaxLq
    -- Capture the ending (landing) voltage as the last known live voltage
    if type(state.voltage) == "number" and state.voltage > 0 then
      state.lastFlightEndingVoltage = state.voltage
    end
    state.currentFlightSeconds = 0
    state.currentFlightMinVoltage = nil
    state.currentFlightMaxVoltage = nil
    state.currentFlightMinBecVoltage = nil
    state.currentFlightMinLq = nil
    state.currentFlightMaxLq = nil
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

-- A stored path is a selection only if it names a theme: an empty select is written as the
-- string "nil", and an absent one is empty or missing altogether.
local function selectedThemePath(value)
  if value and value ~= "" and value ~= "nil" then return value end
  return nil
end

local function resolveThemePathForState(dashboard, modelPrefs, flightMode)
  if themePathMemo.dashboard == dashboard
    and themePathMemo.modelPrefs == modelPrefs
    and themePathMemo.flightMode == flightMode then
    return themePathMemo.chosen
  end

  local modelDashboard = modelPrefs and modelPrefs.dashboard or {}
  local modelOverride = modelDashboard.model_override == true

  -- A theme declares preflight, inflight and postflight itself and switches between them, so
  -- the phase keys are overrides on top of the theme chosen for the context. They are read
  -- only while the per-phase option is on; with it off the context theme covers all three,
  -- and the keys keep their values for whoever turns the option back on.
  local key = nil
  local modelKey = nil
  if dashboard and dashboard.theme_per_phase == true then
    if flightMode == "inflight" then
      key = "theme_inflight"
      modelKey = "model_theme_inflight"
    elseif flightMode == "postflight" then
      key = "theme_postflight"
      modelKey = "model_theme_postflight"
    end
  end

  local chosen = nil
  local reason = nil

  -- The model's theme is a context of its own, so an unset phase override falls back to it
  -- and only an unset model theme reaches the global table. Without that step a per-model
  -- theme set for the ground alone was replaced by a global one the moment the aircraft went
  -- inflight, which is not what a select left at its default reads as.
  if modelOverride then
    if modelKey then
      chosen = selectedThemePath(modelDashboard[modelKey])
      if chosen then reason = "model_" .. modelKey end
    end
    if not chosen then
      chosen = selectedThemePath(modelDashboard.model_theme_preflight)
      if chosen then reason = "model_context" end
    end
  end

  if not chosen and key and dashboard then
    chosen = selectedThemePath(dashboard[key])
    if chosen then reason = "global_" .. key end
  end

  if not chosen then
    chosen = selectedThemePath(dashboard and dashboard.theme_preflight)
    if chosen then reason = "global_context" end
  end

  if not chosen then
    chosen = "system/default"
    reason = "default_fallback"
  end

  logGv("resolveTheme: mode=%s, modelOverride=%s, modelPreflight=%s, globalPreflight=%s, modelKey=%s, modelValue=%s, globalKey=%s, globalValue=%s => chosen=%s (%s)",
    tostring(flightMode), tostring(modelOverride),
    tostring(modelDashboard and modelDashboard.model_theme_preflight),
    tostring(dashboard and dashboard.theme_preflight),
    tostring(modelKey),
    tostring(modelKey and modelDashboard and modelDashboard[modelKey]),
    tostring(key), tostring(key and dashboard and dashboard[key]),
    tostring(chosen), tostring(reason))

  themePathMemo.dashboard = dashboard
  themePathMemo.modelPrefs = modelPrefs
  themePathMemo.flightMode = flightMode
  themePathMemo.chosen = chosen

  return chosen
end

-- Everything reloadActiveTheme reads out of the per-model preferences sits under `dashboard`:
-- resolveThemePathForState above takes `model_override` and the `model_theme_*` keys, and
-- app/pages/settings/dashboard/lib.lua's getThemeConfig takes the `cfg_<theme>_*` keys. A
-- signature over that one flat table therefore decides whether anything a rebuild would read
-- has actually changed.
local function modelPreferencesSignature(modelPrefs)
  if type(modelPrefs) ~= "table" then return nil end
  local dashboard = modelPrefs.dashboard
  if type(dashboard) ~= "table" then return "" end

  local keys = {}
  for k in pairs(dashboard) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local parts = {}
  for i = 1, #keys do
    local k = keys[i]
    parts[i] = tostring(k) .. "=" .. tostring(dashboard[k])
  end
  return table.concat(parts, "\n")
end

-- Hoisted out of readTelemetry, which runs on the display's 2 Hz cadence: the per-pass cache
-- and the two helpers below were rebuilt each time, and they are almost everything the pass
-- allocates.
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
  -- Which sensor answered for `link`. The search path in lib/sensors.lua ends in 1RSS and
  -- 2RSS, and those carry an RSSI in dBm rather than a quality in percent, which is a
  -- difference a consumer of `lq` cannot see in the number alone.
  setField("lqSource", Sensors.active_paths and Sensors.active_paths.link)
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
    -- Instruction-budget reporting, see traceInstructionUsage above. The object count starts at
    -- 0 rather than at "unknown": before the first build this widget has put nothing on screen,
    -- so 0 is what the reactive sweep walks and the honest thing to print.
    _usagePeak = -1,
    _usageWindowPeak = -1,
    _usageReportAt = 0,
    _lastChildCount = 0,
    -- The pending job, at most one: { kind, step } or nil. See the job steps above and
    -- the dispatcher in widget.refresh.
    _job = nil,
    _lastReloadSeqs = nil,
    _reloadPending = nil,
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
      currentFlightMinVoltage = nil,
      currentFlightMaxVoltage = nil,
      currentFlightMinLq = nil,
      currentFlightMaxLq = nil,
      currentFlightMinBecVoltage = nil,
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
      batteryTelemetrySeen = false,
      rfTelemetrySeen = false,
      lastMinVoltage = nil,
      lastFlightMaxVoltage = nil,
      lastMinBecVoltage = nil,
      lastFlightMinBecVoltage = nil,
      lastMinLq = nil,
      lastFlightMaxLq = nil,
      lastFlightEndingVoltage = nil,
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
    -- A pending job may belong to the theme just torn down; drop it. The next STATE
    -- pass re-detects and enqueues a build against the new theme, in a pass of its own.
    self._job = nil

    logGv("reloadActiveTheme: flightMode=%s, selectedTheme=%s, loadedTheme=%s, v_min=%.1f, v_max=%.1f, customV=%s",
      tostring(self.flightMode), tostring(selectedTheme), tostring(self.theme ~= nil),
      nextConfig.v_min, nextConfig.v_max, tostring(hasCustomVoltage))

    local sources = {}
    if self.theme then
      local seen = {}
      local function collect(boxes)
        local parsedBoxes = nil
        if type(boxes) == "function" then
          local ok, b = pcall(boxes, nil, self.state)
          if ok and type(b) == "table" then parsedBoxes = b end
        elseif type(boxes) == "table" then
          parsedBoxes = boxes
        end
        if not parsedBoxes then return end
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
      collect(self.theme.boxes)
      -- Header boxes stand in the same tree and their closures read the same snapshot.
      collect(self.theme.header_boxes)
    end
    self.boxSources = sources
    -- One immediate build, so a theme switch never leaves the new tree a tick of "--"
    -- staring at an empty snapshot.
    if DerivedSnapshot and type(DerivedSnapshot.build) == "function" then
      DerivedSnapshot.build(self.state, self.boxSources)
    end
  end

  local function performBackgroundWork(self, isBackground)
    local now = nowSeconds()
    if self._lastWorkTick == now then return self.connectionReady end
    self._lastWorkTick = now

    if not self._lastLogicTick then self._lastLogicTick = 0 end
    -- A start, and not merely "not ready": with no flight controller present the gate below is
    -- false for as long as the radio is on, and paying the faster rate for that would be the
    -- whole steady state of a bench radio.
    local starting = (self.state.rfConnected == true) and (self.connectionReady ~= true)
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
    
    local reloaded = (reloadPreferencesIfNeeded(self, false, isBackground) == true)
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
    local isPostflightOffline = (self.state.hadInflightFlight == true) and (self.state.rfConnected ~= true)
    if not isPostflightOffline then
      if (now - (self._lastTelemetryReadAt or 0)) >= TELEMETRY_READ_SECONDS then
        self._lastTelemetryReadAt = now
        readTelemetry(self.state)
        -- The snapshot the reactive closures read, rebuilt on the same cadence as the
        -- telemetry read that feeds it -- probing is legal here and nowhere in the sweep.
        if DerivedSnapshot and type(DerivedSnapshot.build) == "function" then
          DerivedSnapshot.build(self.state, self.boxSources)
        end
      end
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
      -- Clear the reference so the identity check fails on the next frame
      -- and the slow-path signature comparison is triggered.  Keep the
      -- signature itself so that an identical modelPrefs content (same model,
      -- same settings) is correctly identified as "no change" and only a
      -- genuine model or settings change triggers a theme rebuild.
      self.lastModelPreferences = nil
      -- self.lastModelPrefsSignature is intentionally NOT cleared here.
      self.flightMode = "preflight"
      self.theme = nil
      self.built = false
      self.renderKey = nil
      self._cachedRenderKey = nil
      self._job = nil
      if self.audioState and DashboardAudio and type(DashboardAudio.resetConnectionState) == "function" then
        DashboardAudio.resetConnectionState(self.audioState)
      end
      widgetLog(self, "FBL reconnect edge: reset dashboard session state", "info")
    elseif not isFblConnected and wasFblConnected then
      -- The session latches are cleared here rather than on the connect edge, and the difference
      -- is not stylistic. updateConnectionState() runs at the top of this pass, so a clear placed
      -- on the connect edge is first READ by the next pass -- the opening pass of a new session,
      -- which is exactly where an instantaneous sensor read is least likely to answer. A brief
      -- interruption is the case this gate exists for, and it is the case where that pass would
      -- find lq and both RSS at 0, shut the gate, tear the scene down and announce the model a
      -- second time -- the failure the latch was added to prevent. Cleared here, they are false
      -- for the whole disconnected stretch and the returning session earns them back before
      -- anything reads them.
      self.state.batteryTelemetrySeen = false
      self.state.rfTelemetrySeen = false
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

    -- A different table is not a different preference set. The connect chain
    -- (tasks/events/onconnect/tasks/uid.lua), the MSP publisher (tasks/msp/runtime.lua) and
    -- reloadPreferencesIfNeeded above each load the per-model preferences file on their own,
    -- so the same content arrives here as several distinct tables within a few hundred
    -- milliseconds. Comparing the table identity made every one of them call
    -- reloadActiveTheme, which clears `built` and `renderKey` and so tears the whole theme
    -- page down and builds it again -- and a build shares the widget's instruction budget
    -- with the reactive-reference sweep the firmware runs after it. Compare the content the
    -- rebuild would read instead, and keep the identity test as the cheap path so the
    -- signature is only built when the table really was replaced.
    local modelPrefsChanged = false
    if modelPrefs ~= self.lastModelPreferences then
      local signature = modelPreferencesSignature(modelPrefs)
      modelPrefsChanged = (signature ~= self.lastModelPrefsSignature)
      self.lastModelPrefsSignature = signature
    end
    self.lastModelPreferences = modelPrefs

    if reloaded then
      -- If preferences were reloaded from disk in this pass, defer theme module loading
      -- to the next pass to prevent EdgeTX CPU limit faults. reloadPreferencesIfNeeded
      -- already invalidated self.theme = nil and self.built = false. The next pass
      -- will run reloadActiveTheme on a dedicated fresh instruction budget.
      if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
        _G.rfsuite.session.event_context = nil
      end
      return ready
    end

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
    self._job = nil
  end

  function widget.reload(self, force)
    logGv("widget.reload called with force=%s", tostring(force))
    reloadPreferencesIfNeeded(self, force ~= false)
    reloadActiveTheme(self)
    self._job = nil
    self.built = false
    self.renderKey = nil
    self._cachedRenderKey = nil
    self._lastUIRefresh = 0
    -- Reporting starts over, which is what makes switching tracing on mid-session work: changing
    -- the debug level rewrites preferences.ini, which reloadPreferencesIfNeeded watches,
    -- so the reload lands at exactly the moment a user is asked to turn tracing on.
    self._usagePeak = -1
    self._usageWindowPeak = -1
    self._usageReportAt = 0
  end


  -- One work class per pass. `refresh` dispatches: when a job is pending, the pass runs
  -- that job and nothing else; otherwise it runs the background/state half, whose
  -- invalidation checks may enqueue a job but never execute one. A build therefore never
  -- shares a pass with the connect chain, so the two cannot sum against the firmware's
  -- per-call instruction limit. This generalises the one-tick deferral #152 introduced
  -- for theme loads into a structural rule for every build.
  function widget.refresh(self, event, touchState)
    traceInstructionUsage(self)

    -- Route touch/key events to LVGL engine when active (e.g. fullscreen)
    if lvgl and type(lvgl.onEvent) == "function" and event ~= nil then
       -- On some EdgeTX versions, touchState coordinates are global.
       -- We need to ensure LVGL knows the widget's offset if it doesn't handle it.
       -- However, in Fullscreen, offset is usually 0,0.
       lvgl.onEvent(event, touchState)
    end

    if self.zone then
      self.state.zoneW = self.zone.w or 0
      self.state.zoneH = self.zone.h or 0
      self.state.zoneX = self.zone.x or 0
      self.state.zoneY = self.zone.y or 0
    end
    self.state.flightMode = self.flightMode

    -- JOB pass: serve the link with the minimal queue quantum, then run one job step.
    -- pump() is the queue half of tick() and nothing else, so in-flight MSP transfers
    -- keep moving while the build occupies the pass.
    --
    -- The same event context the background half sets brackets the pump: the poll and
    -- drain loops it reaches (tasks/msp/common.lua, tasks/msp/queue.lua) pick their
    -- widget-state bounds -- counts per pass, never wall clock -- by reading it, and
    -- without the bracket a JOB pass would silently run them under the tool rules.
    if self._job then
      if MspRuntime and type(MspRuntime.pump) == "function" then
        if type(_G) == "table" then
          _G.rfsuite = _G.rfsuite or {}
          _G.rfsuite.session = _G.rfsuite.session or {}
          _G.rfsuite.session.event_context = "widget"
        end
        MspRuntime.pump()
        if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
          _G.rfsuite.session.event_context = nil
        end
      end
      if self._job.step(self) then
        self._job = nil
      end
      return
    end

    -- STATE pass: the background half, then invalidation checks that only enqueue.
    local ready = performBackgroundWork(self, false)

    if not ready and self.flightMode ~= "postflight" then
      local statusLine = self.statusLine or "Please wait..."
      local splashKey = "splash|" .. tostring(statusLine) .. "|" .. tostring(self.state.zoneW) .. "x" .. tostring(self.state.zoneH)
      if self.renderKey ~= splashKey then
        self.renderKey = splashKey
        self.built = false
      end
      if not self.built then
        self._job = { kind = "splash", step = splashJobStep }
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
      -- Fall through: detection and enqueue happen in this same pass, and the build
      -- lands in the next one, which carries nothing else.
    end

    if not self.built then
      if isInteractive then
        self._job = { kind = "menu", step = menuJobStep }
      else
        self._job = { kind = "scene", step = sceneJobStep }
      end
    end
  end

  function widget.background(self)
    performBackgroundWork(self, true)
    return 0
  end

  reloadActiveTheme(widget)
  return widget
end

return Runtime
