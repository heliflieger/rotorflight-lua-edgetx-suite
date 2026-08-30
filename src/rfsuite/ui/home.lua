local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local state

local function logToFile(msg)
  local prefs = state and state.preferences
  local general = prefs and prefs.general
  local debugLevel = general and general.debug_level
  if debugLevel == "debug" or debugLevel == "info" then
    local f = io.open("/SCRIPTS/TOOLS/rfsuite.user/exit_debug.log", "a")
    if f then
      local t = getTime and getTime() or 0
      io.write(f, "[" .. tostring(t) .. "] " .. tostring(msg) .. "\n")
      io.close(f)
    end
  end
end

local GridLayout = nil
local I18n = nil
local DisplayProfile = nil
local manifest = nil
local MenuRegistry = nil
local PageRegistry = nil
local HelpRegistryFactory = nil
local HelpRegistry = nil
local Tiles = nil
local Header = nil
local HelpView = nil
local PreferencesSafe = nil
local Version = nil
local MspRuntime = nil
local EepromWriteApi = nil
local Log = nil
local Events = nil
local Audio = nil
local Sensors = nil
local Precompile = nil

local MEM_LOG_INTERVAL_TICKS = 100

local APP_ICON  = "/SCRIPTS/TOOLS/rfsuite-core/assets/icon.png"

local M = {}

local mspUnsupportedDialogModule = nil
local mspUnsupportedDialogLoadTried = false

local Prefs = nil
local loadPreferencesSafe = nil
local savePreferencesSafe = nil

local function ensurePreferencesSafe()
  if not PreferencesSafe then
    PreferencesSafe = loadModule("ui/preferences.lua")
  end
  if not Prefs and PreferencesSafe and type(PreferencesSafe.new) == "function" then
    Prefs = PreferencesSafe.new(loadModule)
    loadPreferencesSafe = Prefs.load
    savePreferencesSafe = Prefs.save
  end
end

local function ensureVersion()
  if not Version then
    Version = loadModule("lib/version.lua")
  end
end

local function ensurePrecompile()
  if not Precompile then
    Precompile = loadModule("lib/precompile.lua")
  end
end

local function ensureMspRuntime()
  if not MspRuntime then
    MspRuntime = loadModule("tasks/msp/runtime.lua")
  end
end

-- Who the MSP queue files a request under while no page is open. It is the id this script
-- attaches to the runtime with, so that whatever the host itself queues goes when the host does.
local TOOL_MSP_CLIENT = "tool"

-- One client per page, because that is the unit that appears and disappears: everything a page
-- queued stops being wanted the moment the page is gone, and nothing else in the queue does.
local function mspClientForMenu(menuId)
  if menuId == nil then
    return TOOL_MSP_CLIENT
  end
  return "page:" .. tostring(menuId)
end

local function ensureEepromWriteApi()
  if not EepromWriteApi then
    EepromWriteApi = loadModule("tasks/msp/api/eeprom_write.lua")
  end
end

local function queueEepromWriteIfNeeded(page)
  if type(page) ~= "table" or page.eepromWrite ~= true then
    return true
  end

  ensureMspRuntime()
  ensureEepromWriteApi()

  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end
  if not EepromWriteApi or type(EepromWriteApi.buildWritePayload) ~= "function" then
    return false, "eeprom_api_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  queue:add({
    command = EepromWriteApi.writeCommand,
    payload = EepromWriteApi.buildWritePayload({}),
    timeout = 5.0,
    isWrite = true,
    processReply = function() end,
    errorHandler = function() end
  })

  return true, nil
end

local function ensureEvents()
  if not Events then
    Events = loadModule("tasks/events/runtime.lua")
  end
  if not Audio then
    Audio = loadModule("lib/audio.lua")
  end
  if not Sensors then
    Sensors = loadModule("lib/sensors.lua")
  end
end

local function isModelArmed()
  ensureEvents()
  if not Sensors or type(Sensors.getValue) ~= "function" then
    return false
  end
  local isSim = false
  if Sensors and type(Sensors.isSimulator) == "function" then
    isSim = Sensors.isSimulator()
  end
  if not isSim and type(getRSSI) == "function" then
    local ok, rssi = pcall(getRSSI)
    if ok and type(rssi) == "number" and rssi <= 0 then
      return false
    end
  end
  local value = Sensors.getValue("armflags")
  if value ~= nil then
    if type(value) == "number" then
      if type(bit32) == "table" and type(bit32.btest) == "function" then
        return bit32.btest(value, 1)
      end
      return value ~= 0
    end
    if type(value) == "boolean" then
      return value
    end
    if type(value) == "string" then
      local n = tonumber(value)
      if type(n) == "number" then
        return n ~= 0
      end
    end
  end
  return false
end

-- A no-op stand-in rather than false. Every call site below is `pcall(Log.emit, ...)`, and Lua
-- evaluates the argument list before pcall runs -- so indexing a false Log raises outside the
-- very pcall that was written to contain it.
local NO_LOG = { emit = function() end }
-- Whether the armed state cannot be established AT ALL, as opposed to being established as
-- disarmed. isModelArmed answers the question the screen needs -- "paint the warning?" -- and
-- answers false for three different reasons: not armed, no sensor, no link. That is the right
-- default for a warning, which must not stand permanently on a radio that cannot know. It is
-- the wrong default in front of a WRITE, where "cannot tell" is not "safe to proceed".
--
-- Deliberately narrow. A missing sensor module is a broken tool and not this question; a link
-- that is down cannot carry the write either, so the save fails on its own terms. What is left
-- is the case worth asking about: the link is up, the module is there, and the flight
-- controller does not report the arming flags -- no bridge, or no slot for them among its
-- forty telemetry sensors.
local function armedStateIsUncertain()
  ensureEvents()
  if not Sensors or type(Sensors.getValue) ~= "function" then
    return false
  end
  if Sensors.getValue("armflags") ~= nil then
    return false
  end
  local isSim = type(Sensors.isSimulator) == "function" and Sensors.isSimulator() or false
  if not isSim and type(getRSSI) == "function" then
    local ok, rssi = pcall(getRSSI)
    if ok and type(rssi) == "number" and rssi <= 0 then
      return false
    end
  end
  return true
end

local Log = nil
if Log == nil then
  Log = loadModule("lib/log.lua") or NO_LOG
end

-- The card sink is loaded on first use rather than here: with the option off, which is how it
-- ships, the chunk is never read off the card and the cost of asking is one table lookup.
-- lib/log_sink.lua makes the same check itself, so a caller cannot be wrong about it -- this
-- one only decides whether the module is worth loading.
local LogSink = nil
local logSinkTried = false

local function cardLogEnabled()
  local general = state and state.preferences and state.preferences.general
  return type(general) == "table" and general.log_to_card == true
end

local function sink()
  if not cardLogEnabled() then return nil end
  if not LogSink and not logSinkTried then
    logSinkTried = true
    LogSink = loadModule("lib/log_sink.lua")
    if LogSink and type(LogSink.configure) == "function" then
      LogSink.configure("tool")
    end
  end
  return LogSink
end

-- Navigation, in the log rather than only on the screen. The tool's whole job is to move
-- between menus and pages, and until now almost none of that left a trace: a report that "it
-- hung after I opened X" could not be checked against what the tool thought it had opened.
local function logf(level, fmt, ...)
  if Log and type(Log.emitf) == "function" then
    Log.emitf("rfsuite.ui", level, fmt, ...)
  end
end

-- What was being started. Written to a file of its own that is closed again immediately, so it
-- is on the card even when the call it names never returns.
local function logStep(label, force, key)
  local s = sink()
  if s and type(s.step) == "function" then
    pcall(s.step, label, force, key)
  end
end

local function ensurePageRegistry()
  if not PageRegistry then
    PageRegistry = loadModule("app/pages/init.lua")
  end
end

local function ensureHelpRegistry()
  ensurePageRegistry()
  if not HelpRegistryFactory then
    HelpRegistryFactory = loadModule("app/pages/help_registry.lua")
  end
  if not HelpRegistry and HelpRegistryFactory and type(HelpRegistryFactory.new) == "function" then
    HelpRegistry = HelpRegistryFactory.new({
      pagePathByMenuId = PageRegistry.pagePathByMenuId
    })
  end
end

local LoadingOverlay = nil
local SavePipeline = nil

--- What the start is waiting for, by the onconnect runner's own task name.
-- The runner reports the pending task as the manifest id; these are the same ids, with a text
-- the pilot can read. An id with no entry falls back to the generic notice rather than putting
-- an internal name on screen.
--- What a save is doing, for the phases that have no step count of their own.
-- The writes and the EEPROM commit are counted, so they name the step being written; everything
-- after the commit is a wait on the flight controller and is named rather than counted.
local SAVE_TEXT = {
  rebooting    = "@i18n(app.save.rebooting)@",
  waiting      = "@i18n(app.save.waiting)@",
  reconnecting = "@i18n(app.save.reconnecting)@",
  reading_back = "@i18n(app.save.reading_back)@",
  saved_title  = "@i18n(app.save.saved_title)@",
  dismiss      = "@i18n(app.save.dismiss)@",
  done_message = "@i18n(app.save.done_message)@",
  timeout_title   = "@i18n(app.save.timeout_title)@",
  timeout_message = "@i18n(app.save.timeout_message)@",
  failed_title    = "@i18n(app.save.failed_title)@",
  failed_message  = "@i18n(app.save.failed_message)@",
  eeprom_pending  = "@i18n(app.save.eeprom_pending)@",
}

-- getTime() ticks, at 10 ms each. How long a notice reporting a SUCCESSFUL save stays up
-- before it clears itself; the button it already draws stays as the earlier way out. A page
-- says a save succeeded by passing `ok = true` to reportSave -- absent, the notice stands,
-- which is what a failure, a warning and a refusal all need. Kept level with the pipeline's
-- own OUTCOME_LINGER_SECONDS so a save reports for the same length of time either way.
local SAVE_OUTCOME_LINGER_TICKS = 200

local SAVE_PHASE_TEXT = {
  preflight = "rebooting",
  reboot    = "rebooting",
  probe     = "waiting",
  onconnect = "reconnecting",
  verify    = "reading_back",
  reload    = "reading_back",
}

local ONCONNECT_TEXT = {
  apiversion        = "@i18n(app.onconnect.apiversion)@",
  uid               = "@i18n(app.onconnect.uid)@",
  rtc               = "@i18n(app.onconnect.rtc)@",
  status            = "@i18n(app.onconnect.status)@",
  battery_config    = "@i18n(app.onconnect.battery_config)@",
  governor_config   = "@i18n(app.onconnect.governor_config)@",
  esc_sensor_config = "@i18n(app.onconnect.esc_sensor_config)@",
  smartfuel_config  = "@i18n(app.onconnect.smartfuel_config)@",
  name              = "@i18n(app.onconnect.name)@",
  telemetry         = "@i18n(app.onconnect.telemetry)@",
  flight_stats      = "@i18n(app.onconnect.flight_stats)@",
  dataflash_summary = "@i18n(app.onconnect.dataflash_summary)@"
}

-- The glyph on a tile the armed state has locked. It goes through i18n like every other
-- string on screen, even though both locales carry the same mark: ui/tiles.lua is a pure
-- renderer and is handed the resolved text rather than a locale of its own.
local ARMED_BADGE_TEXT = "@i18n(app.model_armed_badge)@"

-- The one line the strip carries. It says what the state is and what it costs, because the
-- tool stays usable around it -- it is a status, not a demand.
local ARMED_BANNER_TEXT = "@i18n(app.model_armed_banner)@"

-- What the backstop behind the disabled Save and Reload buttons says. Unchanged wording: it
-- is the same refusal it always was, in the tool's own box instead of a native modal.
local ARMED_NOTICE_TITLE = "@i18n(app.model_armed_title)@"
local ARMED_NOTICE_MESSAGE = "@i18n(app.model_armed_warning)@"

