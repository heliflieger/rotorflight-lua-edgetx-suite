if type(_G) == "table" and type(_G.__rfsuite_system_locale_module) == "table" then
  return _G.__rfsuite_system_locale_module
end

local M = {}

local function trace(message)
  -- Silenced to reduce log spam in production
  -- if type(print) == "function" then
  --   print("[system_locale] " .. tostring(message))
  -- end
end

local function normalizeLanguage(value)
  local text = string.lower(tostring(value or ""))
  if text == "de" then return "de" end
  if text == "en" then return "en" end
  return nil
end

local PREF_PATH = "/SCRIPTS/TOOLS/rfsuite.user/preferences.lua"

-- The store is read through lib/config_store.lua with a schema naming the one key this needs,
-- rather than through lib/preferences.lua: this runs very early in the boot sequence, before
-- the rest of the suite is up, and it has no business pulling in the whole settings module or
-- its root probing to answer one question.
--
-- Built once and kept, because resolveSystemLanguage below is reached from the dashboard's
-- reactive closures -- a theme's t() resolves the locale on every call -- and a module load
-- with a table construction after it would then happen once per frame.
local cachedStore = nil

-- And the answer itself is kept beside it, for the same reason and one step further up: a
-- theme's t() resolves the locale on EVERY call, so without this the radio reads a file per
-- frame whatever that read costs. The window is short because it is also what a language
-- changed in the configuration tool waits before the dashboard speaks it, and two seconds is
-- well inside the reload that settings change triggers anyway.
--
-- getTime() counts hundredths of a second since the radio came up. Where it is not there at all
-- nothing is cached, which is the old behaviour rather than a stale answer.
local LANGUAGE_CACHE_TICKS = 200
local cachedLanguage = nil
local cachedLanguageFor = nil
local cachedLanguageAt = nil

local function nowTicks()
  if type(getTime) ~= "function" then return nil end
  local ok, v = pcall(getTime)
  if ok and type(v) == "number" then return v end
  return nil
end

local function languageStore()
  if cachedStore then return cachedStore end
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/config_store.lua", "t")
  if type(chunk) ~= "function" then return nil end
  local okMod, ConfigStore = pcall(chunk)
  if not okMod or type(ConfigStore) ~= "table" then return nil end
  cachedStore = ConfigStore.new({
    name = "preferences",
    schema = { localizations = { optional = { "language" } } },
  })
  return cachedStore
end

-- What this reader asks of the store, and both flags keep work off a path a theme's t() reaches.
--
-- `recover = false`: an interrupted save is the settings module's to finish, not this reader's.
-- This is called from a widget's reactive sweep, where renaming a file has no business being.
--
-- `legacy = false`: the store alone, so that a card which has not been brought across yet does
-- not pay the former file's parse on every read. That file is read once instead, below.
local STORE_OPTS = { recover = false, legacy = false }
local LEGACY_OPTS = { recover = false }

-- Read the preferred language out of the radio-wide store. Answers the language and whether the
-- store was there at all, which is what decides whether the former file is consulted below.
local function readLanguageFromStore()
  local store = languageStore()
  if not store then return nil, false end
  local ok, prefs, info = pcall(store.load, store, PREF_PATH, STORE_OPTS)
  if not ok or type(prefs) ~= "table" then return nil, false end

  local loc = prefs.localizations
  local norm = normalizeLanguage(loc and loc.language)
  if norm then
    trace("language from prefs: " .. norm)
    return norm, true
  end
  return nil, (type(info) == "table" and info.found) or false
end

-- The former format, for a card whose store has not been brought across yet: without this the
-- language would flip back to the radio's for the one boot before the migration runs. It goes
-- through the same store, which is the only thing in the suite that still reads that format.
--
-- READ AT MOST ONCE PER LUA STATE, which is what makes it affordable here. Nothing in the suite
-- writes the former file -- the migration only ever renames it away -- so its answer cannot
-- change while this state runs, and parsing it is by a wide margin the most expensive thing on
-- a path that a theme's t() reaches. A miss is remembered for the same reason.
local legacyRead = false
local legacyLanguage = nil

