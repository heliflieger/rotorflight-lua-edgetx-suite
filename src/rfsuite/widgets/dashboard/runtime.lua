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
-- Box sources that are a text and the severity of it: naming either declares both, because a
-- colour closure can read only what the derived snapshot carries. The two rows are the speed
-- controller's health on file since the flight controller connected and what it is reporting on
-- this pass; they are separate pairs on purpose, so a surface asking for one is not handed the
-- other. Built once rather than per theme load, and walked where the sources are collected.
local PAIRED_SOURCES = {
  { "esc_status", "esc_status_level" },
  { "esc_status_live", "esc_status_live_level" },
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

-- How long a hole between two passes has to be before it is worth a line.
--
-- Three quanta. The firmware calls a widget's refresh() from its menus task on a fixed period and
-- never catches up (radio/src/tasks.cpp, MENU_TASK_PERIOD; the call site is LuaWidget::refresh in
-- lua_widget.cpp), so a pass that overruns its slot costs the NEXT slots rather than running
-- twice, and every gap is a multiple of that period. Two slots in a row is ordinary on a busy
-- start-up; a hole this long is what anything timed from a pass overruns by, and on this widget
-- the shortest deadline of the lot is the in-flight overlay's value pulse.
local PASS_GAP_REPORT = 0.15

-- Which shared-memory slot carries this widget's heartbeat, and how the two figures are packed
-- into the one integer it holds.
--
-- **The map of the sixteen slots is in tasks/events/telemetry_bg/drain.lua**, which allocates
-- them; these are literals rather than a read of that module because nothing on this pass loads
-- it and pulling in the decoder's subtree for two constants would cost more than the feature.
-- Keeping them in step is therefore a manual obligation, and the map is the authority.
--
-- The wrap stays far inside the firmware's `int`: `shmVar` is a plain C int array
-- (radio/src/lua/api_general.cpp), so the packed value must not reach 2^31. It also never lands
-- on zero, because a slot that was never written reads zero and a writer that produced one would
-- be indistinguishable from that.
local SHM_PASS_ID = 15
local SHM_PASS_SHIFT = 256
local SHM_PASS_WRAP = 0x400000

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

  -- What the LAST pass cost, kept where anything else on this pass can read it.
  --
  -- getUsage() answers the figure for the cycle that has just been billed, and this runs at the
  -- very top of refresh -- so on THIS pass it describes the previous one, which is exactly what a
  -- gate wants: work that is optional can look at what the widget has just been costing and stand
  -- aside. The overlay's ground half is the one caller (inflight/prime.lua); nothing else reads it
  -- and nothing decides anything about the dashboard from it.
  self._usageLast = percent

  -- The cheap path, taken on all but one pass in fifty: two comparisons and a clock read.
  -- Sampling has to happen on every pass, because the peak is the point of the line.
  if percent > self._usageWindowPeak then self._usageWindowPeak = percent end
  if percent > self._usagePeak then self._usagePeak = percent end

  -- The heartbeat, for a reader outside this Lua state.
  --
  -- A widget whose pass overruns the instruction budget is not called again, so THIS function
  -- cannot report the pass that ends it and no line in the widget's own log can be the failing
  -- one. What says it stopped is that the counter below stops moving, and only something outside
  -- this state can see that -- the shared-memory slots are the one channel there is.
  --
  -- A moving counter rather than a flag, and never zero: nothing clears the slots, not a model
  -- change and not the interpreter being torn down, so a flag left set by a state that has gone
  -- away would mislead for as long as the radio is on, and a slot that was never written reads
  -- zero. It counts PASSES rather than saying "I am alive", which is also what makes it the rate
  -- a reader wants: the difference between two samples over the time between them is the pass
  -- rate, and a widget at twelve per cent of budget and thirty passes a second is a different
  -- machine from one at twelve per cent and four.
  --
  -- `widget.background` bumps the same counter. EdgeTX calls `background()` instead of
  -- `refresh()` for a widget that is not on the visible screen -- one on another screen page, or
  -- behind one of the radio's menu pages (WidgetsContainer::refreshWidgets,
  -- radio/src/gui/colorlcd/mainview/widgets_container.cpp) -- and that pass still runs the
  -- dashboard's background work, so a counter bumped here alone would stand still for as long as
  -- the dashboard is off screen and the reader would record a running widget as stopped. Bumped
  -- by both, it stands still only while the radio calls this widget not at all, which is the case
  -- it exists for: past the instruction budget the radio calls neither (LuaWidget::background
  -- returns at once on a widget that has raised, radio/src/lua/lua_widget.cpp). The few lines
  -- below are repeated there rather than shared through a function, because a call here would
  -- cost every pass that draws.
  --
  -- The gate is sampled on the report window below and cached, not asked per pass: this is a
  -- diagnostic, it belongs behind the debug level like every other, and asking the preferences
  -- for it thirty times a second would be the diagnostic becoming the cost.
  -- Sampled once on the first pass and then on the report window below. Without the first
  -- sample the heartbeat would not start until five seconds in -- and a widget that dies inside
  -- those five seconds is exactly the case worth recording, since the cold-start pass is the
  -- most expensive one this widget has.
  if self._shmOn == nil then
    self._shmOn = Log and type(Log.wanted) == "function" and Log.wanted("debug") or false
  end

  self._shmPass = (self._shmPass or 0) + 1
  if self._shmPass >= SHM_PASS_WRAP then self._shmPass = 1 end
  if self._shmOn and type(setShmVar) == "function" then
    setShmVar(SHM_PASS_ID, self._shmPass * SHM_PASS_SHIFT + (percent > 255 and 255 or percent))
    -- Which dashboard drew last, for widget.background. Every dashboard on the radio runs its own
    -- copy of this file, so the mark is kept on the Lua state's shared table, as a token rather
    -- than the widget itself so that a dashboard removed from the screen is not kept alive by it.
    local shared = _G.rfsuite
    if type(shared) == "table" then
      shared.dashboardHeartbeatOwner = self._shmToken
    end
  end

  local now = nowSeconds()

  -- THE REFRESH CADENCE, which is the firmware's and not this widget's.
  --
  -- Nothing inside a pass can see the hole in front of it, and the hole is what every deadline
  -- the widget keeps is really measured against: the in-flight overlay writes a magnitude to a
  -- global variable and clears it a set number of milliseconds later, from a pass, so a pass that
  -- does not come leaves the magnitude standing and the flight controller repeats the step.
  --
  -- Two clock reads separate the two halves of such a hole. This one is the top of the pass and
  -- the end of refresh writes the other, so the line can say how much of the gap this widget
  -- spent inside its own refresh and how much of it went elsewhere in the radio -- another Lua
  -- state, a background script, the card. A pass that never reached the end of refresh leaves no
  -- second read behind and the line says -1 rather than guessing: killed by the instruction limit
  -- is exactly the case worth telling apart.
  --
  -- The cost on an ordinary pass is one field read, one field write and one comparison; the
  -- arithmetic and the formatting are inside the branch, which on a healthy radio is never taken.
  local lastPassAt = self._passAt
  self._passAt = now
  if lastPassAt and (now - lastPassAt) > PASS_GAP_REPORT
    and Log and type(Log.emitf) == "function" then
    local endAt = self._passEndAt
    local inside = (endAt and endAt >= lastPassAt) and (endAt - lastPassAt) or -0.001
    Log.emitf("rfsuite.widget", "debug",
      "pass gap %d ms, %d ms of it inside refresh, previous pass %s",
      math.floor((now - lastPassAt) * 1000 + 0.5), math.floor(inside * 1000 + 0.5),
      tostring(self._passWork))
  end

  if now < self._usageReportAt then return end
  self._usageReportAt = now + USAGE_REPORT_INTERVAL

  self._shmOn = Log and type(Log.wanted) == "function" and Log.wanted("debug") or false

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

-- A save started in the tool opened from this widget (widgets/dashboard/tool_host.lua) outlives
-- the tool. Its messages are filed under the save's own client, which the tool's close leaves on
-- the queue, so the replies keep advancing it on this widget's MSP tick: the writes, the EEPROM
-- commit, the restart. The phases that wait on time instead -- the wait for a restarted flight
-- controller to answer, the bound on the connect chain run after it, the short linger of a
-- successful outcome -- advance only in SavePipeline.wakeup(), which the tool calls while it runs
-- and which nothing called once it was closed. A restart under way when fullscreen was left then
-- stayed in its probe phase, the connect chain was never run again for the restarted board, and
-- the next open of the tool reported a board that had not come back.
--
-- The run is shared through the global table (tasks/msp/save_pipeline.lua), so the test is a read,
-- and the module is loaded only when there is something to drive. While the tool is open this
-- widget does not reach it: the tool runs in place of the widget's pass and drives the save itself.
-- A second dashboard on another screen page still does, from its background pass, and that is
-- harmless: every phase of wakeup() advances on a reply, a deadline or a one-time transition, so a
-- call from a second instance soon after the tool's own finds nothing new to do.
local SavePipeline = nil

local function driveLeftSave()
  local tasks = _G.rfsuite and _G.rfsuite.tasks
  local shared = tasks and tasks.savePipeline
  if type(shared) ~= "table" then return end
  -- A successful outcome that clears itself is driven too: left standing, it would be drawn by the
  -- tool's first build at its next open, before the tool's own wakeup could clear it.
  if shared.run == nil and not (type(shared.outcome) == "table" and shared.outcome.clearAt) then
    return
  end
  if not SavePipeline then
    SavePipeline = requireModule("tasks/msp/save_pipeline.lua")
  end
  if type(SavePipeline) == "table" and type(SavePipeline.wakeup) == "function" then
    pcall(SavePipeline.wakeup)
  end
end

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

local function tickMspRuntime(self, carry)
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
  
  -- Ahead of the event runner, so a connect chain it asks for again starts on this pass, and of
  -- the pump below, so a probe it queues goes out on this pass too.
  driveLeftSave()

  if EventsRuntime and type(EventsRuntime.wakeup) == "function" then
    pcall(EventsRuntime.wakeup, carry)
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
local PREFERENCES_FILE  = "/SCRIPTS/TOOLS/rfsuite.user/preferences.lua"
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

-- The in-flight tuning overlay, loaded on first use rather than at the top of this file. It is
-- off by default and the widget's cold start is the pass closest to the firmware's instruction
-- limit, so a model that does not use it never pays for the module.
--- A load that FAILED is not a load that will always fail.
--
-- These files are read the first time a pilot's model has the overlay switched on, which on a
-- radio that came up without a flight controller is the pass the connect chain and the theme
-- reload are already filling. lib/require.lua runs a chunk under pcall, and a pcall catches the
-- firmware's instruction-limit error like any other -- so that pass can lose the load through no
-- fault of the file. Latching the answer to `false` there turned one busy pass into an overlay
-- that stayed off for the rest of the session.
--
-- So a failure is retried, and not on every pass: RETRY_TICKS apart, which on a radio's 10 ms tick
-- is a second. A file that genuinely is not there then costs one load attempt per second and
-- nothing else, and one that lost a race gets the next quiet pass.
local INFLIGHT_RETRY_TICKS = 100

local function loadInflightModule(cache, path)
  if type(cache.module) == "table" then return cache.module end
  local now = (type(getTime) == "function") and getTime() or 0
  if cache.triedAt ~= nil and (now - cache.triedAt) < INFLIGHT_RETRY_TICKS then return nil end
  cache.triedAt = now
  local module = requireModule(path)
  if type(module) ~= "table" then return nil end
  cache.module = module
  return module
end

local InflightDriveCache = {}
local function inflightDrive()
  return loadInflightModule(InflightDriveCache, "widgets/dashboard/inflight/drive.lua")
end

-- Three switches, and they answer different questions. The preview switch under
-- Settings > General is the pilot saying he wants an unfinished feature on the radio at all;
-- the radio's own `enabled`, beside the interlock switch it belongs with, says he wants the
-- overlay on this transmitter; the per-model `enabled` says which model it is set up for. None
-- implies another, so all three are read, and this is the one place the widget half asks: with
-- any of them off the drive is never constructed, no module of the overlay is loaded and no
-- variable is written.
--
-- The global preferences the widget holds are re-read when the file changes, and that reload
-- is held back while the craft is armed -- so a preview or a radio switch changed in the air is
-- adopted once it has landed, not during the flight it would take the surface away in.
local function inflightEnabled(self)
  local prefs = self.preferences
  local general = prefs and prefs.general
  if not isTruthy(general and general.preview_inflight_tuning) then return false end
  local radio = (type(prefs) == "table") and prefs.inflight or nil
  if type(radio) ~= "table" or radio.enabled ~= true then return false end
  local model = self.modelPreferences
  local section = (type(model) == "table") and model.inflight or nil
  return type(section) == "table" and section.enabled == true
end

--- Everything the overlay wrote goes back to 0. Called on every way out -- the widget going to
-- background, the link dropping, the feature being switched off -- because which transition is
-- actually observed is not knowable in advance, and a value variable left standing keeps the
-- flight controller stepping.
local function cleanupInflight(self)
  if self._inflight == nil then return end
  local drive = inflightDrive()
  if drive then drive.cleanup(self) end
end

-- The overlay's ground half, loaded on the same terms and separately from the drive: it speaks
-- MSP and the drive does not, and a widget whose pilot has the feature off loads neither.
local InflightPrimeCache = {}
local function inflightPrime()
  return loadInflightModule(InflightPrimeCache, "widgets/dashboard/inflight/prime.lua")
end

-- The screen is loaded by the two tuning job steps, which already answer "nothing built this pass"
-- when it is not there. It goes through the same gate so that a job pass cannot re-read the file
-- on every pass either.
local InflightScreenCache = {}
local function inflightScreen()
  return loadInflightModule(InflightScreenCache, "widgets/dashboard/inflight/screen.lua")
end

--- The clear the widget's entry point can reach when the widget itself has been shut down.
--
-- src/widgets/rfsuite/main.lua holds a widget off for 1.2 s after a CPU limit and RETURNS before
-- widget.refresh for the whole of that time. Every path that takes the overlay's two variables
-- back to 0 -- the interlock falling, fullscreen closing, the widget going to background, the link
-- dropping -- lives inside refresh or background, so for those 1.2 s not one of them runs. A value
-- left standing there is a flight controller stepping a parameter every 200 ms with nothing
-- driving it, which is exactly the state the whole drive is built to make impossible.
--
-- So the runtime hands the entry point something it can call instead. It is two model writes and
-- nothing else: no module is loaded, nothing is allocated, and a drive that believes both
-- variables are already at 0 does not write at all. The flight mode each write goes back to is the
-- one it was made in, because model.setGlobalVariable resolves a "same as FMx" link itself and a
-- clear sent to the wrong mode leaves the first one standing.
local function installInflightPanic(self)
  if self._inflightPanic ~= nil then return end
  self._inflightPanic = function()
    local drive = self._inflight
    if drive == nil then return end
    local settings = drive.settings
    if settings == nil then return end
    if drive.written ~= 0 and (settings.value_gvar or 0) > 0 then
      model.setGlobalVariable(settings.value_gvar - 1, drive.writtenFm or 0, 0)
      drive.written = 0
      drive.writtenFm = nil
    end
    if (drive.bankWritten or 0) ~= 0 and (settings.bank_gvar or 0) > 0 then
      local fm = drive.bankFm
      -- Through the drive's own radio table rather than the global, which is where every other
      -- reading of the flight mode in the overlay comes from.
      if fm == nil and type(drive.radio) == "table" then fm = drive.radio.flightMode() end
      model.setGlobalVariable(settings.bank_gvar - 1, fm or 0, 0)
      drive.bankWritten = 0
      drive.bankFm = nil
    end
  end
end

--- One pass of the overlay. Off the overlay this costs one table lookup; with it enabled but the
-- interlock open, one switch read.
local function tickInflight(self)
  if self._foreground ~= true or not inflightEnabled(self) then
    cleanupInflight(self)
    return
  end
  local drive = inflightDrive()
  if not drive then return end
  local instance = drive.get(self)
  if instance ~= nil then installInflightPanic(self) end
  -- The ground half runs BEFORE the drive's own pass, on the same drive object: what it moves has
  -- to reach the published snapshot in the pass that moved it, and it is the drive's pass that
  -- publishes.
  local prime = inflightPrime()
  if prime and instance then prime.tick(self, instance) end
  drive.tick(self)
end

--- The overlay's fast half, on EVERY foreground pass rather than on the logic tick.
--
-- performBackgroundWork below runs at 100 ms and a JOB pass skips it entirely, which is the right
-- cadence for reading telemetry into a dashboard and the wrong one for a surface that is driving
-- a flight controller. The value the pilot reads is the board's answer to the step he has just
-- asked for, and the trims are momentary contacts a slower poll can miss between two ticks.
--
-- Costs one table lookup and one boolean test while the overlay is not live, and it constructs
-- nothing: the drive is built by tickInflight and this only ever samples one that exists.
local function sampleInflight(self)
  if self._inflight == nil then return end
  local drive = inflightDrive()
  if drive and type(drive.sample) == "function" then drive.sample(self) end
