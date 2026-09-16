local M = {}

local PREF_PATH        = "/SCRIPTS/TOOLS/rfsuite.user/preferences.lua"
-- Reload request file monitored by the dashboard widget via fstat size.
-- Uses a rotating byte counter (1..32 bytes) so changes are reliably detected
-- where fstat is available even without an RTC or when the INI byte-size doesn't change,
-- without ever consuming or deleting the file (which breaks multi-reader and drops armed events).
local RELOAD_REQ_PATH  = "/SCRIPTS/TOOLS/rfsuite.user/reload.req"

local cachedModelPreferences = nil

local function logD(fmt, ...)
  local L = _G.rfsuite and _G.rfsuite.Log
  if L and type(L.emitf) == "function" then
    L.emitf("rfsuite.reload", "debug", fmt, ...)
  end
end

local function getModelPreferences()
  if cachedModelPreferences then
    return cachedModelPreferences
  end
  if _G.rfsuite and _G.rfsuite.require then
    cachedModelPreferences = _G.rfsuite.require("lib/model_preferences.lua")
    return cachedModelPreferences
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then
      cachedModelPreferences = mod
      return cachedModelPreferences
    end
  end
  return nil
end

local function bumpReloadCounter(userRoot)
  local MP = getModelPreferences()
  if MP and type(MP.bumpReloadCounter) == "function" then
    MP.bumpReloadCounter(userRoot)
    return
  end

  local targetPath = userRoot and (userRoot .. "/reload.req") or RELOAD_REQ_PATH
  local prevN = 0
  local n = 1
  if type(fstat) == "function" then
    local ok, info = pcall(fstat, targetPath)
    if ok and type(info) == "table" then
      prevN = (info.size or 0)
      n = (prevN % 32) + 1
    end
  end
  local f = io.open(targetPath, "w")
  if f then
    io.write(f, string.rep("x", n))
    io.close(f)
    logD("Preferences.bumpReloadCounter: wrote %d bytes (was %d) to %s", n, prevN, targetPath)
  else
    logD("Preferences.bumpReloadCounter: FAILED to open %s for write", targetPath)
  end
end