local function readLanguageFromLegacy()
  if legacyRead then return legacyLanguage end
  legacyRead = true

  local store = languageStore()
  if not store then return nil end
  local ok, prefs = pcall(store.load, store, PREF_PATH, LEGACY_OPTS)
  if not ok or type(prefs) ~= "table" then return nil end

  local loc = prefs.localizations
  legacyLanguage = normalizeLanguage(loc and loc.language)
  if legacyLanguage then trace("language from prefs: " .. legacyLanguage) end
  return legacyLanguage
end

local function readLanguageFromPrefs()
  local fromStore, storeFound = readLanguageFromStore()
  if fromStore then return fromStore end
  -- A store that is there and carries no language means "auto", so there is nothing the former
  -- file could add. Only a card whose store has not been brought across yet reaches it.
  if storeFound then return nil end
  return readLanguageFromLegacy()
end

-- Resolve the EdgeTX system language via getGeneralSettings().language.
-- EdgeTX 2.12 exposes this as an uppercase two-letter code (e.g. "DE", "EN")
-- on ALL_LANGS builds, or as the build's fixed translation otherwise.
-- _G.LANGUAGE does not exist in EdgeTX 2.12; getGeneralSettings() is the
-- correct public API (api_general.cpp:1761-1775).
local function readLanguageFromRadio()
  if type(getGeneralSettings) == "function" then
    local ok, gs = pcall(getGeneralSettings)
    if ok and type(gs) == "table" then
      local lang = normalizeLanguage(gs.language)
      if lang then
        trace("language from radio: " .. lang)
        return lang
      end
    end
  end
  return nil
end

-- Build-time baked token (only present in packaged release builds).
-- We reconstruct it so the packager's text-replace cannot touch the comparison.
-- On a packaged build the constant is replaced by the target locale ("de",
-- "en", …) and isBaked becomes true; in the source / simulator it stays
-- "@i18n_language@" and isBaked is false.
local BAKED = "@i18n_language@"
local isBaked = (BAKED ~= "@i18n_" .. "language@")

-- Resolve the locale to use at runtime.
-- Priority on packaged builds:  explicit user pref → baked package locale
-- Priority on source/simulator: explicit user pref → radio language → caller default
--
-- An explicit user preference (set via Settings › Localization) always wins
-- so that operators can override a German package when running on an English
-- radio, or vice-versa.  When no explicit preference exists, packaged builds
-- fall back to the baked locale; simulator / source builds query the radio.
local function resolveUncached(defaultLang)
  -- 1. Explicit user preference stored in the radio-wide settings file.
  local fromPrefs = readLanguageFromPrefs()
  if fromPrefs then return fromPrefs end

  -- 2a. Packaged build: use the baked locale (already validated by the packager).
  if isBaked then
    return normalizeLanguage(BAKED) or "en"
  end

  -- 2b. Source / simulator: query the radio's own language setting.
  local fromRadio = readLanguageFromRadio()
  if fromRadio then return fromRadio end

  -- 3. Caller-supplied default (usually "en").
  return normalizeLanguage(defaultLang) or "en"
end

function M.resolveSystemLanguage(defaultLang)
  -- The caller's default is part of what the answer depends on -- it is step 3 above -- so a
  -- cached answer only stands for the caller that asked with the same one.
  local now = nowTicks()
  if now and cachedLanguage and cachedLanguageFor == defaultLang
      and (now - cachedLanguageAt) < LANGUAGE_CACHE_TICKS then
    return cachedLanguage
  end

  local lang = resolveUncached(defaultLang)

  if now then
    cachedLanguage = lang
    cachedLanguageFor = defaultLang
    cachedLanguageAt = now
  end
  return lang
end

function M.resolveAudioFolder(defaultFolder)
  local lang = M.resolveSystemLanguage(defaultFolder or "en")
  if lang ~= "de" and lang ~= "en" then
    return "en"
  end
  return lang
end

if type(_G) == "table" then
  _G.__rfsuite_system_locale_module = M
end

return M