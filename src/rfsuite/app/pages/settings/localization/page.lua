local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Controls = nil
local Common = nil

-- ─── Config schema ────────────────────────────────────────────────────────────
-- All persisted localization settings. Loading and saving are automatic.
--   type "number" → tonumber() coercion, default must be a number
--   optional      → the key is written only when a value is chosen; the empty string is
--                    the selection that means "not set"

-- The selection that means "resolve automatically". It is the empty string rather than a
-- language, because what means auto is the *absence* of the key: preferences.lua declares
-- `language` optional on purpose, and system_locale.lua resolves an absent key from the baked
-- package locale or from the radio's own setting. A hard "en" default here both made the combo
-- read English on a build that resolves to German, and -- because onSave below wrote every
-- schema key -- wrote that English into preferences.lua on any save of this page, pinning the
-- locale for a change the pilot made to the temperature unit (#275).
local AUTO = ""

local CONFIG_SCHEMA = {
  { key = "language",         type = "string", default = AUTO, optional = true },
  { key = "temperature_unit", type = "number", default = 0     },
  { key = "altitude_unit",    type = "number", default = 0     },
}

local function buildDefaultConfig()
  local cfg = {}
  for _, field in ipairs(CONFIG_SCHEMA) do cfg[field.key] = field.default end
  return cfg
end

-- ─── State ────────────────────────────────────────────────────────────────────

local ui = {
  loaded    = false,
  dirty     = false,
  config    = buildDefaultConfig(),
}

ui.runtime = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local t = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_localization")
  end
end

local function copyFromPrefs(prefs)
  local loc = (prefs and prefs.localizations) or {}

  for _, field in ipairs(CONFIG_SCHEMA) do
    if field.type == "string" then
      local v = tostring(loc[field.key] or "")
      ui.config[field.key] = v ~= "" and v or field.default
    else
      ui.config[field.key] = tonumber(loc[field.key]) or field.default
    end
  end
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  copyFromPrefs(prefs)
  ui.loaded = true
end

local function getTempOptions(i18n)
  return {
    { value = 0, label = t(i18n, "temp_celsius", "Celsius") },
    { value = 1, label = t(i18n, "temp_fahrenheit", "Fahrenheit") },
  }
end

local function getAltOptions(i18n)
  return {
    { value = 0, label = t(i18n, "alt_meter", "Meter") },
    { value = 1, label = t(i18n, "alt_feet", "Feet") },
  }
end

local function getLangOptions(i18n)
  -- Automatic first, because it is what an untouched install is on and the combo has to be
  -- able to say so. The other two are the whole of what normalizeLanguage accepts, so this
  -- list is the entire range of an explicit choice.
  return {
    { value = AUTO, label = t(i18n, "language_auto", "Automatic") },
    { value = "en",  label = t(i18n, "language_en", "English") },
    { value = "de",  label = t(i18n, "language_de", "German")  },
  }
end

-- ─── Module API ──────────────────────────────────────────────────────────────

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end


function M.onReload(ctx)
  ensureDeps()
  copyFromPrefs(ctx.preferences)
  ui.dirty = false
end

function M.onSave(ctx)
  ensureDeps()
  if not ctx.preferences.localizations then ctx.preferences.localizations = {} end

  for _, field in ipairs(CONFIG_SCHEMA) do
    local value = ui.config[field.key]
    if field.optional then
      -- An optional key is written as soon as it is non-nil (lib/config_store.lua), so the
      -- automatic selection clears it again rather than storing an empty language. That is
      -- the only way back to the documented state, and it is what makes the combo a
      -- statement about the file rather than about a page default.
      ctx.preferences.localizations[field.key] =
        (value ~= nil and value ~= "") and value or nil
    else
      ctx.preferences.localizations[field.key] = value
    end
  end
  local ok, err = ctx.savePreferences()
  if ok then
    ui.dirty = false
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ ok = true, title = t(ctx.i18n, "saved_title", "Saved"), message = t(ctx.i18n, "saved_message", "Settings saved") })
    end
  else
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"), message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. tostring(err or "io") })
    end
  end
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)

  local children = ctx.children
  local x, w = ctx.x, ctx.w
  local i18n = ctx.i18n
  local cursorY = ctx.y

  ui.runtime.setRequestRebuild(ctx.requestRebuild)

  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    t(i18n, "language", "Language"),
    getLangOptions(i18n),
    ui.config.language,
    ui.runtime.getValueSetter("language")
  )

  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    t(i18n, "temperature_unit", "Temperature Unit"),
    getTempOptions(i18n),
    ui.config.temperature_unit,
    ui.runtime.getValueSetter("temperature_unit")
  )

  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    t(i18n, "altitude_unit", "Altitude Unit"),
    getAltOptions(i18n),
    ui.config.altitude_unit,
    ui.runtime.getValueSetter("altitude_unit")
  )
end

function M.onClose()
  Common.resetPageState(ui)
  Controls = nil
  Common = nil
  t = nil
end

return M
