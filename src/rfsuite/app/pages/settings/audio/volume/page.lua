local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Controls = nil
local Common = nil

-- ─── Config schema ────────────────────────────────────────────────────────────

local CONFIG_SCHEMA = {
  { key = "level",                type = "number", default = 0 },
  { key = "level_connected_only", type = "bool",   default = false },
  { key = "master_gvar",          type = "number", default = 0 },
  { key = "master_normal",        type = "number", default = 80 },
  { key = "master_alert",         type = "number", default = 100 },
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
    t = Common.pageT("settings_audio_volume")
  end
end

local function copyFromPrefs(prefs)
  local audio = (prefs and prefs.audio) or {}

  for _, field in ipairs(CONFIG_SCHEMA) do
    if field.type == "string" then
      local v = tostring(audio[field.key] or "")
      ui.config[field.key] = v ~= "" and v or field.default
    elseif field.type == "bool" then
      if audio[field.key] ~= nil then
        ui.config[field.key] = audio[field.key]
      else
        ui.config[field.key] = field.default
      end
    else
      ui.config[field.key] = tonumber(audio[field.key]) or field.default
    end
  end
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  copyFromPrefs(prefs)
  ui.loaded = true
end

local function getLevelOptions(i18n)
  return {
    { value = 0, label = t(i18n, "level_default", "Radio default") },
    { value = 1, label = "1" },
    { value = 2, label = "2" },
    { value = 3, label = "3" },
    { value = 4, label = "4" },
    { value = 5, label = "5" },
  }
end

local function getMasterGvarOptions(i18n)
  return {
    { value = 0, label = t(i18n, "gvar_off", "Off") },
    { value = 1, label = "GV1" },
    { value = 2, label = "GV2" },
    { value = 3, label = "GV3" },
    { value = 4, label = "GV4" },
    { value = 5, label = "GV5" },
    { value = 6, label = "GV6" },
    { value = 7, label = "GV7" },
    { value = 8, label = "GV8" },
    { value = 9, label = "GV9" },
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
  if type(ctx.preferences.audio) ~= "table" then ctx.preferences.audio = {} end

  for _, field in ipairs(CONFIG_SCHEMA) do
    ctx.preferences.audio[field.key] = ui.config[field.key]
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

  Controls.appendStaticSectionHeader(
    children, x, cursorY, w,
    t(i18n, "section_callouts", "Callouts")
  )
  cursorY = cursorY + Controls.STATIC_SECTION_H

  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    t(i18n, "level", "Level"),
    getLevelOptions(i18n),
    ui.config.level,
    ui.runtime.getValueSetter("level")
  )

  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    t(i18n, "level_connected_only", "Connected only"),
    ui.config.level_connected_only,
    ui.runtime.getBoolSetter("level_connected_only")
  )

  cursorY = cursorY + 10
  Controls.appendStaticSectionHeader(
    children, x, cursorY, w,
    t(i18n, "section_master", "Master Volume")
  )
  cursorY = cursorY + Controls.STATIC_SECTION_H

  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    t(i18n, "master_gvar", "GVAR"),
    getMasterGvarOptions(i18n),
    ui.config.master_gvar,
    function(value)
      ui.config.master_gvar = value
      ui.runtime.markDirty()
    end
  )

  if ui.config.master_gvar > 0 then
    cursorY = cursorY + Controls.appendNumberField(
      children, x, cursorY, w,
      t(i18n, "master_normal", "Normal"),
      {
        min = 0,
        max = 100,
        step = 5,
        suffix = "%",
        get = function() return ui.config.master_normal end,
        set = ui.runtime.getValueSetter("master_normal")
      }
    )

    cursorY = cursorY + Controls.appendNumberField(
      children, x, cursorY, w,
      t(i18n, "master_alert", "Alert"),
      {
        min = 0,
        max = 100,
        step = 5,
        suffix = "%",
        get = function() return ui.config.master_alert end,
        set = ui.runtime.getValueSetter("master_alert")
      }
    )

    if type(model) == "table" and type(model.getGlobalVariableDetails) == "function" then
      local ok, details = pcall(model.getGlobalVariableDetails, ui.config.master_gvar - 1)
      if ok and type(details) == "table" then
        if details.popup and details.popup ~= 0 and details.popup ~= false then
          children[#children + 1] = {
            type = "label",
            x = x, y = cursorY, w = w,
            text = t(i18n, "gvar_popup_warning", "Warning: GVAR popup is enabled"),
            color = COLOR_THEME_PRIMARY1,
            font = SMLSIZE
          }
          cursorY = cursorY + Controls.LABEL_H + 4
        end
      end
    end
  end
end

function M.onClose()
  Common.resetPageState(ui)
  Controls = nil
  Common = nil
  t = nil
end

return M
