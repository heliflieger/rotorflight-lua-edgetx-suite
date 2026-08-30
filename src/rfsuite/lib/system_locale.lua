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

-- Read the preferred language from RFSuite's preferences.ini.
-- Only the [localizations] section's `language` key is scanned so that this
-- function can be called very early in the boot sequence, before the full
-- preferences module is loaded.
--
-- io.read() on EdgeTX returns at most the requested byte count (it is a chunk
-- read, not a line read), so we accumulate chunks and then split on newlines
-- — the same idiom used by lib/preferences.lua:loadFileAsString().
local function readLanguageFromPrefs()
  local PREF_PATH = "/SCRIPTS/TOOLS/rfsuite.user/preferences.ini"
  local ok, f = pcall(io.open, PREF_PATH, "r")
  if not ok or not f then return nil end

  -- Accumulate the whole file first.
  local parts = {}
  while true do
    local ok2, chunk = pcall(io.read, f, 128)
    if not ok2 or chunk == nil or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  pcall(io.close, f)

  local content = table.concat(parts)
  if content == "" then return nil end

  -- Scan line by line for [localizations] > language = <value>.
  local inSection = false
  for line in string.gmatch(content, "[^\r\n]+") do
    local trimmed = string.match(line, "^%s*(.-)%s*$")
    if trimmed == "[localizations]" then
      inSection = true
    elseif string.sub(trimmed, 1, 1) == "[" then
      if inSection then break end -- left the section without finding the key
    elseif inSection then
      local k, v = string.match(trimmed, "^([%w_]+)%s*=%s*(.+)$")
      if k and string.lower(k) == "language" then
        local norm = normalizeLanguage(v)
        if norm then
          trace("language from prefs: " .. norm)
          return norm
        end
      end
    end
  end
  return nil
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
function M.resolveSystemLanguage(defaultLang)
  -- 1. Explicit user preference stored in preferences.ini.
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