local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Common = nil
local Controls = nil
local DashboardLib = nil
local Log = nil

local M = {}

local DEBUG_PREFIX = "[dashboard.theme.page] "

local function debugLog(message)
  if Log and type(Log.emit) == "function" then
    Log.emit("dashboard.theme.page", DEBUG_PREFIX .. tostring(message), "debug")
  end
end

local ui = {
  loaded = false,
  dirty = false,
  config = {
    theme_preflight = nil,
    theme_inflight = nil,
    theme_postflight = nil,
    model_override = false,
    model_theme_preflight = "nil",
    model_theme_inflight = "nil",
    model_theme_postflight = "nil",
    theme_per_phase = false,
  },
  themes = nil,
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
  if not DashboardLib then
    DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
  end
  if not Log then
    Log = loadModule("lib/log.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_dashboard_theme")
  end
end

local function refreshThemes(forceRefresh)
  ensureDeps()
  ui.themes = DashboardLib.listThemes(forceRefresh == true)
  debugLog("refreshThemes count=" .. tostring(ui.themes and #ui.themes or 0))
end

-- Every selection except the general theme may legitimately be unset: a per-model theme that
-- is not given falls through to the general one, and a phase override that is not given falls
-- through to the theme of its own context.
local OPTIONAL_THEME_KEYS = {
  "theme_inflight",
  "theme_postflight",
  "model_theme_preflight",
  "model_theme_inflight",
  "model_theme_postflight",
}

local function ensureValidSelections()
  local defaultPath = DashboardLib.getDefaultThemePath(ui.themes)
  if not defaultPath then return end

  if not DashboardLib.getThemeByPath(ui.themes, ui.config.theme_preflight) then
    ui.config.theme_preflight = defaultPath
  end

  for i = 1, #OPTIONAL_THEME_KEYS do
    local key = OPTIONAL_THEME_KEYS[i]
    local value = ui.config[key]
    if value ~= "nil" and not DashboardLib.getThemeByPath(ui.themes, value) then
      ui.config[key] = "nil"
    end
  end
end

local function ensureLoaded(prefs)
  if ui.loaded then return end

  if not ui.themes then
    refreshThemes(false)
  end
  local defaultPath = DashboardLib.getDefaultThemePath(ui.themes)
  local src = (prefs and prefs.dashboard) or {}

  local modelSrc = nil
  if type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and type(_G.rfsuite.session.modelPreferences) == "table" then
    if _G.rfsuite.session.modelPreferences.dashboard then
      modelSrc = _G.rfsuite.session.modelPreferences.dashboard
    end
  end

  local modelOverride = false
  if type(modelSrc) == "table" and modelSrc.model_override ~= nil then
    modelOverride = modelSrc.model_override == true
  end

  ui.config.theme_preflight = src.theme_preflight or defaultPath
  ui.config.theme_inflight = src.theme_inflight or "nil"
  ui.config.theme_postflight = src.theme_postflight or "nil"
  ui.config.theme_per_phase = src.theme_per_phase == true
  ui.config.model_override = modelOverride
  ui.config.model_theme_preflight = (modelSrc and modelSrc.model_theme_preflight) or "nil"
  ui.config.model_theme_inflight = (modelSrc and modelSrc.model_theme_inflight) or "nil"
  ui.config.model_theme_postflight = (modelSrc and modelSrc.model_theme_postflight) or "nil"

  ui.loaded = true
end

local function getThemeId(path)
  local fallback = DashboardLib.getThemeIdByPath(ui.themes, DashboardLib.getDefaultThemePath(ui.themes), 1)
  return DashboardLib.getThemeIdByPath(ui.themes, path, fallback)
end

local function getOptionalThemeId(path)
  if path == nil or path == "" or path == "nil" then return 0 end
  local fallback = DashboardLib.getThemeIdByPath(ui.themes, DashboardLib.getDefaultThemePath(ui.themes), 1)
  return DashboardLib.getThemeIdByPath(ui.themes, path, fallback)
end

local function setThemeFromId(key, id)
  local theme = DashboardLib.getThemeById(ui.themes, id)
  if not theme then return end
  if ui.config[key] ~= theme.path then
    ui.config[key] = theme.path
    ui.runtime.markDirty()
  end
end

local function setOptionalThemeFromId(key, id)
  local numeric = tonumber(id) or 0
  local nextPath = "nil"
  if numeric ~= 0 then
    local theme = DashboardLib.getThemeById(ui.themes, numeric)
    if not theme then return end
    nextPath = theme.path
  end
  if ui.config[key] ~= nextPath then
    ui.config[key] = nextPath
    ui.runtime.markDirty()
  end
end

-- The two phase rows are identical in both sections and differ only in the key prefix they
-- write to: "theme_" for the general context, "model_theme_" for the connected model.
local function appendPhaseOverrides(children, x, y, w, i18n, prefix, options, active)
  local used = 0

  used = used + Controls.appendComboSelect(
    children, x, y + used, w,
    t(i18n, "theme_inflight_override", "Inflight Override"),
    options,
    getOptionalThemeId(ui.config[prefix .. "inflight"]),
    function(id) setOptionalThemeFromId(prefix .. "inflight", id) end,
    { active = active }
  )

  used = used + Controls.appendComboSelect(
    children, x, y + used, w,
    t(i18n, "theme_postflight_override", "Postflight Override"),
    options,
    getOptionalThemeId(ui.config[prefix .. "postflight"]),
    function(id) setOptionalThemeFromId(prefix .. "postflight", id) end,
    { active = active }
  )

  return used
end

-- Per-model preferences are keyed by the flight controller's MCU id, so the
-- model override can only be stored while a flight controller is connected.
local function hasModelStore()
  if type(_G) ~= "table" or not _G.rfsuite then return false end
  if type(_G.rfsuite.session) ~= "table" then return false end
  return _G.rfsuite.session.mcu_id ~= nil
end

local function saveToPreferences(prefs)
  if not prefs.dashboard then prefs.dashboard = {} end
  prefs.dashboard.theme_preflight = ui.config.theme_preflight
  prefs.dashboard.theme_inflight = ui.config.theme_inflight
  prefs.dashboard.theme_postflight = ui.config.theme_postflight
  prefs.dashboard.theme_per_phase = ui.config.theme_per_phase == true
  -- Ensure legacy model_override keys are not stored in global preferences
  prefs.dashboard.model_override = nil
  prefs.dashboard.model_theme_preflight = nil
  prefs.dashboard.model_theme_inflight = nil
  prefs.dashboard.model_theme_postflight = nil

  -- Nothing per-model to write is a success; anything attempted has to report.
  local modelOk, modelErr = true, nil

  if type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" then
    local session = _G.rfsuite.session
    if session.mcu_id then
      if type(session.modelPreferences) ~= "table" then session.modelPreferences = {} end
      if type(session.modelPreferences.dashboard) ~= "table" then session.modelPreferences.dashboard = {} end
      local mDashboard = session.modelPreferences.dashboard

      mDashboard.model_override = ui.config.model_override == true
      if ui.config.model_override == true then
        mDashboard.model_theme_preflight = ui.config.model_theme_preflight
        mDashboard.model_theme_inflight = ui.config.model_theme_inflight
        mDashboard.model_theme_postflight = ui.config.model_theme_postflight
      else
        mDashboard.model_theme_preflight = "nil"
        mDashboard.model_theme_inflight = "nil"
        mDashboard.model_theme_postflight = "nil"
      end

      -- Save model preferences using ModelPreferences module
      modelOk, modelErr = false, "model_preferences"
      local loadMod = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", "t")
      if type(loadMod) == "function" then
        local loaded, MP = pcall(loadMod)
        if loaded and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
          modelOk, modelErr = MP.saveByMcuId(session.mcu_id, session.modelPreferences)
        end
      end
    end
  end

  return modelOk ~= false, modelErr
end

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end


function M.onReload(ctx)
  ensureDeps()
  ui.loaded = false
  ui.dirty = false
  ui.themes = nil
  if DashboardLib and type(DashboardLib.invalidateThemeCache) == "function" then
    DashboardLib.invalidateThemeCache()
  end
  ensureLoaded(ctx.preferences)
  return true
end

local function reportSaveError(ctx, err)
  if ctx and type(ctx.reportSave) == "function" then
    ctx.reportSave({
      title = t(ctx.i18n, "save_error_title", "Error"),
      message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. tostring(err or "io")
    })
  end
end

function M.onSave(ctx)
  ensureDeps()
  -- The page saves into two stores. Both have to be believed before the save
  -- is reported as done, and a failure in either one has to be shown.
  local modelOk, modelErr = saveToPreferences(ctx.preferences)
  local ok, err = ctx.savePreferences()
  if not ok then
    reportSaveError(ctx, err)
  elseif not modelOk then
    reportSaveError(ctx, modelErr)
  else
    -- Both stores, because this page reports a save as done only when both were believed.
    ui.dirty = false
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        ok = true,
        title = t(ctx.i18n, "saved_title", "Saved"),
        message = t(ctx.i18n, "saved_message", "Theme settings saved")
      })
    end
  end
  return true
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)
  if not ui.themes then
    refreshThemes(false)
  end
  ensureValidSelections()
  ui.runtime.setRequestRebuild(ctx.requestRebuild)

  debugLog("build theme count=" .. tostring(ui.themes and #ui.themes or 0) .. " preflight=" .. tostring(ui.config.theme_preflight) .. " inflight=" .. tostring(ui.config.theme_inflight) .. " postflight=" .. tostring(ui.config.theme_postflight))
  if type(ui.themes) == "table" then
    for i = 1, #ui.themes do
      local theme = ui.themes[i]
      debugLog("option[" .. tostring(i) .. "] name=" .. tostring(theme.name) .. " path=" .. tostring(theme.path))
    end
  end

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local i18n = ctx.i18n
  local cursorY = y

  if not ui.themes or #ui.themes == 0 then
    children[#children + 1] = {
      type = "label",
      x = x,
      y = y + 10,
      w = w,
      text = t(i18n, "no_themes_found", "No dashboard themes found"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    return
  end

  local themeOptions = DashboardLib.buildThemeOptions(ui.themes)
  local modelOptions = DashboardLib.buildModelThemeOptions(ui.themes, t(i18n, "model_disabled", "Disabled"))
  local overrideOptions = DashboardLib.buildModelThemeOptions(ui.themes, t(i18n, "theme_use_context", "Use theme above"))
  local perPhase = ui.config.theme_per_phase == true

  Controls.appendSectionHeader(children, x, cursorY, w,
    t(i18n, "section_dashboard_theme", "Dashboard Theme"), true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  -- One theme for everything that is not the connected model. It carries all three flight
  -- phases, which it declares and switches between itself.
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    t(i18n, "theme", "Theme"),
    themeOptions,
    getThemeId(ui.config.theme_preflight),
    function(id) setThemeFromId("theme_preflight", id) end
  )

  if perPhase then
    cursorY = cursorY + appendPhaseOverrides(children, x, cursorY, w, i18n, "theme_", overrideOptions, nil)
  end

  cursorY = cursorY + 10
  Controls.appendSectionHeader(children, x, cursorY, w,
    t(i18n, "section_dashboard_theme_model", "Model Override"), true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  local modelStoreReady = hasModelStore()
  local modelStoreActive = function() return modelStoreReady end

  if not modelStoreReady then
    children[#children + 1] = {
      type = "label",
      x = x,
      y = cursorY,
      w = w,
      text = t(i18n, "model_override_unavailable", "Connect a flight controller to store a per-model theme"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    cursorY = cursorY + 24
  end

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "model_override", "Model Override"),
    ui.runtime.getBoolGetter("model_override"),
    ui.runtime.getBoolSetter("model_override"),
    modelStoreActive
  )

  if ui.config.model_override == true then
    -- The theme of the connected model, again for all three of its phases.
    cursorY = cursorY + Controls.appendComboSelect(
      children, x, cursorY, w,
      t(i18n, "theme", "Theme"),
      modelOptions,
      getOptionalThemeId(ui.config.model_theme_preflight),
      function(id) setOptionalThemeFromId("model_theme_preflight", id) end,
      { active = modelStoreActive }
    )

    if perPhase then
      cursorY = cursorY + appendPhaseOverrides(children, x, cursorY, w, i18n, "model_theme_", overrideOptions, modelStoreActive)
    end
  end

  cursorY = cursorY + 10
  Controls.appendSectionHeader(children, x, cursorY, w,
    t(i18n, "section_advanced", "Advanced"), true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  -- Off, the page offers one theme per context and nothing else. On, each context gains the
  -- two overrides that let a phase be drawn by a different theme than the one above it.
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "theme_per_phase", "Per-Phase Themes"),
    ui.runtime.getBoolGetter("theme_per_phase"),
    ui.runtime.getBoolSetter("theme_per_phase")
  )
end

function M.onClose()
  Common.resetPageState(ui)
  ui.themes = nil
  Controls = nil
  Common = nil
  DashboardLib = nil
  Log = nil
  t = nil
end

return M
