
local loadedModules = {}
local loadedThemeConfigs = {}
local function loadModule(path)
  if loadedModules[path] then return loadedModules[path] end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  local mod = chunk()
  loadedModules[path] = mod
  return mod
end

-- Cached per scope as well as per file. A theme's module keeps the values it has read in its own
-- upvalues, and running the file again is the only way to get a module that has read nothing, so
-- the standard values and a model's overrides are never shown by the same copy.
--
-- A failure is answered with its reason and is not cached here. It is not tried again on every
-- build: loadThemeModule keeps what a finished load gave -- the module, or an empty one with
-- `ui.loadError` beside it -- in `ui.activeModule` and returns that while the theme, page and
-- scope are unchanged, so a failing module is loaded and logged once per open of the page and
-- once per Reload, which both clear it.
local function loadThemeConfig(configurePath, scope)
  local cacheKey = configurePath .. "|" .. tostring(scope)
  local cached = loadedThemeConfigs[cacheKey]
  if cached ~= nil then
    return cached
  end
  local ok, chunk, loadErr = pcall(loadScript, configurePath, "t")
  if not ok then
    return nil, chunk
  end
  if type(chunk) ~= "function" then
    return nil, loadErr
  end
  local loadedOk, loaded = pcall(chunk)
  if not loadedOk then
    return nil, loaded
  end
  loadedThemeConfigs[cacheKey] = loaded
  return loaded
end

-- Written only when a theme's module fails to load, so the log module is read only then.
local function logLoadFailure(path, reason)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local okLoad, chunk = pcall(loadScript, "/SCRIPTS/TOOLS/rfsuite-core/lib/log.lua", mode)
  if not okLoad or type(chunk) ~= "function" then return end
  local okMod, Log = pcall(chunk)
  if okMod and type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite", "theme settings not loaded: " .. tostring(path) .. ": " .. tostring(reason), "error")
  end
end

-- EdgeTX does not wrap a label, and a load error carries the file's path and line ahead of the
-- message, so the line naming it is cut to the row with "..." (as fitToWidth in
-- app/pages/logs/page.lua cuts a file name). The log keeps the whole reason. The cut is kept for
-- the text and width it was made for, so a build that draws the same line measures nothing.
local ELLIPSIS = "..."
local fitted = {}

local function textWidth(text, font)
  local fn = lcd and lcd.sizeText
  if type(fn) == "function" then
    local ok, w = pcall(fn, text, font)
    w = tonumber(w)
    if ok and w then return w end
  end
  return #text * 7
end

