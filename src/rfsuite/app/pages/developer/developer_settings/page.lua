local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Controls = nil
local Common = nil
local Log = nil

local CONFIG_SCHEMA = {
  { key = "debug_level", type = "string", default = "off" },
  { key = "continuous_memory_log", type = "bool", default = false },
  { key = "show_header_memory", type = "bool", default = false },
  { key = "enable_serial_debug", type = "bool", default = false },
  { key = "log_to_card", type = "bool", default = false }
}

-- Mirrors the ladder in lib/log.lua and is replaced by it in ensureDeps(). It is kept as a
-- literal only so this page still builds if the log module cannot be loaded; log.lua holds the
-- definition, and the values below are the order the selector offers them in.
local DEBUG_LEVEL_VALUES = { "off", "error", "warn", "info", "debug" }

local function isKnownDebugLevel(value)
  for _, name in ipairs(DEBUG_LEVEL_VALUES) do
    if name == value then return true end
  end
  return false
end

local function buildDefaultConfig()
  local cfg = {}
  for _, field in ipairs(CONFIG_SCHEMA) do
    cfg[field.key] = field.default
  end
  return cfg
end

local ui = {
  loaded = false,
  sections = {
    logging = true
  },
  config = buildDefaultConfig()
}

ui.runtime = nil

local t = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if Log == nil then
    -- pcall because loadModule asserts, and a missing log module must not take the page down.
    local ok, mod = pcall(loadModule, "lib/log.lua")
    Log = (ok and mod) or false
    if Log and type(Log.LEVELS) == "table" and #Log.LEVELS > 0 then
      DEBUG_LEVEL_VALUES = Log.LEVELS
    end
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
    ui.runtime.valueGetters = {}
    ui.runtime.valueSetters = {}
  end
  if not t then
    t = Common.pageT("settings_developer_settings")
  end
end

local function prefBool(value, default)
  if value == nil then return default end
  return value == true or value == "true" or value == 1 or value == "1"
end

local function copyFromPrefs(prefs)
  local general = (prefs and prefs.general) or {}
  for _, field in ipairs(CONFIG_SCHEMA) do
    local raw = general[field.key]
    if field.type == "number" then
      ui.config[field.key] = tonumber(raw) or field.default
    elseif field.type == "string" then
      local text = tostring(raw or "")
      if text == "" then text = field.default end
      ui.config[field.key] = string.lower(text)
    else
      ui.config[field.key] = prefBool(raw, field.default)
    end
  end

  if not isKnownDebugLevel(ui.config.debug_level) then
    ui.config.debug_level = "off"
  end
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  copyFromPrefs(prefs)
  ui.loaded = true
end

local function getValueGetter(key)
  local getter = ui.runtime.valueGetters[key]
  if getter then return getter end

  getter = function()
    return ui.config[key]
  end
  ui.runtime.valueGetters[key] = getter
  return getter
end

local function getValueSetter(key)
  local setter = ui.runtime.valueSetters[key]
  if setter then return setter end

  setter = function(value)
    if ui.config[key] == value then return end
    ui.config[key] = value
  end
  ui.runtime.valueSetters[key] = setter
  return setter
end

local function buildDebugLevelOptions(i18n)
  local options = {}
  for _, name in ipairs(DEBUG_LEVEL_VALUES) do
    options[#options + 1] = {
      value = name,
      label = t(i18n, "debug_level_" .. name, string.upper(name))
    }
  end
  return options
end

local function buildLogging(cursorY, children, x, w, i18n)
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    t(i18n, "debug_level", "Debug Level"),
    buildDebugLevelOptions(i18n),
    getValueGetter("debug_level")(),
    getValueSetter("debug_level")
  )

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "continuous_memory_log", "Continuous Memory Log"),
    ui.runtime.getBoolGetter("continuous_memory_log"),
    ui.runtime.getBoolSetter("continuous_memory_log")
  )

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "show_header_memory", "Show Header Memory"),
    ui.runtime.getBoolGetter("show_header_memory"),
    ui.runtime.getBoolSetter("show_header_memory")
  )

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "enable_serial_debug", "Enable Serial Debug"),
    ui.runtime.getBoolGetter("enable_serial_debug"),
    ui.runtime.getBoolSetter("enable_serial_debug")
  )

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "log_to_card", "Log Session To Card"),
    ui.runtime.getBoolGetter("log_to_card"),
    ui.runtime.getBoolSetter("log_to_card")
  )
  return cursorY
end

local SECTIONS = {
  {
    key = "logging",
    titleKey = "section_logging",
    titleFallback = "Logging",
    build = buildLogging
  }
}

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end


function M.onReload(ctx)
  ensureDeps()
  copyFromPrefs(ctx.preferences)
end

function M.onSave(ctx)
  ensureDeps()
  if not ctx.preferences.general then ctx.preferences.general = {} end

  for _, field in ipairs(CONFIG_SCHEMA) do
    ctx.preferences.general[field.key] = ui.config[field.key]
  end

  local ok, err = ctx.savePreferences()
  if ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ ok = true, title = t(ctx.i18n, "saved_title", "Saved"), message = t(ctx.i18n, "saved_message", "Developer settings saved") })
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
  ui.runtime.setRequestRebuild(ctx.requestRebuild)
  local cursorY = ctx.y

  for i, section in ipairs(SECTIONS) do
    if i > 1 then cursorY = cursorY + 10 end

    Controls.appendStaticSectionHeader(children, x, cursorY, w,
      t(i18n, section.titleKey, section.titleFallback)
    )

    cursorY = cursorY + Controls.STATIC_SECTION_H
    cursorY = section.build(cursorY, children, x, w, i18n)
  end
end

function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui)
  else
    ui.runtime = nil
    ui.loaded = false
  end
  Controls = nil
  Common = nil
  t = nil
end

return M