end

-- Which tuning surface this pass belongs to, or nil for the dashboard as it has always been.
-- `zone` needs the interlock; `fs` is also reached from the quick settings menu with the
-- interlock open, where the drive is inert and the screen is a read-out.
local function inflightMode(self, isInteractive)
  local snapshot = self.state and self.state.inflight
  if type(snapshot) ~= "table" then return nil end
  if isInteractive then
    if snapshot.live == true or self.inflightFullscreen == true then return "fs" end
    return nil
  end
  -- `setupFault` is the interlock closed and the overlay refusing: the model's setup check found
  -- something that would make a press move the wrong parameter. The zone surface comes up anyway
  -- and its ground read-out names the fault, because a switch that does nothing and says nothing
  -- is the one failure a pilot cannot act on.
  if snapshot.live == true or snapshot.setupFault == true then return "zone" end
  return nil
end

-- The job slot. At most one job is pending per widget, held in `self._job` as
-- { kind, step }: `kind` names the job for the log line, `step(self)` runs the work
-- against the CURRENT state (never a snapshot taken at enqueue time) and returns true
-- when the job is complete. The splash and view jobs complete in one step; the scene job
-- returns false to keep the slot and spread its build over several passes -- prepare,
-- a bounded chunk per pass, then the swap. The STATE pass enqueues, the JOB pass
-- executes -- see the dispatcher in widget.refresh.

-- Whether an error is the firmware's instruction limit. The entry point owns the response to it
-- (see the dispatcher in widget.refresh), so a step that catches an error of its own hands this
-- one on rather than treating it as a failure of what it was running.
local function isCpuLimitError(err)
  return (LogSink and type(LogSink.isCpuLimitError) == "function" and LogSink.isCpuLimitError(err))
    or (type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil)
end

-- How many times in a row a job of one kind may raise before it is no longer armed. The
-- dispatcher catches a raising step and clears the slot and `built`, and the next STATE pass
-- arms the same job again -- so a cause that does not go away (a theme file that throws, a nil
-- in a scene definition) would have the widget run the failing step every other pass for as
-- long as it is up, writing a fault line each time. The count is per kind and consecutive: a
-- step of that kind that draws its surface clears it, and a theme reload clears them all, since
-- that is what replaces the code that raised.
local JOB_FAULT_LIMIT = 3

-- How long a held step control may keep back a rebuild of the surface it is on (the hold gate in
-- the state pass), counted from the start of the hold. The rebuild waits because it would delete
-- the button under the finger; but a release EdgeTX never reports would then keep it waiting for
-- as long as the surface is up. Past this the rebuild runs, and lets go of the hold first, as
-- every rebuild that is not held back does. The flight controller steps a held value every
-- 200 ms after the first 100 ms (fc/rc_adjustments.c), so five seconds is 25 steps: at the
-- largest step of every row but the head speed, 10, that is 250 units -- the whole range of most
-- parameters, which run 0-250 or 0-255. A hold that long has crossed the range or lost its
-- release. A hold with no rebuild waiting is not ended here: the drive ends every hold itself after
-- the same five seconds (HOLD_LIMIT_SECONDS in widgets/dashboard/inflight/drive.lua). That limit
-- counts from the press, this one from the first pass that sees the hold, so the drive's fires
-- first and this cap stays as the second line; keep the two numbers equal.
local HOLD_DEFER_SECONDS = 5

local function jobCapped(self, kind)
  return (self._jobFaults[kind] or 0) >= JOB_FAULT_LIMIT
end

local function splashJobStep(self)
  local statusLine = self.statusLine or "Please wait..."
  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local title = (t and t("widgets.dashboard.connecting_fbl")) or "Connecting FBL..."
  local splash = buildConnectionSplash(self.zone, statusLine, title)
  -- At full screen the splash carries the tool control, so the tool can be opened while the
  -- dashboard is still waiting for the link. A zone takes no press, so it is not drawn there.
  if self._job and self._job.fullscreenSplash then
    local Controls = requireModule("widgets/dashboard/fullscreen_controls.lua")
    if type(Controls) == "table" and type(Controls.appendTool) == "function" then
      Controls.appendTool(splash, self)
    end
  end
  lvgl.clear()
  lvgl.build(splash)
  self.built = true
  -- What the reactive sweep walks from the next pass on. Kept up to date here as well as
  -- at the scene build below, so the usage line never reports a count belonging to a
  -- tree that has already been cleared.
  self._lastChildCount = #splash
  return true
end

-- The zone view a free-form theme's scene build draws instead of the theme, or nil; defined with
-- the theme views further down.
local zoneViewFor

-- A free-form theme's `build` must return a node list. One that returns anything else has drawn
-- nothing and leaves `built` false, so the state pass would arm the same build again every other
-- pass, with nothing logged. It raises instead, and is counted and given up like any other build
-- that raises (see JOB_FAULT_LIMIT); the message names the theme.
local function checkNodeList(self, children)
  if type(children) ~= "table" then
    error("theme build returned " .. type(children) .. ", not a node list: " .. tostring(self.themePath), 0)
  end
end

-- The log lines of a job step that raised: the error itself, and on the raise that reaches
-- JOB_FAULT_LIMIT the reason the screen now shows what it shows.
local function logJobFault(self, jobKind, err, faults)
  widgetLog(self, "job step error (" .. tostring(jobKind) .. "): " .. tostring(err), "error")
  if faults == JOB_FAULT_LIMIT then
    widgetLog(self, "job " .. tostring(jobKind) .. " raised " .. faults
      .. " times in a row; not retried until the theme is reloaded", "error")
  end
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
    -- A zone view the theme registered takes the zone's place while its condition holds. It is
    -- looked for here, in the branch only a free-form theme reaches, so a declarative theme's
    -- build carries no test for it.
    local zoneView = zoneViewFor(self)
    if zoneView ~= nil then
      -- A zone view whose build raises is given up on, with one log line, and the theme's own
      -- zone picture is built instead, in this same step -- rather than the dispatcher clearing
      -- the job and the next pass queuing the same failing build again.
      local nodes = {}
      local ok, err = pcall(zoneView.build, nodes, self.zone, self.state)
      if ok then
        lvgl.clear()
        lvgl.build(nodes)
        self.built = true
        self._lastChildCount = #nodes
        return true
      end
      if isCpuLimitError(err) then error(err, 0) end
      local entry = self._zoneView
      widgetLog(self, "zone view '" .. tostring(entry and entry.id) .. "' of the theme did not build: " .. tostring(err), "warn")
      if entry ~= nil then entry.failed = true end
      self._zoneView = nil
    end
    -- A free-form theme builds in one step, exactly as before -- the engine cannot chunk
    -- what it does not render.
    local children = self.theme.build(self.zone, self.state)
    checkNodeList(self, children)
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

-- The fullscreen views (widgets/dashboard/views.lua): which surface fullscreen shows, and what
-- follows a press on it. Loaded on the first fullscreen pass rather than at the top of this
-- file, through the same retrying loader as the overlay, so a dashboard that is never put full
-- screen never pays for it and a load lost to a busy pass is tried again.
local ViewsCache = {}
local function viewsModule()
  return loadInflightModule(ViewsCache, "widgets/dashboard/views.lua")
end

-- The `ctx` a theme's fullscreen builds receive: one per widget, made on the first build that
-- needs it and dropped when the theme on screen changes (takeFullscreenMode).
local function viewCtx(self)
  local ctx = self._viewCtx
  if ctx == nil then
    local Views = viewsModule()
    ctx = Views and Views.bind(self) or nil
    self._viewCtx = ctx
  end
  return ctx
end

-- The suite's tool, run inside this widget (widgets/dashboard/tool_host.lua). The press that
-- opens it has already loaded the module through the module cache, so `self._toolHost` is never
-- set without it; this is a cache read.
local function toolHostModule()
  return requireModule("widgets/dashboard/tool_host.lua")
end

--- Draw the fullscreen view the job is named after: the quick menu, the battery picker, or a
--- view the theme registered.
---
--- The view's module is loaded here, on the job pass, and kept on this widget's registry entry,
--- which is where the state pass reads a view's own render key from. A theme's module -- a view
--- of its own, or the look of the menu or the picker -- is built like the rest of the theme,
--- `build(children, zone, state, ctx)`. What the picker offers and what its presses do stay the
--- widget's either way: the theme draws the `battery_pick` record through `ctx`, and RTN is the
--- core picker's `back`. The widget's own picker, drawn where a theme does not replace it, keeps
--- its close box.
local function viewJobStep(self)
  local Views = viewsModule()
  local entry = Views and Views.find(self, self._job.kind) or nil
  if entry == nil then return true end
  local view = Views.load(self, entry)
  if view == nil then return true end
  local children = {}
  if entry.load ~= nil then
    -- A theme's build that raises is given up on as a module that does not load is, rather than
    -- raising out of the step: the dispatcher would clear the job and the next pass queue the
    -- same failing build again. A replaced look is built from the core module at once; a view of
    -- the theme's own has been closed, and the next pass builds what lies under it.
    local ok, err = pcall(view.build, children, self.zone, self.state, viewCtx(self))
    if not ok then
      if isCpuLimitError(err) then error(err, 0) end
      Views.fail(self, entry, "did not build: " .. tostring(err))
      if entry.theme then return true end
      view = Views.load(self, entry)
      if view == nil then return true end
      children = {}
      view.build(children, self)
    end
  else
    view.build(children, self)
  end
  lvgl.clear()
  lvgl.build(children)
  self.built = true
  self._lastChildCount = #children
  -- The state pass keyed this build before the module was loaded, so without the module's own
  -- key; the next one will include it. Record that key now, or the view is built twice on its
  -- first opening.
  self.renderKey = Views.viewKey(self, entry, entry.id)
  return true
end