local function fitToRow(text, font, maxW)
  if fitted.text == text and fitted.w == maxW then return fitted.out end
  local out = text
  if type(maxW) == "number" and maxW > 0 and textWidth(text, font) > maxW then
    local room = maxW - textWidth(ELLIPSIS, font)
    local best, lo, hi = 0, 0, #text - 1
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local n = mid
      -- Never end on half a UTF-8 sequence.
      while n > 0 do
        local b = string.byte(text, n + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        n = n - 1
      end
      if textWidth(string.sub(text, 1, n), font) <= room then
        if n > best then best = n end
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    out = (string.gsub(string.sub(text, 1, best), "[%.%s:]+$", "")) .. ELLIPSIS
  end
  fitted.text, fitted.w, fitted.out = text, maxW, out
  return out
end

local Common = nil
local DashboardLib = nil

local M = {}

local ui = {
  loaded = false,
  themes = nil,
  configurableThemes = nil,
  activeThemeConfigPath = nil,
  activePageId = nil,
  activeScope = nil,
  activePage = nil,
  activeTheme = nil,
  activeModule = nil,
  loadError = nil,
}

ui.runtime = nil
local t = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not DashboardLib then
    DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_dashboard_settings")
  end
end

local function hexDecode(input)
  if type(input) ~= "string" or input == "" then return nil end
  if #input % 2 ~= 0 then return nil end
  local out = {}
  for i = 1, #input, 2 do
    local byte = tonumber(string.sub(input, i, i + 1), 16)
    if not byte then return nil end
    out[#out + 1] = string.char(byte)
  end
  return table.concat(out)
end

-- The menu id carries the theme, and for a theme that splits its settings it carries the page
-- as well. The theme token is hexadecimal and so holds no underscore, which is what keeps the
-- two apart however many underscores a page id has. Its prefix carries the scope: `settings_`
-- edits the radio's standard values, `model_` the connected model's overrides.
local MENU_SCOPES = {
  { prefix = "^settings_dashboard_settings_", scope = "standard" },
  { prefix = "^settings_dashboard_model_", scope = "model" },
}

-- The line naming the scope above the theme's own controls.
local SCOPE_LABEL_H = 24

local function themePathFromMenu(ctx)
  local menu = ctx and ctx.menu
  local menuId = menu and menu.getCurrentMenuId and menu.getCurrentMenuId() or nil
  if type(menuId) ~= "string" then return nil end

  for i = 1, #MENU_SCOPES do
    local entry = MENU_SCOPES[i]
    local token = string.match(menuId, entry.prefix .. "([0-9a-f]+)_page$")
    if token then return hexDecode(token), nil, entry.scope end

    local pageToken, pageId = string.match(menuId, entry.prefix .. "([0-9a-f]+)_([a-z0-9_]+)_page$")
    if pageToken then return hexDecode(pageToken), pageId, entry.scope end
  end

  return nil
end

local function connectedModelName()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if type(session) == "table" then
    if type(session.modelName) == "string" and session.modelName ~= "" then
      return session.modelName
    end
    local craft = type(session.modelPreferences) == "table" and session.modelPreferences.craft or nil
    if type(craft) == "table" and type(craft.name) == "string" and craft.name ~= "" then
      return craft.name
    end
  end
  if type(model) == "table" and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
      return info.name
    end
  end
  return nil
end

local function modelStoreReady()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  return type(session) == "table" and session.mcu_id ~= nil and type(session.modelPreferences) == "table"
end

-- What the theme declared for the page this menu id names, so the module is told the page by
-- the same title the tile was drawn with. A page id the theme no longer declares resolves to
-- nothing, and the module is then called exactly as a theme without pages is.
local function findThemePage(theme, pageId)
  if type(pageId) ~= "string" or type(theme) ~= "table" or type(theme.pages) ~= "table" then
    return nil
  end
  for i = 1, #theme.pages do
    local page = theme.pages[i]
    if page.id == pageId then
      return { id = page.id, title = page.title }
    end
  end
  return nil
end

-- Every context the theme's module is handed carries the page, not only the factory's: a module
-- returned as a plain table never sees the factory context, and reads the page inside `build`.
local function setContextPage(ctx)
  if type(ctx) == "table" then
    ctx.page = ui.activePage
  end
end

-- Asked once per page module, not on every call: the build, a save and a reload all reach the
-- theme through here, and opened from the dashboard the build runs under the widget's per-call
-- instruction limit. The module is loaded afresh when the page opens, so a theme copied onto the
-- card is found at the next open, and Reload clears the list to ask again.
local function ensureThemes()
  ensureDeps()
  if ui.themes ~= nil then return end
  ui.themes = DashboardLib.listThemes()
  ui.configurableThemes = DashboardLib.getConfigurableThemes(ui.themes)
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  ensureThemes()

  ui.loaded = true
end

-- Every hook that reaches the theme's module comes through here, so this is where the scope is
-- set: before anything of the module runs, because the module reads and saves through the
-- library without being told which half of the configuration it is editing.
local function loadThemeModule(ctx)
  ensureThemes()

  local path, pageId, scope = themePathFromMenu(ctx)
  DashboardLib.setEditScope(scope)
  if type(path) ~= "string" or path == "" then
    ui.activeThemeConfigPath = nil
    ui.activePageId = nil
    ui.activeScope = nil
    ui.activePage = nil
    ui.activeTheme = nil
    ui.activeModule = nil
    setContextPage(ctx)
    return nil
  end

  -- The bound on a failing load (see loadThemeConfig). `ui.activeModule` is set only once the
  -- load has finished, so a build stopped part-way through it -- at the instruction limit, which
  -- ui/home.lua answers by building again on the next pass -- loads again rather than finding
  -- a module that was never loaded.
  if ui.activeThemeConfigPath == path and ui.activePageId == pageId and ui.activeScope == scope
    and ui.activeModule ~= nil then
    setContextPage(ctx)
    return ui.activeModule
  end

  local theme = DashboardLib.getThemeByPath(ui.configurableThemes, path)
  ui.activeThemeConfigPath = path
  ui.activePageId = pageId
  ui.activeScope = scope
  ui.activePage = findThemePage(theme, pageId)
  ui.activeTheme = theme
  ui.activeModule = nil
  ui.loadError = nil
  setContextPage(ctx)

  if not theme or type(theme.configurePath) ~= "string" or theme.configurePath == "" then
    ui.activeModule = false
    return nil
  end

  local loaded, loadErr = loadThemeConfig(theme.configurePath, scope)
  if type(loaded) == "function" then
    local createdOk, created = pcall(loaded, {
      theme = theme,
      page = ui.activePage,
      preferences = ctx and ctx.preferences or nil,
      i18n = ctx and ctx.i18n or nil,
      dashboardLib = DashboardLib,
    })
    if createdOk then
      loaded = created
    else
      loaded, loadErr = nil, created
    end
  end
  if type(loaded) ~= "table" then
    -- Without the reason the page draws only its scope line, which reads as a theme with
    -- nothing to set.
    if loaded == nil then
      ui.loadError = tostring(loadErr or "?")
      logLoadFailure(theme.configurePath, ui.loadError)
    end
    loaded = {}
  end
  ui.activeModule = loaded
  return loaded
end

function M.getHeaderActions()
  -- Save und Reload immer aktiv für Theme-Settings
  return { save = true, reload = true, help = true }
end


function M.onReload(ctx)
  ensureDeps()
  ui.loaded = false
  ui.themes = nil
  ui.configurableThemes = nil
  ui.activeThemeConfigPath = nil
  ui.activePageId = nil
  ui.activeScope = nil
  ui.activePage = nil
  ui.activeTheme = nil
  ui.activeModule = nil
  ui.loadError = nil

  ensureLoaded(ctx.preferences)
  local module = loadThemeModule(ctx)
  if type(module) == "table" and type(module.onReload) == "function" then
    return module.onReload(ctx)
  end
  return true
end

function M.onSave(ctx)
  ensureDeps()
  local module = loadThemeModule(ctx)
  -- Without the model's store the library saves nothing in the model scope, so a model page
  -- that has lost its flight controller says so rather than reporting a save that did not happen.
  if ui.activeScope == "model" and not modelStoreReady() then
    if type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = t(ctx.i18n, "save_error_title", "Error"),
        message = t(ctx.i18n, "model_store_missing", "Connect the flight controller to save this model's settings")
      })
    end
    return true
  end
  if type(module) == "table" then
    if type(module.onSave) == "function" then
      return module.onSave(ctx)
    end
    if type(module.write) == "function" then
      local okWrite = pcall(module.write, ctx)
      if not okWrite then
        return true
      end
      local ok, err = ctx.savePreferences()
      if not ok and ctx and type(ctx.reportSave) == "function" then
        ctx.reportSave({
          title = t(ctx.i18n, "save_error_title", "Error"),
          message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. DashboardLib.saveFailureReason(ctx.i18n, err)
        })
      end
      return true
    end
  end
  return true
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)
  ui.runtime.setRequestRebuild(ctx.requestRebuild)

  local module = loadThemeModule(ctx)

  -- Which values the page edits, above whatever the theme draws: the theme's module is the same
  -- in both scopes and cannot say it.
  if ui.activeTheme ~= nil then
    local scopeText
    if ui.activeScope == "model" then
      scopeText = t(ctx.i18n, "scope_model", "Own settings for this model")
      local name = connectedModelName()
      if name then scopeText = scopeText .. ": " .. name end
    else
      scopeText = t(ctx.i18n, "scope_standard", "Standard values for all models")
    end
    ctx.children[#ctx.children + 1] = {
      type = "label",
      x = ctx.x,
      y = ctx.y,
      w = ctx.w,
      text = scopeText,
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    ctx.y = ctx.y + SCOPE_LABEL_H
    if type(ctx.h) == "number" then ctx.h = ctx.h - SCOPE_LABEL_H end

    if ui.activeScope == "model" and not modelStoreReady() then
      ctx.children[#ctx.children + 1] = {
        type = "label",
        x = ctx.x,
        y = ctx.y,
        w = ctx.w,
        text = t(ctx.i18n, "model_store_missing", "Connect the flight controller to save this model's settings"),
        color = COLOR_THEME_PRIMARY1,
        font = SMLSIZE
      }
      return
    end

    if ui.loadError ~= nil then
      local failed = t(ctx.i18n, "theme_settings_load_failed", "This theme's settings could not be loaded")
      ctx.children[#ctx.children + 1] = {
        type = "label",
        x = ctx.x,
        y = ctx.y,
        w = ctx.w,
        text = fitToRow(failed .. ": " .. ui.loadError, SMLSIZE, ctx.w),
        color = COLOR_THEME_PRIMARY1,
        font = SMLSIZE
      }
      return
    end
  end

  if type(module) == "table" then
    if type(module.build) == "function" then
      module.build(ctx)
      return
    end
    if type(module.configure) == "function" then
      module.configure(ctx)
      return
    end
    if ui.activeTheme ~= nil then
      return
    end
  end

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local i18n = ctx.i18n
  local labelY = y + 10

  children[#children + 1] = {
    type = "label",
    x = x,
    y = labelY,
    w = w,
    text = t(i18n, "no_theme_settings", "No settings available for this dashboard theme"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
end

function M.onClose()
  -- Leaving the page ends the edit: the library reads what applies again, as the dashboard does.
  if DashboardLib then DashboardLib.setEditScope(nil) end
  Common.resetPageState(ui)
  ui.themes = nil
  ui.configurableThemes = nil
  ui.activeThemeConfigPath = nil
  ui.activePageId = nil
  ui.activeScope = nil
  ui.activePage = nil
  ui.activeTheme = nil
  ui.activeModule = nil
  ui.loadError = nil
  Common = nil
  DashboardLib = nil
  t = nil
end

return M