local function ensureBuildDeps()
  if not GridLayout then
    GridLayout = loadModule("layouts/grid.lua")
  end
  if not DisplayProfile then
    DisplayProfile = loadModule("core/display_profile.lua")
  end
  if not Tiles then
    Tiles = loadModule("ui/tiles.lua")
  end
  if not Header then
    Header = loadModule("ui/header.lua")
  end
  if not LoadingOverlay then
    LoadingOverlay = loadModule("ui/loading_overlay.lua")
  end
  if not SavePipeline then
    SavePipeline = loadModule("tasks/msp/save_pipeline.lua")
  end
end

local function ensureHelpView()
  if not HelpView then
    HelpView = loadModule("ui/help_view.lua")
  end
end

local function ensureInitDeps()
  ensurePreferencesSafe()
  if not I18n then
    I18n = loadModule("i18n/init.lua")
  end
  if not manifest then
    manifest = loadModule("app/manifest.lua")
  end
  if not MenuRegistry then
    MenuRegistry = loadModule("app/menu_registry.lua")
  end
end

-- Global access point: rfsuite.preferences and rfsuite.savePreferences
-- Any module can read settings via: rfsuite.preferences.general.save_confirm
_G.rfsuite = _G.rfsuite or {}
_G.rfsuite.savePreferences = function()
  return savePreferencesSafe(_G.rfsuite.preferences)
end

local function computeTileSize(cardW, cardH, cfg)
  local size = math.min(cfg.tileMax, cardW)
  if size < 1 then
    return 1
  end
  return size
end

-- The height a page module may actually lay out in.
--
-- `lvgl.build` gives a "page" element a header of its own and parents the children to
-- page->getBody(), a window at {0, MENU_HEADER_HEIGHT, LCD_W, LCD_H - MENU_HEADER_HEIGHT}
-- (lua_lvgl_widget.cpp). Handing a page module LCD_H therefore overstates its room by exactly
-- that header, and nothing complains because the page scrolls.
--
-- EdgeTxStyles::MENU_HEADER_HEIGHT is LAYOUT_SCALE(45) and is not exposed to Lua, so the value
-- is restated here. LAYOUT_SCALE is the identity outside landscape, where it gives 36 at
-- LCD_W 320 and 62 at 800 (etx_lv_theme.h) -- a portrait radio 320 wide still gets 45.
local function pageBodyHeight()
  local screenW = LCD_W or 480
  local screenH = LCD_H or 320
  local headerH = 45
  if screenW > screenH then
    if screenW == 320 then
      headerH = 36
    elseif screenW == 800 then
      headerH = 62
    end
  end
  return screenH - headerH
end

local function toWrappedItems(items, cols)
  local wrapped = {}
  local c = 1
  local r = 1
  for i = 1, #items do
    local item = items[i]
    wrapped[i] = {
      id = item.id,
      row = r,
      col = c,
      data = item.data
    }
    c = c + 1
    if c > cols then
      c = 1
      r = r + 1
    end
  end
  return wrapped, r
end

local function wipeTable(t)
  if type(t) ~= "table" then return end
  for k in pairs(t) do t[k] = nil end
end

state = {
  shouldExit   = false,
  cards        = {},
  i18n         = nil,
  menu         = nil,
  preferences  = nil,
  manifest     = nil,
  cardHandlers = {},
  focusIndex   = 0,
  ignoreNextPageKey = false,
  suppressPressFrames = 0,
  suppressBackFrames = 0,
  backGestureActive = false,
  lastBackTick = 0,
  memBucket    = nil,
  memLastTick  = 0,
  memPeakKb    = 0,
  lastInputTick = 0,
  initialLoadStartTick = 0,
  activePageMenuId = nil,
  helpContent = nil,
  helpPageTitle = nil,
  helpPageSubtitle = nil,
  pendingBuildUI = false,
  pendingGcAfterBuild = false,
  pendingSaveAction = nil,
  saveOutcome = nil,
  saveOverlayVisible = false,
  armedNoticeVisible = false,
  lastSaveSnapshot = nil,
  mspAttached = false,
  mspLastTick = 0,
  fblConnected = false,
  infoSessionSnapshot = nil,
  lastAudioTick = 0,
  audioState = {
    initialized = false,
    nextAllowedAt = 0,
    modelAnnounced = false,
    lastFuelCallout = nil,
    lowFuelActive = false,
    lowFuelLastAt = 0,
    lowFuelRepeatCount = 0,
    -- This table is rebuilt every time the tool is started, which is not the same thing as
    -- the craft having reconnected. The fuel level and the battery capacity are announced
    -- once per connection, so without these two the pilot hears both again on every open,
    -- with nothing on the craft having changed. Each flag is consumed once, by the first
    -- reading that would otherwise have been announced, and a genuine reconnect later in the
    -- same session speaks as it always did.
    seedInitialFuel = true,
    seedBatteryCapacity = true,
    -- lastAlertAt wird nicht mehr hier initialisiert, sondern nur noch lazy in Audio
    lastValues = { arming_flags = nil, governor_state = nil, pid_profile = nil, rate_profile = nil, battery_profile = nil },
    pendingValues = { pid_profile = nil, rate_profile = nil, battery_profile = nil },
    lastEnabled = { governor_state = nil }
  },
  telemetryState = { profile = 1, rateProfile = 1, batteryProfile = 1, voltage = 0, bec_voltage = 0, escTemp = 0, fuel = 100, armFlags = 0, governor = 0, themeConfig = { v_min = 18.0 } },
  mspLinkConfigWarningAt = 0,
  headerActions = {
    defaults = {
      root = {
        star = false,
        reload = false,
        save = false,
        help = false
      },
      menu = {
        star = false,
        reload = false,
        save = false,
        help = false
      }
    },
    byEntryId = {
      -- Example:
      -- pids = { reload = true, save = true, star = true }
    },
    byMenuId = {
      settings_general_page      = { save = true, reload = true, help = false },
      settings_localization_page = { save = true, reload = true, help = false }
    }
  },
  children = {}
}

