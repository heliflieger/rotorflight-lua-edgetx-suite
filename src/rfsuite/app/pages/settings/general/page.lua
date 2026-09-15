local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Controls = nil
local Common = nil

-- ─── Config schema ───────────────────────────────────────────────────────────
-- Single source of truth for all persisted settings.
-- To add a setting: one entry here — loading and saving are automatic.
--   type "bool"   → stored/restored as boolean, default must be true/false
--   type "number" → stored/restored via tonumber(), default must be a number

-- The schema is what is loaded, defaulted and SAVED. A control the page draws whose key is not
-- in here is read from nothing, written to nothing and lost when the page closes -- which is
-- what happened to `save_confirm`: it is in SAFETY_ITEMS below, so it is drawn and it can be
-- toggled, and neither `copyFromPrefs` nor `onSave` ever touched it, because both walk this
-- table. The comment those two carry -- "no manual field list" -- is true of them and was not
-- true of the page, because the page had a second list.
local CONFIG_SCHEMA = {
  { key = "save_confirm",                 type = "bool",   default = true   },
  { key = "save_armed_warning",           type = "bool",   default = true   },
  { key = "reload_confirm",               type = "bool",   default = true   },
  { key = "preview_setup_wizard",         type = "bool",   default = false  },
  { key = "preview_flight_log",           type = "bool",   default = false  },
  { key = "preview_inflight_tuning",      type = "bool",   default = false  },
  { key = "developer_tools",              type = "bool",   default = false  },
}

-- Build ui.config defaults from schema so there is no second place to update.
local function buildDefaultConfig()
  local cfg = {}
  for _, field in ipairs(CONFIG_SCHEMA) do
    cfg[field.key] = field.default
  end
  return cfg
end

-- ─── State ────────────────────────────────────────────────────────────────────

local ui = {
  loaded = false,
  dirty = false,
  sections = {
    safety      = true,
    preview     = false,
    development = false,
  },
  config = buildDefaultConfig()
}

ui.runtime = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local t = nil
local pageI18n = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
    ui.runtime.valueGetters = {}
    ui.runtime.valueSetters = {}
  end
  if not t then
    t = Common.pageT("settings_general")
  end
end

local function prefBool(value, default)
  if value == nil then return default end
  return value == true or value == "true" or value == 1 or value == "1"
end

-- Loads all settings from preferences using the schema — no manual field list.
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

-- ─── Section content builders ────────────────────────────────────────────────
-- Signature: (cursorY, children, x, w, i18n, requestRebuild) -> newCursorY

local SAFETY_ITEMS = {
  { key = "save_confirm",                 labelKey = "save_confirm",                 fallback = "Confirm on Save" },
  { key = "save_armed_warning",           labelKey = "save_armed_warning",           fallback = "Show Disarm Warning on Save/Reload" },
  { key = "reload_confirm",               labelKey = "reload_confirm",               fallback = "Confirm on Reload" },
}

local function buildSafety(cursorY, children, x, w, i18n)
  for _, item in ipairs(SAFETY_ITEMS) do
    local k = item.key
    cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
      t(i18n, item.labelKey, item.fallback),
      ui.runtime.getBoolGetter(k),
      ui.runtime.getBoolSetter(k)
    )
  end
  return cursorY
end

-- ─── Preview features ────────────────────────────────────────────────────────
-- A preview feature is in the tree but not finished. It stays hidden until it is switched on
-- here, one switch per feature and no master switch, so that what is unfinished is only seen by
-- somebody who has said they want to see it. Turning one on asks once; turning it off does not.
--
-- To put a feature behind this: one entry below, one key in CONFIG_SCHEMA and in the preference
-- defaults, the matching condition published in onSave, and `visibleWhen` on its menu entry.

local PREVIEW_ITEMS = {
  {
    key             = "preview_setup_wizard",
    labelKey        = "preview_setup_wizard",
    labelFallback   = "Setup Assistant",
    confirmKey      = "preview_confirm_setup_wizard",
    confirmFallback = "The setup assistant is not finished. Its screens and their order can still change, and it can write to "
      .. "the flight controller. Check what it has written before you fly. Show it anyway?"
  },
  {
    key             = "preview_flight_log",
    labelKey        = "preview_flight_log",
    labelFallback   = "Flight Log",
    confirmKey      = "preview_confirm_flight_log",
    confirmFallback = "The flight log is not finished. What it records, and how the page presents it, can still change, and "
      .. "it keeps a file of its own on the card. Show it anyway?"
  },
  {
    key             = "preview_inflight_tuning",
    labelKey        = "preview_inflight_tuning",
    labelFallback   = "In-flight tuning",
    confirmKey      = "preview_confirm_inflight_tuning",
    confirmFallback = "Not finished, and it changes the flight controller's parameters in flight. Show it anyway?"
  },
}