local function loadConfigStore()
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require("lib/config_store.lua")
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/config_store.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- The one place the radio-wide settings are declared: a section's `keys` carry the defaults
-- and are written on every save, `optional` names a key that exists in the file only once
-- something has set it, and an `open` section keeps the keys it is handed even though no
-- schema can name them. Anything a save is handed that is declared nowhere here is dropped,
-- which is how a key outliving the code that read it leaves the file again.
local SCHEMA = {
  general = {
    keys = {
      -- safety & prompts
      save_confirm                 = true,
      save_armed_warning           = true,
      reload_confirm               = true,
      -- preview features
      preview_setup_wizard         = false,
      preview_flight_log           = false,
      preview_inflight_tuning      = false,
      -- development
      developer_tools              = false,
      continuous_memory_log        = false,
      show_header_memory           = false,
      enable_serial_debug          = false,
      log_to_card                  = false,
      debug_level                  = "off",
    },
    -- Read by the connect tasks that copy the craft's name and parameters onto the radio, and
    -- written by Setup > Model. They carry no default because neither is a setting of the
    -- radio's: absence is the same as off, and seeding them would write a flag into every
    -- pilot's file for a feature most of them never turn on.
    optional = { "syncname", "syncparams" },
  },
  localizations = {
    keys = {
      temperature_unit = 0,
      altitude_unit    = 0,
    },
    -- `language` carries no default on purpose. Absence of the key means "auto":
    -- system_locale.lua then falls through to the baked package locale (release builds) or
    -- to getGeneralSettings() (source / simulator). It appears only once the pilot has made
    -- an explicit choice in Settings > Localization.
    optional = { "language" },
  },
  audio_events = {
    keys = {
      arming_flags = true,
      governor_state = true,
      voltage_alert = true,
      pack_not_full = false,
      pack_not_full_margin = 100,
      pid_profile = true,
      rate_profile = true,
      esc_temperature = false,
      esc_threshold = 90,
      mcu_temperature = false,
      mcu_threshold = 80,
      lq_alert = false,
      lq_warn = 70,
      lq_critical = 50,
      adjustment_events = false,
      fuel_alerts = true,
      battery_profile = true,
      model_announcement = false,
      initial_fuel = true,
    },
    -- The keys above are what a fresh install starts with. The full set the announcement pages
    -- offer is larger and partly built in a loop -- one enable per governor state -- and it is
    -- declared where it is offered, in app/pages/settings/audio/events/. This section therefore
    -- keeps what it is handed rather than holding a second copy of that list.
    open = true,
  },
  audio = {
    keys = {
      -- WAV volume level passed to playFile / playNumber. 0 = radio default (today's behaviour),
      -- 1..5 = every RFSuite callout at that explicit level.
      level                = 0,
      -- When set, `level` applies only while a model is connected, so bench work
      -- and menu interaction stays at the radio's own volume.
      level_connected_only = false,
      -- Global variable that carries the master level for layer B. 0 = off (the default);
      -- otherwise 1..9 (the GV slot on the radio). With a matching logical switch and
      -- special function on the model, this lets the suite override the pot while flying
      -- and release it on disconnect.
      master_gvar          = 0,
      -- The master level written to the GVAR while connected and no critical alert is active.
      master_normal        = 80,
      -- The master level written to the GVAR while a sustained critical alert is active
      -- (low voltage, ESC over-temperature, empty tank).
      master_alert         = 100,
    },
  },
  flightlog = {
    keys = {
      -- Off by default, and deliberately so: a suite that starts writing files to every pilot's
      -- card without being asked has made a decision that is the pilot's.
      enabled = false,
      -- An arm shorter than this is a check rather than a flight, and reaches neither the log
      -- nor a battery's cycle count. 0 logs every arm.
      min_seconds = 30,
    },
  },
  -- The radio's half of the in-flight tuning overlay: what is true of this transmitter whatever
  -- is plugged into it. The machine's half -- which parameters its flight controller offers,
  -- how far one press moves them, which PID profile is the undo -- is in the per-model store.
  -- Off by default, like every preview surface: see app/pages/settings/dashboard/inflight.
  inflight = {
    keys = {
      enabled = false,
    },
    -- Everything else the transmitter's half holds -- the interlock switch, the channel and
    -- global-variable pair, the pulse length and the trim assignment -- is declared and
    -- defaulted by widgets/dashboard/inflight/setup.lua, which states that the radio half is
    -- duplicated nowhere. Keeping the section open is what honours that.
    open = true,
  },
  dashboard = {
    keys = {
      theme_preflight = "system/default",
      -- Phase overrides on top of the theme above, read only while theme_per_phase is on.
      theme_inflight = "nil",
      theme_postflight = "nil",
      theme_per_phase = false,
    },
    -- A theme's own configuration is stored here under keys built from the theme's path
    -- (app/pages/settings/dashboard/lib.lua), so the set of key names is not knowable from
    -- a schema and the section keeps whatever it is handed.
    open = true,
    -- Two keys nothing in the suite has ever read. An open section would carry them for the
    -- life of the card otherwise, since no schema names them to begin with.
    retired = { "theme_config_target", "connection_guard" },
  },
  -- Written by nothing: the developer pages read it so that a value can be put there by hand.
  -- Declared so that such a value is not thrown away by the next save.
  developer = { open = true },
}

local ConfigStore = loadConfigStore()
local store = ConfigStore and ConfigStore.new({ name = "preferences", schema = SCHEMA })

-- What is answered when lib/config_store.lua could not be loaded at all -- a truncated install,
-- a card pulled mid-read. The empty table this used to answer with is the worst of both: every
-- caller that reaches rfsuite.preferences.general or .flightlog indexes nil and raises, at a
-- point that says nothing about why. The schema is right here, so a section per section of it
-- with its declared keys costs one walk and leaves every reader something to read.
local function schemaDefaults()
  local out = {}
  for name, spec in pairs(SCHEMA) do
    local section = {}
    local keys = spec.keys
    if keys then
      for k, v in pairs(keys) do section[k] = v end
    end
    out[name] = section
  end
  return out
end

-- Said at error level and not swallowed: the suite is running on its built-in answers, nothing
-- the pilot changes will be kept, and there is no other sign of it on the screen.
local function reportNoStore(what)
  local L = _G.rfsuite and _G.rfsuite.Log
  if L and type(L.emitf) == "function" then
    L.emitf("rfsuite.preferences", "error",
      "%s: lib/config_store.lua could not be loaded -- the built-in settings are used and nothing is saved",
      tostring(what))
  end
end

-- Puts the freshly read settings where the log looks for its level, and ONLY where nothing has
-- put a table there yet.
--
-- Every host of the suite assigns the answer of this function to rfsuite.preferences within a
-- line or two of asking for it, so on a first load this publishes the same table a moment early
-- and nothing observable changes. A state that already has one is left alone: a reload is the
-- caller's to adopt, and publishing it here would hand the widgets a new settings table before
-- the code that asked for it had decided to keep it.
local function publishIfUnclaimed(prefs)
  if type(_G) ~= "table" then return end
  local root = _G.rfsuite
  if type(root) ~= "table" then return end
  if root.preferences == nil then
    root.preferences = prefs
  end
end

-- The store's messages, written now that the level gate has something to read.
--
-- Log.emit rather than emitf: the text is already formatted, and a file name carrying a percent
-- sign would be read as a format directive by the second one.
local function emitDeferred(messages)
  if type(messages) ~= "table" then return end
  local L = _G.rfsuite and _G.rfsuite.Log
  if type(L) ~= "table" or type(L.emit) ~= "function" then return end
  for i = 1, #messages do
    pcall(L.emit, "rfsuite.config", messages[i].text, messages[i].level)
  end
end

function M.getPath(safeId)
  local mcuId = safeId
  if not mcuId and type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
    mcuId = _G.rfsuite.session.mcu_id
  end
  local MP = getModelPreferences()
  if MP and type(MP.preferencesPath) == "function" then
    return MP.preferencesPath(mcuId)
  end
  return PREF_PATH
end

-- The declared defaults, without touching the card. Callers that need them -- ui/preferences.lua
-- is one -- ask for them here rather than keeping a copy of their own.
function M.defaults()
  if not store then return schemaDefaults() end
  return store:defaults()
end

--- Reads the radio-wide settings. Answers the table and whether the file was there; the table
--- is usable either way, and a corrupt file gives the declared defaults and a logged error.
---
--- Every section the schema declares is present in the answer whatever happened, because the
--- callers read `preferences.general.<key>` without asking first and a missing section raises
--- where a wrong value would only misbehave.
function M.load()
  if not store then
    reportNoStore(PREF_PATH)
    return schemaDefaults(), false
  end
  local path = M.getPath()

  -- The store is told to hand its messages back rather than write them, because on the first
  -- load of a Lua state there is nothing yet that would print them. The log's level gate reads
  -- rfsuite.preferences.general.debug_level, and while that field is absent it answers "off"
  -- and refuses every line at every level -- and this very call is what fetches it. So the one
  -- report that matters most, the error saying a broken settings file was replaced by the
  -- declared defaults, was the one report that never appeared.
  local opts = { messages = {} }

  -- A card written by an earlier release carries the former format. Bringing it across is a
  -- one-off, and after it the probe below costs one failed open. It happens only in a Lua state
  -- that is yielded rather than cut off at an instruction count, so this call does nothing in a
  -- widget; there the load below reads the former file into memory instead and writes nothing.
  store:migrate(path, ConfigStore.legacyPath(path), opts)
  local prefs, info = store:load(path, opts)

  publishIfUnclaimed(prefs)
  emitDeferred(opts.messages)

  return prefs, info.found
end

-- The install carries no directory entries, so /SCRIPTS/TOOLS/rfsuite.user exists on a card
-- only because a file was unpacked into it, and io.open(path, "w") does not create a missing
-- parent. Without this, the first save on such a card fails and every setting the pilot
-- changed is lost with it.
--
-- mkdir() is a bare global of the firmware's filesystem library, not a member of os: there is
-- no os table in this Lua at all, so a guard on os.mkdir can never be true. The shape follows
-- app/pages/logs/graph.lua, which tests fstat() the same way. mkdir() creates one level at a
-- time, so the tools root goes first.
local function makeDir(path)
  if type(mkdir) ~= "function" then return end
  if type(path) ~= "string" or path == "" then return end
  pcall(mkdir, path)
end

local function ensureUserDir(targetPath)
  local userRoot = string.match(targetPath or M.getPath(), "^(.*)/[^/]+$")
  if not userRoot then return end
  local toolsRoot = string.gsub(userRoot, "/rfsuite%.user$", "")
  if toolsRoot ~= "" and toolsRoot ~= userRoot then
    makeDir(toolsRoot)
  end
  makeDir(userRoot)
end

--- Writes the radio-wide settings and tells the widgets that they changed. What is written is
--- the schema above, so a key nothing declares any more leaves the file here.
function M.save(prefs)
  if not store then
    reportNoStore(PREF_PATH)
    return false, "unavailable"
  end
  local path = M.getPath()
  ensureUserDir(path)

  local ok, err = store:save(path, prefs)
  if not ok then
    logD("Preferences.save: FAILED to write %s: %s", path, tostring(err))
    return false, err
  end

  -- Signal the dashboard widget that preferences have changed via rotating
  -- sequence length in reload.req. Multi-reader safe, armed-safe, and independent
  -- of RTC timestamp or file size equality.
  local userRoot = string.match(path, "^(.*)/[^/]+$")
  bumpReloadCounter(userRoot)
  logD("Preferences.save: saved to %s", path)

  return true
end

return M