local function shortenBreadcrumb(breadcrumb)
  -- Reduces full breadcrumb to "../LastPart" format
  -- E.g., "System / Tools" or "System > Tools" becomes "../Tools"
  if type(breadcrumb) ~= "string" or breadcrumb == "" then
    return breadcrumb
  end
  
  local parts = {}
  local normalized = string.gsub(breadcrumb, " > ", " / ")
  for part in string.gmatch(normalized, "[^/]+") do
    local trimmed = string.match(part, "^%s*(.-)%s*$")
    if trimmed then
      parts[#parts + 1] = trimmed
    end
  end
  
  if #parts <= 1 then
    return breadcrumb
  end
  
  local lastPart = parts[#parts]
  if lastPart then
    return "../" .. lastPart
  end
  return breadcrumb
end

local function performSave()
  _G.rfsuite.preferences = state.preferences
  return savePreferencesSafe(state.preferences)
end

local function isContinuousMemoryLogEnabled()
  local general = state.preferences and state.preferences.general
  return type(general) == "table" and general.continuous_memory_log == true
end

local function isSerialMemoryLogEnabled()
  local general = state.preferences and state.preferences.general
  return type(general) == "table" and general.enable_serial_debug == true and type(serialWrite) == "function"
end

local function logMemoryUsage(now)
  if not isContinuousMemoryLogEnabled() then
    state.memLastTick = 0
    return
  end

  if type(collectgarbage) ~= "function" then
    return
  end

  local tickNow = tonumber(now) or 0
  if tickNow > 0 and state.memLastTick > 0 and (tickNow - state.memLastTick) < MEM_LOG_INTERVAL_TICKS then
    return
  end

  local memKb = math.floor((collectgarbage("count") or 0) + 0.5)
  if memKb > (state.memPeakKb or 0) then
    state.memPeakKb = memKb
  end

  state.memLastTick = tickNow > 0 and tickNow or (state.memLastTick or 0)

  local line = "[mem][info] lua_kb=" .. tostring(memKb) .. " peak_kb=" .. tostring(state.memPeakKb or memKb)
  local msg = "lua_kb=" .. tostring(memKb) .. " peak_kb=" .. tostring(state.memPeakKb or memKb)
  pcall(Log.emit, "mem", msg, "info", true)
end

local function resolveLocaleFromSystem()
  -- Always reload module on init so locale behavior changes are picked up
  -- immediately and not held back by stale cached globals.
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", "t")
  if chunk then
    local ok, localeMod = pcall(chunk)
    if ok and type(localeMod) == "table" and type(localeMod.resolveSystemLanguage) == "function" then
      if type(_G) == "table" then
        _G.__rfsuite_system_locale_module = localeMod
      end
      local okResolve, locale = pcall(localeMod.resolveSystemLanguage, "en")
      if okResolve and type(locale) == "string" and locale ~= "" then
        return locale
      end
    end
  end

  return "en"
end

local function buildPageContext()
  return {
    i18n = state.i18n,
    preferences = state.preferences,
    menu = state.menu,
    manifest = state.manifest,
    refresh = M.buildUI,
    savePreferences = performSave
  }
end

local function scheduleBuildUI(withGc)
  state.pendingBuildUI = true
  if withGc == true then
    state.pendingGcAfterBuild = true
  end
end

-- The `requestRebuild` handed to a page, a dialog or the help view is always one of
-- these two calls. Written inline at six sites, a closure was built every time the
-- table around it was: once per scene build at five of them, and once per frame at
-- the sixth, which is the active page's wakeup in `M.run`.
local function requestRebuild() scheduleBuildUI(false) end
local function requestRebuildWithGc() scheduleBuildUI(true) end

local function syncActivePageModule()
  local currentMenuId = state.menu and state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
  if state.activePageMenuId == currentMenuId then
    return
  end

  -- Take the outgoing page's reads back before it is released. Every one of them carries a
  -- processReply that closes over the widgets this rebuild is about to destroy, so a reply that
  -- arrives after the release runs against a tree that no longer exists. This happens first
  -- because the release itself queues work -- the override and rollback resets -- and that work
  -- must not be dropped again as part of the page it belongs to.
  ensureMspRuntime()
  if state.activePageMenuId ~= nil and MspRuntime and type(MspRuntime.dropClientReads) == "function" then
    pcall(MspRuntime.dropClientReads, mspClientForMenu(state.activePageMenuId))
  end

  if state.activePageMenuId and PageRegistry and PageRegistry.release then
    PageRegistry.release(state.activePageMenuId, buildPageContext())
  end

  logf("debug", "page %s -> %s", tostring(state.activePageMenuId), tostring(currentMenuId))
  state.activePageMenuId = currentMenuId

  -- From here everything queued belongs to the page that is up, without the page saying so: the
  -- pages hold the queue itself and none of them names a client.
  if MspRuntime and type(MspRuntime.setDefaultClient) == "function" then
    pcall(MspRuntime.setDefaultClient, mspClientForMenu(currentMenuId))
  end
end

-- ── Handlers ─────────────────────────────────────────────────────────────────

local function onBack(source, ev)
  logToFile("onBack called source=" .. tostring(source) .. " ev=" .. tostring(ev))
  logf("debug", "back source=%s ev=%s at=%s", tostring(source), tostring(ev),
    tostring(state.menu and state.menu.getCurrentMenuId and state.menu.getCurrentMenuId()))

  if state.isClosing then
    return
  end

  local now = (type(getTime) == "function" and getTime()) or 0
  if now > 0 and (state.lastBackTick or 0) > 0 and (now - state.lastBackTick) < 35 and (now - state.lastBackTick) >= 0 then
    logf("debug", "back dropped by debounce (dt=%d ticks)", now - state.lastBackTick)
    return
  end

  local fromEvent = source == "event"

  if state.backGestureActive then
    return
  end
  state.backGestureActive = true

  -- A save that reboots holds the page: the values are on their way to a flight controller that
  -- is about to restart, and leaving would put a page on screen showing what it read before.
  -- Once the settings are in EEPROM there is nothing left to protect, so from that moment the
  -- same press dismisses the overlay and the pipeline carries on without a screen.
  -- A save that has just reported itself is not holding the page -- it is holding a notice, and
  -- the press that would leave the page reads it instead.
  -- A save with no pipeline reports into the same notice, and the press that would leave the
  -- page reads that notice away instead.
  if state.saveOutcome then
    state.saveOutcome = nil
    state.saveOverlayVisible = false
    if fromEvent then
      state.suppressBackFrames = 6
    end
    scheduleBuildUI(false)
    return
  end

  if SavePipeline and type(SavePipeline.hasOutcome) == "function" and SavePipeline.hasOutcome() then
    SavePipeline.dismiss()
    if fromEvent then
      state.suppressBackFrames = 6
    end
    scheduleBuildUI(false)
    return
  end

  if SavePipeline and type(SavePipeline.blocksNavigation) == "function"
    and SavePipeline.blocksNavigation() then
    if SavePipeline.isDismissible() then
      SavePipeline.dismiss()
      if fromEvent then
        state.suppressBackFrames = 6
      end
      scheduleBuildUI(false)
    end
    return
  end

  if state.helpContent then
    closeHelpDialogIfOpen()
    if fromEvent then
      state.suppressBackFrames = 6
    end
    scheduleBuildUI(false)
    return
  end

  local currentMenuId = state.menu and state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
  if currentMenuId then
    ensurePageRegistry()
    local pageModule = PageRegistry and PageRegistry.get and PageRegistry.get(currentMenuId) or nil
    if pageModule and type(pageModule.onBack) == "function" then
      local handled = pageModule.onBack({
        requestRebuild = requestRebuildWithGc,
        i18n = state.i18n
      })
      if handled == true then
        if fromEvent then
          state.suppressBackFrames = 6
        end
        scheduleBuildUI(true)
        return
      end
    end
  end

  if state.menu and not state.menu.isRoot() then
    local didGoBack = false
    local newMenuId = nil
    if state.menu.goBack and state.menu.goBack() then
      didGoBack = true
      state.focusIndex = 0
      newMenuId = state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
    end

    if not didGoBack and state.menu.getActiveSection and state.menu.setActiveSection then
      local section = state.menu.getActiveSection()
      if section and section.id then
        state.menu.setActiveSection(section.id)
        state.focusIndex = 0
        newMenuId = state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
      end
    end
    if fromEvent then
      state.suppressBackFrames = 6
    end
    state.lastBackTick = now
    scheduleBuildUI(true)
    return
  end
  state.lastBackTick = now
  state.isClosing = true
end

local function onHelp()
  if state.helpContent then return end

  local menuId = state.menu and state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
  if not menuId then return end

  local function resolveI18nHelpMessageFromPagePath(id)
    if not (state.i18n and type(state.i18n.t) == "function") then
      return nil
    end
    ensurePageRegistry()
    local pagePathByMenuId = PageRegistry and PageRegistry.pagePathByMenuId or nil
    local pagePath = type(pagePathByMenuId) == "table" and pagePathByMenuId[id] or nil
    if type(pagePath) ~= "string" or pagePath == "" then
      return nil
    end

    if string.sub(pagePath, -9) == "/page.lua" then
      pagePath = string.sub(pagePath, 1, -10)
    end

    local pageKey = string.gsub(pagePath, "/", "_")
    local i18nKey = "pages." .. pageKey .. ".help_message"
    local translated = state.i18n.t(i18nKey)
    if type(translated) == "string" and translated ~= "" and translated ~= i18nKey then
      return translated
    end
    return nil
  end

  ensureHelpRegistry()

  local helpCtx = {
    i18n = state.i18n,
    preferences = state.preferences,
    menu = state.menu,
    manifest = state.manifest
  }

  local helpData = nil
  local page = getActivePageModule()
  if page and type(page.onHelp) == "function" then
    helpData = page.onHelp(helpCtx)
  elseif HelpRegistry and HelpRegistry.get then
    helpData = HelpRegistry.get(menuId, helpCtx)
  end

  local message = nil
  if type(helpData) == "string" then
    message = helpData
  elseif type(helpData) == "table" then
    message = helpData.message or helpData.text
  end
  if type(message) ~= "string" or message == "" then
    message = resolveI18nHelpMessageFromPagePath(menuId)
    if type(message) ~= "string" or message == "" then
      return
    end
  end

  local title = state.menu.getHeaderTitle and state.menu.getHeaderTitle() or ""
  local subtitle = nil
  local breadcrumb = state.menu.getHeaderBreadcrumb and state.menu.getHeaderBreadcrumb() or ""
  if breadcrumb == "" and state.menu.getBreadcrumb then
    breadcrumb = state.menu.getBreadcrumb() or ""
  end
  if breadcrumb ~= "" then
    subtitle = shortenBreadcrumb(breadcrumb)
  end

  state.helpContent = message
  state.helpPageTitle = title
  state.helpPageSubtitle = subtitle
  scheduleBuildUI(false)
end

local function openPageHelpDialog(message, title, subtitle)
  if type(message) ~= "string" or message == "" then
    return
  end

  state.helpContent = message
  state.helpPageTitle = title
  state.helpPageSubtitle = subtitle
  scheduleBuildUI(false)
end

local function onStar()
  local page = getActivePageModule()
  if page and type(page.onStar) == "function" then
    closeHelpDialogIfOpen()
    local shouldRebuild = page.onStar({
      i18n = state.i18n,
      preferences = state.preferences,
      menu = state.menu,
      refresh = M.buildUI
    })
    if shouldRebuild ~= false then
      scheduleBuildUI(false)
    end
    return
  end

  state.helpContent = "Star action is reserved for standard functions."
  state.helpPageTitle = (state.i18n and state.i18n.t and state.i18n.t("app.help.title")) or "Help"
  scheduleBuildUI(true)
end

getActivePageModule = function()
  if not state.menu then return nil end
  local menuId = state.menu.getCurrentMenuId and state.menu.getCurrentMenuId()
  if not menuId then return nil end
  ensurePageRegistry()
  return PageRegistry and PageRegistry.byMenuId and PageRegistry.byMenuId[menuId]
end

-- Closes the dialog object only and leaves the help CONTENT in place: buildUI needs it for
-- the repaint it is performing. Every real dismissal uses closeHelpDialogIfOpen instead.
local function closeHelpDialogHandle()
  if state.helpDialog and type(state.helpDialog.close) == "function" then
    pcall(state.helpDialog.close, state.helpDialog)
  end
  state.helpDialog = nil
end

closeHelpDialogIfOpen = function()
  closeHelpDialogHandle()
  state.helpContent = nil
  state.helpPageTitle = nil
  state.helpPageSubtitle = nil
end

local function applyLocaleFromPreferences()
  -- No longer needed, active language is hardcoded at compile time.
end

local function getMspUnsupportedDialogModule()
  if mspUnsupportedDialogLoadTried then
    return mspUnsupportedDialogModule
  end
  mspUnsupportedDialogLoadTried = true
  mspUnsupportedDialogModule = loadModule("ui/msp_unsupported_dialog.lua")
  return mspUnsupportedDialogModule
end

local confirmDialogModule = nil
local confirmDialogLoadTried = false
local function getConfirmDialogModule()
  if confirmDialogLoadTried then
    return confirmDialogModule
  end
  confirmDialogLoadTried = true
  confirmDialogModule = loadModule("ui/confirm_dialog.lua")
  return confirmDialogModule
end

local function maybeShowUnsupportedMspDialog()
  if not state.i18n then
    return
  end

  local root = _G and _G.rfsuite
  local session = root and root.session
  local diagnostics = root and root.diagnostics
  if type(session) ~= "table" and type(diagnostics) ~= "table" then
    return
  end

  local function tr(key, fallback)
    local value = state.i18n.t and state.i18n.t(key) or nil
    if type(value) ~= "string" or value == "" or value == key then
      return fallback
    end
    return value
  end

  local apiSupported = nil
  if type(session) == "table" and session.apiSupported ~= nil then
    apiSupported = session.apiSupported
  elseif type(diagnostics) == "table" and diagnostics.apiSupported ~= nil then
    apiSupported = diagnostics.apiSupported
  end

  if apiSupported == true then
    return
  end

  if apiSupported ~= false then
    return
  end

  local apiVersion = nil
  if type(session) == "table" and session.apiVersion ~= nil then
    apiVersion = session.apiVersion
  elseif type(diagnostics) == "table" and diagnostics.apiVersion ~= nil then
    apiVersion = diagnostics.apiVersion
  end
  local version = tostring(apiVersion or "?")

  local supported = "-"
  ensureVersion()
  if Version and type(Version.getSupportedMspApiVersionsString) == "function" then
    supported = Version.getSupportedMspApiVersionsString() or "-"
  end

  local title = tr("app.msp.unsupported_title", "Unsupported MSP API")
  local prefix = tr("app.msp.unsupported_message_prefix", "MSP API version ")
  local suffix = tr("app.msp.unsupported_message_suffix", " is not supported.")
  local supportedLabel = tr("app.msp.supported_label", "Supported: ")
  local message = prefix .. version .. suffix .. "\n" .. supportedLabel .. tostring(supported)

  local dialog = getMspUnsupportedDialogModule()
  if dialog then
    local shown = dialog.show({
      title = title,
      message = message,
      version = version,
      onFallback = function(fallbackTitle, fallbackMessage)
        state.helpContent = fallbackMessage
        state.helpPageTitle = fallbackTitle
        state.helpPageSubtitle = nil
        scheduleBuildUI(false)
      end
    })
    if shown then
      return
    end
  end

  -- Ultimate fallback if dialog module failed to load.
  state.helpContent = message
  state.helpPageTitle = title
  state.helpPageSubtitle = nil
  scheduleBuildUI(false)
end

local function maybeShowMspLinkConfigDialog()
  if not state.i18n then
    return
  end

  local root = _G and _G.rfsuite
  local session = root and root.session
  local diagnostics = root and root.diagnostics
  if type(session) ~= "table" and type(diagnostics) ~= "table" then
    return
  end

  local function tr(key, fallback)
    local value = state.i18n.t and state.i18n.t(key) or nil
    if type(value) ~= "string" or value == "" or value == key then
      return fallback
    end
    return value
  end

  local errMsg = nil
  local errAt = 0
  if type(session) == "table" then
    errMsg = session.mspLastError or errMsg
    errAt = tonumber(session.mspLastErrorAt) or errAt
  end
  if (not errMsg or errMsg == "") and type(diagnostics) == "table" then
    errMsg = diagnostics.mspLastError or errMsg
    errAt = tonumber(diagnostics.mspLastErrorAt) or errAt
  end

  if type(errMsg) ~= "string" or errMsg == "" then
    state.mspLinkConfigWarningAt = 0
    return
  end

  if not string.find(errMsg, "cmd=1", 1, true) then
    return
  end

  if errAt > 0 and state.mspLinkConfigWarningAt == errAt then
    return
  end

  local title = tr("app.msp.link_config_title", "MSP link configuration")
  local l1 = tr("app.msp.link_config_message_1", "Initial MSP read failed (API_VERSION).")
  local l2 = tr("app.msp.link_config_message_2", "Please check Rotorflight telemetry settings.")
  local l3 = tr("app.msp.link_config_message_3", "Packet Rate and Packet Ratio must match the ELRS link.")
  local l4 = tr("app.msp.link_config_message_4", "Then reconnect and open Info again.")
  local message = l1 .. "\n" .. l2 .. "\n" .. l3 .. "\n" .. l4

  local dialog = getMspUnsupportedDialogModule()
  if dialog then
    local shown = dialog.show({
      title = title,
      message = message,
      onFallback = function(fallbackTitle, fallbackMessage)
        state.helpContent = fallbackMessage
        state.helpPageTitle = fallbackTitle
        state.helpPageSubtitle = nil
        scheduleBuildUI(false)
      end
    })
    if shown then
      state.mspLinkConfigWarningAt = errAt > 0 and errAt or (state.mspLinkConfigWarningAt + 1)
      return
    end
  end

  state.helpContent = message
  state.helpPageTitle = title
  state.helpPageSubtitle = nil
  state.mspLinkConfigWarningAt = errAt > 0 and errAt or (state.mspLinkConfigWarningAt + 1)
  scheduleBuildUI(false)
end

local function readFblConnected()
  local root = _G and _G.rfsuite
  local session = root and root.session
  if type(session) == "table" and session.isConnected ~= nil then
    return session.isConnected == true
  end

  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false
  end

  local mspState = MspRuntime.getState()
  if type(mspState) ~= "table" then
    return false
  end

  -- MSP-Version nicht unterstützt? Dann wie "nicht verbunden" behandeln
  if mspState.unsupportedApi == true then
    return false
  end
  if mspState.apiSupported == false then
    return false
  end
  if mspState.versionReadCompleted ~= true then
    return false
  end

  return mspState.lastConnected == true
end

local function returnToRootOnDisconnect()
  if not state.menu or state.menu.isRoot() then
    return
  end

  closeHelpDialogIfOpen()
  state.pendingMenuOpen = nil

  local stepped = false
  while state.menu and (not state.menu.isRoot()) do
    if state.menu.goBack and state.menu.goBack() then
      stepped = true
    else
      break
    end
  end

  if stepped then
    state.focusIndex = 0
    scheduleBuildUI(false)
  end
end

local function updateRuntimeMenuConditions()
  if not state.menu then return end

  local root = _G and _G.rfsuite
  local session = root and root.session

  local wasConnected = state.fblConnected == true
  local nextFblConnected = readFblConnected()
  if state.fblConnected ~= nextFblConnected then
    state.fblConnected = nextFblConnected
    state.menu.setCondition("fblConnected", nextFblConnected)
    if not nextFblConnected then
      if session then
        session.esc4WayDetectedProto = nil
      end
      if wasConnected then
        if Audio and type(Audio.resetConnectionState) == "function" then
          Audio.resetConnectionState(state.audioState)
        end
        returnToRootOnDisconnect()
      end
    end
    scheduleBuildUI(false)
  end

  local currentMenuId = state.menu.getCurrentMenuId()
  if currentMenuId ~= "esc_tools_menu" then
    state.escProtoCheckPending = false
  end

  if currentMenuId == "esc_tools_menu" and session and session.esc4WayDetectedProto == nil and not state.escProtoCheckPending then
    local SensorConfigApi = loadModule("tasks/msp/api/esc_sensor_config.lua")
    local msp = root and root.tasks and root.tasks.msp
    local queue = msp and msp.getState and msp.getState().queue
    if queue and SensorConfigApi then
      queue:add({
        command = SensorConfigApi.command,
        isWrite = false,
        simulatorResponse = { 1, 0, 200, 0, 0, 15, 0, 0, 0, 30, 0, 0, 0, 0 },
        processReply = function(self, buf)
          state.escProtoCheckPending = false
          local parsed = SensorConfigApi.parse(buf)
          if parsed and parsed.protocol then
            local proto = tonumber(parsed.protocol) or 0
            session.esc4WayDetectedProto = proto
          end
        end,
        errorHandler = function()
          state.escProtoCheckPending = false
        end
      })
      -- The three assignments above are all resets. Without this one the guard on the `if`
      -- is never false, so the probe is queued again on every pass through this function.
      state.escProtoCheckPending = true
    else
      state.escProtoCheckPending = false
    end
  end

  local initialVersion = state.menu._conditionsVersion
  local proto = session and session.esc4WayDetectedProto
  local protocols = {1, 3, 4, 6, 7, 9, 10, 12}
  for _, p in ipairs(protocols) do
    local isEnabled = false
    if proto ~= nil then
      isEnabled = (proto == p)
    end
    state.menu.setCondition("escProto" .. p, isEnabled)
  end
  if state.menu._conditionsVersion ~= initialVersion then
    scheduleBuildUI(false)
  end
end

local function maybeRefreshInfoPageFromSession()
  if not state.menu or state.menu.getCurrentMenuId() ~= "diagnostics_info_page" then
    state.infoSessionSnapshot = nil
    return
  end

  local root = _G and _G.rfsuite
  local session = root and root.session
  local diagnostics = root and root.diagnostics
  if type(session) ~= "table" then
    return
  end

  local snapshot = tostring(session.apiVersion or "") .. "|" .. tostring(session.fcVersion or "") .. "|" .. tostring(session.rfVersion or "") ..
    "|" .. tostring(session.mcu_id or "") ..
    "|" .. tostring(session.mspLastError or "") .. "|" .. tostring(session.mspLastErrorAt or "") ..
    "|" .. tostring(diagnostics and diagnostics.mspLastError or "") .. "|" .. tostring(diagnostics and diagnostics.mspLastErrorAt or "")
  if state.infoSessionSnapshot ~= snapshot then
    state.infoSessionSnapshot = snapshot
    scheduleBuildUI(false)
  end
end

local function isLocalSettingsPage()
  local page = getActivePageModule()
  if type(page) == "table" and (page.savesLocally == true or page.isLocal == true) then
    return true
  end
  if state.menu and type(state.menu.getCurrentMenuId) == "function" then
    local menuId = state.menu.getCurrentMenuId()
    if type(menuId) == "string" and string.sub(menuId, 1, 9) == "settings_" then
      return true
    end
  end
  return false
end

-- Drop everything the MSP layer is still holding from an earlier read.
--
-- The response cache answers a re-read from the last reply while its key still holds, and its
-- keys are the connection and the live profile. Two events move the value on the board without
-- moving either key, so they are named here rather than left to the key to catch:
--
--   a Reload   the pilot asked for what the board holds NOW, and was told that unsaved changes
--              would be discarded to get it. A reload that serves the value it already had is
--              not a reload, whatever it saves in round trips.
--   a disarm   an in-flight adjustment changes gains, rates and governor values on the flight
--              controller with nothing written from here, and this tool is not on screen while
--              it happens. So the first read after a flight has to reach the board.
--
-- Everything else the cache holds is dropped by the two rules it already has: a disconnect,
-- and any write this tool issues.
local function dropMspResponseCache()
  local ok, cache = pcall(loadModule, "tasks/msp/cache.lua")
  if ok and type(cache) == "table" and type(cache.clear) == "function" then
    pcall(cache.clear)
  end
end

-- The backstop behind the disabled Save and Reload buttons: a path that reaches either of
-- them while the craft is armed is refused, and says so. Drawn as the tool's own notice box
-- rather than raised as an `lvgl.message`, which is a native MessageDialog with no focusable
-- child of its own -- its key path exists only while its LVGL group is empty, and while one
-- stands this script's run() is not reached at all.
local function showArmedNotice()
  state.armedNoticeVisible = true
  scheduleBuildUI(false)
end

-- A page that has no pipeline still saves behind the notice, so its outcome belongs in the
-- notice as well. Raising a dialog for it puts a second box on top of a first one that cannot
-- be repainted away, because the report is made from inside the save the notice is announcing --
-- and while a native modal stands the tool's run() does not run at all.
local function reportSaveOutcome(outcome)
  if type(outcome) ~= "table" then return end
  local title = outcome.title
  local message = outcome.message
  if type(title) ~= "string" and type(message) ~= "string" then return end
  state.saveOutcome = { title = title, message = message }
  -- A save that worked has nothing to be acknowledged, so its notice gets a moment to be read
  -- and then goes; anything else stands until it is read away. The page decides which it is,
  -- because only the page knows whether the write it just made reached anything.
  if outcome.ok == true then
    state.saveOutcome.clearAt = (getTime and getTime() or 0) + SAVE_OUTCOME_LINGER_TICKS
  end
  state.saveOverlayVisible = true
  scheduleBuildUI(false)
end

local function onReload()
  if isModelArmed() and not isLocalSettingsPage() then
    showArmedNotice()
    return
  end

  local page = getActivePageModule()

  if page and page.onReload then
    local actions = nil
    if type(page.getHeaderActions) == "function" then
      actions = page.getHeaderActions()
    end
    if type(actions) == "table" and actions.reload == false then
      return
    end
    closeHelpDialogIfOpen()

    local function doPageReload()
      -- Before the page re-reads, not after: every route into a reload ends here, and the
      -- page issues its requests inside onReload below.
      dropMspResponseCache()
      -- Keep preferences in-memory for reload to avoid repeated disk loads and table churn.
      _G.rfsuite.preferences = state.preferences
      local shouldRebuild = page.onReload({
        i18n = state.i18n,
        preferences = state.preferences,
        menu = state.menu,
        refresh = M.buildUI
      })
      if shouldRebuild == false then
        -- Even with deferred page-managed reloads, render once so loading state
        -- (progress/overlay) is visible immediately after pressing Reload.
        scheduleBuildUI(false)
      else
        scheduleBuildUI(true)
      end
    end

    local reloadPref = state.preferences and state.preferences.general and state.preferences.general.reload_confirm
    if reloadPref == true and lvgl then
      local function tr(key, fallback)
        if state and state.i18n and type(state.i18n.t) == "function" then
          local ok, val = pcall(state.i18n.t, key)
          if ok and type(val) == "string" and val ~= "" and val ~= key then
            return val
          end
        end
        return fallback
      end

      local title = tr("app.pages.settings_general.reload_confirm", "Confirm on Reload")
      local message = tr("app.dialogs.confirm_reload", "Reload and discard unsaved changes?")

      pcall(Log.emit, "rfsuite", "onReload invoked; reloadPref=true", "debug", true)
      if lvgl then
        pcall(Log.emit, "rfsuite", "lvgl types: confirm=" .. tostring(type(lvgl.confirm)) .. ", dialog=" .. tostring(type(lvgl.dialog)) .. ", alert=" .. tostring(type(lvgl.message)), "debug", true)
      else
        pcall(Log.emit, "rfsuite", "lvgl is nil", "debug", true)
      end

      local confirmModule = getConfirmDialogModule()
      if confirmModule and type(confirmModule.show) == "function" then
        local ok, res = pcall(confirmModule.show, {
          title = title,
          message = message,
          onConfirm = doPageReload,
          onCancel = function() end,
          onFallback = doPageReload
        })
        if ok and res == true then return end
      end

      -- Fallback: no confirm UI available — proceed with reload.
      pcall(Log.emit, "rfsuite", "no confirm API available; performing reload fallback", "debug", true)
      doPageReload()
      return
    end

    -- Preference disabled: just reload immediately.
    doPageReload()
    return
  end

  reportSaveOutcome({
    ok = false,
    title = "Reload",
    message = "Reload from FBL is not wired yet."
  })
end

local function onSave()
  local armedWarningPref = state.preferences and state.preferences.general and state.preferences.general.save_armed_warning
  if isModelArmed() and not isLocalSettingsPage() then
    if armedWarningPref ~= false then
      showArmedNotice()
    end
    return
  end

  local page = getActivePageModule()
  if page and page.onSave then
    closeHelpDialogIfOpen()

    -- Runs save in the next tick so the save overlay can render first.
    local function queuePageSave()
      state.saveOutcome = nil
      state.pendingSaveAction = function()
        local ok, shouldRebuild = pcall(page.onSave, {
          i18n = state.i18n,
          preferences = state.preferences,
          menu = state.menu,
          savePreferences = performSave,
          refresh = M.buildUI,
          requestRebuild = requestRebuild,
          reportSave = reportSaveOutcome
        })

        if not ok then
          pcall(Log.emit, "rfsuite", "page.onSave failed: " .. tostring(shouldRebuild), "error", true)
          reportSaveOutcome({
            ok = false,
            title = SAVE_TEXT.failed_title,
            message = tostring(shouldRebuild)
          })
          scheduleBuildUI(false)
          return
        end

        -- Apply possibly updated language setting immediately after save.
        applyLocaleFromPreferences()

        local okEeprom, errEeprom = queueEepromWriteIfNeeded(page)
        if not okEeprom then
          pcall(Log.emit, "rfsuite", "EEPROM write queue failed: " .. tostring(errEeprom), "warn", true)
          reportSaveOutcome({
            ok = false,
            title = SAVE_TEXT.saved_title,
            message = SAVE_TEXT.eeprom_pending .. " " .. tostring(errEeprom)
          })
        end

        if shouldRebuild ~= false then
          scheduleBuildUI(false)
        end
      end
      state.saveOverlayVisible = true
      scheduleBuildUI(false)
    end

    -- Check preference and show confirm dialog if enabled.
    local savePref = state.preferences and state.preferences.general and state.preferences.general.save_confirm
    -- The confirmation is a preference, except when the armed state cannot be read: then it is
    -- asked whatever the preference says, because the alternative is writing to a flight
    -- controller that may be armed without anybody having been told the check did not run.
    local armedUnknown = armedStateIsUncertain()
    if (savePref == true or armedUnknown) and lvgl then
      local function tr(key, fallback)
        if state and state.i18n and type(state.i18n.t) == "function" then
          local ok, val = pcall(state.i18n.t, key)
          if ok and type(val) == "string" and val ~= "" and val ~= key then
            return val
          end
        end
        return fallback
      end

      local title = tr("app.pages.settings_general.save_confirm", "Confirm on Save")
      local message = tr("app.dialogs.confirm_save", "Save changes?")
      if armedUnknown then
        message = tr("app.dialogs.confirm_save_arm_unknown", "Cannot read the arming state. Disarmed?")
      end

      pcall(Log.emit, "rfsuite", "onSave invoked; savePref=true", "debug", true)
      if lvgl then
        pcall(Log.emit, "rfsuite", "lvgl types: confirm=" .. tostring(type(lvgl.confirm)) .. ", dialog=" .. tostring(type(lvgl.dialog)) .. ", alert=" .. tostring(type(lvgl.message)), "debug", true)
      else
        pcall(Log.emit, "rfsuite", "lvgl is nil", "debug", true)
      end

      local confirmModule = getConfirmDialogModule()
      if confirmModule and type(confirmModule.show) == "function" then
        local ok, res = pcall(confirmModule.show, {
          title = title,
          message = message,
          onConfirm = queuePageSave,
          onCancel = function() end,
          onFallback = queuePageSave
        })
        if ok and res == true then return end
      end

      -- Fallback: no confirm API available — proceed with save.
      pcall(Log.emit, "rfsuite", "no confirm API available; performing save fallback", "debug", true)
      queuePageSave()
      return
    end

    -- Preference disabled: just save immediately.
    queuePageSave()
    return
  end

  reportSaveOutcome({
    ok = false,
    title = "Save",
    message = "Save to FBL is not wired yet."
  })
end

local function getCardPressHandler(cardId)
  if state.cardHandlers[cardId] then return state.cardHandlers[cardId] end
  local fn = function()
    if (state.suppressPressFrames or 0) > 0 then
      return
    end
    if state.menu and (not state.menu.isRoot()) then
      logf("debug", "press card=%s from=%s", tostring(cardId),
        tostring(state.menu.getCurrentMenuId and state.menu.getCurrentMenuId()))
      -- Parking the target is the whole press: run() opens pendingMenuOpen and schedules the
      -- rebuild itself, so nothing is scheduled here and the next thing drawn is the target's
      -- own first frame -- a menu, or a page with the loading overlay the page paints while it
      -- reads. A frame in front of that one is a second scene rebuild whose only content is a
      -- notice the frame after it replaces.
      state.pendingMenuOpen = cardId
    end
  end
  state.cardHandlers[cardId] = fn
  return fn
end

local function getRootCardPressHandler(sectionId, cardId)
  local key = sectionId .. ":" .. cardId
  if state.cardHandlers[key] then return state.cardHandlers[key] end
  local fn = function()
    if (state.suppressPressFrames or 0) > 0 then
      return
    end
    if state.menu and state.menu.isRoot() then
      logf("debug", "press root section=%s card=%s", tostring(sectionId), tostring(cardId))
      state.pendingMenuOpen = { section = sectionId, card = cardId }
    end
  end
  state.cardHandlers[key] = fn
  return fn
end

-- A strip across the top of the page body, drawn on root, on a menu and on a page for as long
-- as the craft is armed. The content below it is moved down by exactly this height rather than
-- being drawn under it: a warning that covers a value is worse than no warning at all.
--
-- The colours are the firmware's own full-screen alert idiom -- WARNING as the background with
-- the message in PRIMARY1 (libui/fullscreen_dialog.cpp). The pairing this replaces was the
-- other way round, WARNING text on PRIMARY3, which computes about 2.2:1 off the default theme
-- table and is below every legibility floor there is.
local function appendArmedBanner(children, x, y, w, h, text)
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y, w = w, h = h,
    color = COLOR_THEME_WARNING or COLOR_THEME_SECONDARY1,
    filled = true
  }

  local radius = math.max(6, math.floor(h * 0.30))
  local pad = math.max(4, math.floor(h * 0.20))
  local cx = x + pad + radius
  local cy = y + math.floor(h / 2)
  Tiles.appendBadge(children, cx, cy, radius, ARMED_BADGE_TEXT)

  local textX = cx + radius + pad
  local textH = Tiles.lineHeight(SMLSIZE, 14)
  children[#children + 1] = {
    type  = "label",
    x = textX,
    y = y + math.floor((h - textH) / 2),
    w = math.max(0, (x + w) - textX - pad),
    text  = text,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }
end

-- ── Main UI build ─────────────────────────────────────────────────────────────

function M.buildUI()
  if lvgl == nil then return end

  ensureBuildDeps()

  -- Before the build, not after it. A build that allocates more than the LVGL pool can give it
  -- does not come back, so a line written afterwards is the one line that would never appear --
  -- and it is the one naming the screen that could not be built.
  local buildingMenuId = state.menu and state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
  logStep("build menu=" .. tostring(buildingMenuId))

  local isArmed = isModelArmed()

  if state.initialLoad then
    -- The run loop already counts this start: it reads done/total off the onconnect runner and
    -- repaints whenever that number changes. The frame it repainted carried none of it, so every
    -- one of those repaints produced a screen identical to the one before it. Draw what is being
    -- counted -- on the start's own full-screen background, in the shape this file already uses
    -- for a full-screen notice: a centred title over a centred message. The offsets are wider
    -- than the armed screen's because a third element follows them and MIDSIZE at h/2 - 30 puts
    -- the title's descenders on the message's ascenders. The page overlays' box is not reused
    -- here: that is a box drawn OVER a page, and there is no page yet.
    if lvgl and type(lvgl.clear) == "function" then lvgl.clear() end
    local title = state.i18n and state.i18n.t and state.i18n.t("app.loading") or "Loading..."

    -- Two things are counted while this screen stands, and only one of them can own the bar.
    -- The compile pass runs first, happens only after an install or a version change, and is by
    -- far the longer of the two, so it takes the bar for as long as it lasts and names itself in
    -- the message line. It used to ride along as a bare "47/312" behind the title, which counts
    -- files that mean nothing to whoever is holding the radio and leaves the message reading
    -- "Connecting" while nothing is being connected -- the pair of them reads as a stall rather
    -- than as work.
    local compileDone = state.precompileDone or 0
    local compileTotal = state.precompileTotal or 0
    local preparing = compileTotal > 0 and compileDone < compileTotal

    local message
    if preparing then
      message = state.i18n and state.i18n.t and state.i18n.t("app.preparing") or "Preparing suite"
    else
      message = ONCONNECT_TEXT[state.startTaskName or ""] or
                (state.i18n and state.i18n.t and state.i18n.t("app.connecting")) or
                "Connecting"
    end
    local screenW = LCD_W or 320
    local screenH = LCD_H or 240

    -- The logo, in the same box the widget's own connection splash gives it
    -- (widgets/dashboard/splash.lua): the arithmetic below is that file's, applied to the
    -- full screen instead of a widget zone. Reusing it rather than choosing new numbers
    -- keeps the tool's start and the widget's splash the same picture, and the caps are
    -- what stop a 400x84 image from filling a large screen.
    local logoW = math.max(112, math.min(math.floor(screenW * 0.80), 240))
    local logoH = math.max(36, math.min(math.floor(screenH * 0.32), 68))
    local logoX = math.floor((screenW - logoW) * 0.5)
    local logoY = math.max(6, math.floor(screenH * 0.10))

    local children = {
      {
        type = "rectangle",
        x = 0, y = 0, w = screenW, h = screenH,
        color = COLOR_THEME_PRIMARY3,
        filled = true
      },
      {
        type = "image",
        x = logoX, y = logoY, w = logoW, h = logoH,
        file = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/gfx/logo.png"
      },
      {
        type = "label",
        x = 0, y = screenH / 2 - 44, w = screenW,
        text = title,
        color = COLOR_THEME_PRIMARY2,
        align = CENTER,
        font = MIDSIZE
      },
      {
        type = "label",
        x = 20, y = screenH / 2 - 4, w = screenW - 40,
        text = message,
        color = COLOR_THEME_PRIMARY2,
        align = CENTER,
        font = SMLSIZE
      }
    }

    -- The bar is drawn only once there is something to count. Before the onconnect runner has
    -- loaded its manifest there is no denominator, and an empty trough would claim a measurement
    -- that has not started. The track is the theme's inactive colour rather than its accent, so
    -- that an empty bar cannot be mistaken for a full one -- the failure the page overlay's own
    -- track had until this series.
    --
    -- The compile pass fills the same bar while it is the phase being shown. Its denominator
    -- grows for as long as the tree is still being walked, but nothing is compiled before the
    -- walk is through, so the numerator is zero throughout it and the fill never runs backwards.
    local done = preparing and compileDone or (state.startDone or 0)
    local total = preparing and compileTotal or (state.startTotal or 0)
    if total > 0 then
      local barW = math.min(420, math.max(200, screenW - 120))
      local barH = 12
      local barX = math.floor((screenW - barW) / 2)
      local barY = math.floor(screenH / 2) + 26
      local fillW = math.floor((barW - 4) * math.min(1, done / total) + 0.5)

      children[#children + 1] = {
        type = "rectangle",
        x = barX, y = barY, w = barW, h = barH,
        color = COLOR_THEME_DISABLED,
        filled = true
      }
      if fillW > 0 then
        children[#children + 1] = {
          type = "rectangle",
          x = barX + 2, y = barY + 2, w = fillW, h = barH - 4,
          color = COLOR_THEME_SECONDARY2,
          filled = true
        }
      end
    end

    lvgl.build(children)
    return
  end

  local saveProgress = SavePipeline and type(SavePipeline.getProgress) == "function"
    and SavePipeline.getProgress() or nil

  if state.pendingSaveAction or saveProgress or state.saveOutcome then
    local title = state.i18n and state.i18n.t and state.i18n.t("app.saving") or "Saving..."
    local message = state.i18n and state.i18n.t and state.i18n.t("app.saving_settings") or "Applying settings"
    local progress = 0.35
    local action = nil

    -- Until the save reaches the flight controller the notice says only that something is being
    -- applied, which is all a queued chain can honestly say. A pipeline reports which step it is
    -- on, and stays on screen for the phases the old notice never covered: the restart, the wait
    -- for the board to answer and the read-back.
    if saveProgress then
      local phaseKey = SAVE_PHASE_TEXT[saveProgress.phase]
      message = saveProgress.label or (phaseKey and SAVE_TEXT[phaseKey]) or message
      progress = saveProgress.indeterminate and 1 or (saveProgress.fraction or 0)
      if saveProgress.saved then
        title = SAVE_TEXT.saved_title
      end
      -- A finished save reports itself HERE, in the box that has been reporting all along. A
      -- native dialog for it would be drawn over this one from inside the reply handler, so
      -- this box could not be repainted away first -- and while such a dialog stands the tool's
      -- run() does not run at all.
      if saveProgress.terminal then
        local result = saveProgress.result or {}
        if saveProgress.status == "timeout" and result.saved then
          title = SAVE_TEXT.timeout_title
          message = SAVE_TEXT.timeout_message
        elseif saveProgress.status ~= "done" then
          title = SAVE_TEXT.failed_title
          message = SAVE_TEXT.failed_message
        else
          title = SAVE_TEXT.saved_title
          message = SAVE_TEXT.done_message
        end
      end
      if saveProgress.dismissible then
        action = {
          text = SAVE_TEXT.dismiss,
          press = function()
            SavePipeline.dismiss()
            scheduleBuildUI(false)
          end
        }
      end
    end

    -- A page with no pipeline is finished the moment its onSave returns, so there is no bar
    -- left to fill: the notice carries the result and the way out of it instead.
    if state.saveOutcome and not saveProgress then
      title = state.saveOutcome.title or title
      message = state.saveOutcome.message or message
      progress = 1
      action = {
        text = SAVE_TEXT.dismiss,
        press = function()
          state.saveOutcome = nil
          state.saveOverlayVisible = false
          scheduleBuildUI(false)
        end
      }
    end

    if lvgl and type(lvgl.clear) == "function" then lvgl.clear() end
    local lyt = {
      {
        type = "rectangle",
        x = 0, y = 0, w = LCD_W or 320, h = LCD_H or 240,
        color = COLOR_THEME_PRIMARY3,
        filled = true
      }
    }
    LoadingOverlay.append(lyt, {
      x = 0,
      y = 0,
      w = LCD_W or 320,
      h = LCD_H or 240,
      title = title,
      message = message,
      progress = progress,
      action = action
    })
    lvgl.build(lyt)
    state.saveOverlayVisible = true
    return
  end

  if state.armedNoticeVisible then
    if lvgl and type(lvgl.clear) == "function" then lvgl.clear() end
    local lyt = {
      {
        type = "rectangle",
        x = 0, y = 0, w = LCD_W or 320, h = LCD_H or 240,
        color = COLOR_THEME_PRIMARY3,
        filled = true
      }
    }
    LoadingOverlay.appendNotice(lyt, {
      x = 0,
      y = 0,
      w = LCD_W or 320,
      h = LCD_H or 240,
      title = ARMED_NOTICE_TITLE,
      message = ARMED_NOTICE_MESSAGE,
      press = function()
        state.armedNoticeVisible = false
        scheduleBuildUI(false)
      end
    })
    lvgl.build(lyt)
    return
  end

  syncActivePageModule()

  local profile = DisplayProfile.current()
  local contentPad = profile.contentPad
  local labelIndent = profile.labelIndent
  local tileGap = profile.tileGap
  local groupTitleH = profile.groupTitleH
  local groupDivH = profile.groupDivH
  local groupGapAfter = profile.groupGapAfter
  local groupHeaderH = groupTitleH + groupDivH + groupGapAfter

  local breadcrumb = ""
  if not state.menu.isRoot() then
    breadcrumb = state.menu.getHeaderBreadcrumb()
    if breadcrumb == "" then breadcrumb = state.menu.getBreadcrumb() end
  end

  local pageTitle = state.menu.isRoot() and "Rotorflight" or state.menu.getHeaderTitle()
  local currentMenuId = state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or "root"
  if currentMenuId ~= "root" and not PageRegistry then
    ensurePageRegistry()
  end
  local actions = Header.resolveActions({
    headerActions = state.headerActions,
    menu          = state.menu,
    i18n          = state.i18n,
    preferences   = state.preferences,
    PageRegistry  = PageRegistry,
    HelpRegistry  = HelpRegistry
  })

  -- Both actions end at the MSP queue, which the runtime clears on every tick while armed, so
  -- neither could do anything but fail. Rendered disabled rather than merely inert: ui/header.lua
  -- reports that through `active`, which also takes the button out of the encoder focus group.
  if isArmed then
    actions.save = false
    actions.reload = false
  end

  -- Clear and reuse the children table to reduce garbage collection
  local children = state.children
  wipeTable(children)

  local contentX = contentPad
  -- The strip sits flush under the page header and the content starts one gap below it, so
  -- everything the view already laid out is moved down by exactly the strip's own height.
  local bannerH = isArmed and (profile.armedBannerH or 24) or 0
  local contentY = tileGap + bannerH
  local contentW = LCD_W - contentPad * 2

  -- ── Help view (no lvgl.dialog – avoids LVGL lifecycle crashes) ───────────────
  if state.helpContent then
    local helpMessage = state.helpContent
    local helpTitle = state.helpPageTitle or pageTitle
    local helpSubtitle = state.helpPageSubtitle
    ensureHelpView()
    closeHelpDialogHandle()
    if HelpView and type(HelpView.open) == "function" then
      local opened = HelpView.open({
        i18n = state.i18n,
        contentX = contentX,
        contentY = contentY,
        contentW = contentW,
        lcdH = LCD_H,
        message = helpMessage,
        title = helpTitle,
        subtitle = helpSubtitle,
        icon = APP_ICON,
        onBack = onBack,
        requestRebuild = requestRebuild,
        header = Header,
        headerLayout = profile.header,
        state = state
      })
      if opened == true then
        return
      end
    end

    local helpLyt = HelpView.build({
      i18n = state.i18n,
      contentX = contentX,
      contentY = contentY,
      contentW = contentW,
      lcdH = LCD_H,
      message = helpMessage,
      title = helpTitle,
      subtitle = helpSubtitle,
      icon = APP_ICON,
      onBack = onBack,
      requestRebuild = requestRebuild,
      header = Header,
      headerLayout = profile.header,
      state = state
    })
    if lvgl and type(lvgl.clear) == "function" then
      lvgl.clear()
    end
    lvgl.build(helpLyt)
    return
  end
  -- ── End help view ────────────────────────────────────────────────────────────

  if bannerH > 0 then
    appendArmedBanner(children, contentX, 0, contentW, bannerH, ARMED_BANNER_TEXT)
  end

  if state.menu.isRoot() then
    local groups    = state.menu.getRootGroups()
    local flatCards = Tiles.flattenRootCards(groups)
    -- Never alias cached root card tables into state.cards because submenu grid
    -- layout reuses state.cards as mutable output and would overwrite root data.
    wipeTable(state.cards)
    state.focusIndex = math.max(0, math.min(state.focusIndex, #flatCards))

    local cursorY   = contentY
    local flatIndex = 0

    for i = 1, #groups do
      local group   = groups[i]
      local computedCols = Tiles.computeColumns(contentW, profile.rootMinCardWidth, profile.rootMaxColumns)
      local columns = computedCols
      local layoutItems, rows = toWrappedItems(group.cards, columns)
      local rowHeight = profile.rootRowHeight
      local gridH = rows * rowHeight + math.max(0, rows - 1) * tileGap

      -- Section heading label (indented from left edge)
      children[#children + 1] = {
        type  = "label",
        x = contentX + labelIndent, y = cursorY,
        text  = group.title,
        color = COLOR_THEME_PRIMARY1,
        font  = SMLSIZE
      }
      -- Divider line
      children[#children + 1] = {
        type   = "rectangle",
        x = contentX, y = cursorY + groupTitleH,
        w = contentW, h = groupDivH,
        color  = COLOR_THEME_SECONDARY1,
        filled = true
      }
      cursorY = cursorY + groupHeaderH

      local groupCards = GridLayout.layout(
        { x = contentX, y = cursorY, w = contentW, h = gridH },
        { rows = rows, cols = columns, gap = tileGap, padding = 0, items = layoutItems },
        {}
      )

      local groupBottom = cursorY
      for j = 1, #groupCards do
        local card     = groupCards[j]
        flatIndex      = flatIndex + 1
        local tileSize = computeTileSize(card.w, card.h, profile)
        local tileX    = card.x + math.floor((card.w - tileSize) / 2)
        local tileY    = card.y + math.floor((card.h - tileSize) / 2)

        Tiles.append(
          children, tileX, tileY, tileSize,
          card.data.icon, card.data.text,
          flatIndex == state.focusIndex,
          getRootCardPressHandler(group.id, card.id),
          card.data.enabled,
          card.data.lockedByArm and ARMED_BADGE_TEXT or nil
        )

        local bottom = tileY + tileSize
        if bottom > groupBottom then groupBottom = bottom end
      end

      cursorY = groupBottom + profile.groupGapBottom
    end

  else
    currentMenuId = state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
    ensurePageRegistry()
    local pageModule = PageRegistry and PageRegistry.byMenuId and PageRegistry.byMenuId[currentMenuId] or nil
    if pageModule and pageModule.build then
      wipeTable(state.cards)
      state.focusIndex = 0
      pageModule.build({
        children = children,
        x = contentX,
        y = contentY,
        w = contentW,
        h = pageBodyHeight() - bannerH,
        i18n = state.i18n,
        preferences = state.preferences,
        menu = state.menu,
        manifest = state.manifest,
        openHelp = function(message, title, subtitle)
          local resolvedTitle = title or pageTitle
          local resolvedSubtitle = subtitle
          if resolvedSubtitle == nil and breadcrumb ~= "" then
            resolvedSubtitle = shortenBreadcrumb(breadcrumb)
          end
          openPageHelpDialog(message, resolvedTitle, resolvedSubtitle)
        end,
        requestRebuild = requestRebuild
      })
    else
      local gridItems = state.menu.getCards()
      local computedCols = Tiles.computeColumns(contentW, profile.menuMinCardWidth, profile.menuMaxColumns)
      local columns   = computedCols
      local layoutItems, rows = toWrappedItems(gridItems, columns)
      local rowHeight = profile.tileMax
      local gridH = rows * rowHeight + math.max(0, rows - 1) * tileGap
      local cards     = GridLayout.layout(
        { x = contentX, y = contentY, w = contentW, h = gridH },
        { rows = rows, cols = columns, gap = tileGap, padding = 2, items = layoutItems },
        state.cards
      )
      state.cards = cards
      state.focusIndex = math.max(0, math.min(state.focusIndex, #cards))

      for i = 1, #cards do
        local card     = cards[i]
        local tileSize = computeTileSize(card.w, card.h, profile)
        local tileX    = card.x + math.floor((card.w - tileSize) / 2)
        local tileY    = card.y + math.floor((card.h - tileSize) / 2)

        Tiles.append(
          children, tileX, tileY, tileSize,
          card.data.icon, card.data.text,
          i == state.focusIndex,
          getCardPressHandler(card.id),
          card.data.enabled,
          card.data.lockedByArm and ARMED_BADGE_TEXT or nil
        )
      end
    end
  end

  -- Build layout: page + children table, then "?" button as sibling (same as Save in page.lua)
  local rootSubtitle = nil
  if breadcrumb ~= "" then
    rootSubtitle = shortenBreadcrumb(breadcrumb)
  elseif state.menu.isRoot() then
    ensureVersion()
    if Version and type(Version.getVersionString) == "function" then
      rootSubtitle = Version.getVersionString()
    end
  end

  local lyt = {
    {
      type     = "page",
      title    = pageTitle,
      subtitle = rootSubtitle,
      icon     = APP_ICON,
      back     = onBack,
      children = children
    }
  }

  Header.appendToLayout(lyt, {
    actions  = actions,
    i18n     = state.i18n,
    preferences = state.preferences,
    layout   = profile.header,
    onHelp   = onHelp,
    onStar   = onStar,
    onReload = onReload,
    onSave   = onSave,
    onBack   = onBack
  })

  if lvgl and type(lvgl.clear) == "function" then
    lvgl.clear()
  end
  lvgl.build(lyt)
end

-- ── Init / Run ────────────────────────────────────────────────────────────────

function M.init()
  ensureInitDeps()

  ensurePreferencesSafe()
  state.shouldExit = false
  local prefs = loadPreferencesSafe()
  state.preferences = prefs
  _G.rfsuite.preferences = prefs

  -- The earliest point at which anything can be written, because the option lives in the file
  -- that was just read. Everything before this line -- the module loads and the preference read
  -- itself -- is invisible by construction and no option could change that.
  --
  -- What it does reach back over is the log ring: attaching seeds the sink from it, so the lines
  -- emitted while the modules above were loading go out with the first flush. A start that hangs
  -- after this point leaves the step file naming the stage it stopped in.
  logStep("init: preferences read", true)

  local locale = resolveLocaleFromSystem()
  state.i18n       = I18n.new(locale)
  logStep("init: locale " .. tostring(locale), true)
  _G.rfsuite.savePreferences = performSave
  state.manifest = manifest
  logStep("init: menu registry", true)
  state.menu       = MenuRegistry.new(manifest, state.i18n, {
    conditions = {
      developerTools = prefs.general and prefs.general.developer_tools == true,
      fblConnected = false,
      -- Declared here rather than left to the first run() tick, so that the build M.init()
      -- does below already asks the registry a question it can answer. run() owns the value
      -- from its first pass on.
      modelArmed = false
    },
    apiVersionProvider = function()
      local root = _G and _G.rfsuite
      local session = root and root.session
      return session and session.apiVersion or nil
    end,
    iconByMenuIdProvider = function()
      ensurePageRegistry()
      return PageRegistry and PageRegistry.iconByMenuId or nil
    end
  })
  state.memBucket  = nil
  state.memLastTick = 0
  state.memPeakKb = 0
  state.lastInputTick = getTime and getTime() or 0
  state.initialLoadStartTick = getTime and getTime() or 0
  state.ignoreNextPageKey = false
  state.suppressPressFrames = 0
  state.suppressBackFrames = 0
  state.backGestureActive = false
  state.lastBackTick = 0
  state.focusIndex = 0
  state.activePageMenuId = nil
  state.helpContent = nil
  state.helpPageTitle = nil
  state.helpPageSubtitle = nil
  state.pendingBuildUI = false
  state.pendingGcAfterBuild = false
  state.pendingSaveAction = nil
  state.saveOutcome = nil
  state.saveOverlayVisible = false
  state.armedNoticeVisible = false
  state.pendingMenuOpen = nil
  state.isClosing = false
  state.closeTicks = nil
  state.closeMemStart = nil
  state.mspLastTick = 0
  state.fblConnected = false
  state.infoSessionSnapshot = nil
  state.mspUnsupportedDialogShown = false
  state.mspUnsupportedVersionShown = nil
  state.mspLinkConfigWarningAt = 0
  state.mspAttached = false
  state.initialLoad = true
  state.lastProgressSnapshot = ""
  state.precompileDone = 0
  state.precompileTotal = 0
  ensureVersion()
  ensurePrecompile()
  if Precompile then
    Precompile.start(Version and Version.VERSION or nil)
  end
  logStep("init: first build", true)
  M.buildUI()
  logStep("init: done", true)
end

-- Hoisted out of `M.run`. EdgeTX drives `run()` from the standalone window's event
-- check, so anything declared inside it is built again on every refresh. None of the
-- three captures anything from that call and none of them changes while the script
-- runs, so file scope is where they belong.
local function isEvent(ev, ...)
  for i = 1, select("#", ...) do
    local c = select(i, ...)
    if c and ev == c then return true end
  end
  return false
end

-- Read once instead of per call. The globals a radio exports do not change while the
-- script runs, and a nil entry is skipped by the type tests below exactly as before.
local BACK_KEY_CANDIDATES = {
  _G.KEY_EXIT,
  _G.KEY_RTN,
  _G.KEY_RETURN,
  _G.KEY_ESC
}

local BACK_EVENT_GENERATORS = {
  _G.EVT_KEY_BREAK,
  _G.EVT_KEY_FIRST,
  _G.EVT_KEY_LONG
}

local function isGeneratedBackEvent(ev)
  if type(ev) ~= "number" or ev == 0 then
    return false
  end

  -- Observed on some radios/pages: RTN can arrive as raw generated event 1537.
  if ev == 1537 then
    return true
  end

  local keyCandidates = BACK_KEY_CANDIDATES
  local generators = BACK_EVENT_GENERATORS

  for gi = 1, #generators do
    local gen = generators[gi]
    if type(gen) == "function" then
      for ki = 1, #keyCandidates do
        local key = keyCandidates[ki]
        if type(key) == "number" then
          local ok, generated = pcall(gen, key)
          if ok and generated == ev then
            return true
          end
        end
      end
    end
  end

  return false
end

local function isBackEvent(ev)
  if isEvent(
    ev,
    EVT_VIRTUAL_EXIT,
    EVT_VIRTUAL_EXIT_BREAK,
    EVT_VIRTUAL_EXIT_FIRST,
    EVT_VIRTUAL_EXIT_LONG,
    EVT_EXIT_BREAK,
    EVT_EXIT_FIRST,
    EVT_EXIT_LONG,
    EVT_RTN_BREAK,
    EVT_RTN_FIRST,
    EVT_RTN_LONG
  ) then
    return true
  end

  return isGeneratedBackEvent(ev)
end

function M.run(event, touchState)
  if lvgl == nil then
    lcd.drawText(10, 10, "LVGL support required (EdgeTX 2.11+)", WHITE)
  end

  if state.menu then
    local now = getTime and getTime() or 0
    local transitionedMenuThisTick = false

    local armed = isModelArmed()

    -- The card sink advances here and nowhere else in this state: it is the one place per pass
    -- that runs whatever is on screen. It decides for itself whether anything is written, and
    -- the armed state only lengthens its interval.
    local cardSink = sink()
    if cardSink and type(cardSink.tick) == "function" then
      pcall(cardSink.tick, armed)
    end

    if armed ~= state.lastModelArmedState then
      state.lastModelArmedState = armed
      -- The registry is the one place that already knows why an entry is or is not
      -- available, and it invalidates its own card caches when a condition moves. Feeding
      -- the armed state in here costs no new update path: the scheduleBuildUI below is the
      -- redraw this transition already asked for.
      state.menu.setCondition("modelArmed", armed)
      if not armed then
        -- The refusal has outlived its reason; it must not stand over the tool after a disarm.
        state.armedNoticeVisible = false
        -- And no cached reply has outlived the flight that just ended: an in-flight
        -- adjustment can have moved any of them, and this is the edge the cache's own keys
        -- cannot see. It costs no new update path -- the transition is already handled here.
        dropMspResponseCache()
      end
      if armed then
        -- Clear MSP queue to abort any pending MSP operations immediately
        ensureMspRuntime()
        if MspRuntime and type(MspRuntime.getState) == "function" then
          local mspState = MspRuntime.getState()
          if mspState and mspState.queue and type(mspState.queue.clear) == "function" then
            pcall(mspState.queue.clear, mspState.queue)
          end
        end
      end
      scheduleBuildUI(false)
    end

    if armed then
      state.lastInputTick = now
    end

    if not state.mspAttached then
      ensureMspRuntime()
      if MspRuntime and type(MspRuntime.attach) == "function" then
        MspRuntime.attach("tool")
        state.mspAttached = true
      end
    end

    if (state.suppressPressFrames or 0) > 0 then
      state.suppressPressFrames = state.suppressPressFrames - 1
    end
    if (state.suppressBackFrames or 0) > 0 then
      state.suppressBackFrames = state.suppressBackFrames - 1
    end

    if getTime and event and event ~= 0 then
      state.lastInputTick = getTime()
    end

    -- Keep a single focus model: LVGL handles PAGE/PAGE- and ENTER natively.
    -- We only handle EXIT/back here.
    local backEvent = isBackEvent(event)

    if not backEvent then
      state.backGestureActive = false
    end

    if backEvent and (state.suppressBackFrames or 0) <= 0 then
      onBack("event", event)
    end

    if state.isClosing then
      if not state.closeTicks then
        logToFile("Closing sequence started (Tick 0).")
        logStep("closing tick 0", true)
        state.closeTicks = 0
        -- Tick 0: ONLY build the UI overlay. Do NOT do any cleanup or GC yet.
        -- This ensures the Lua VM yields immediately and EdgeTX can draw the screen.
        if lvgl and lvgl.clear then
          lvgl.clear()
          local tr = state.i18n and state.i18n.t and state.i18n.t("app.closing_rfsuite") or "Closing RFSuite..."
          lvgl.build({
            {
              type = "rectangle",
              x = 0, y = 0, w = LCD_W or 320, h = LCD_H or 240,
              color = COLOR_THEME_PRIMARY3,
              filled = true
            },
            {
              type = "label",
              x = 0, y = (LCD_H or 240) / 2 - 10, w = LCD_W or 320,
              text = tr,
              color = COLOR_THEME_PRIMARY2,
              align = CENTER,
              font = MIDSIZE
            }
          })
        end
        return 0 -- Yield to OS immediately
      end
      
      if state.closeTicks == 0 then
        -- Tick 1: Do page releases and event resets (this queues any override resets)
        logToFile("Closing sequence Tick 1. Starting cleanup.")
        logStep("closing tick 1: cleanup", true)
        state.pendingBuildUI = false
        state.pendingGcAfterBuild = false
        state.pendingSaveAction = nil
        state.saveOutcome = nil
        state.saveOverlayVisible = false
        state.pendingMenuOpen = nil
        closeHelpDialogIfOpen()
        
        -- Same as on a page change, and for the same reason: the page on screen loses its reads
        -- before it is released, so none of them can come back to a torn-down tree. Its writes
        -- stay -- the shutdown ticks below are there to get exactly those out.
        if state.activePageMenuId ~= nil and MspRuntime and type(MspRuntime.dropClientReads) == "function" then
          pcall(MspRuntime.dropClientReads, mspClientForMenu(state.activePageMenuId))
        end

        -- Release all pages in the registry to free their resources (queues override/rollback resets)
        if PageRegistry and type(PageRegistry.releaseAll) == "function" then
          logToFile("Releasing all pages in registry.")
          pcall(PageRegistry.releaseAll, buildPageContext())
        elseif state.activePageMenuId and PageRegistry and type(PageRegistry.release) == "function" then
          logToFile("Releasing active page: " .. tostring(state.activePageMenuId))
          pcall(PageRegistry.release, state.activePageMenuId, buildPageContext())
        end
        state.activePageMenuId = nil
        if MspRuntime and type(MspRuntime.setDefaultClient) == "function" then
          pcall(MspRuntime.setDefaultClient, TOOL_MSP_CLIENT)
        end
        
        if Events and type(Events.reset) == "function" then
          logToFile("Resetting events.")
          pcall(Events.reset)
        end
      end

      -- Run MSP ticks to process the queued packets during shutdown (ticks 1 to 15)
      if state.closeTicks <= 15 then
        if MspRuntime and type(MspRuntime.tick) == "function" then
          pcall(MspRuntime.tick)
        end
      elseif not state.shouldExit then
        -- Tick 16: Finalize library cleanup and detach MSP
        logToFile("Closing sequence finalizing. Detaching MSP.")
        logStep("closing: detaching MSP", true)
        if state.mspAttached then
          if MspRuntime and type(MspRuntime.detach) == "function" then
            pcall(MspRuntime.detach, "tool")
          end
          state.mspAttached = false
        end
        
        -- Clear chunk cache to allow all compiled functions to be garbage collected
        if _G.rfsuite and _G.rfsuite.utils and type(_G.rfsuite.utils.clearChunkCache) == "function" then
          logToFile("Clearing compiled chunk cache.")
          pcall(_G.rfsuite.utils.clearChunkCache)
        end
        
        -- Release references to libraries to allow them to be GC'd
        GridLayout = nil
        I18n = nil
        DisplayProfile = nil
        manifest = nil
        MenuRegistry = nil
        PageRegistry = nil
        HelpRegistryFactory = nil
        HelpRegistry = nil
        Tiles = nil
        Header = nil
        HelpView = nil
        PreferencesSafe = nil
        Version = nil
        MspRuntime = nil
        EepromWriteApi = nil
        Log = nil
        Events = nil
        Audio = nil
        Sensors = nil
        
        -- Clear the global table so everything becomes unreachable
        _G.rfsuite = nil
        
        -- Clear local state fields to break references to heavy tables
        state.i18n = nil
        state.menu = nil
        state.preferences = nil
        state.children = nil
        state.cards = nil
        state.telemetryState = nil
        state.audioState = nil
        state.cardHandlers = nil

        state.shouldExit = true
      end

      state.closeTicks = state.closeTicks + 1
      
      -- Skip all other background tasks and exit immediately
      if state.shouldExit then
        logToFile("Closing sequence returning 2 to EdgeTX.")
        logStep("closing: returning to the radio", true)
        if state.mspAttached and MspRuntime and type(MspRuntime.detach) == "function" then
          pcall(MspRuntime.detach, "tool")
          state.mspAttached = false
        end
        return 2
      end
      return 0
    end

    if state.pendingBuildUI and not state.isClosing then
      state.pendingBuildUI = false
      local doGc = state.pendingGcAfterBuild == true
      state.pendingGcAfterBuild = false
      M.buildUI()
      if doGc and collectgarbage then
        collectgarbage("collect")
      end
    end

    if state.pendingSaveAction and state.saveOverlayVisible and not state.isClosing then
      local action = state.pendingSaveAction
      state.pendingSaveAction = nil
      state.saveOverlayVisible = false
      local ok, err = pcall(action)
      if not ok then
        pcall(Log.emit, "rfsuite", "pendingSaveAction failed: " .. tostring(err), "error", true)
      end
      -- A page that only queues its writes is finished here and the notice goes; a page that
      -- started the pipeline is not, and the notice stays up for the phases that follow.
      if SavePipeline and type(SavePipeline.isActive) == "function" and SavePipeline.isActive() then
        state.saveOverlayVisible = true
      end
      -- A page that reported an outcome is finished, but the notice is not: it is now the box
      -- carrying the result, and it stands until the pilot reads it away.
      if state.saveOutcome then
        state.saveOverlayVisible = true
      end
      -- Ensure the save overlay is replaced even when page.onSave returns false.
      scheduleBuildUI(false)
    end

    -- A reported save that carried a linger has it counted here rather than by the page, which
    -- is gone by the time it runs out.
    if state.saveOutcome and state.saveOutcome.clearAt and not state.isClosing
      and (getTime and getTime() or 0) >= state.saveOutcome.clearAt then
      state.saveOutcome = nil
      state.saveOverlayVisible = false
      scheduleBuildUI(false)
    end

    -- The pipeline's reply-driven steps advance themselves; this drives the phases that wait on
    -- time -- the bound on a flight controller that does not come back, and the bound on the
    -- connect chain. Repaint on what is DISPLAYED rather than on every tick, the same rule the
    -- start screen follows, or an unchanged notice would be rebuilt at tick rate.
    if SavePipeline and type(SavePipeline.wakeup) == "function" and not state.isClosing then
      SavePipeline.wakeup()
      local saveProgress = SavePipeline.getProgress()
      local snapshot = saveProgress and (tostring(saveProgress.phase) .. "/"
        .. tostring(saveProgress.done) .. "/" .. tostring(saveProgress.label) .. "/"
        .. tostring(saveProgress.dismissible)) or nil
      if snapshot ~= state.lastSaveSnapshot then
        state.lastSaveSnapshot = snapshot
        state.saveOverlayVisible = snapshot ~= nil
        scheduleBuildUI(false)
      end
    end

    if state.pendingMenuOpen and not state.isClosing then
      -- The press parks a target and this is where it is taken, a tick later. A press with no
      -- open after it is the shape of a menu step that stalls, and the two lines apart are what
      -- tell that apart from a press that never registered.
      if type(state.pendingMenuOpen) == "table" then
        logf("debug", "open root section=%s card=%s", tostring(state.pendingMenuOpen.section),
          tostring(state.pendingMenuOpen.card))
        state.menu.openRootEntry(state.pendingMenuOpen.section, state.pendingMenuOpen.card)
      else
        logf("debug", "open entry=%s", tostring(state.pendingMenuOpen))
        state.menu.openEntry(state.pendingMenuOpen)
      end
      state.focusIndex = 0
      state.pendingMenuOpen = nil
      transitionedMenuThisTick = true
      scheduleBuildUI(true)
    end

    local currentMenuId = state.menu and state.menu.getCurrentMenuId and state.menu.getCurrentMenuId() or nil
    local mspSpeedPageActive = currentMenuId == "developer_msp_speed_page"

    if state.initialLoad then
      ensureMspRuntime()
      ensureEvents()
      local mspProgress = MspRuntime and MspRuntime.getProgress() or { done = 0, total = 0 }
      local onconnectProgress = Events and Events.getOnconnectProgress() or nil

      local pDone = 0
      local pTotal = 0
      if onconnectProgress and onconnectProgress.total > 0 then
        pDone = onconnectProgress.done or 0
        pTotal = onconnectProgress.total or 0
      elseif mspProgress then
        pDone = mspProgress.done or 0
        pTotal = mspProgress.total or 0
      end

      local taskName = Events and Events.getOnconnectPendingTaskName and
                       Events.getOnconnectPendingTaskName() or nil

      state.startDone = pDone
      state.startTotal = pTotal
      state.startTaskName = taskName

      local compileDone, compileTotal, compileFinished = 0, 0, true
      if Precompile then
        Precompile.step()
        compileDone, compileTotal, compileFinished = Precompile.getProgress()
      end
      state.precompileDone = compileDone
      state.precompileTotal = compileTotal

      -- Repaint when what is DISPLAYED changes, which is the count, the task name and the
      -- compile count -- not the count alone, or the frame naming a task would go stale
      -- within its own step.
      local snapshot = tostring(pDone) .. "/" .. tostring(pTotal) .. "/" .. tostring(taskName) ..
                       " " .. tostring(compileDone) .. "/" .. tostring(compileTotal)
      if snapshot ~= state.lastProgressSnapshot then
        state.lastProgressSnapshot = snapshot
        scheduleBuildUI(false)
      end

      -- Finish initial load when core MSP identity is resolved or timeout is reached.
      -- If the FBL is offline, we enter the menu after a short timeout (2s).
      -- If connected but the FC is unresponsive or wedged, we bound the wait (3.5s)
      -- so the pilot reaches the main menu with locked tiles rather than hanging on the start screen indefinitely.
      local mspState = nil
      if MspRuntime and type(MspRuntime.getState) == "function" then
        mspState = MspRuntime.getState()
      end
      local isConnected = mspState and mspState.lastConnected == true
      local elapsed = now - (state.initialLoadStartTick or now)
      local timeoutReached = (not isConnected and elapsed > 200) or (elapsed > 350)

      local mspSettled = (isConnected and mspProgress and mspProgress.done >= mspProgress.total)
                         or timeoutReached

      -- Hold the start screen until the compiling is through, which is the point of doing it
      -- here rather than on the first page that happens to need a file.
      if mspSettled and compileFinished then
        state.initialLoad = false
        scheduleBuildUI(false)
      end
    end

    if (not transitionedMenuThisTick) and (not mspSpeedPageActive) and MspRuntime and type(MspRuntime.tick) == "function" then
      if now == 0 or (now - (state.mspLastTick or 0)) >= 5 then
        state.mspLastTick = now
        MspRuntime.tick()
        -- Let events process (telemetry, arm state transitions, etc.)
        ensureEvents()
        if Events and type(Events.wakeup) == "function" then
          pcall(Events.wakeup)
        end
        -- The wakeup above is what fills the queue while the connect chain runs. Without a
        -- second turn here every request it enqueues waits for the next tick of this block
        -- before it is looked at.
        if type(MspRuntime.pump) == "function" then
          MspRuntime.pump()
        end
      end
    end

    if not armed then
      if not transitionedMenuThisTick then
        local activePage = getActivePageModule()
        local wakeupFn = activePage and (activePage.wakeup or activePage.onWake)
        if type(wakeupFn) == "function" then
          local ok, err = pcall(wakeupFn, {
            i18n = state.i18n,
            preferences = state.preferences,
            menu = state.menu,
            manifest = state.manifest,
            requestRebuild = requestRebuild
          })
          if not ok then
            pcall(Log.emit, "rfsuite", "Crash in activePage.wakeup: " .. tostring(err), "error", true)
            if type(serialWrite) == "function" then
              pcall(serialWrite, "[rfsuite][error] Crash in activePage.wakeup: " .. tostring(err) .. "\n")
            end
          end
        end
      end
    end

    logMemoryUsage(now)

    updateRuntimeMenuConditions()
    maybeRefreshInfoPageFromSession()

    -- Audio Feedback Polling (gedrosselt auf ca. 5Hz)
    if Audio and type(Audio.process) == "function" and (now - state.lastAudioTick) >= 20 then
      state.lastAudioTick = now
      
      local lq = Sensors and Sensors.getValue("link") or 0
      local vbat = Sensors and Sensors.getValue("voltage") or 0
      local fuel = Sensors and (Sensors.getValue("smartfuel") or Sensors.getValue("fuel")) or -1

      if type(fuel) == "number" and fuel >= 0 then
        if fuel > 100 then fuel = 100 end
      end

      if Sensors then
        state.telemetryState.profile = Sensors.getValue("pid_profile") or state.telemetryState.profile
        state.telemetryState.rateProfile = Sensors.getValue("rate_profile") or state.telemetryState.rateProfile
        state.telemetryState.batteryProfile = Sensors.getValue("battery_profile") or state.telemetryState.batteryProfile
        state.telemetryState.bec_voltage = Sensors.getValue("bec_voltage") or state.telemetryState.bec_voltage
        state.telemetryState.armFlags = Sensors.getValue("armflags") or state.telemetryState.armFlags
        state.telemetryState.governor = Sensors.getValue("governor") or state.telemetryState.governor
        state.telemetryState.escTemp = Sensors.getValue("temp_esc") or state.telemetryState.escTemp
      end

      state.telemetryState.voltage = vbat > 0 and vbat or state.telemetryState.voltage
      state.telemetryState.fuel = fuel >= 0 and fuel or state.telemetryState.fuel

      local batteryReady = (vbat > 0) or (fuel >= 0)
      local rfReady = (lq ~= 0)
      local connected = readFblConnected()

      if connected and batteryReady and rfReady then
        local modelName = nil
        if _G.rfsuite and _G.rfsuite.session then
          modelName = _G.rfsuite.session.modelName
        end
        local audioContext = {
          audioState = state.audioState,
          preferences = state.preferences,
          state = state.telemetryState,
          modelName = modelName
        }
        Audio.process(audioContext, { log = function(msg, level) if Log then pcall(Log.emit, "rfsuite.audio", msg, level, false) end end })
      else
        if Audio and type(Audio.resetConnectionState) == "function" then
          Audio.resetConnectionState(state.audioState)
        else
          state.audioState.initialized = false
          state.audioState.modelAnnounced = false
        end
        state.telemetryState.profile = nil
        state.telemetryState.rateProfile = nil
        state.telemetryState.batteryProfile = nil
        state.telemetryState.voltage = nil
        state.telemetryState.fuel = nil
      end
    end

    if not transitionedMenuThisTick then
      maybeShowUnsupportedMspDialog()
      maybeShowMspLinkConfigDialog()
    end

    -- Intentionally no periodic MEM-triggered rebuild here.
    -- Rebuilding while navigating resets LVGL focus on some pages.
    -- MEM value updates on normal UI rebuild points (navigation/actions).
  end

  if state.shouldExit then
    if state.mspAttached and MspRuntime and type(MspRuntime.detach) == "function" then
      MspRuntime.detach("tool")
      state.mspAttached = false
    end
    -- An orderly exit is the one case where the tail is not lost, so take it.
    local exitSink = sink()
    if exitSink and type(exitSink.shutdown) == "function" then
      pcall(exitSink.shutdown)
    end
    return 2
  end
  return 0
end

-- `requestRebuild` is the same schedule-and-repaint-later mechanism this file uses
-- internally, exposed so an embedding host can ask for a repaint after it has cleared the
-- LVGL tree itself. A host that clears the tree without it leaves the page blank, because
-- nothing in `run` notices that the objects it built are gone. The rebuild still happens at
-- the same point in `run` as every other one, so it cannot land in the middle of a build.
return { init = M.init, run = M.run, useLvgl = true, requestRebuild = scheduleBuildUI }