local ConfirmDialog = nil
local confirmDialogTried = false

local function getConfirmDialog()
  if confirmDialogTried then return ConfirmDialog end
  confirmDialogTried = true
  local ok, mod = pcall(loadModule, "ui/confirm_dialog.lua")
  if ok and type(mod) == "table" and type(mod.show) == "function" then
    ConfirmDialog = mod
  end
  return ConfirmDialog
end

local previewSetters = {}

-- The switch draws itself from the getter, so a refused acknowledgement needs nothing written
-- back: the value never moved, and a repaint puts the switch where the value still is.
--
-- The setter is cached for the module's lifetime while ui.runtime is rebuilt on every visit, so
-- it resolves the runtime when it runs rather than closing over the one that existed when it was
-- created -- otherwise a page that has been closed and reopened would mark an abandoned runtime
-- dirty and ask a dead rebuild hook for the repaint.
local function getPreviewSetter(item)
  local setter = previewSetters[item.key]
  if setter then return setter end

  setter = function(nextVal)
    local apply = ui.runtime.getBoolSetter(item.key)
    if nextVal ~= true then
      apply(false)
      return
    end
    if ui.config[item.key] == true then
      return
    end

    local dialog = getConfirmDialog()
    if dialog then
      local ok, shown = pcall(dialog.show, {
        title = t(pageI18n, item.labelKey, item.labelFallback),
        message = t(pageI18n, item.confirmKey, item.confirmFallback),
        onConfirm = function() apply(true) end,
        onCancel = function()
          local rebuild = ui.runtime and ui.runtime.requestRebuild
          if rebuild then rebuild() end
        end,
        onFallback = function() apply(true) end
      })
      if ok and shown == true then return end
    end

    -- No confirm UI could be put up. The switch then does what it was asked to do: refusing it
    -- because the acknowledgement cannot be shown would leave the feature unreachable.
    apply(true)
  end

  previewSetters[item.key] = setter
  return setter
end

local function buildPreview(cursorY, children, x, w, i18n)
  for _, item in ipairs(PREVIEW_ITEMS) do
    cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
      t(i18n, item.labelKey, item.labelFallback),
      ui.runtime.getBoolGetter(item.key),
      getPreviewSetter(item)
    )
  end
  return cursorY
end

local function buildDevelopment(cursorY, children, x, w, i18n)
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "developer_tools", "Developer Tools"),
    ui.runtime.getBoolGetter("developer_tools"),
    ui.runtime.getBoolSetter("developer_tools")
  )
  return cursorY
end

-- ─── Section manifest ────────────────────────────────────────────────────────
-- Add new sections here — one entry, one builder function above, done.

local SECTIONS = {
  { key = "safety",      titleKey = "section_safety",      titleFallback = "Safety & Prompts", build = buildSafety      },
  { key = "preview",     titleKey = "section_preview",     titleFallback = "Preview",          build = buildPreview     },
  { key = "development", titleKey = "section_development", titleFallback = "Development",      build = buildDevelopment },
}

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
  if not ctx.preferences.general then ctx.preferences.general = {} end

  -- Saves all settings using the schema — no manual field list.
  for _, field in ipairs(CONFIG_SCHEMA) do
    ctx.preferences.general[field.key] = ui.config[field.key]
  end

  local ok, err = ctx.savePreferences()
  if ok then
    ui.dirty = false
    if ctx.menu and ctx.menu.setCondition then
      ctx.menu.setCondition("developerTools", ui.config.developer_tools == true)
      ctx.menu.setCondition("previewSetupWizard", ui.config.preview_setup_wizard == true)
      ctx.menu.setCondition("previewFlightLog", ui.config.preview_flight_log == true)
      ctx.menu.setCondition("previewInflightTuning", ui.config.preview_inflight_tuning == true)
    end
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

  local children       = ctx.children
  local x, w          = ctx.x, ctx.w
  local i18n           = ctx.i18n
  pageI18n             = i18n
  ui.runtime.setRequestRebuild(ctx.requestRebuild)
  local cursorY        = ctx.y

  for i, section in ipairs(SECTIONS) do
    if i > 1 then cursorY = cursorY + 10 end

    local key = section.key
    Controls.appendSectionHeader(children, x, cursorY, w,
      t(i18n, section.titleKey, section.titleFallback),
      ui.sections[key],
      ui.runtime.getSectionToggleHandler(key)
    )

    cursorY = cursorY + Controls.SECTION_H
    if ui.sections[key] then
      cursorY = section.build(cursorY, children, x, w, i18n)
    end
  end
end

function M.onClose()
  Common.resetPageState(ui)
  Controls = nil
  Common = nil
  t = nil
  pageI18n = nil
end

return M