-- What the derived snapshot resolves while a fullscreen view stands whose module names readings of
-- its own: the theme's sources (`self.boxSources`, collected at the theme load) followed by the
-- view's `sources(zone, state)`, without duplicates. Nil where no such view is on top, and the
-- snapshot then resolves the theme's sources alone -- so a reading only a view shows is read only
-- while that view is open.
--
-- The module is the one the job pass loaded for the view, never loaded here; a view that has not
-- been built yet names nothing until it has. The list is made once per view module and per
-- source list of the theme -- a theme reload replaces the latter -- so a standing view costs two
-- comparisons a pass. A pair the host completes for the theme (PAIRED_SOURCES) is not completed
-- for a view: it names both halves itself.
local function viewSnapshotSources(self, Views, viewId)
  if viewId == nil then return nil end
  local entry = Views.find(self, viewId)
  local view = entry and entry.loaded or nil
  if view == nil or type(view.sources) ~= "function" then return nil end
  local base = self.boxSources or {}
  local memo = self._viewSourcesMemo
  if memo ~= nil and memo.view == view and memo.base == base then return memo.list end
  local list, seen = {}, {}
  for i = 1, #base do
    list[i] = base[i]
    seen[base[i]] = true
  end
  local ok, declared = pcall(view.sources, self.zone, self.state)
  if ok and type(declared) == "table" then
    for i = 1, #declared do
      local src = declared[i]
      if type(src) == "string" and src ~= "" and not seen[src] then
        seen[src] = true
        list[#list + 1] = src
      end
    end
  end
  self._viewSourcesMemo = { view = view, base = base, list = list }
  return list
end

-- Whether a node list binds a press anywhere, nested children included.
local function bindsPress(nodes)
  for i = 1, #nodes do
    local node = nodes[i]
    if type(node) == "table" then
      if node.press ~= nil then return true end
      if type(node.children) == "table" and bindsPress(node.children) then return true end
    end
  end
  return false
end

-- The widget's own menu control and way out, for a fullscreen theme that binds none of its own.
local function appendFullscreenControls(self, nodes)
  local Controls = requireModule("widgets/dashboard/fullscreen_controls.lua")
  if type(Controls) == "table" and type(Controls.append) == "function" then
    Controls.append(nodes, self)
  end
end

--- Build the theme that has taken fullscreen, at the fullscreen zone: the base layer under the
--- fullscreen views (widgets/dashboard/views.lua).
---
--- The chunking and the swap are sceneJobStep's, reached through it unchanged; this step adds what
--- only the fullscreen build has, so the dashboard's own scene build carries no test for it. A
--- free-form theme gets the views' `ctx` as the third argument of `build(zone, state, ctx)`,
--- through which it binds its own controls. A tree that binds no press anywhere -- always the
--- case for a declarative theme, whose boxes cannot take a tap -- gets the widget's two controls
--- appended after the theme's nodes, so no fullscreen is without the menu and a way out.
local function fsThemeJobStep(self)
  local job = self._job
  if job.swap then
    appendFullscreenControls(self, job.build.nodes)
    return sceneJobStep(self)
  end
  if job.build then return sceneJobStep(self) end

  if not self.theme then return true end

  if type(self.theme.build) == "function" then
    local children = self.theme.build(self.zone, self.state, viewCtx(self))
    checkNodeList(self, children)
    if not bindsPress(children) then
      -- Onto a copy: the table is the theme's, and a theme that hands back one it keeps would
      -- otherwise carry the controls from then on -- into its zone tree as well.
      local nodes = {}
      for i = 1, #children do nodes[i] = children[i] end
      children = nodes
      appendFullscreenControls(self, children)
    end
    lvgl.clear()
    lvgl.build(children)
    self.built = true
    self._lastChildCount = #children
    logGv("LVGL BUILD SUCCESS: themePath=%s, #children=%d", tostring(self.themePath), #children)
    return true
  end

  local theme = self.theme
  if self.dashboardEngine
    and (type(theme.layout) == "table" or type(theme.boxes) == "table" or type(theme.boxes) == "function") then
    job.build = self.dashboardEngine.beginBuild(self.zone, self.state, theme)
    return false
  end

  local empty = {}
  appendFullscreenControls(self, empty)
  lvgl.clear()
  lvgl.build(empty)
  self.built = true
  self._lastChildCount = #empty
  logGv("LVGL BUILD SUCCESS: themePath=%s, #children=%d", tostring(self.themePath), #empty)
  return true
end

-- ---------------------------------------------------------------------------
-- The battery prompt
-- ---------------------------------------------------------------------------

-- `state.batteryPick` is a TABLE from the first pass on and is replaced rather than cleared on
-- the reconnect edge: a theme's closures read it in the reactive sweep, outside the widget's
-- pcall, where indexing a nil field is the whole screen gone.
local function newBatteryPickState()
  return {
    loaded = false,
    pending = false,
    candidates = {},
    selectedId = nil,
    selectedName = nil,
    boardProfile = nil,
    dismissed = false,
    applied = nil
  }
end

local function batteryPickEntry(pick, id)
  if id == nil then return nil end
  local list = pick.candidates
  for i = 1, #list do
    if list[i].id == id then return list[i] end
  end
  return nil
end

--- Read the registry and ask the board which profile it is on. Once per FBL session.
--
-- `loaded` is raised before the card is touched rather than after: a step that raises is caught
-- by the dispatcher and the slot is cleared, so a flag set at the end would have this job
-- enqueued again on every pass for the rest of the session.
local function batteryPickLoadStep(self)
  local pick = self.state.batteryPick
  pick.loaded = true

  local BatteryPick = requireModule("lib/battery_pick.lua")
  if type(BatteryPick) ~= "table" then return true end

  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local list = BatteryPick.candidates(session)
  local cfg = self.state.battery_config
  for i = 1, #list do
    list[i].targetProfile = BatteryPick.targetProfile(list[i], cfg)
  end
  pick.candidates = list

  local id = BatteryPick.selectedId(session)
  pick.selectedId = id
  local entry = batteryPickEntry(pick, id)
  pick.selectedName = entry and entry.name or nil

  -- Not raised while armed: a model armed before this step ran has already passed the arm edge
  -- that ends the prompt, and would otherwise be asked in flight.
  local ask = BatteryPick.settings(self.preferences)
  pick.pending = (ask == true) and (#list > 0) and (pick.dismissed ~= true) and (self._batteryPickPicked ~= true)
    and (self.state.armed ~= true)

  -- The reply writes into THIS table rather than into whatever `state.batteryPick` is by the
  -- time it arrives: a reply that outlives its connection then lands in a table nothing reads,
  -- instead of reporting the previous board's profile as the new one's.
  BatteryPick.readProfile(function(index0) pick.boardProfile = index0 end)

  -- The registry is read whole off the card; GEMINI.md asks for an explicit collect after that.
  collectgarbage("collect")
  return true
end

--- An `rfsuite.batteryPick.open()` that is still waiting, taken by a fullscreen pass: the picker
--- is opened explicitly, as the call itself does in fullscreen. Dropped instead where the model is
--- armed or has disarmed since the call, because a pack chosen then would not be the one the call
--- was about. Taken once either way.
local function takeBatteryPickOpen(self, Views, pick)
  local request = pick.openRequest
  pick.openRequest = nil
  if self.state.armed == true or request.disarmAt ~= self.state.lastDisarmAt then return end
  if Views.top(self) ~= "battery_pick" then Views.navigate(self, "openView:battery_pick") end
end

--- Perform a pick: record it, and write the pack's battery profile when that is switched on.
local function batteryPickApplyStep(self)
  local request = self._batteryPickRequest
  self._batteryPickRequest = nil
  -- `false` is the "no battery" answer; nil would be indistinguishable from no request at all.
  if request == nil then return true end

  local pick = self.state.batteryPick
  -- Refused while armed, here as well as by hiding BATTERY: a picker that was already open when
  -- the model armed, or a caller of rfsuite.batteryPick, still arrives at this step, and a pack
  -- recorded now would be written against the flight in progress.
  if self.state.armed == true then
    widgetLog(self, "battery pick refused: the model is armed", "warn")
    pick.applied = "refused:armed"
    return true
  end
  local BatteryPick = requireModule("lib/battery_pick.lua")
  if type(BatteryPick) ~= "table" then return true end
  -- Normalised here, before the candidate lookup below, and not only inside select(): an id
  -- handed in as a number would otherwise be recorded and still match no candidate, so the
  -- pack's profile would never be written. `false` and "" both come back as nil.
  local id = BatteryPick.normalizeId(request)

  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  BatteryPick.select(session, id)

  self._batteryPickPicked = true
  pick.pending = false
  pick.selectedId = id
  pick.applied = nil

  local entry = batteryPickEntry(pick, id)
  pick.selectedName = entry and entry.name or nil

  local _, setsProfile = BatteryPick.settings(self.preferences)
  if entry == nil or setsProfile ~= true then return true end

  -- Resolved again here rather than reused from the load: the board's battery configuration
  -- may have arrived in between, and that is what turns a `cap=` into a profile.
  local target = BatteryPick.targetProfile(entry, self.state.battery_config)
  entry.targetProfile = target
  if target == nil then
    pick.applied = "skipped"
    return true
  end
  -- Where the board has answered and is already on that profile, nothing is sent. Where it has
  -- NOT answered, the write goes out all the same: it is idempotent, and refusing it would lose
  -- the feature entirely on a board whose profile read never came back.
  if pick.boardProfile ~= nil and target == pick.boardProfile then
    pick.applied = "skipped"
    return true
  end

  local queued, why = BatteryPick.applyProfile(target, { reason = "battery pick" })
  pick.applied = queued and "queued" or ("refused:" .. tostring(why))
  -- A queued write carries no reply handler and can still be dropped (retries exhausted, the
  -- queue cleared on arming or on a link loss), so the board's answer from the load no longer
  -- says which profile it is on. Forgotten rather than set to the target: the next pick then
  -- always writes.
  if queued then pick.boardProfile = nil end
  return true
end

--- A step control that is still held, let go before the object holding it is destroyed.
--
-- EdgeTX's momentary button reports a release only as LV_EVENT_RELEASED on the object itself
-- (lua_lvgl_widget.cpp, MomentaryButton::customEventHandler); an object deleted under the finger
-- never gets that event, and lvgl.clear() below deletes the whole tree. Without this the drive
-- would go on writing the row's magnitude to the value variable with nothing left in the world
-- able to take it back, and the flight controller would keep stepping the parameter.
--
-- The render key is held still while a control is held, so this is the second line of defence
-- rather than the first: it covers the rebuilds that are not the key's -- leaving fullscreen,
-- the close box, a build forced from elsewhere.
local function releaseInflightHold(self)
  if self._inflight == nil then return end
  local drive = inflightDrive()
  if drive and type(drive.release) == "function" then drive.release(self) end
end

-- The tuning overlay's two builds. Both complete in one step, like the menu: the tree is a fixed
-- handful of nodes rather than a theme's box list, so there is nothing to spread over passes.
local function tuningJobStep(self)
  local screen = inflightScreen()
  if not (screen and type(screen.buildZone) == "function") then return true end
  local children = {}
  screen.buildZone(children, self)
  releaseInflightHold(self)
  lvgl.clear()
  lvgl.build(children)
  self.built = true
  self._lastChildCount = #children
  return true
end

local function tuningFullscreenJobStep(self)
  local screen = inflightScreen()
  if not (screen and type(screen.buildFullscreen) == "function") then return true end
  local children = {}
  screen.buildFullscreen(children, self)
  releaseInflightHold(self)
  lvgl.clear()
  lvgl.build(children)
  self.built = true
  self._lastChildCount = #children
  return true
end

--- What stands in for a surface whose job has raised JOB_FAULT_LIMIT times in a row: the
--- connection splash's layout, saying that the screen could not be drawn. Without it the pilot
--- is left with whatever was on screen before -- usually a connection status that is no longer
--- true. It can replace the tuning surface, so a held step control is let go first, as the
--- tuning builds do. At full screen it carries the tool control, as the connect splash does
--- there: the tool is where another theme can be chosen, which gives every job its tries back.
local function failedJobStep(self)
  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local title = (t and t("widgets.dashboard.build_failed")) or "Dashboard error"
  local line = (t and t("widgets.dashboard.build_failed_hint")) or "This screen could not be drawn"
  local splash = buildConnectionSplash(self.zone, line, title)
  if self._job and self._job.fullscreenSplash then
    local Controls = requireModule("widgets/dashboard/fullscreen_controls.lua")
    if type(Controls) == "table" and type(Controls.appendTool) == "function" then
      Controls.appendTool(splash, self)
    end
  end
  releaseInflightHold(self)
  lvgl.clear()
  lvgl.build(splash)
  self.built = true
  self._lastChildCount = #splash
  return true
end

--- What stands in when the failure surface or the connect splash has itself raised
--- JOB_FAULT_LIMIT times in a row: the same title as one label on a plain background, drawn
--- without the splash builder and without the tool control, so neither of the two can be what
--- fails here. Without it the last surface would stay up with nothing saying the dashboard has
--- stopped drawing. A held step control is let go before the tree is cleared, as in
--- failedJobStep.
local function failedLabelJobStep(self)
  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local title = (t and t("widgets.dashboard.build_failed")) or "Dashboard error"
  local w = (self.zone and self.zone.w) or LCD_W or 320
  local h = (self.zone and self.zone.h) or LCD_H or 172
  -- The connect splash's two colours, on a filled rectangle of its own: after lvgl.clear() the
  -- zone is transparent, and a bare label would sit on whatever the radio's layout draws there.
  local nodes = {
    { type = "rectangle", x = 0, y = 0, w = w, h = h, color = COLOR_THEME_PRIMARY3, filled = true },
    { type = "label", x = 0, y = math.floor(h * 0.4), w = w, text = title, align = CENTER,
      color = COLOR_THEME_PRIMARY2, font = MIDSIZE },
  }
  releaseInflightHold(self)
  lvgl.clear()
  lvgl.build(nodes)
  self.built = true
  self._lastChildCount = #nodes
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

--- What the preference files look like right now, or nil where that could not be established.
--
-- The difference between those two is the point. A file that could not be READ is not a file
-- that CHANGED, and the caller compares this string against the one it kept -- so a failed read
-- that returns a shorter string turns "I could not look" into "the per-model file is gone". The
-- reload that answers it re-reads the preferences, drops the theme and rebuilds the scene; and
-- when the file reads again the string grows back, which is reported as a second change.
--
-- Four conditions used to be swallowed that way: an `fstat` that raises and one that answers
-- something `stampOf` cannot read, for each of the two files. The global pair left the stamp an
-- empty string, the per-model pair dropped its half. Each of the four is a failure to measure,
-- and a failure to measure is now nil -- which the caller already treats as "no comparison this
-- pass". That costs nothing: the next pass looks again a second later.
--
-- A nil `modelPath` is deliberately NOT one of them. It says the session has no per-model file,
-- which is a fact about the model rather than a failed read, and the stamp is then the global
-- half alone.
--- One preference file's stamp, or the stamp of the file it is brought across from where the
--- former has not been written yet.
--
-- A card written by an earlier release carries only the file in the previous format, and this
-- widget is not the one that brings it across: that costs more instructions than a widget call
-- is allowed, so it belongs to the configuration tool and to the background decoder. Stamping
-- only the current name would therefore leave nothing to compare on such a card -- and, worse,
-- would take the FIRST stamp after the migration, which the caller reads as a baseline rather
-- than as the change it is. The two files have different sizes, so the swap moves the stamp.
--
-- The second call is made only when the first misses, so a card that has already been brought
-- across pays exactly one fstat per file, as before.
local function stampOfEither(path)
  if type(path) ~= "string" then return nil end

  local ok, info = pcall(fstat, path)
  local stamp = ok and stampOf(info) or nil
  if stamp then return stamp end

  local former = string.gsub(path, "%.lua$", ".ini")
  if former == path then return nil end
  ok, info = pcall(fstat, former)
  return ok and stampOf(info) or nil
end

local function preferencesStamp(modelPath)
  if type(fstat) ~= "function" then return nil end

  local globalStamp = stampOfEither(preferencesFile())
  if not globalStamp then return nil end

  if not modelPath then return globalStamp end

  local modelStamp = stampOfEither(modelPath)
  if not modelStamp then return nil end

  return globalStamp .. "|" .. modelStamp
end

--- Which of the two files a stamp difference is about.
--
-- The stamp is the global half, then `|`, then the per-model half where there is one. The two
-- are independent files with independent writers, so a difference in one says nothing about the
-- other -- and the reload below is the only place that ever needed to know which.
--
-- Returns nil where the question cannot be answered, and then both files are read -- which is
-- what this function did unconditionally before. Three cases answer nil:
--
--   * no stamp on one side, or a shape change (one side carrying a per-model half, the other
--     not). There is nothing to compare half against half;
--   * both halves differ, which needs no attribution;
--   * **the changed half's TIMESTAMP did not move.** That is the case this test exists for. A
--     half is `<size>:<time>`, and a file can change without its stamp moving if the clock is
--     not running and the new content happens to be the same length -- which is the very reason
--     the sequence file beside this stamp exists. So an unchanged half is only evidence that its
--     file is unchanged while the clock is demonstrably running, and the changed half's own
--     timestamp is what demonstrates it. Where only a SIZE moved, the clock has proved nothing
--     and both files are read.
local function stampTime(half)
  return string.match(half or "", "^[^:]*:(.*)$")
end

local function changedHalves(oldStamp, newStamp)
  if type(oldStamp) ~= "string" or type(newStamp) ~= "string" then return nil end

  local oldGlobal, oldModel = string.match(oldStamp, "^([^|]*)|?(.*)$")
  local newGlobal, newModel = string.match(newStamp, "^([^|]*)|?(.*)$")
  if oldGlobal == nil or newGlobal == nil then return nil end
  if (oldModel == "") ~= (newModel == "") then return nil end

  local globalMoved = oldGlobal ~= newGlobal
  local modelMoved = oldModel ~= newModel
  if globalMoved == modelMoved then return nil end

  local movedOld, movedNew = oldGlobal, newGlobal
  if modelMoved then movedOld, movedNew = oldModel, newModel end
  local a, b = stampTime(movedOld), stampTime(movedNew)
  if a == nil or b == nil or a == b then return nil end

  return { global = globalMoved, model = modelMoved }
end

--- The locale module, as the dashboard's other holders of it see it.
--
-- lib/system_locale.lua registers itself in _G and returns the table that is already there, so
-- this is the one instance per Lua state -- the same one the theme commons and the object layer
-- hold. Reading it from _G first is what keeps invalidateLanguage() below from bumping the
-- generation of a module nobody else can see.
local function localeModule()
  local cached = type(_G) == "table" and _G.__rfsuite_system_locale_module or nil
  if type(cached) == "table" then return cached end
  return requireModule("lib/system_locale.lua")
end

--- Drop every locale memo in this Lua state.
--
-- Called from the preferences reload, which is the one moment that knows a setting changed. The
-- language is such a setting, and without this the theme's t(), the object layer's title
-- normaliser and the widget's own context below each keep answering with the language the widget
-- started with -- the object layer's memo had no invalidation at all until this.
local function invalidateLocale()
  local mod = localeModule()
  if mod and type(mod.invalidateLanguage) == "function" then
    pcall(mod.invalidateLanguage)
  end
end

--- The widget's i18n context for the language as it stands now.
local function buildI18nContext()
  if not (I18nModule and type(I18nModule.new) == "function") then return nil end
  local mod = localeModule()
  local locale = nil
  if mod and type(mod.resolveSystemLanguage) == "function" then
    local okResolve, resolved = pcall(mod.resolveSystemLanguage, "en")
    if okResolve and type(resolved) == "string" and resolved ~= "" then
      locale = resolved
    end
  end
  local ok, ctx = pcall(I18nModule.new, locale)
  if ok and type(ctx) == "table" then return ctx end
  return nil
end

local function reloadPreferencesIfNeeded(self, force, isBackground)
  local now = nowSeconds()

  -- The stamp and sequences that a completed reload will adopt. Held back on purpose -- see the armed
  -- guard below.
  local currentStamp = nil
  local currentSeqs = nil
  local signalReload = false
  -- Which halves the stamp says have moved, or nil where that is not answerable. Any signal
  -- that is not a stamp difference -- the sequence file, a forced caller -- leaves it nil and
  -- both files are read, because those signals do not name a file.
  local halves = nil
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
        halves = changedHalves(self._lastPrefsStamp, stamp)
        logGv("reloadPreferencesIfNeeded: stamp changed ('%s' -> '%s') [global=%s model=%s]",
          tostring(self._lastPrefsStamp), tostring(stamp),
          halves and tostring(halves.global) or "?", halves and tostring(halves.model) or "?")
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
  themePathMemo = {}

  -- Read only the file the stamp says has moved. The two are separate files with separate
  -- writers, and a save made from the settings screen touches the per-model one alone -- so
  -- re-reading the global file with it is a parse of bytes that have not changed, and that parse
  -- is the expensive half by a wide margin. Where the signal does not name a file -- a forced
  -- caller, the sequence file, a shape change in the stamp -- `halves` is nil and both are read,
  -- which is what this function always did.
  local doGlobal = (halves == nil) or halves.global
  local doModel = (halves == nil) or halves.model
  if not (doGlobal and doModel) then
    logGv("reloadPreferencesIfNeeded: reading global=%s model=%s", tostring(doGlobal), tostring(doModel))
  end

  -- Cleared only where it is about to be re-read. reloadActiveTheme reads self.modelPreferences
  -- with priority over session.modelPreferences, so clearing it on a pass that is not going to
  -- reload it would drop a good value for no reason.
  if doModel then self.modelPreferences = nil end

  local loaded = false

  local prefs = doGlobal and loadPreferences() or nil
  if type(prefs) == "table" then
    loaded = true
    self.preferences = prefs
    publishPreferencesToGlobal(prefs)

    -- The language is one of the settings in this file, and a memo of it that outlives a single
    -- call would keep answering with the old one. The order matters: the memos go first, so the
    -- context below is built from the language as it is now and not from the one just dropped.
    -- Gated on doGlobal because a save made from the settings screen can touch the per-model file
    -- alone, and that file carries no language.
    invalidateLocale()
    local ctx = buildI18nContext()
    if ctx then
      self.i18n = ctx
    end

    -- Expose i18n on the runtime state so theme renderers can access it
    if self.i18n then
      if type(self.state) ~= "table" then self.state = {} end
      self.state.i18n = self.i18n
    end
  end

  -- The per-model half, no longer nested inside the global one: it never read `prefs`, and with
  -- the two halves now independent a global read that was skipped must not take this with it.
  if doModel then
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    if session and session.mcu_id then
      local MP = ModelPreferences or requireModule("lib/model_preferences.lua")
      if MP and type(MP.loadByMcuId) == "function" then
        local mPrefs, mPath = MP.loadByMcuId(session.mcu_id, true)
        if mPrefs then
          loaded = true
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
  end

  if loaded then
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
  --
  -- A board whose MSP API version was refused is never ready, the soft timeout included: the
  -- splash stays up and says why, and the dashboard is not drawn for a board the suite does not
  -- talk to.
  local refused = type(runtimeState) == "table" and runtimeState.unsupportedApi == true
  local rawReady = connected and batteryReady and rfReady and modelPrefsResolved and tasksDone
    and not refused
  local now = nowSeconds()

  -- Not counted while refused, so a refusal that is lifted (a fresh connect re-reads the version)
  -- does not find a soft timeout already run out.
  if connected and not rawReady and not refused then
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

  local softTimeoutReady = connected and not refused and self.pendingSince ~= nil
    and (now - self.pendingSince) >= SPLASH_SOFT_TIMEOUT_SECONDS
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
  elseif refused then
    local fmt = (t and t("widgets.dashboard.api_unsupported"))
      or "MSP API %s not supported, needs Rotorflight 4.6+"
    statusLine = string.format(fmt, tostring(runtimeState.refusedApiVersion or "?"))
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
      -- Nothing is announced here. The gate shuts on `connected`, i.e. on the RF link, and a lost
      -- link is the radio's own announcement; a flight controller that stops sending with the
      -- link up never shuts it, and lib/audio.lua hears that case from the telemetry frames.
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
  -- Published because `connectionReady` is not the same question: it opens on the soft timeout
  -- while the connect chain is still running, and anything that must not compete with that chain
  -- for the single MSP queue needs to know when the chain is actually finished.
  self.state.tasksDone = tasksDone
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
  if v >= 1000 then
    v = v / 1000
  elseif v >= 100 then
    v = v / 100
  elseif v > 10 then
    v = v / 10
  end
  if v <= 0 then
    return fallback
  end
  return v
end

-- Flight statistics: this file no longer keeps them. They are recorded by
-- tasks/events/telemetry/flight_record.lua, which runs from the event runtimes in the widget
-- context, and published under rfsuite.session.flight -- so the record survives a model with no
-- dashboard on any screen, and a dashboard reads it instead of being the only thing that has it.
-- What is left here is the reading, below, plus the compatibility mapping at the end of this
-- file for a user theme that still reaches for the old flat field names.

-- The event history: what changed on the craft and when, newest last, for a theme that shows it
-- (`state.eventLog`). Each entry is `{ kind, value, text, level, time }`:
--
--   kind    "armed", "disarmed", "connected", "disconnected", "governor" or "esc"
--   value   the governor state index (rotorflight-firmware governor.h) for "governor", else nil
--   text    the speed controller's own verdict for "esc", already in the package's language;
--           nil for every other kind, which a theme names in its own words
--   level   1 information, 2 warning, 3 error -- lib/esc_status.lua's levels, which "esc" carries
--   time    the radio's clock as "HH:MM:SS", or "" on a radio that has none
--
-- Nothing here detects anything of its own. Each kind is noted where this file already acts on
-- the transition: the arm edge in updateDerivedFlightState, the flight controller's connect and
-- disconnect edges in the background work, and the governor and the speed controller after the
-- telemetry read that brought them. So an entry costs a table and a clock read on the pass that
-- has the transition, and a steady pass costs the two comparisons in noteReadingEvents.
--
-- The speed controller is the reading the theme already declared (`esc_status_live` in its
-- sources, as the snapshot resolves it); a theme that does not declare it gets no "esc" entries,
-- and nothing reads the two sensors for the history alone. The list is kept across connections:
-- the disconnect is itself an entry, and the next connection's entries follow it.
local EVENT_LOG_SIZE = 30

local function eventClock()
  if type(getDateTime) ~= "function" then return "" end
  local ok, dt = pcall(getDateTime)
  if not ok or type(dt) ~= "table" then return "" end
  return string.format("%02d:%02d:%02d", dt.hour or 0, dt.min or 0, dt.sec or 0)
end

local function noteEvent(state, kind, level, value, text)
  local log = state.eventLog
  if type(log) ~= "table" then
    log = {}
    state.eventLog = log
  end
  log[#log + 1] = { kind = kind, value = value, text = text, level = level, time = eventClock() }
  if #log > EVENT_LOG_SIZE then table.remove(log, 1) end
end

-- The two readings with no edge of their own elsewhere, on a pass that read them. A connection's
-- first governor state is taken as the starting point and noted only once it moves; the speed
-- controller's first verdict is noted, because it says which controller answered and how. A
-- verdict the controller repeats is noted once, and a pass that resolved none (no link, nothing
-- declared) leaves the last one standing.
local function noteReadingEvents(state)
  local governor = state.governor
  if governor ~= state.eventGovernor then
    if state.eventGovernor ~= nil then noteEvent(state, "governor", 1, governor) end
    state.eventGovernor = governor
  end
  local derived = state.derived
  local esc = derived and derived.esc_status_live
  if type(esc) == "string" and esc ~= "" and esc ~= state.eventEsc then
    state.eventEsc = esc
    noteEvent(state, "esc", tonumber(derived.esc_status_live_level) or 1, nil, esc)
  end
end

--- What this widget still keeps for itself across an arm edge, and the reading of what it does
--- not. The statistics and the flight clock come from the record; the fields below are the
--- dashboard's own, because they are about this widget's screen rather than about the flight:
--- `hadArmedFlight` holds the postflight page up while the link is down, `lastFlightEndingVoltage`
--- is the landing voltage a tile shows, and `lastDisarmAt` times the postflight switch.
--- `lastFlightEndingCells` is taken with the landing voltage: a tile that shows that voltage per
--- cell has to divide by the pack that landed, and the live count follows whatever pack is
--- plugged in after it.
---
--- This still uses the widget's own armed reading. That is deliberate: the record's arm edge is
--- the event runtime's, and these follow the screen, not the record.
local function updateDerivedFlightState(state)
  local wasArmed = state.wasArmed == true
  local isArmed = state.armed == true

  if isArmed and not wasArmed then
    state.lastFlightEndingVoltage = nil
    state.lastFlightEndingCells = nil
    state.hadArmedFlight = true
    -- An unanswered battery prompt ends with the arming: the pack is on the craft by then, and
    -- fullscreen during the flight and after it shows what it would show without the prompt.
    -- BATTERY in the quick menu still brings the picker back.
    local pick = state.batteryPick
    if pick then pick.pending = false end
    noteEvent(state, "armed", 1)
  elseif wasArmed and not isArmed then
    state.lastDisarmAt = nowSeconds()
    state.hadArmedFlight = true
    noteEvent(state, "disarmed", 1)
    -- Capture the ending (landing) voltage as the last known live voltage, and the cell count
    -- readTelemetry took in the same pass, before it reached the arm flags.
    if type(state.voltage) == "number" and state.voltage > 0 then
      state.lastFlightEndingVoltage = state.voltage
      local cells = tonumber(state.batteryCellCount)
      state.lastFlightEndingCells = (cells and cells > 0) and cells or nil
    end
  end

  state.prevArmed = wasArmed
  state.wasArmed = isArmed
end

--- Read the record. Once per pass, whatever the telemetry did: the flight clock advances on the
--- owner's wakeups, not on this widget's reads, and a tile showing the time should follow it.
---
--- The four scalars stay on `state` under the names they have always had, because `lib/audio.lua`
--- and the time objects read them there.
local function readFlightRecord(state)
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local flight = type(session) == "table" and session.flight or nil
  if type(flight) ~= "table" then return end

  state.flight = flight
  state.flights = flight.flights or 0
  state.lastFlightSeconds = flight.lastSeconds or 0
  state.totalFlightSeconds = flight.totalSeconds or 0
  state.flightSeconds = flight.armed and (flight.seconds or 0) or (flight.lastSeconds or 0)

end

local function loadDashboardLib()
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/app/pages/settings/dashboard/lib.lua", mode)
  if not chunk then return nil end
  local ok, lib = pcall(chunk)
  if not ok or type(lib) ~= "table" then return nil end
  return lib
end

local function loadDashboardEngine()
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/engine.lua", mode)
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

-- A theme under the user directory is a file the pilot edits on the card, and nothing
-- precompiles or sweeps that tree: lib/precompile.lua walks the two shipped roots only, so a
-- .luac left beside an edited theme would be preferred whenever the two timestamps tie at the
-- two-second resolution a FAT card stores. It is read from source for the same reason
-- lib/sensors.lua reads a user simulated-sensor file from source. A shipped theme takes the
-- mode the suite publishes, like every other shipped module.
local function themeLoadMode(base)
  if base == USER_THEME_BASE then return "t" end
  return (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
end

local function loadThemeInit(themePath)
  local source, folder = parseThemePath(themePath)
  local base = source == "user" and USER_THEME_BASE or SYSTEM_THEME_BASE
  local initChunk = loadScript(base .. folder .. "/init.lua", themeLoadMode(base))
  if not initChunk then return nil, base, folder end
  local ok, initTable = pcall(initChunk)
  if not ok or type(initTable) ~= "table" then return nil, base, folder end
  return initTable, base, folder
end

-- The phases the widget computes, and for each one the phase it refines. A theme declares as
-- many of them as it wants to draw differently; a phase it does not declare resolves along this
-- chain, so `armed` falls back to the ground screen and `offline` to the post-flight one. A
-- theme that declares only the three original phases therefore draws exactly what it drew
-- before the other two existed, and needs no new file.
local PHASE_FALLBACK = {
  preflight  = false,
  armed      = "preflight",
  inflight   = false,
  postflight = false,
  offline    = "postflight",
}

-- The phase whose module a theme actually draws for `flightMode`. It walks the chain above
-- until the theme declares a module, and ends on the last phase of the chain when the theme
-- declares none -- which is the phase the shipped default theme has a file for, so the fallback
-- at the end of loadThemeModuleForState keeps resolving.
local function themeStateKey(declared, flightMode)
  local key = flightMode
  if PHASE_FALLBACK[key] == nil then key = "preflight" end
  while true do
    if type(declared) == "table" and type(declared[key]) == "string" and declared[key] ~= "" then
      return key
    end
    local fallback = PHASE_FALLBACK[key]
    if not fallback then return key end
    key = fallback
  end
end

-- The same answer for every phase at once, taken when a theme loads, so that a phase change
-- compares one lookup rather than walking the chain again on the pass that changes phase.
local function themeStateKeys(declared)
  local keys = {}
  for phase in pairs(PHASE_FALLBACK) do
    keys[phase] = themeStateKey(declared, phase)
  end
  return keys
end

-- Returns the theme module, the phase key it was resolved for, and the theme's own init table.
-- The caller keeps the last two so that a phase change can be told from a MODULE change without
-- reading init.lua off the card again: a phase that falls back to the module already on screen
-- must not tear the scene down and build it again for no visible difference.
local function loadThemeModuleForState(themePath, flightMode)
  local initTable, base, folder = loadThemeInit(themePath)
  local stateKey = themeStateKey(initTable, flightMode)

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

  local chunk = loadScript(scriptPath, themeLoadMode(base))
  if chunk then
    local ok, theme = pcall(chunk)
    if ok and type(theme) == "table" and (
      type(theme.build) == "function" or
      type(theme.layout) == "table" or
      type(theme.boxes) == "table" or
      type(theme.boxes) == "function"
    ) then
      return theme, stateKey, initTable
    end
  end

  local fallbackPath = SYSTEM_THEME_BASE .. "default/" .. stateKey .. ".lua"
  local fallbackChunk = loadScript(fallbackPath, themeLoadMode(SYSTEM_THEME_BASE))
  if not fallbackChunk then
    fallbackChunk = loadScript(SYSTEM_THEME_BASE .. "default/preflight.lua",
                               themeLoadMode(SYSTEM_THEME_BASE))
  end
  if not fallbackChunk then return nil, stateKey, initTable end
  local ok, theme = pcall(fallbackChunk)
  if ok and type(theme) == "table" and (
    type(theme.build) == "function" or
    type(theme.layout) == "table" or
    type(theme.boxes) == "table" or
    type(theme.boxes) == "function"
  ) then
    return theme, stateKey, initTable
  end
  return nil, stateKey, initTable
end

-- ---------------------------------------------------------------------------
-- Theme mode: a theme that draws its own fullscreen
-- ---------------------------------------------------------------------------
--
-- A theme opts in with `fullscreen = "theme"` in its init.lua. Fullscreen then builds that theme
-- at the fullscreen size as the base layer under the fullscreen views (widgets/dashboard/views.lua),
-- instead of opening on the quick menu, and the widget answers the page keys and RTN. A theme
-- that says nothing is fullscreen exactly as before: the menu, and no key.
--
-- Everything here runs on a fullscreen pass or on a pass of a widget whose theme opted in, never
-- on the zone pass of a theme that did not. The mode is therefore not taken where the theme is
-- loaded -- a theme load is also what the arm and disarm edges pay for -- but on the first
-- fullscreen pass after the theme on screen has changed, keyed on the theme module itself.

-- Holds the theme module the mode was last taken for, without keeping a module that has since
-- been replaced alive until the next fullscreen pass.
local WEAK_VALUES = { __mode = "v" }

-- Where a theme's view may be shown, by the value of its `where`; a view that says nothing is a
-- fullscreen view.
local VIEW_PLACES = {
  fullscreen = { fullscreen = true },
  zone = { zone = true },
  both = { fullscreen = true, zone = true },
}

--- The views a free-form theme registers in its init.lua (`views`) for one place, "fullscreen"
--- or "zone", in the theme's order: `{ id, openWhen, load }`.
---
--- `load()` reads the view's module through the theme loader -- the theme's own folder, in the
--- theme's load mode -- and not through the suite's module loader, which resolves a path under the
--- suite's own folder, where a user theme's file is not. Nothing is read here. An entry without a
--- string `id` and `module`, or with a `where` that is none of the three, is left out.
local function themeViewList(initTable, base, folder, place)
  local declared = type(initTable) == "table" and initTable.views or nil
  if type(declared) ~= "table" then return nil end
  local list = {}
  for i = 1, #declared do
    local view = declared[i]
    local places = type(view) == "table" and VIEW_PLACES[view.where or "fullscreen"] or nil
    if places and places[place] and type(view.id) == "string" and view.id ~= ""
      and type(view.module) == "string" and view.module ~= "" then
      local path = base .. folder .. "/" .. view.module
      list[#list + 1] = {
        id = view.id,
        openWhen = view.openWhen,
        load = function()
          local chunk = loadScript(path, themeLoadMode(base))
          if not chunk then return nil end
          local ok, module = pcall(chunk)
          if ok and type(module) == "table" then return module end
          return nil
        end,
      }
    end
  end
  return list
end

--- Take the fullscreen mode for the theme now loaded, and reset what belongs to the previous one.
--
-- init.lua is read again for its `fullscreen` key rather than kept from the load, once per theme
-- change and only on a fullscreen pass. The `ctx` handed to the previous theme is dropped with it,
-- since the keys a theme bound belong to that theme.
--
-- The same read takes the theme's `views`: the fullscreen view registry is made anew from the
-- core views and those of a free-form theme -- only a module that builds its own tree can draw a
-- view -- and a view of the previous theme's that is still on the stack is taken off it.
local function takeFullscreenMode(self)
  local holder = self._fullscreenModeOf
  if holder == nil then
    holder = setmetatable({}, WEAK_VALUES)
    self._fullscreenModeOf = holder
  end
  holder[1] = self.theme
  local initTable, base, folder = loadThemeInit(self.themePath)
  local themeMode = type(initTable) == "table" and initTable.fullscreen == "theme"
  self._viewBase = themeMode and "theme" or nil
  self._viewCtx = nil
  self._cachedFullscreenKey = nil
  local Views = viewsModule()
  if Views then
    local themeViews = nil
    if type(self.theme.build) == "function" then
      themeViews = themeViewList(initTable, base, folder, "fullscreen")
    end
    Views.register(self, themeViews)
  end
  -- What became of the work the previous theme ran was that theme's to draw. A phase change of
  -- the same theme keeps it.
  if holder.path ~= self.themePath then
    holder.path = self.themePath
    if Views then Views.forgetOutcomes(self) end
  end
end

--- The render key of the theme as the base layer, under the same 2 Hz throttle as the zone key.
---
--- It is computed at once, not at the next tick of the throttle, on the pass the base layer comes
--- back on screen -- entering fullscreen, or the last view closing over it. The key carries the
--- zone size, so the key the last tick left was computed for the other surface, and waiting for
--- the throttle would build the theme and then build it a second time within half a second. The
--- cached key is dropped whenever something else is on screen, which is what marks the return.
local function fullscreenThemeKey(self)
  local key = self._cachedFullscreenKey
  local now = nowSeconds()
  if key == nil or (now - (self._lastUIRefresh or 0)) >= 0.5 then
    self._lastUIRefresh = now
    local themeKey = nil
    local theme = self.theme
    if type(theme.renderKey) == "function" then
      themeKey = theme.renderKey(self.zone, self.state)
    elseif self.dashboardEngine
      and (type(theme.layout) == "table" or type(theme.boxes) == "table" or type(theme.boxes) == "function") then
      themeKey = self.dashboardEngine.renderKey(self.state, self.boxSources)
    end
    -- Its own prefix, so the fullscreen tree and the zone tree can never share a key across the
    -- transition: they are two trees at two sizes.
    key = "fs_theme|" .. tostring(themeKey)
    self._cachedFullscreenKey = key
  end
  return key
end

--- `widget.refresh` while a theme-mode fullscreen is up: the keys, then the pass itself.
---
--- EdgeTX hands a widget one event per call, and a pass that runs a job returns before the state
--- half, so a key read there would be lost whenever it arrived during a build. This reads it
--- ahead of that split instead, and the widget's own refresh is left as it is. It is put in place
--- by the fullscreen pass of a theme-mode widget, and it puts the widget's own refresh back on the
--- first pass without an event -- fullscreen has been left -- or once the theme no longer asks for
--- fullscreen, so no zone pass and no widget without a base layer ever runs it.
local function themeModeRefresh(self, event, touchState)
  local ownRefresh = self._ownRefresh
  if event == nil or self._viewBase == nil then
    self.refresh = ownRefresh
    self._cachedFullscreenKey = nil
  elseif event ~= 0 and self.theme ~= nil and inflightMode(self, true) == nil and self._toolHost == nil
    and (self.connectionReady == true or self.flightMode == "postflight" or self.flightMode == "offline") then
    -- Not while the tuning surface is up, the tool is open, before a theme is loaded, or on the
    -- connect splash: none of them is a view or the base layer.
    local Views = viewsModule()
    if Views then Views.key(self, event) end
  end
  return ownRefresh(self, event, touchState)
end

--- The fullscreen pass of a theme-mode widget: put the key route in place, and resolve the
--- surface. Returns the view id and the render key, as views.resolve() does, with the base layer's
--- key where no view is on top.
local function resolveThemeMode(self, viewId, viewKey)
  if self.refresh ~= themeModeRefresh then
    self._ownRefresh = self.refresh
    self.refresh = themeModeRefresh
  end
  if viewId == nil then return nil, fullscreenThemeKey(self) end
  self._cachedFullscreenKey = nil
  return viewId, viewKey
end

-- ---------------------------------------------------------------------------
-- Zone views: a free-form theme's views that take the widget zone
-- ---------------------------------------------------------------------------
--
-- A view a free-form theme registers with `where = "zone"` or `"both"` replaces the theme's zone
-- picture while its `openWhen` holds -- a level, not an edge: it shows exactly as long as the
-- condition does, armed or not. It is display only. It is not on the view stack, it answers no
-- key, and it is built without a `ctx`, so it binds no press; a zone receives no touch anyway.
--
-- None of this is reached by a declarative theme. The list is read by the scene build, in the
-- branch only a free-form theme's module takes, and the condition is asked by a `refresh`
-- wrapper that only a theme with zone views puts in place -- the same way the theme mode's key
-- route is installed -- so the zone pass of every other theme is the pass it was. The wrapper
-- only decides; a change of view is built by the scene job in the job slot, never inline.

-- The first of the theme's zone views, in its order, whose condition holds; nil for none.
local function pickZoneView(self)
  local list = self._zoneViews
  local Views = viewsModule()
  if list == nil or Views == nil then return nil end
  for i = 1, #list do
    local entry = list[i]
    if not entry.failed and entry.openWhen ~= nil and Views.opens(entry, self) then return entry end
  end
  return nil
end

-- What the wrapper below does on a tick: take itself out once the theme that put it in place has
-- gone, or else ask which zone view shows and mark the scene for a rebuild when that, or the
-- view's own render key, has changed.
local function zoneViewTick(self)
  if self._zoneViews == nil or self._zoneViewsPath ~= self.themePath then
    self.refresh = self._zoneOwnRefresh
    self._zoneOwnRefresh = nil
    self._zoneViews = nil
    self._zoneViewsPath = nil
    if self._zoneView ~= nil then
      self._zoneView = nil
      self.built = false
    end
    return
  end
  if self.theme == nil or type(self.theme.build) ~= "function" then return end
  local view = pickZoneView(self)
  if view ~= self._zoneView then
    self._zoneView = view
    self._zoneViewKey = nil
    self.built = false
  elseif view ~= nil and view.loaded ~= nil and type(view.loaded.renderKey) == "function" then
    local key = view.loaded.renderKey(self.zone, self.state)
    if key ~= self._zoneViewKey then
      self._zoneViewKey = key
      self.built = false
    end
  end
end

--- `widget.refresh` while the theme on screen has zone views.
---
--- The conditions are asked on the zone's own 2 Hz tick and on no other pass: the render key
--- throttle of the pass before moved `_lastUIRefresh`, and this pass sees that it did. So a zone
--- view comes and goes within half a second and a pass in between costs a comparison. The pass
--- that follows a theme load is a tick as well, since the load resets the throttle.
---
--- A fullscreen pass goes straight through: the theme mode's own wrapper may sit on top of this
--- one there, and puts this one back on the first pass without an event.
local function zoneViewRefresh(self, event, touchState)
  local ownRefresh = self._zoneOwnRefresh
  if event == nil and self._lastUIRefresh ~= self._zoneViewTick then
    self._zoneViewTick = self._lastUIRefresh
    zoneViewTick(self)
  end
  return ownRefresh(self, event, touchState)
end

-- Put the wrapper in place, under the theme mode's where that one is on top.
local function installZoneViewRefresh(self)
  if self._zoneOwnRefresh ~= nil then return end
  if self.refresh == themeModeRefresh then
    self._zoneOwnRefresh = self._ownRefresh
    self._ownRefresh = zoneViewRefresh
  else
    self._zoneOwnRefresh = self.refresh
    self.refresh = zoneViewRefresh
  end
end

--- The module of the zone view the scene build draws, or nil for the theme itself.
---
--- The theme's `views` are read once per theme path, here: the first scene build of a free-form
--- theme after the path has changed. The view to show is decided then as well, so the first
--- frame is the right one, and from then on by the wrapper. A zone view's module is loaded when
--- it is first shown, through the theme loader; one that does not load is not asked for again.
zoneViewFor = function(self)
  if self._zoneViewsPath ~= self.themePath then
    self._zoneViewsPath = self.themePath
    local initTable, base, folder = loadThemeInit(self.themePath)
    local list = themeViewList(initTable, base, folder, "zone")
    if list ~= nil and #list == 0 then list = nil end
    self._zoneViews = list
    self._zoneView = nil
    self._zoneViewKey = nil
    if list == nil then return nil end
    installZoneViewRefresh(self)
    self._zoneView = pickZoneView(self)
  end
  local entry = self._zoneView
  if entry == nil then return nil end
  local view = entry.loaded
  if view == nil then
    view = entry.load()
    if type(view) ~= "table" or type(view.build) ~= "function" then
      widgetLog(self, "zone view '" .. tostring(entry.id) .. "' of the theme did not load", "warn")
      entry.failed = true
      self._zoneView = nil
      return nil
    end
    entry.loaded = view
  end
  if type(view.renderKey) == "function" then self._zoneViewKey = view.renderKey(self.zone, self.state) end
  return view
end

-- A stored path is a selection only if it names a theme: an empty select is written as the
-- string "nil", and an absent one is empty or missing altogether.
local function selectedThemePath(value)
  if value and value ~= "" and value ~= "nil" then return value end
  return nil
end

local function resolveThemePathForState(dashboard, modelPrefs, flightMode, lib)
  -- `armed` and `offline` refine the ground and the post-flight screen rather than standing
  -- beside them, so they have no slot of their own: each resolves through the theme chosen for
  -- the phase it refines, and the Design page keeps the three selects it has. The answer below
  -- depends on the slot alone, so the memo is keyed on the slot too, and arming answers from it
  -- instead of resolving the same path again.
  local slotMode = flightMode
  if slotMode == "armed" then
    slotMode = "preflight"
  elseif slotMode == "offline" then
    slotMode = "postflight"
  end

  if themePathMemo.dashboard == dashboard
    and themePathMemo.modelPrefs == modelPrefs
    and themePathMemo.slotMode == slotMode then
    return themePathMemo.chosen
  end

  local modelDashboard = modelPrefs and modelPrefs.dashboard or {}
  -- The radio's and the model's override switches, and what an absent one means, are decided
  -- in one place (app/pages/settings/dashboard/lib.lua), which the theme settings read too.
  local modelOverride
  if lib and lib.modelOverridesActive then
    modelOverride = lib.modelOverridesActive(dashboard, modelDashboard)
  else
    modelOverride = modelDashboard.model_override == true
  end

  -- A theme declares preflight, inflight and postflight itself and switches between them, so
  -- the phase keys are overrides on top of the theme chosen for the context. They are read
  -- only while the per-phase option is on; with it off the context theme covers all three,
  -- and the keys keep their values for whoever turns the option back on.
  local key = nil
  local modelKey = nil
  if dashboard and dashboard.theme_per_phase == true then
    if slotMode == "inflight" then
      key = "theme_inflight"
      modelKey = "model_theme_inflight"
    elseif slotMode == "postflight" then
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
  themePathMemo.slotMode = slotMode
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

-- What the flight record has already read this pass.
--
-- The record runs from the event runtimes, which this widget drives at the top of its own pass,
-- so on a pass where it samples it has asked the sensors for most of the names below before
-- this read is reached -- and a second read of the same name inside one pass cannot answer
-- anything the first did not. Counting the pass for it is what lets it offer those readings and
-- what tells this pass's offer from the one before it; the offer's schema is
-- tasks/events/telemetry/flight_record.lua's.
--
-- The pass also tells the record its clock and whether this read falls due in it, so that the
-- record takes its samples on the passes that read rather than on a clock of its own that starts
-- at the arm and may sit in any phase of this read's.
local sharedRead = nil

--- Count this pass for the record, before the event runtimes are driven.
local function countSharedPass(now, reads)
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session
  if type(session) ~= "table" then
    sharedRead = nil
    return
  end
  local shared = session.telemetryRead
  if type(shared) ~= "table" then
    shared = { values = {}, pass = 0, at = -1 }
    session.telemetryRead = shared
  end
  shared.pass = shared.pass + 1
  shared.now = now
  shared.reads = reads
  sharedRead = shared
end

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

-- Whether this read's arm flags are left untaken, because the MSP runtime still reads the model
-- as armed.
--
-- While the link is up the runtime reads the same ARM sensor on every logic tick and keeps the
-- answer in `lastArmed`, and this widget ticks it at the top of the very pass that reads below --
-- ahead of the event runtimes, whose custom-telemetry drain publishes that sensor. So when the
-- runtime holds armed and this read finds bit 0 clear, the sensor changed between two reads of
-- one pass: a frame the drain published in between, possibly one queued long before, or a sensor
-- that read 0 for that moment. (While the link is down the runtime does not read at all and keeps
-- its last answer; a disarmed reading taken then is a reading from a link that is not there.)
-- Taking it would end the flight on this screen -- the phase drops to postflight and back, the
-- disarm is announced, the landing voltage and `lastDisarmAt` are stamped -- for a model that is
-- still flying. Left untaken, a real disarm is taken by the first read after the runtime's next
-- tick, which has read it by then.
--
-- One direction only. A reading of ARMED is always taken: the runtime's `false` is also what it
-- holds when no arm source answers at all -- a simulator with no flight controller behind it is
-- one such case -- so it cannot overrule a reading that says the model is armed, and erring
-- towards armed is the safe side of that question.
--
-- One log line per run of untaken reads, not one per read.
local armFlagsRefusalLogged = false

local function armFlagsRefused(value)
  if type(value) ~= "number" then return false end
  local armedBit
  if bit32 then armedBit = bit32.btest(value, 1) else armedBit = value ~= 0 end
  local runtimeState = (not armedBit) and MspRuntime and type(MspRuntime.getState) == "function"
    and MspRuntime.getState() or nil
  if type(runtimeState) ~= "table" or runtimeState.lastArmed ~= true then
    armFlagsRefusalLogged = false
    return false
  end
  if not armFlagsRefusalLogged then
    armFlagsRefusalLogged = true
    local rssi = nil
    local rssiFn = _G.getRSSI
    if type(rssiFn) == "function" then
      local ok, reading = pcall(rssiFn)
      if ok then rssi = reading end
    end
    widgetLog(nil, string.format("arm flags %s not taken: the MSP runtime still reads armed (RSSI %s)",
      tostring(value), tostring(rssi)), "info")
  end
  return true
end

local function readTelemetry(state, audioState)
  if not (Sensors and type(Sensors.getValue) == "function") then return end
  telemetryTarget = state
  telemetryChanged = false
  for name in pairs(sensorCache) do sensorCache[name] = nil end

  -- Seed the pass cache with what the record read in this same pass. Only this pass's stamp is
  -- taken, and only names the sensors actually answered for are in the table -- a name that
  -- answered nothing is absent, so it is asked for below exactly as it always was.
  local shared = sharedRead
  if shared and shared.at == shared.pass then
    for name, value in pairs(shared.values) do
      sensorCache[name] = value
    end
  end

  setField("rpm", getSensor("rpm"))
  setField("lq", getSensor("link"))
  -- Which sensor answered for `link`. The search path in lib/sensors.lua ends in 1RSS and
  -- 2RSS, and those carry an RSSI in dBm rather than a quality in percent, which is a
  -- difference a consumer of `lq` cannot see in the number alone.
  setField("lqSource", Sensors.active_paths and Sensors.active_paths.link)
  setField("profile", roundInt(getSensor("pid_profile") or state.profile, state.profile or 1))
  setField("rateProfile", roundInt(getSensor("rate_profile") or state.rateProfile, state.rateProfile or 1))
  setField("batteryProfile", roundInt(getSensor("battery_profile") or state.batteryProfile, state.batteryProfile))
  -- Read once for both fields that carry it -- `armFlags` here, which the announcements speak, and
  -- `armed` further down -- so a reading armFlagsRefused leaves untaken is untaken for both.
  local armState = getSensor("armflags")
  local armTaken = armState
  if armFlagsRefused(armState) then armTaken = nil end
  setField("armFlags", roundInt(armTaken or state.armFlags, state.armFlags or 0))
  local armDisableFlagsValue = getSensor("armdisableflags")
  if type(armDisableFlagsValue) == "number" then
    setField("armDisableFlags", math.max(0, math.floor(armDisableFlagsValue + 0.5)))
  end
  setField("governor", roundInt(getSensor("governor") or state.governor, state.governor or 0))
  -- The governor MODE, which is configuration rather than telemetry: the connect chain reads it
  -- once over MSP (tasks/events/common/governor_config.lua) and leaves it on the session. It is
  -- carried onto the state here so that an object needing it reads precomputed state, which is
  -- what the reactive sweep is allowed to do; reaching into the session from a render closure is
  -- not. Nil until the chain has answered, and a consumer has to cope with that.
  --
  -- Assigned even when nil, unlike every setField above, because the mode goes back to nil when a
  -- new board's read starts and setField never clears: without this the previous board's mode
  -- would stand for the rest of the session. The governor text objects and the urban theme decide
  -- on this field ahead of the live value, so a stale mode has them say a governor state the model
  -- is not in -- the same treatment the battery configuration gets below.
  local rfRoot = type(_G) == "table" and _G.rfsuite or nil
  local governorMode = rfRoot and rfRoot.session and rfRoot.session.governorMode
  if governorMode ~= state.governorMode then
    state.governorMode = governorMode
    telemetryChanged = true
  end
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

  -- ESC load: the current as a share of the limit the speed controller is set to allow. Derived
  -- here beside the watts above rather than read from anywhere: one division on a pass that has
  -- both a limit and a reading, and a pair of comparisons on a pass that has neither.
  --
  -- Nil and not zero where the limit is unknown, and assigned rather than set through setField:
  -- a load of nought is a reading and "no limit on file" is not, and setField never clears, so a
  -- limit taken away again would leave its last percentage standing for the rest of the session.
  --
  -- The reading this pass produced and not the value kept from the last one, which is where this
  -- differs from `watts` above: watts is a figure the flight statistics record extremes of and is
  -- worth holding across a pass that answered nothing, while a percentage nobody records is
  -- better absent for that pass than a frame old.
  local escLimit = state.escCurrentLimit
  if type(escLimit) == "number" and escLimit > 0 and type(currentValue) == "number" then
    state.escLoad = currentValue / escLimit * 100
  else
    state.escLoad = nil
  end
  setField("altitude", getSensor("altitude") or state.altitude)
  -- SmartFuel computes these two in this same Lua state and hands them over there
  -- (tasks/events/telemetry_bg/smart.lua), so neither has to travel out to a telemetry sensor
  -- and back in again. The sensor search stays behind the hand-over rather than instead of it:
  -- it answers for a value this state did not compute, and it is what carries the reading
  -- before SmartFuel has one -- on an older flight controller, and in the window before the
  -- pack voltage has settled.
  local smart = _G.rfsuite and _G.rfsuite.session and _G.rfsuite.session.smartfuel or nil
  setField("consumedMah", (smart and smart.consumption) or getSensor("smartconsumption") or state.consumedMah)

  local fuel = (smart and smart.fuel) or getSensor("smartfuel") or getSensor("fuel")
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

  -- Published rather than computed here, because the announcement in lib/audio.lua decides the
  -- same question and a second reading of it would drift. The audio state is handed in as the
  -- memo the test needs, so the one piece of history behind it is cleared on the connection
  -- edges that already clear it and nowhere else. Plain assignment and not setField: this is
  -- derived from readings that have just been taken, not a reading of its own, and nothing about
  -- it should look to the rest of the pass like telemetry that changed.
  if DashboardAudio and type(DashboardAudio.mainPowerLost) == "function" then
    state.mainPowerLost = DashboardAudio.mainPowerLost(state, audioState)
  end

  local batteryCellCountValue = getSensor("battery_cell_count")
  if type(batteryCellCountValue) == "number" and batteryCellCountValue > 0 then
    setField("batteryCellCount", roundInt(batteryCellCountValue, state.batteryCellCount or 0))
  elseif type(voltageValue) == "number" and voltageValue > 0 then
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
    -- A cell count configured on the flight controller is the count it latches when it detects
    -- the pack (rotorflight-firmware `batteryUpdatePresence`), so it is taken as it is rather than
    -- guessed from the voltage: while the cell count sensor still reads 0 after a pack is plugged
    -- in, and on a model that carries no such sensor. lib/audio.lua and the flight record read the
    -- same field first for the same question. A count of 0 is the board detecting it itself.
    local configuredCells = tonumber(batteryConfig and batteryConfig.batteryCellCount)
    if configuredCells and configuredCells > 0 then
      setField("batteryCellCount", roundInt(configuredCells, state.batteryCellCount or 0))
    else
      -- Otherwise infer it from the battery config's max cell voltage. A voltage below half a
      -- cell is not a 1S pack but no pack at all -- a meter with nothing on it, or a pack that is
      -- gone -- so it never sets a count. A count already held is kept then: it is the count of
      -- the pack that was there, which is still the best fact about the pack that is gone.
      local maxCellVoltage = normalizeCellVoltage(batteryConfig and batteryConfig.vbatmaxcellvoltage, 4.2)

      local inferredCells = math.floor((voltageValue / maxCellVoltage) + 0.5)
      if inferredCells > 0 then
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
    end
  end

  -- Whether the pack the model came up with was full: judged once per connection by lib/audio.lua's
  -- *Pack Not Full* check, which takes it whether or not that announcement is switched on, and only
  -- READ here, from the audio state that latches it, to publish it for a theme the way
  -- `mainPowerLost` is published above. Not judged here: this read runs from the first pass of a
  -- connection, while the voltage it has can still be the previous pack's. Nil until judged, so a theme
  -- reading it with `== true` draws exactly what it drew before the verdict existed.
  if DashboardAudio and type(DashboardAudio.packVerdict) == "function" then
    state.packNotFull = DashboardAudio.packVerdict(audioState)
  end

  if type(armState) == "number" then
    -- STICKY, and cleared only on the reconnect edge below. `armed` starting false is
    -- indistinguishable from `armed` never having been read at all -- a model whose telemetry
    -- sensor 99 is not selected reads nil here for ever and looks disarmed the whole time -- and
    -- anything that refuses while armed has to be able to tell those two apart, because failing
    -- open there means sending MSP to a flying helicopter. Set on a reading left untaken as well:
    -- the sensor answered.
    state.armedSeen = true
  end
  if type(armTaken) == "number" and bit32 then
    setField("armed", bit32.btest(armTaken, 1))
  elseif type(armTaken) == "number" then
    setField("armed", armTaken ~= 0)
  end

  local rss1 = readFirstNumber(RSS1_SOURCES, state.rss1)
  setField("rss1", rss1)
  local rss2 = readFirstNumber(RSS2_SOURCES, state.rss2)
  setField("rss2", rss2)

  if telemetryChanged then updateDerivedFlightState(state) end
  readFlightRecord(state)
end

local function computeFlightMode(state)
  local isArmed = state.armed == true
  local wasArmed = state.prevArmed == true

  -- Arming is not flight: the governor is not up and the throttle has not risen, so the phase
  -- is neither the ground screen nor the in-flight one. It is its own phase, and a theme that
  -- does not draw it separately resolves it back to the ground screen.
  if isArmed and not wasArmed then
    state.hadInflightFlight = false
    return "armed"
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

    return "armed"
  end

  if state.hadInflightFlight == true then
    -- After the flight the link is what separates the two phases. While the board still
    -- answers, the summary stands beside a model that is live and can be armed again; once it
    -- stops answering, readTelemetry is skipped on purpose and every number on the screen is
    -- the last flight's. The two are the same picture only until a theme says otherwise, so
    -- `offline` falls back to the post-flight module.
    if state.rfConnected ~= true then
      return "offline"
    end
    return "postflight"
  end

  return "preflight"
end

-- Compatibility for a user theme that reads the record off `state` under its old flat names.
--
-- The record moved to rfsuite.session.flight and its field names went with it. A theme that has
-- always read `state.currentFlightMaxRpm` keeps working through the map below, which is built
-- from the record's OWN row list so that it cannot drift from the set. It is reached only for a
-- name that is not on the state table, which is no shipped theme and no code in this tree.
--
-- Deprecated: the record is `state.flight` for a theme, and rfsuite.session.flight for anything
-- outside the widget. See docs/reference/flight-statistics.md.
local compatNames = {}
local compatBuilt = false

local function buildCompatNames()
  if compatBuilt then return end
  compatBuilt = true
  local Record = nil
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local ok, mod = pcall(_G.rfsuite.require, "tasks/events/telemetry/flight_record.lua")
    if ok then Record = mod end
  end
  local rows = type(Record) == "table" and Record.stats or nil
  if type(rows) ~= "table" then return end
  for i = 1, #rows do
    local stat = rows[i]
    if stat.max then
      compatNames["currentFlightMax" .. stat.key] = { "current", "max" .. stat.key }
      compatNames["lastFlightMax" .. stat.key] = { "last", "max" .. stat.key }
    end
    if stat.min then
      compatNames["currentFlightMin" .. stat.key] = { "current", "min" .. stat.key }
      compatNames["lastFlightMin" .. stat.key] = { "last", "min" .. stat.key }
    end
  end
  -- The three older spellings without "Flight", which the record was also published under and
  -- which a theme is at least as likely to have copied as the longer ones.
  compatNames["lastMinVoltage"] = { "last", "minVoltage" }
  compatNames["lastMinBecVoltage"] = { "last", "minBecVoltage" }
  compatNames["lastMinLq"] = { "last", "minLq" }
end

local stateCompatMeta = {
  __index = function(state, key)
    local entry = compatNames[key]
    if entry == nil then return nil end
    local flight = rawget(state, "flight")
    local record = flight and flight[entry[1]]
    return record and record[entry[2]]
  end,
}

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
    -- Consecutive raises per job kind; see JOB_FAULT_LIMIT.
    _jobFaults = {},
    -- The fullscreen views, see widgets/dashboard/views.lua: the stack of open views, nil when
    -- none is open; the base layer under it, `"theme"` for a theme that draws its own fullscreen
    -- (taken on the fullscreen pass, see takeFullscreenMode); and the view the last interactive
    -- pass resolved, which the job it enqueues is named after.
    _viewStack = nil,
    _viewBase = nil,
    _viewId = nil,
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
      -- Set the first time the arm sensor answers with a number, and never inferred from `armed`
      -- being false: see readTelemetry.
      armedSeen = false,
      hadArmedFlight = false,
      hadInflightFlight = false,
      prevArmed = false,
      wasArmed = false,
      fblConnected = false,
      connectionReady = false,
      rpm = 0,
      profile = 1,
      rateProfile = 1,
      batteryProfile = nil,
      armFlags = 0,
      armDisableFlags = 0,
      -- The event history (noteEvent above): a table from here on, never nil, empty until the first
      -- transition.
      eventLog = {},
      -- The flight log's battery prompt. A table from here on, never nil: see
      -- newBatteryPickState above.
      batteryPick = newBatteryPickState(),
      governor = 0,
      -- The governor mode, carried over from the session in readTelemetry; nil until the
      -- connect chain has read it.
      governorMode = nil,
      throttlePercent = 0,
      mcuTemp = 0,
      escTemp = 0,
      bec_voltage = 0,
      current = 0,
      watts = 0,
      altitude = 0,
      consumedMah = 0,
      -- The per-flight extremes are not here any more: they are the record's, under
      -- rfsuite.session.flight, and `state.flight` below points at it. The four scalars that
      -- follow are read from the record once per pass and kept under the names they have
      -- always had, because lib/audio.lua and the time objects read them here.
      flight = nil,
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
      -- The main pack is gone while the board is still answering, decided in lib/audio.lua and
      -- published here so a theme can draw it. False rather than nil before the first read: a
      -- theme asking the question before any telemetry has arrived is not being told yes.
      mainPowerLost = false,
      -- The pack plugged in was not full: true, false once judged full, nil until judged. Decided
      -- once per connection in lib/audio.lua and published by readTelemetry.
      packNotFull = nil,
      lastFlightEndingVoltage = nil,
      lastFlightEndingCells = nil,
      lastDisarmAt = nil,
      themeConfig = { v_min = 18.0, v_max = 25.2 }
    },
    audioState = {
      initialized = false,
      nextAllowedAt = 0,
      modelAnnounced = false,
      lastFuelCallout = nil,
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

  -- Initialize i18n context for the widget using system locale. buildI18nContext is the same
  -- call the preferences reload makes after a language changed, so the widget's context is built
  -- from one place and not from two that can drift.
  widget.i18n = buildI18nContext()
  -- ensure renderers can access the same i18n via state
  if widget.i18n then
    widget.state.i18n = widget.i18n
  end

  -- The old flat names of the record answer through this, and nothing else does: __index is
  -- reached only for a key the state table does not hold.

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
    -- The same rule as readTelemetry's: a voltage below half a cell gives no count.
    if type(voltage) == "number" and voltage > 0 and maxCellVoltage > 0 then
      local implied = math.floor((voltage / maxCellVoltage) + 0.5)
      if implied > 0 then return implied end
    end

    return nil
  end

  -- The pack bounds the flight controller's cell limits give for this cell count.
  local function normalizedVoltageBounds(cells)
    local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
    local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
    local minCellVoltage = normalizeCellVoltage(batteryConfig and batteryConfig.vbatmincellvoltage, 3.3)
    local maxCellVoltage = normalizeCellVoltage(batteryConfig and batteryConfig.vbatmaxcellvoltage, 4.2)
    return cells * minCellVoltage, cells * maxCellVoltage
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
      -- refresh() computes the render key under a 2 Hz throttle and hands on the cached key while
      -- it is closed, which is nil now; a scene queued under that would be built again once the
      -- throttle computed the real key. Opening it keys the scene on the new bounds in this pass.
      self._lastUIRefresh = 0
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
    -- the four branches below that would end in a value-identical config -- custom bounds,
    -- no cell count, plausible bounds kept for the count they were derived for, or a
    -- normalization that lands on the bounds
    -- already held -- are decided here on the numbers alone, the existing table is kept, and
    -- only the (deduplicated, developer-gated) log line is still offered. Every path that can
    -- CHANGE a value falls through to the full copy below, so what the function computes is
    -- exactly what it computed before.
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
      local boundsCells = currentConfig._boundsCells
      if (not isExactDefault) and (not looksInvalidForCells) and (boundsCells == nil or boundsCells == cells) then
        logVoltageThemeDecision(self, "keep", cells, currentConfig.v_min, currentConfig.v_max, curMin, curMax)
        return
      end
      -- A normalization can land on exactly the bounds in hand: 6S with 3.0/4.2 V cell limits
      -- gives 18.0/25.2 V, the pair isExactDefault reads as an unnormalized default, so without
      -- this every pass would copy the table only to write the same two numbers back. The raw
      -- values are compared, not curMin/curMax, so bounds held as strings still get converted.
      -- The bounds in hand are then the ones derived for this count, and say so: a tag left at
      -- another count would let them stand if the count ever moved back to it.
      local nextMin, nextMax = normalizedVoltageBounds(cells)
      if currentConfig.v_min == nextMin and currentConfig.v_max == nextMax then
        if boundsCells ~= cells then currentConfig._boundsCells = cells end
        logVoltageThemeDecision(self, "normalize", cells, currentConfig.v_min, currentConfig.v_max, nextMin, nextMax)
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
    -- Bounds this function derived carry the cell count they were derived for, and are derived
    -- again when the count moves, however plausible they still look per cell: a count inferred
    -- from a voltage that was still rising (11 for a 12S pack) gives bounds that pass the test
    -- above for the real count too, and the real count arriving half a second later has to
    -- replace them. Bounds with no count of their own are judged by that test alone, as before.
    local boundsCells = currentConfig._boundsCells
    if (not isExactDefault) and (not looksInvalidForCells) and (boundsCells == nil or boundsCells == cells) then
      applyThemeConfig(self, nextConfig)
      logVoltageThemeDecision(self, "keep", cells, currentConfig.v_min, currentConfig.v_max, nextConfig.v_min, nextConfig.v_max)
      return
    end

    nextConfig.v_min, nextConfig.v_max = normalizedVoltageBounds(cells)
    nextConfig._boundsCells = cells
    applyThemeConfig(self, nextConfig)
    logVoltageThemeDecision(self, "normalize", cells, currentConfig.v_min, currentConfig.v_max, nextConfig.v_min, nextConfig.v_max)
  end

  local function reloadActiveTheme(self)
    -- A reload carried over from a telemetry read pass is answered by this one, whoever called
    -- it. Cleared first, so a load that raises is retried by the same tests as it was before.
    self._themeReloadPending = nil
    local modelPrefs = self.modelPreferences or (type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session.modelPreferences) or nil
    local selectedTheme = resolveThemePathForState((self.preferences and self.preferences.dashboard) or EMPTY_DASHBOARD, modelPrefs, self.flightMode, self.dashboardLib)
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
    -- The phase key, and the key every other phase resolves to for this theme, are kept so that
    -- the pass below can compare MODULES rather than phase names: a phase change that resolves
    -- to the module already on screen is not a reason to tear the scene down.
    local declares
    self.theme, self.themeStateKey, declares = loadThemeModuleForState(selectedTheme, self.flightMode)
    self.themeStateKeys = themeStateKeys(declares)

    -- A theme of the pilot's own may read the flight record under the names it carried before it
    -- moved to the session table. The mapping goes on HERE -- with the theme, in the same call,
    -- ahead of the build below that is the first thing to read it -- rather than on a later pass,
    -- where that first build would see nothing. A radio running the shipped themes never reaches
    -- this: the mapping answers every read of a key the state table does not hold, which is not
    -- free, and no shipped theme asks for one.
    if not self.flightCompat and parseThemePath(selectedTheme) ~= "system" then
      self.flightCompat = true
      buildCompatNames()
      setmetatable(self.state, stateCompatMeta)
    end

    self.built = false
    self.renderKey = nil
    -- The scene is to be keyed on the module this call has just loaded. refresh() copies the phase
    -- onto the state only at the top of a pass, and the 2 Hz throttle may hand back the key of the
    -- previous module; a scene queued under that key is built again once the throttle computes
    -- the new one. So the two fields refresh() copies are written here too, and the throttle is
    -- opened, which makes the next key computed the new module's. The cached key is left alone:
    -- the throttle overwrites it, and a surface that takes the throttle first falls back to it.
    self.state.flightMode = self.flightMode
    self.state.themePhase = self.themeStateKey or self.flightMode
    self._lastUIRefresh = 0
    -- A pending job may belong to the theme just torn down; drop it. The next STATE
    -- pass re-detects and enqueues a build against the new theme, in a pass of its own.
    self._job = nil
    -- And every job gets its tries back: what raised may have been the theme just replaced.
    self._jobFaults = {}

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
      -- A source a module reads without a box of its own naming it. Two shapes need this and
      -- neither can go through collect(): a free-form theme declares no boxes at all, so its
      -- closures see a snapshot holding only the fixed state fields; and a box that draws a
      -- session minimum or maximum beside its live value reads three sources through one
      -- `source` field. The list is the phase module's own, which is what makes it per phase --
      -- this runs again on every phase change, and the module standing here is the one being
      -- drawn, so a source declared for the ground is not read in the air.
      local function collectDeclared(declared)
        if type(declared) == "function" then
          local ok, list = pcall(declared, nil, self.state)
          declared = (ok and type(list) == "table") and list or nil
        end
        if type(declared) ~= "table" then return end
        for i = 1, #declared do
          local src = declared[i]
          if type(src) == "string" and src ~= "" and not seen[src] then
            seen[src] = true
            sources[#sources + 1] = src
          end
        end
      end
      collect(self.theme.boxes)
      -- Header boxes stand in the same tree and their closures read the same snapshot.
      collect(self.theme.header_boxes)
      -- Declared before the pairs are completed below, so a declared half gets its other half.
      collectDeclared(self.theme.sources)
      -- A status and the severity of it are one reading used together: the text goes in the box
      -- and the level colours it, and a colour closure can read only what the snapshot carries.
      -- So naming either half of a pair declares both. The second one costs a cache read on the
      -- pass that already resolved the first rather than a second pair of sensor reads, and a
      -- theme that names no half of a pair reaches none of it. Each pair stands alone: asking for
      -- the reading on file does not also resolve the live one, or the other way about.
      for i = 1, #PAIRED_SOURCES do
        local pair = PAIRED_SOURCES[i]
        if (seen[pair[1]] == nil) ~= (seen[pair[2]] == nil) then
          local missing = (seen[pair[1]] == nil) and pair[1] or pair[2]
          seen[missing] = true
          sources[#sources + 1] = missing
        end
      end
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
    local sinceLastTick = now - self._lastLogicTick
    if sinceLastTick < logicTick then return self.connectionReady end
    self._lastLogicTick = now

    -- Set event context to 'widget' before events wakeup
    if type(_G) == "table" then
      _G.rfsuite = _G.rfsuite or {}
      _G.rfsuite.session = _G.rfsuite.session or {}
      _G.rfsuite.session.event_context = "widget"
    end
    -- The announcements and SmartFuel's wake run on cadences of their own (0.25-0.6 s and 1.0 s),
    -- are independent of the telemetry read, and drift onto the read tick; on an arm or disarm
    -- edge they land there together with the drain, the edge runner and the read itself. So a
    -- pass that is going to read carries both to the next logic tick, the way a theme reload is
    -- carried further down.
    --
    -- Only where logic ticks come closer together than the read interval, because only there is
    -- the next tick one that does not read: where they are that far apart -- every pass of a scene
    -- build in between, or a widget called that rarely -- every tick reads, and carrying would put
    -- the work on the next read a whole interval later.
    --
    -- SmartFuel's wake runs inside the event runtime, before the connection state is updated and
    -- the read is decided below, so its flag is the same test on the state the previous pass left.
    -- At a link transition that can be one tick off in either direction, which moves the wake by a
    -- tick. The announcements run after the read and use the decision itself (see there).
    local carry = sinceLastTick < TELEMETRY_READ_SECONDS
      and (self.state.hadInflightFlight ~= true or self.state.rfConnected == true)
      and (now - (self._lastTelemetryReadAt or 0)) >= TELEMETRY_READ_SECONDS

    -- Ahead of the runtimes, because the record samples inside them: the count is what tells
    -- this pass's readings from the pass before it, and whether the read below is due is what
    -- lets the record sample on this pass rather than on one that does not read. Nothing between
    -- here and the read moves the read clock, so this is the test the read itself uses.
    local readDue = (now - (self._lastTelemetryReadAt or 0)) >= TELEMETRY_READ_SECONDS
    countSharedPass(now, readDue)
    tickMspRuntime(self, carry)
    
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
    local readThisPass = false
    if not isPostflightOffline then
      if readDue then
        self._lastTelemetryReadAt = now
        readThisPass = true
        readTelemetry(self.state, self.audioState)
        -- The snapshot the reactive closures read, rebuilt on the same cadence as the
        -- telemetry read that feeds it -- probing is legal here and nowhere in the sweep.
        if DerivedSnapshot and type(DerivedSnapshot.build) == "function" then
          DerivedSnapshot.build(self.state, self._snapshotSources or self.boxSources)
        end
        -- Only once this connection's edge below has been taken, so its first entry is the
        -- connection itself and not a reading taken on the pass that found it.
        if self.lastFblConnected == true then noteReadingEvents(self.state) end
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
      -- Copied even when nil, so a cleared configuration does not survive on the dashboard.
      self.state.battery_config = _G.rfsuite.session.battery_config
      if type(_G.rfsuite.session.modelPreferences) == "table" then
        self.modelPreferences = _G.rfsuite.session.modelPreferences
      end
    end

    -- The speed controller's current limit, lifted off the per-model store once per table rather
    -- than once per pass: a reload replaces the table, so the identity test above is what says
    -- the figure may have moved, and a steady-state pass pays one comparison. Reading the store
    -- itself here would be two table lookups and a tonumber on every pass for a value that
    -- changes when a pilot changes it and at no other time.
    --
    -- Both routes the preferences arrive by end in this reference: the widget's own disk read,
    -- and the connect chain leaving the table on the session.
    if self._escLimitSource ~= self.modelPreferences then
      self._escLimitSource = self.modelPreferences
      local battery = self.modelPreferences and self.modelPreferences.battery
      local limit = tonumber(battery and battery.esc_current_limit) or 0
      self.state.escCurrentLimit = (limit > 0) and limit or nil
    end

    updateVoltageThemeConfig(self)
    if isFblConnected and not wasFblConnected then
      -- New FBL session detected: clear stale postflight state and rebuild theme/UI.
      noteEvent(self.state, "connected", 1)
      self.state.hadArmedFlight = false
      self.state.hadInflightFlight = false
      self.state.prevArmed = false
      self.state.wasArmed = false
      self.state.armed = false
      -- Whether the arm sensor has been read at all this session. Cleared with the rest, because
      -- a new flight controller is a new answer to that question.
      self.state.armedSeen = false
      self.state.batteryCellCount = 0
      -- What the link sources derived for the last session. The diversity latch above all:
      -- it only ever rises, so carrying it over would report a second antenna on a receiver
      -- that has none. The packet-rate memo goes with it so that the first pass of the new
      -- session reads the rate rather than answering out of the previous one's cache. The
      -- transmitter module's ExpressLRS generation goes too, so the new session asks again: the
      -- module may have been reflashed or swapped while nothing was connected.
      self.state.linkDiversity = nil
      self.state.linkDiversityTick = nil
      self.state.linkRfMode = nil
      self.state.linkRfModeTick = nil
      self.state.linkGeneration = nil
      self.state.linkPingSent = nil
      -- The flight clock and the statistics are the record's; the event runtime drops them on
      -- the connect edge of its own link detector, which follows this one once the link has held
      -- for its CONNECT_STABLE_SECONDS -- not on the disconnect before it, which the post-flight
      -- page has to outlive -- and the passes after that read what is left. Nothing shows them in
      -- between: this branch has just torn the scene down, and the splash stands until the
      -- connect chain has run.
      self.state.lastDisarmAt = nil
      self.state.profile = nil
      self.state.rateProfile = nil
      self.state.batteryProfile = nil
      -- The worst the speed controller has reported since it was last asked, kept by the
      -- `esc_status` box source in widgets/dashboard/objects/common.lua. A new flight controller
      -- is a new answer to that question, and nothing else clears it -- a fault the controller
      -- has since stopped reporting is deliberately still on file for the rest of the session.
      -- `esc_status_live` shares this table and is not latched at all, so dropping it costs that
      -- reading nothing: the next pass decodes the two sensors again and answers afresh.
      self.state.escStatusCache = nil
      -- The battery prompt is per connection: which packs this model has, which one was picked
      -- for it, what the board answered, and whether the pilot has already been asked. A link
      -- that comes back is a fresh pack as far as anything here can tell, which is the same
      -- reading the event runtime takes when it drops the flight log's pending entry.
      self.state.batteryPick = newBatteryPickState()
      self._batteryPickRequest = nil
      self._batteryPickPicked = nil
      self._viewStack = nil
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
      if Sensors and type(Sensors.reset) == "function" then
        Sensors.reset()
      end
      if self.audioState and DashboardAudio and type(DashboardAudio.resetConnectionState) == "function" then
        DashboardAudio.resetConnectionState(self.audioState)
      end
      widgetLog(self, "FBL reconnect edge: reset dashboard session state", "info")
    elseif not isFblConnected and wasFblConnected then
      -- The event history's two memos go with the connection: the next one starts its governor
      -- from its own first reading and notes its speed controller's first verdict again.
      noteEvent(self.state, "disconnected", 2)
      self.state.eventGovernor = nil
      self.state.eventEsc = nil
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
      self.state.fuelTelemetrySeen = false
      self.state.packNotFull = nil
      self.state.previousSessionFuel = self.state.fuel
      self.state.fuel = 0
      if Sensors and type(Sensors.reset) == "function" then
        Sensors.reset()
      end
      -- The link is gone, so nothing can report what the board is doing with what the overlay
      -- last wrote. Both variables go back to 0 here rather than being left for the interlock.
      cleanupInflight(self)
      if self.audioState and DashboardAudio and type(DashboardAudio.resetConnectionState) == "function" then
        DashboardAudio.resetConnectionState(self.audioState)
      end
    end
    self.lastFblConnected = isFblConnected

    local nextMode = computeFlightMode(self.state)
    if statusLine ~= nil then self.statusLine = statusLine end

    -- The read has been decided by now, so this is exact rather than predicted: a pass that read
    -- while logic ticks come closer together than the read interval leaves the announcements to
    -- the next tick. That tick either does not read (the read stamp is this pass) or comes a read
    -- interval later, and runs them either way, so they are never put off twice in a row.
    if self.startupComplete and not (readThisPass and sinceLastTick < TELEMETRY_READ_SECONDS) then
      processAudioEvents(self)
    end

    local modelPrefs = self.modelPreferences or (type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session.modelPreferences) or nil
    local selectedTheme = resolveThemePathForState((self.preferences and self.preferences.dashboard) or EMPTY_DASHBOARD, modelPrefs, nextMode, self.dashboardLib)

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

    -- A phase change only rebuilds when it changes the module that is drawn. A theme that does
    -- not declare `armed` or `offline` resolves them to the ground and the post-flight module
    -- it already has on screen, and a rebuild there would be a torn-down LVGL tree for no
    -- visible difference -- once per arm, and again on every link transition after a flight.
    local modeChanged = (nextMode ~= self.flightMode)
    local wantReload = self._themeReloadPending == true
      or selectedTheme ~= self.themePath
      or modelPrefsChanged
      or not self.theme
      or (modeChanged and self.themeStateKeys[nextMode] ~= self.themeStateKey)

    -- A theme reload does not share a pass with the telemetry read: the two are the largest
    -- pieces of state work this runtime has, and on connect they land together with the connect
    -- chain. A reload that falls due in a read pass is carried to the next logic tick, and the
    -- flight mode waits with it, so nothing in between sees the new mode against the old theme.
    -- The next tick computes the mode again from the same state; only a preference change, which
    -- this pass has already consumed above, has to ride on the flag. A reload is carried once: the
    -- next tick is normally not a read pass (the read runs every TELEMETRY_READ_SECONDS, the tick
    -- every LOGIC_TICK_SECONDS), but where passes come further apart than the read interval every
    -- tick reads, and a carried reload then runs anyway rather than waiting for ever.
    if wantReload and readThisPass and self._themeReloadPending ~= true then
      self._themeReloadPending = true
      -- As the reload itself would: a job already queued belongs to the theme being replaced. In
      -- a foreground pass none is (a job pass never reaches this function), but widget.background
      -- runs this work whatever is queued.
      self._job = nil
    else
      self.flightMode = nextMode
      if wantReload then
        reloadActiveTheme(self)
      end
    end
    
    -- The overlay, last in the pass: it reads the per-model preferences and the connection state
    -- this pass has just settled, and it writes nothing that anything above it reads back.
    tickInflight(self)

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
    -- the debug level rewrites the settings file, which reloadPreferencesIfNeeded watches,
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

    -- The firmware calls refresh() for the widget the pilot is looking at and background() for
    -- every other one, so this is where "on screen" is known. The overlay drives only from here.
    self._foreground = true

    -- The suite's tool, opened from a fullscreen control, runs in place of the whole pass until
    -- it is closed (widgets/dashboard/tool_host.lua). It drives the MSP runtime and the event
    -- runner itself, so nothing below may run beside it; once it is closed the next pass finds
    -- the scene dropped and builds it again.
    if self._toolHost ~= nil then
      self._passWork = "tool"
      local ToolHost = toolHostModule()
      if type(ToolHost) == "table" then
        ToolHost.step(self, event, touchState)
      else
        self._toolHost = nil
      end
      self._passEndAt = nowSeconds()
      return
    end

    -- The tuning overlay's fast half, ahead of everything else this pass may or may not do: a
    -- JOB pass returns before the background half and a state pass reaches it only on the logic
    -- tick, and neither cadence is one a surface driving a flight controller can be read at.
    sampleInflight(self)

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
    -- The phase whose module is actually on screen. It differs from the phase above whenever a
    -- phase falls back to another one's module, and it is what the engine's render key is built
    -- from, so a fallback phase does not rebuild the scene it is already showing.
    self.state.themePhase = self.themeStateKey or self.flightMode

    -- JOB pass: serve the link with the minimal queue quantum, then run one job step.
    -- pump() is the queue half of tick() and nothing else, so in-flight MSP transfers
    -- keep moving while the build occupies the pass.
    --
    -- The same event context the background half sets brackets the pump: the poll and
    -- drain loops it reaches (tasks/msp/common.lua, tasks/msp/queue.lua) pick their
    -- widget-state bounds -- counts per pass, never wall clock -- by reading it, and
    -- without the bracket a JOB pass would silently run them under the tool rules.
    if self._job then
      -- A step line naming the work class this pass is about to do, so the card says what the
      -- widget was doing when it stopped rather than what the connect sequence last did.
      --
      -- Without it this file is not empty, which is worse than empty: the event runner leaves a
      -- line per task while connecting and then nothing, so it stands frozen at whatever the
      -- connect sequence last did, minutes or hours before the fault. That looks like an answer.
      --
      -- The KEY is the constant "wgt job" and the kind travels in the LABEL. That is the whole
      -- discipline `Sink.step` documents: it throttles a caller repeating the same KIND, so a key
      -- that varied with the work -- or was left to default to a label carrying a counter -- would
      -- look like news on every call and the file would be rewritten as fast as the widget
      -- renders. The label is a bounded set of strings -- one per job kind, the fullscreen views'
      -- ids and the fullscreen theme's `fs_theme` among them -- not a formatted one, so nothing is
      -- built on the pass either.
      local step = _G.rfsuite and _G.rfsuite.logStep
      if step then step("widget job: " .. tostring(self._job.kind), false, "wgt job") end

      -- and the same word for the gap line at the top of the NEXT pass, which is where a pass is
      -- charged for the slots it overran into. A build is the expensive work class this widget
      -- has, so a hole that follows one is a different finding from a hole that follows a state
      -- pass.
      self._passWork = self._job.kind

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
      -- Run the step under pcall so that a raise (including a CPU-limit kill or a
      -- theme build error) always clears _job.  Without this guard a raising step
      -- pins the widget in the JOB branch for ever: the next pass finds _job still
      -- set, reruns the same step, raises again, and the STATE branch — where
      -- performBackgroundWork / MspRuntime.tick live — is never reached again.
      local jobKind = self._job.kind
      -- Only a job the state pass arms on `built` can loop, so only those are counted. A one-shot
      -- job is armed by a request that it clears before it can raise, and each new request arms it
      -- again: it is logged in full every time, as before.
      local counted = self._job.oneShot ~= true
      -- Which surface the tree on screen is, for the hold gate in the state pass: forgotten before
      -- any build step runs, since a step may clear the tree and then raise, and recorded only
      -- once a build has completed. A one-shot job builds nothing and leaves the record alone.
      if counted then self._treeKind, self._treeKey = nil, nil end
      local stepOk, stepDone = pcall(self._job.step, self)
      if not stepOk then
        self._job   = nil
        self.built  = false
        local isCpuLimit = (LogSink and type(LogSink.isCpuLimitError) == "function" and LogSink.isCpuLimitError(stepDone))
          or (type(stepDone) == "string" and string.find(stepDone, "CPU limit", 1, true) ~= nil)
        -- Every raise counts against its kind, a step stopped at the instruction limit included;
        -- see JOB_FAULT_LIMIT. A build that always overruns is otherwise armed again after every
        -- back-off for as long as the widget runs. Counting here is safe after such a stop: the
        -- firmware raises the limit once per call and runs the rest of the call unmetered.
        local faults = 1
        if counted then
          faults = (self._jobFaults[jobKind] or 0) + 1
          self._jobFaults[jobKind] = faults
        end
        -- Only the first of a run goes to the card as a fault -- the ones after it are the same
        -- fault, and a fault line is written to the card as it happens; a stop at the limit is
        -- written there by the entry point -- and the raise that reaches the limit says so, so
        -- the log ends with the reason the screen shows what it shows.
        if faults == 1 and not isCpuLimit and LogSink and type(LogSink.fault) == "function" then
          pcall(LogSink.fault, "dashboard.job." .. tostring(jobKind), stepDone)
        end
        -- Under pcall: a log line that fails (out of memory) must not replace a CPU-limit stop on
        -- its way to the entry point below.
        pcall(logJobFault, self, jobKind, stepDone, faults)
        -- The entry point owns the CPU-limit response: the hold-off, and the release of the two
        -- variables the overlay may be holding. It cannot do either if the raise stops here.
        if isCpuLimit then
          error(stepDone, 0)
        end
      elseif stepDone then
        -- step returned true: job is done. A run of raises ends when the surface is drawn, not
        -- when a step merely returns: several steps finish without building anything, and the
        -- state pass then arms them again.
        if self.built then
          self._jobFaults[jobKind] = nil
          if counted then self._treeKind, self._treeKey = jobKind, self.renderKey end
        end
        self._job = nil
      end
      -- The second of the two clock reads the gap line is built from; see traceInstructionUsage.
      -- This exit and the end of the function carry it, which are the two a widget that is up
      -- takes. The cold-start exits below deliberately do not: a pass that returned there has not
      -- done the work the line is about, and -1 says so.
      self._passEndAt = nowSeconds()
      return
    end

    -- STATE pass: the background half, then invalidation checks that only enqueue.
    local ready = performBackgroundWork(self, false)

    -- `offline` is the post-flight phase with the link already gone, which is exactly the case
    -- this splash must not cover: the summary is what the pilot walked back to the bench for.
    if not ready and self.flightMode ~= "postflight" and self.flightMode ~= "offline" then
      local statusLine = self.statusLine or "Please wait..."
      -- Full screen and the zone are two splashes, because only the first carries the tool control.
      local fullscreenSplash = event ~= nil
      local splashKey = "splash|" .. tostring(statusLine) .. "|" .. tostring(self.state.zoneW) .. "x" .. tostring(self.state.zoneH)
        .. (fullscreenSplash and "|fs" or "")
      if self.renderKey ~= splashKey then
        self.renderKey = splashKey
        self.built = false
      end
      -- A splash that keeps raising falls back to the bare label, not to the failure surface,
      -- which is drawn by the same builder.
      if not self.built then
        if not jobCapped(self, "splash") then
          self._job = { kind = "splash", step = splashJobStep, fullscreenSplash = fullscreenSplash }
        elseif not jobCapped(self, "failed_label") then
          self._job = { kind = "failed_label", step = failedLabelJobStep }
        end
      end
      return
    end

    -- In EdgeTX, `event` is nil in normal widget mode, and an integer (including 0 for idle) in fullscreen.
    local isInteractive = (event ~= nil)
    if not isInteractive then
      -- Leaving fullscreen is the one exit the firmware does not always report -- a long press on
      -- RTN closes it and Lua may never see the key -- so the ground surface is dropped whenever a
      -- pass arrives without an event rather than when a close is observed. Ahead of the two
      -- early returns below, so a pass that returns there drops it as well.
      self.inflightFullscreen = nil
      -- The fullscreen views that are open are a fullscreen state and are dropped on the way
      -- out for the same reason the tuning surface is: a long press on RTN closes fullscreen
      -- without Lua ever seeing the key. The whole stack is this one field.
      self._viewStack = nil
    end

    -- A theme reload that fell on a read pass waits for the next logic tick; the deferral itself
    -- is in performBackgroundWork. Queuing a scene job here would build against the theme that
    -- reload is about to replace, and run ahead of it. widget.background queues no scene jobs.
    if self._themeReloadPending then
      self._passEndAt = nowSeconds()
      return
    end

    if not self.theme then return end

    local tuningMode = inflightMode(self, isInteractive)
    -- The readings of the fullscreen view on top, where it names any (viewSnapshotSources); every
    -- other surface leaves this nil, so leaving fullscreen stops reading them.
    local viewSources = nil
    -- See the gap line in traceInstructionUsage: a state pass is named by the surface it is for,
    -- so a hole measured while the tuning surface was up can be told from one on the dashboard.
    self._passWork = tuningMode or "state"
    local nextRenderKey = nil
    local holding, heldFor = false, 0
    if tuningMode then
      -- The same 2 Hz throttle the scene key is under. The values and the armed row are reactive
      -- closures and follow the state per frame; everything the key covers is layout, and
      -- rebuilding that at the pass rate would spend the budget those closures live on.
      --
      -- With one exception, and it is a safety rule rather than a performance one: while a step
      -- control is HELD the key is left exactly where it is. A rebuild calls lvgl.clear(), which
      -- deletes the momentary button under the pilot's finger, and EdgeTX raises that button's
      -- release handler only as LV_EVENT_RELEASED on the object itself -- so a deleted button
      -- never reports its release and the drive would keep writing the row's magnitude. What can
      -- still rebuild under a finger is what changes the LAYOUT -- a bank or a row the trims moved,
      -- the trim walk finishing, the flown profile changing -- and no longer the flight
      -- controller's answer to the step being made: a report moves the drive's report counter
      -- instead of the epoch below, and the number it carries reaches the screen through a closure
      -- (widgets/dashboard/inflight/drive.lua, the AdjF block in fastTick). When the hold ends the
      -- next recompute happens as it always did.
      local snapshot = self.state.inflight
      holding = (type(snapshot) == "table") and snapshot.holding == true
      if not self._lastUIRefresh then self._lastUIRefresh = 0 end
      local now = nowSeconds()
      -- When the hold began, for the cap on the hold gate below (HOLD_DEFER_SECONDS).
      if not holding then
        self._holdSince = nil
      elseif self._holdSince == nil then
        self._holdSince = now
      else
        heldFor = now - self._holdSince
      end
      -- A tap on a bank chip or a row asks for the new selection to be on screen at once rather
      -- than up to half a second later; it sets this flag instead of dropping the key itself, so
      -- that it goes through the hold gate like everything else.
      local wanted = (self._tuningKeyDirty == true) or (now - self._lastUIRefresh) >= 0.5
      if self._cachedTuningKey == nil or (wanted and not holding) then
        self._lastUIRefresh = now
        self._tuningKeyDirty = nil
        -- The PHASE is in the key, and it has to be: the three phases are three different trees,
        -- not three states of one, so a transition that did not move the key would leave the
        -- ground surface standing through a whole flight.
        self._cachedTuningKey = "tuning|" .. tuningMode .. "|" .. tostring(snapshot.phase)
          .. "|" .. tostring(snapshot.bank)
          .. "|" .. tostring(snapshot.row) .. "|" .. tostring(snapshot.epoch)
      end
      nextRenderKey = self._cachedTuningKey
    elseif isInteractive then
      self._cachedTuningKey = nil
      self._tuningKeyDirty = nil
      -- The prompt takes fullscreen ahead of the quick menu, because fullscreen is the only
      -- surface a widget has that can be pressed: a widget zone gets no touch, and Lua can
      -- leave fullscreen but not enter it. "On connect" therefore means "what fullscreen shows
      -- once the connect chain has run", until the pilot answers or closes it. Which view that
      -- is -- the picker, opened by its own condition, or the quick menu -- is views.lua's to say;
      -- a views module that could not be loaded shows no view and builds nothing.
      local Views = viewsModule()
      local viewId, viewKey = nil, nil
      if Views then
        -- A theme that draws its own fullscreen is the base layer under the views; see
        -- takeFullscreenMode. Its mode is taken once per theme, here rather than at the load.
        local modeOf = self._fullscreenModeOf
        if modeOf == nil or modeOf[1] ~= self.theme then takeFullscreenMode(self) end
        local pick = self.state.batteryPick
        if pick.openRequest ~= nil then takeBatteryPickOpen(self, Views, pick) end
        viewId, viewKey = Views.resolve(self)
        if self._viewBase ~= nil then viewId, viewKey = resolveThemeMode(self, viewId, viewKey) end
        viewSources = viewSnapshotSources(self, Views, viewId)
      end
      self._viewId = viewId
      nextRenderKey = viewKey
    else
      self._cachedTuningKey = nil
      self._tuningKeyDirty = nil
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

    self._snapshotSources = viewSources

    -- The job that builds this surface, named before the key is compared: a kind that has raised
    -- JOB_FAULT_LIMIT times in a row is not armed again, and the failure surface takes its place
    -- under a key of its own -- so it is drawn once, and again only after the pilot has been on
    -- another surface. The failure surface counts under its own kind; once it is capped as well,
    -- the bare label (failedLabelJobStep) takes its place under the same key, and once that is
    -- capped nothing is armed -- at most three raises of each, then the chain ends.
    -- `jobFullscreen` is the base layer's mark, which views.lua reads to drop a queued fullscreen
    -- build on a key; the failure surface that stands in for that build carries it too.
    local jobKind, jobStep, jobFullscreen = nil, nil, nil
    if tuningMode == "zone" then
      jobKind, jobStep = "tuning", tuningJobStep
    elseif tuningMode == "fs" then
      jobKind, jobStep = "tuning_fs", tuningFullscreenJobStep
    elseif isInteractive then
      -- The job is named after the view, so the job log line reads "menu" and "battery_pick"
      -- as it always has, and the menu keeps its pass class in bin/accounting/measure.lua.
      if self._viewId ~= nil then
        jobKind, jobStep = self._viewId, viewJobStep
      elseif self._viewBase ~= nil and nextRenderKey ~= nil then
        -- The base layer: the theme at the fullscreen size. Only where the views module was
        -- there to say that no view is on top, which is what a key of its own means.
        jobKind, jobStep, jobFullscreen = "fs_theme", fsThemeJobStep, true
      end
    else
      jobKind, jobStep = "scene", sceneJobStep
    end
    if jobKind ~= nil and jobCapped(self, jobKind) then
      nextRenderKey = "failed|" .. jobKind
      jobKind, jobStep = "failed", failedJobStep
      if jobCapped(self, jobKind) then jobKind, jobStep = "failed_label", failedLabelJobStep end
      if jobCapped(self, jobKind) then jobKind = nil end
    end

    if nextRenderKey ~= self.renderKey then
      self.renderKey = nextRenderKey
      self.built = false
      -- Fall through: detection and enqueue happen in this same pass, and the build
      -- lands in the next one, which carries nothing else.
    end

    -- The hold rule above keeps the tuning key still, but `built` and the render key are cleared
    -- from elsewhere as well: a theme reload (the latch into flight loads the in-flight module, a
    -- changed preference), the voltage bounds moving, new widget options. Each would rebuild the
    -- tuning surface under the finger, and the rebuild lets go of the hold first (tuningJobStep),
    -- so the held step ended with the finger still down. While a control is held and the tree on
    -- screen is the one this pass would build -- same job, same key -- that rebuild waits: `built`
    -- stays false and the first pass after the release builds it. A build of another surface --
    -- the zone's, once fullscreen has been left -- is a different job and is not held back. A hold
    -- older than HOLD_DEFER_SECONDS holds nothing back: the rebuild runs and lets go of it.
    if holding and heldFor < HOLD_DEFER_SECONDS
        and jobKind == self._treeKind and nextRenderKey == self._treeKey then
      jobKind = nil
    end

    if not self.built and jobKind ~= nil then
      -- The failure surface at full screen carries what the connect splash carries there, since
      -- it is drawn by the same builder: see failedJobStep.
      self._job = { kind = jobKind, step = jobStep, fullscreen = jobFullscreen,
        fullscreenSplash = jobKind == "failed" and isInteractive or nil }
    end

    -- The battery prompt's own work, last and only into a free slot: the registry read and the
    -- pick both touch the card, and neither is worth delaying a build for. The steady state
    -- past the load is three table reads. Both are one-shot jobs (see the dispatcher): neither is
    -- armed on `built`, and each clears what arms it before it can raise.
    if self._job == nil then
      if self._batteryPickRequest ~= nil then
        self._job = { kind = "battery_pick_apply", step = batteryPickApplyStep, oneShot = true }
      elseif self.state.batteryPick.loaded ~= true and self.state.tasksDone == true then
        self._job = { kind = "battery_pick_load", step = batteryPickLoadStep, oneShot = true }
      end
    end

    -- The second clock read; see the job pass above and traceInstructionUsage.
    self._passEndAt = nowSeconds()
  end

  function widget.background(self)
    -- Off screen. The overlay's own tick refuses to drive from here and cleans up instead, which
    -- is what makes a widget scrolled away stop writing the two variables.
    self._foreground = false

    -- Still running, so still passing: the heartbeat, as traceInstructionUsage publishes it at
    -- the top of refresh. A dashboard on a screen page the radio does not start on is called
    -- here before its first refresh, so the gate may not have been sampled yet. The usage figure
    -- is the last one refresh sampled: getUsage() answers an LVGL widget the share of its last
    -- pass that DREW in either entry point (luaGetUsage, radio/src/lua/api_general.cpp), so a
    -- background pass has no figure of its own to give.
    --
    -- Only the dashboard that drew last publishes here, or the one built last until one draws. A
    -- second dashboard on another screen page would otherwise keep the counter moving after the one
    -- on screen had been stopped by the instruction limit, and the stop would never be recorded.
    if self._shmOn == nil then
      self._shmOn = Log and type(Log.wanted) == "function" and Log.wanted("debug") or false
    end
    self._shmPass = (self._shmPass or 0) + 1
    if self._shmPass >= SHM_PASS_WRAP then self._shmPass = 1 end
    local shared = _G.rfsuite
    local owner = type(shared) == "table" and shared.dashboardHeartbeatOwner or nil
    if self._shmOn and type(setShmVar) == "function"
      and (owner == nil or owner == self._shmToken) then
      local usage = self._usageLast or 0
      setShmVar(SHM_PASS_ID, self._shmPass * SHM_PASS_SHIFT + (usage > 255 and 255 or usage))
    end

    -- An open tool cannot paint from here and its closing sequence needs the screen, so it is
    -- dropped at once and the dashboard's own background work takes over again.
    if self._toolHost ~= nil then
      local ToolHost = toolHostModule()
      if type(ToolHost) == "table" then ToolHost.abandon(self, "widget in the background") end
      self._toolHost = nil
    end
    performBackgroundWork(self, true)
    return 0
  end

  -- This dashboard's heartbeat mark for widget.background; claimed at the end of this function.
  widget._shmToken = {}

  -- The battery prompt's handle for anything that is not this widget: a theme, another widget,
  -- the tool. It records a REQUEST exactly as a press in the picker
  -- does and performs nothing itself, so a caller cannot put a card write or a queue turn into
  -- a frame that has no budget for it.
  --
  -- It is bound to this instance, and the last instance built wins. That is the honest scope:
  -- jobs are dispatched from `refresh`, so only the widget the pilot is looking at runs them,
  -- and a radio carrying two dashboard widgets has two of everything below anyway.
  if type(_G) == "table" then
    _G.rfsuite = _G.rfsuite or {}
    _G.rfsuite.batteryPick = {
      select = function(id)
        -- `false` is "no battery" and nil is "no request"; see battery_pick_menu.lua for why
        -- this cannot be written as an `and`/`or` pair.
        if id == nil then
          widget._batteryPickRequest = false
        else
          widget._batteryPickRequest = id
        end
      end,
      -- The two below run outside the widget's pcall, so the views module is reached through its
      -- loader, which returns nil rather than raising. Without the module dismiss() still ends
      -- the prompt, and open() only forces the rebuild.
      dismiss = function()
        local pick = widget.state.batteryPick
        pick.dismissed = true
        pick.pending = false
        local Views = viewsModule()
        if Views and Views.top(widget) == "battery_pick" then
          Views.navigate(widget, "closeView")
        end
        widget.built = false
        widget.renderKey = nil
      end,
      open = function()
        local Views = viewsModule()
        if Views then Views.navigate(widget, "openView:battery_pick") end
        -- and kept as a request of its own for the next fullscreen pass, because the stack the
        -- line above writes to is fullscreen state: the next pass without an event drops it, and
        -- a call made while the widget is in its zone -- the only place a theme runs -- would
        -- never reach the screen. The request is stamped with the last disarm, so it lapses once
        -- the model has flown since; it lapses while armed, and with the table on a reconnect.
        widget.state.batteryPick.openRequest = { disarmAt = widget.state.lastDisarmAt }
        widget.built = false
        widget.renderKey = nil
      end
    }
  end

  reloadActiveTheme(widget)

  -- The heartbeat mark for widget.background, claimed by the instance built last. A dashboard
  -- built again in place -- its screen's layout changed, or the widget set again in its zone --
  -- is built while a menu page covers it and draws nothing until that closes; the mark of the
  -- instance it replaced would keep it from publishing meanwhile, and the background decoder,
  -- which has seen the counter move, would record it as stopped. The one on screen takes the mark
  -- back on its next pass. Taken last here, so that a build that fails on the way leaves the
  -- mark where it was.
  if type(_G) == "table" then
    _G.rfsuite = _G.rfsuite or {}
    _G.rfsuite.dashboardHeartbeatOwner = widget._shmToken
  end
  return widget
end

return Runtime
