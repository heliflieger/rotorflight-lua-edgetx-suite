local function loadModule(path)
  local chunk = assert(loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t"))
  return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")

-- The settings page loads this file for the theme it is configuring and hands that theme
-- to the factory below, so a copy of this theme under rfsuite.user/dashboard stores its
-- values under its own key prefix instead of this one's. The literal is the fallback for
-- a caller that passes no theme.
local THEME_PATH = "system/@srb-rc"
local THEME_DEFAULTS = {
  bec_warn = 6.5,
  esctemp_warn = 90,
  esctemp_max = 200,
}

local ui = {
  loaded = false,
  config = {
    bec_warn_tenths = 65,
    esctemp_warn = 90,
    esctemp_max = 200,
  }
}

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function loadConfig(prefs)
  if ui.loaded then return end

  local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
  -- The per-model store is only addressable once the flight controller's id is known, so
  -- the read is conditioned on it exactly as the save is.
  local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

  local cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, THEME_DEFAULTS, modelPrefs)

  ui.config.bec_warn_tenths = math.floor(((tonumber(cfg.bec_warn) or THEME_DEFAULTS.bec_warn) * 10) + 0.5)
  ui.config.esctemp_warn = tonumber(cfg.esctemp_warn) or THEME_DEFAULTS.esctemp_warn
  ui.config.esctemp_max = tonumber(cfg.esctemp_max) or THEME_DEFAULTS.esctemp_max

  ui.config.bec_warn_tenths = clamp(ui.config.bec_warn_tenths, 50, 150)
  ui.config.esctemp_max = clamp(ui.config.esctemp_max, 1, 200)
  ui.config.esctemp_warn = clamp(ui.config.esctemp_warn, 0, ui.config.esctemp_max - 1)

  ui.loaded = true
end

local function saveConfig(prefs)
  local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
  -- The per-model store can only be written once the flight controller's id is known, so
  -- a theme configured without one is stored globally instead.
  local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

  DashboardLib.setThemeConfig(prefs, THEME_PATH, {
    bec_warn = (tonumber(ui.config.bec_warn_tenths) or 65) / 10,
    esctemp_warn = tonumber(ui.config.esctemp_warn) or THEME_DEFAULTS.esctemp_warn,
    esctemp_max = tonumber(ui.config.esctemp_max) or THEME_DEFAULTS.esctemp_max,
  }, modelPrefs)

  if session and session.mcu_id and modelPrefs then
    local loadMod = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", "t")
    if type(loadMod) == "function" then
      local ok, MP = pcall(loadMod)
      if ok and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
        MP.saveByMcuId(session.mcu_id, modelPrefs)
      end
    end
  end
end

local function getBecWarn()
  return tonumber(ui.config.bec_warn_tenths) or 65
end

local function setBecWarn(value)
  ui.config.bec_warn_tenths = clamp(tonumber(value) or 65, 50, 150)
end

local function getEscWarn()
  local maxAllowed = (tonumber(ui.config.esctemp_max) or 200) - 1
  return clamp(tonumber(ui.config.esctemp_warn) or 90, 0, maxAllowed)
end

local function setEscWarn(value)
  local maxAllowed = (tonumber(ui.config.esctemp_max) or 200) - 1
  ui.config.esctemp_warn = clamp(tonumber(value) or 90, 0, maxAllowed)
end

local function getEscMax()
  local minAllowed = (tonumber(ui.config.esctemp_warn) or 90) + 1
  return clamp(tonumber(ui.config.esctemp_max) or 200, minAllowed, 200)
end

local function setEscMax(value)
  local minAllowed = (tonumber(ui.config.esctemp_warn) or 90) + 1
  ui.config.esctemp_max = clamp(tonumber(value) or 200, minAllowed, 200)
end

local M = {}

function M.getHeaderActions()
  return { save = true, help = false }
end


function M.onReload(ctx)
  ui.loaded = false
  loadConfig(ctx.preferences)
  return true
end

function M.onSave(ctx)
  saveConfig(ctx.preferences)
  local ok, err = ctx.savePreferences()
  if ok then
    ui.dirty = false
    if ctx and type(ctx.reportSave) == "function" then
      local i18n = ctx.i18n
      local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_title") or "Saved"
      local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_message") or "Theme settings saved"
      ctx.reportSave({ ok = true, title = title, message = message })
    end
  else
    if ctx and type(ctx.reportSave) == "function" then
      local i18n = ctx.i18n
      local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_title") or "Error"
      local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_message") or "Save failed"
      ctx.reportSave({ title = title, message = message .. ": " .. tostring(err or "io") })
    end
  end
  return true
end

function M.build(ctx)
  loadConfig(ctx.preferences)

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local cursorY = y

  local i18n = ctx.i18n
  local becWarnLabel = "BEC Warning"
  local escWarnLabel = "ESC Warning"
  local escMaxLabel = "ESC Max"
  if i18n and i18n.t then
    local becWarnTranslated = i18n.t("widgets.dashboard.bec_warning")
    if becWarnTranslated and becWarnTranslated ~= "widgets.dashboard.bec_warning" and becWarnTranslated ~= "" then
      becWarnLabel = becWarnTranslated
    end
    local escWarnTranslated = i18n.t("widgets.dashboard.esc_warning")
    if escWarnTranslated and escWarnTranslated ~= "widgets.dashboard.esc_warning" and escWarnTranslated ~= "" then
      escWarnLabel = escWarnTranslated
    end
    local escMaxTranslated = i18n.t("widgets.dashboard.esc_max")
    if escMaxTranslated and escMaxTranslated ~= "widgets.dashboard.esc_max" and escMaxTranslated ~= "" then
      escMaxLabel = escMaxTranslated
    end
  end

  Controls.appendSectionHeader(children, x, cursorY, w, "@SRB-RC", true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, becWarnLabel, {
    min = 50,
    max = 150,
    get = getBecWarn,
    set = setBecWarn,
    display = function(value)
      return string.format("%.1fV", (tonumber(value) or 65) / 10)
    end
  })

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, escWarnLabel, {
    min = 0,
    max = 199,
    get = getEscWarn,
    set = setEscWarn,
    display = function(value)
      return string.format("%d°C", tonumber(value) or 90)
    end
  })

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, escMaxLabel, {
    min = 1,
    max = 200,
    get = getEscMax,
    set = setEscMax,
    display = function(value)
      return string.format("%d°C", tonumber(value) or 200)
    end
  })
end

return function(ctx)
  local theme = ctx and ctx.theme
  if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
    THEME_PATH = theme.path
  end
  return M
end
