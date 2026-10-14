local M = {}

local DEBUG_PREFIX = "[dashboard.lib] "
local INDEX_PATH = "/SCRIPTS/TOOLS/rfsuite-core/app/pages/settings/dashboard/theme_index.lua"

local Log = nil
local themesCache = nil
do
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local okLoad, chunk = pcall(loadScript, "/SCRIPTS/TOOLS/rfsuite-core/lib/log.lua", mode)
  if okLoad and type(chunk) == "function" then
    local okMod, mod = pcall(chunk)
    if okMod and type(mod) == "table" and type(mod.emit) == "function" then
      Log = mod
    end
  end
end

-- Whether a debug line would be written, asked once where a public function starts, so that a
-- line is formatted only when the log level lets it out. The callers hand over the pieces.
local debugOn = false

local function refreshDebug()
  debugOn = Log ~= nil and Log.wanted("debug") == true
end

local function debugLog(fmt, ...)
  if debugOn then
    Log.emit("dashboard.lib", DEBUG_PREFIX .. string.format(fmt, ...), "debug")
  end
end

-- The theme scan reports in ONE debug line, written where listThemes ends, not in a line per
-- folder and per theme: every line is a Log.emit, and opened from the dashboard the scan runs
-- inside the widget's per-call instruction limit. The line keeps what a missing theme is
-- diagnosed with -- how many entries each folder listed and how many became themes, every
-- folder or page entry that was skipped and why, and the themes found. `scanLog` is a table only
-- while that line is wanted, so nothing is collected below the debug level.
local scanLog = nil

local function scanSkipped(fmt, ...)
  if scanLog then
    scanLog.skipped[#scanLog.skipped + 1] = string.format(fmt, ...)
  end
end

local SYSTEM_THEMES_LIST_PATH = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes"
local USER_THEMES_LIST_PATH = "/SCRIPTS/TOOLS/rfsuite.user/dashboard"
local SYSTEM_THEMES_LOAD_PATH = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/"
local USER_THEMES_LOAD_PATH = "/SCRIPTS/TOOLS/rfsuite.user/dashboard/"

local function normalizePath(path)
  if type(path) ~= "string" then return nil end
  if path == "" then return nil end
  return path
end

local function sanitizeThemeKey(path)
  if type(path) ~= "string" then return nil end
  if path == "" then return nil end
  return string.gsub(path, "[^%w]", "_")
end

local function themeConfigKey(path, key)
  local prefix = sanitizeThemeKey(path)
  if not prefix or type(key) ~= "string" or key == "" then return nil end
  return "cfg_" .. prefix .. "_" .. key
end

local function asThemePath(source, folder)
  if type(source) ~= "string" or type(folder) ~= "string" then
    return nil
  end
  if source == "" or folder == "" then
    return nil
  end
  return source .. "/" .. folder
end

local ICON_FILE = "icon.png"

-- A settings page split into pages needs at least two of them: with one, a pilot would press a
-- tile to reach a grid holding the single tile that opens the page.
local MIN_THEME_PAGES = 2

-- An icon is looked up rather than assumed, so a theme that ships none falls back to the tool's
-- own icon instead of drawing an empty tile. Only the theme scan calls this, and that fills a
-- cache, so the card is read once per menu build rather than once per frame.
local function iconExists(path)
  if type(path) ~= "string" or path == "" then return false end
  local file = io.open(path, "r")
  if not file then return false end
  io.close(file)
  return true
end

local function themeIconPath(loadBasePath, folder)
  local path = loadBasePath .. folder .. "/" .. ICON_FILE
  if iconExists(path) then return path end
  return nil
end

-- The optional `pages` list a theme declares in its init.lua, validated. An entry needs an `id`
-- of lowercase letters, digits and underscores -- it becomes part of a menu id -- and a
-- non-empty `title`; ids are unique within the theme and an `icon` is relative to the theme
-- folder. An entry that fails any of it is dropped rather than costing the theme its page, and
-- a list that ends up shorter than two entries is dropped altogether, so everywhere else the
-- presence of the list is what says the theme is split.
local function themePages(declared, loadBasePath, folder)
  if type(declared) ~= "table" then return nil end

  local pages = {}
  local seen = {}
  for i = 1, #declared do
    local entry = declared[i]
    local id = (type(entry) == "table") and entry.id or nil
    local title = (type(entry) == "table") and entry.title or nil
    if type(id) == "string" and string.match(id, "^[a-z0-9_]+$")
      and type(title) == "string" and title ~= "" and not seen[id] then
      seen[id] = true
      local iconPath = nil
      if type(entry.icon) == "string" and entry.icon ~= "" then
        local candidate = loadBasePath .. folder .. "/" .. entry.icon
        if iconExists(candidate) then iconPath = candidate end
      end
      pages[#pages + 1] = { id = id, title = title, iconPath = iconPath }
    else
      scanSkipped("%s page %s (id=%s: invalid or repeated)", folder, i, id)
    end
  end

  if #pages < MIN_THEME_PAGES then
    scanSkipped("%s pages (%s valid, %s needed)", folder, #pages, MIN_THEME_PAGES)
    return nil
  end

  return pages
end

local function appendTheme(themes, nextId, entry, loadBasePath)
  if type(entry) ~= "table" then return nextId end
  if type(entry.name) ~= "string" or entry.name == "" then return nextId end
  if type(entry.folder) ~= "string" or entry.folder == "" then return nextId end

  local configurePath = nil
  if type(entry.configure) == "string" and entry.configure ~= "" then
    configurePath = loadBasePath .. entry.folder .. "/" .. entry.configure
  end

  themes[#themes + 1] = {
    id = nextId,
    name = entry.name,
    source = entry.source,
    folder = entry.folder,
    path = asThemePath(entry.source, entry.folder),
    configure = entry.configure,
    configurePath = configurePath,
    iconPath = themeIconPath(loadBasePath, entry.folder),
    pages = themePages(entry.pages, loadBasePath, entry.folder),
    standalone = entry.standalone == true
  }
  return nextId + 1
end

local function loadThemeIndex()
  local ok, chunk = pcall(loadScript, INDEX_PATH, "t")
  if not ok or type(chunk) ~= "function" then
    debugLog("theme index missing path=%s", INDEX_PATH)
    return nil
  end

  local loadedOk, index = pcall(chunk)
  if not loadedOk or type(index) ~= "table" then
    debugLog("theme index invalid path=%s", INDEX_PATH)
    return nil
  end

  return index
end

local function loadIndexedThemes(themes, nextId)
  local index = loadThemeIndex()
  if type(index) ~= "table" then
    return nextId
  end
  local firstId = nextId

  for i = 1, #index do
    local entry = index[i]
    local source = entry and entry.source or nil
    local loadBasePath = nil
    if source == "system" then
      loadBasePath = SYSTEM_THEMES_LOAD_PATH
    elseif source == "user" then
      loadBasePath = USER_THEMES_LOAD_PATH
    end

    if loadBasePath then
      nextId = appendTheme(themes, nextId, entry, loadBasePath)
    end
  end

  if scanLog then
    scanLog.index = string.format("%s/%s", nextId - firstId, #index)
  end
  return nextId
end

local function collectDirectoryEntries(listBasePath)
  if type(dir) == "function" then
    local iterator = dir(listBasePath)
    -- A folder that is not on the card, the user folder on most radios: the scan's line says
    -- `unlisted(nil)` for it.
    if type(iterator) ~= "function" then
      return nil
    end

    local entries = {}
    for name in iterator do
      entries[#entries + 1] = name
    end
    return entries
  end

  if system and system.listFiles then
    local entries = system.listFiles(listBasePath)
    debugLog("listFiles fallback type=%s path=%s", type(entries), listBasePath)
    return entries
  end

  debugLog("no directory enumeration API available for path=%s", listBasePath)
  return nil
end

local function scanThemes(listBasePath, loadBasePath, source, themes, nextId)
  local entries = collectDirectoryEntries(listBasePath)
  if type(entries) ~= "table" then
    if scanLog then scanLog[source] = "unlisted(" .. type(entries) .. ")" end
    return nextId
  end
  local firstId = nextId

  for i = 1, #entries do
    local rawEntry = entries[i]
    if type(rawEntry) == "string" and rawEntry ~= "" then
      local trimmed = string.gsub(rawEntry, "[/\\]+$", "")
      local folder = string.match(trimmed, "([^/\\]+)$") or trimmed
      if folder ~= "." and folder ~= ".." and folder ~= "" and not string.match(folder, "%.%a+$") then
        local initPath = loadBasePath .. folder .. "/init.lua"
        local ok, chunk = pcall(loadScript, initPath, "t")
        if ok and chunk then
          local initOk, initTable = pcall(chunk)
          if initOk and type(initTable) == "table" and type(initTable.name) == "string" then
            local configurePath = nil
            if type(initTable.configure) == "string" and initTable.configure ~= "" then
              configurePath = loadBasePath .. folder .. "/" .. initTable.configure
            end

            themes[#themes + 1] = {
              id = nextId,
              name = initTable.name,
              source = source,
              folder = folder,
              path = asThemePath(source, folder),
              configure = initTable.configure,
              configurePath = configurePath,
              iconPath = themeIconPath(loadBasePath, folder),
              pages = themePages(initTable.pages, loadBasePath, folder),
              standalone = initTable.standalone == true
            }
            nextId = nextId + 1
          else
            scanSkipped("%s/%s (init.lua %s)", source, folder, initOk and "returned no theme" or "failed")
          end
        else
          scanSkipped("%s/%s (no init.lua)", source, folder)
        end
      end
    end
  end

  if scanLog then
    scanLog[source] = string.format("%s/%s", nextId - firstId, #entries)
  end
  return nextId
end

function M.listThemes(forceRefresh)
  refreshDebug()
  if forceRefresh ~= true and type(themesCache) == "table" then
    debugLog("listThemes cache hit count=%s", #themesCache)
    return themesCache
  end

  local themes = {}
  local nextId = 1

  scanLog = debugOn and { skipped = {} } or nil
  nextId = scanThemes(SYSTEM_THEMES_LIST_PATH, SYSTEM_THEMES_LOAD_PATH, "system", themes, nextId)
  nextId = scanThemes(USER_THEMES_LIST_PATH, USER_THEMES_LOAD_PATH, "user", themes, nextId)

  if #themes == 0 then
    nextId = loadIndexedThemes(themes, nextId)
  end

  -- Fallback: ensure at least the default theme is available
  if #themes == 0 then
    debugLog("no themes found, entering default fallback")
    local defaultPath = "system/default"
    local initPath = SYSTEM_THEMES_LOAD_PATH .. "default/init.lua"
    local ok, chunk = pcall(loadScript, initPath, "t")
    if ok and chunk then
      local initOk, initTable = pcall(chunk)
      if initOk and type(initTable) == "table" and type(initTable.name) == "string" then
        local configurePath = nil
        if type(initTable.configure) == "string" and initTable.configure ~= "" then
          configurePath = SYSTEM_THEMES_LOAD_PATH .. "default/" .. initTable.configure
        end
        themes[#themes + 1] = {
          id = 1,
          name = initTable.name,
          source = "system",
          folder = "default",
          path = defaultPath,
          configure = initTable.configure,
          configurePath = configurePath,
          iconPath = themeIconPath(SYSTEM_THEMES_LOAD_PATH, "default"),
          pages = themePages(initTable.pages, SYSTEM_THEMES_LOAD_PATH, "default"),
          standalone = initTable.standalone == true
        }
        debugLog("fallback default accepted")
      end
    else
      debugLog("fallback default init failed path=%s", initPath)
    end
  end

  -- Themes found per folder as found/listed; `index` appears only when the checked-in list was
  -- read because the scan found nothing.
  if scanLog then
    local paths = {}
    for i = 1, #themes do
      paths[i] = themes[i].path
    end
    debugLog("listThemes count=%s system=%s user=%s%s skipped=%s themes=%s", #themes,
      scanLog.system or "-", scanLog.user or "-", scanLog.index and (" index=" .. scanLog.index) or "",
      #scanLog.skipped > 0 and table.concat(scanLog.skipped, ", ") or "none", table.concat(paths, ","))
    scanLog = nil
  end

  themesCache = themes

  return themes
end

function M.invalidateThemeCache()
  refreshDebug()
  themesCache = nil
  debugLog("theme cache invalidated")
end

function M.getDefaultThemePath(themes)
  if type(themes) == "table" and #themes > 0 then
    return themes[1].path
  end
  return nil
end

function M.getThemeById(themes, id)
  if type(themes) ~= "table" then return nil end
  local wanted = tonumber(id)
  if not wanted then return nil end
  for i = 1, #themes do
    if themes[i].id == wanted then
      return themes[i]
    end
  end
  return nil
end

function M.getThemeByPath(themes, path)
  if type(themes) ~= "table" then return nil end
  local wanted = normalizePath(path)
  if not wanted then return nil end
  for i = 1, #themes do
    if themes[i].path == wanted then
      return themes[i]
    end
  end
  return nil
end

function M.getThemeIdByPath(themes, path, fallbackId)
  local theme = M.getThemeByPath(themes, path)
  if theme then return theme.id end
  return fallbackId
end

function M.buildThemeOptions(themes)
  local options = {}
  if type(themes) ~= "table" then return options end
  for i = 1, #themes do
    local t = themes[i]
    options[#options + 1] = { value = t.id, label = t.name }
  end
  return options
end

function M.buildModelThemeOptions(themes, disabledLabel)
  local options = {
    { value = 0, label = disabledLabel or "Disabled" }
  }
  if type(themes) ~= "table" then return options end
  for i = 1, #themes do
    local t = themes[i]
    options[#options + 1] = { value = t.id, label = t.name }
  end
  return options
end

function M.getConfigurableThemes(themes)
  refreshDebug()
  local configurable = {}
  if type(themes) ~= "table" then return configurable end
  -- One line for the whole list, naming only the themes left out and why.
  local skipped = debugOn and {} or nil
  for i = 1, #themes do
    local t = themes[i]
    if t.standalone ~= true and type(t.configurePath) == "string" and t.configurePath ~= "" then
      configurable[#configurable + 1] = t
    elseif skipped then
      skipped[#skipped + 1] = string.format("%s (%s)", t.path, t.standalone == true and "standalone" or "no configure")
    end
  end
  if skipped then
    debugLog("getConfigurableThemes count=%s of %s skipped=%s", #configurable, #themes,
      #skipped > 0 and table.concat(skipped, ", ") or "none")
  end
  return configurable
end

-- Model overrides: whether a model's own theme and theme settings are used at all.
--
-- Two switches decide it. `model_overrides` in the radio's [dashboard] section allows or
-- forbids per-model overrides on this radio; `overrides` in a model's own [dashboard] section
-- turns them on for that model. Both are optional keys, and an absent one is not a "no": a card
-- written before the switches existed stored per-model values without asking, so an absent
-- radio switch allows, and an absent model switch is answered by what that model's file
-- already holds -- a theme chosen with the old Model Override, or any theme setting. Once a
-- switch has been saved it is the answer, and nothing is inferred any more.
--
-- Switching off never deletes: the model's values stay in its file and are ignored until the
-- switch is turned on again.
local function hasThemeSettings(modelDashboard)
  for k in pairs(modelDashboard) do
    if type(k) == "string" and string.sub(k, 1, 4) == "cfg_" then return true end
  end
  return false
end

function M.overridesAllowed(dashboard)
  if type(dashboard) ~= "table" then return true end
  return dashboard.model_overrides ~= false
end

function M.modelOverridesOn(modelDashboard)
  if type(modelDashboard) ~= "table" then return false end
  if modelDashboard.overrides ~= nil then return modelDashboard.overrides == true end
  return modelDashboard.model_override == true or hasThemeSettings(modelDashboard)
end

function M.modelOverridesActive(dashboard, modelDashboard)
  return M.overridesAllowed(dashboard) and M.modelOverridesOn(modelDashboard)
end

-- The themes a model draws, for the overview: one entry per theme, with the flight phases it is
-- drawn in. The rule is the widget's (resolveThemePathForState in widgets/dashboard/runtime.lua,
-- which keeps its own copy because it runs without this file when it cannot load it): with
-- Per-Phase Themes on, a phase's own select wins over the theme above it; the model's selects
-- count while its overrides are active, and fall back to the radio's.
local PHASES = { "preflight", "inflight", "postflight" }

local function selectedThemePath(value)
  if type(value) == "string" and value ~= "" and value ~= "nil" then return value end
  return nil
end

function M.resolveThemePath(dashboard, modelDashboard, phase)
  if type(dashboard) ~= "table" then dashboard = {} end
  if type(modelDashboard) ~= "table" then modelDashboard = {} end
  local perPhase = dashboard.theme_per_phase == true and phase ~= "preflight"
  if M.modelOverridesActive(dashboard, modelDashboard) then
    local chosen = (perPhase and selectedThemePath(modelDashboard["model_theme_" .. phase]))
      or selectedThemePath(modelDashboard.model_theme_preflight)
    if chosen then return chosen end
  end
  return (perPhase and selectedThemePath(dashboard["theme_" .. phase]))
    or selectedThemePath(dashboard.theme_preflight)
    or "system/default"
end

function M.themesInUse(dashboard, modelDashboard)
  local out, byPath = {}, {}
  for i = 1, #PHASES do
    local path = M.resolveThemePath(dashboard, modelDashboard, PHASES[i])
    local entry = byPath[path]
    if not entry then
      entry = { path = path, phases = {} }
      byPath[path] = entry
      out[#out + 1] = entry
    end
    entry.phases[#entry.phases + 1] = PHASES[i]
  end
  return out
end

-- Which half of the configuration a theme's settings page is editing. The settings page sets
-- it before it opens a theme's module and clears it when it closes, because the modules read
-- and save through getThemeConfig/setThemeConfig and are not told the scope themselves -- a
-- theme written before scopes existed therefore edits the right half unchanged.
--
--   "standard"  the radio's values, which every model without overrides uses
--   "model"     the connected model's overrides on top of the standard values
--   nil         not editing: the dashboard reading what applies (the two switches decide)
--
-- The scope lives on the session because a theme's module loads its own copy of this file.
function M.setEditScope(scope)
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session
  if type(session) == "table" then
    session.dashboardConfigScope = scope
  end
end

function M.getEditScope()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session
  if type(session) == "table" then
    return session.dashboardConfigScope
  end
  return nil
end

-- The reason a pilot reads after "Save failed" on a theme's settings page and on the Theme page.
-- The sentences are settings/common.lua's (Common.saveFailureReason), which every other page that
-- writes a settings file reports through as well. That module is read only once a save has
-- failed, so the dashboard widget, which loads this file too, never pays for it. A save that has
-- already failed must not raise on top of it: where common.lua does not load, the store's own
-- answer stands in.
local SettingsCommon = nil

function M.saveFailureReason(i18n, err, modelStore)
  if not SettingsCommon then
    local okLoad, chunk = pcall(loadScript, "/SCRIPTS/TOOLS/rfsuite-core/app/pages/settings/common.lua", "t")
    local okRun, mod = false, nil
    if okLoad and type(chunk) == "function" then okRun, mod = pcall(chunk) end
    if not (okRun and type(mod) == "table" and type(mod.saveFailureReason) == "function") then
      return tostring(err or "io")
    end
    SettingsCommon = mod
  end
  return SettingsCommon.saveFailureReason(i18n, err, modelStore)
end

-- The defaults each theme reads its configuration with, remembered so a save in the model
-- scope can tell a value that deviates from one that merely repeats the standard.
local themeDefaults = {}

function M.getThemeConfig(prefs, path, defaults, modelPrefs)
  local out = {}
  local source = defaults or {}
  for k, v in pairs(source) do
    out[k] = v
  end
  if type(path) == "string" and defaults ~= nil then
    themeDefaults[path] = defaults
  end

  local dashboard = prefs and prefs.dashboard
  if type(dashboard) ~= "table" then
    dashboard = {}
  end

  local prefix = sanitizeThemeKey(path)
  local prefixPattern = prefix and ("^cfg_" .. prefix .. "_(.+)$")

  -- 1. First, apply global preferences
  if prefixPattern then
    for k, v in pairs(dashboard) do
      local subKey = string.match(k, prefixPattern)
      if subKey then
        out[subKey] = v
      end
    end
  end
  for k in pairs(source) do
    local key = themeConfigKey(path, k)
    if key and dashboard[key] ~= nil then
      out[k] = dashboard[key]
    end
  end

  -- 2. Then, apply model-specific preferences (higher priority), when they apply at all
  local scope = M.getEditScope()
  local useModel = false
  if type(modelPrefs) == "table" then
    if scope == "model" then
      useModel = true
    elseif scope == nil then
      useModel = M.modelOverridesActive(dashboard, modelPrefs.dashboard)
    end
  end
  if useModel then
    local modelDashboard = modelPrefs.dashboard
    if type(modelDashboard) == "table" then
      if prefixPattern then
        for k, v in pairs(modelDashboard) do
          local subKey = string.match(k, prefixPattern)
          if subKey then
            out[subKey] = v
          end
        end
      end
      for k in pairs(source) do
        local key = themeConfigKey(path, k)
        if key and modelDashboard[key] ~= nil then
          out[k] = modelDashboard[key]
        end
      end
    end
  end

  return out
end

local function sameValue(a, b)
  if type(a) == "number" and type(b) == "number" then
    return math.abs(a - b) < 1e-6
  end
  return a == b
end

-- Where a save lands is the scope the page is editing, never whether a flight controller
-- happens to be connected. The standard scope writes the radio's file and leaves every model
-- file alone. The model scope writes only what deviates: a value equal to the standard one --
-- the radio's value where it has one, the theme's default otherwise -- is removed from the model
-- rather than stored, so the model's file lists exactly its overrides and a later change of the
-- standard still reaches every value the model never changed. Without the model's store the
-- model scope saves nothing: writing its values into the radio's file instead would change the
-- standard for every model.
function M.setThemeConfig(prefs, path, values, modelPrefs)
  if type(values) ~= "table" then return end

  if M.getEditScope() == "model" then
    if type(modelPrefs) ~= "table" then return end
    local global = (type(prefs) == "table" and type(prefs.dashboard) == "table") and prefs.dashboard or {}
    local defaults = themeDefaults[path] or {}
    modelPrefs.dashboard = modelPrefs.dashboard or {}
    -- Editing the model's overrides is the decision to have them; a model that only inferred
    -- the switch from its file would lose it with its last deviating value.
    if modelPrefs.dashboard.overrides == nil then modelPrefs.dashboard.overrides = true end
    for k, v in pairs(values) do
      local key = themeConfigKey(path, k)
      if key then
        local standard = global[key]
        if standard == nil then standard = defaults[k] end
        if standard ~= nil and sameValue(v, standard) then
          modelPrefs.dashboard[key] = nil
        else
          modelPrefs.dashboard[key] = v
        end
      end
    end
    return
  end

  if type(prefs) ~= "table" then return end
  prefs.dashboard = prefs.dashboard or {}
  for k, v in pairs(values) do
    local key = themeConfigKey(path, k)
    if key then
      prefs.dashboard[key] = v
    end
  end
end

-- The overrides a model's file holds, for the overview: one entry per theme setting, with the
-- theme it belongs to (by path, where one of `themes` matches its key), the model's value and
-- the radio's standard value (nil where the radio has none and the theme's default applies).
function M.listModelOverrides(prefs, modelPrefs, themes)
  local out = {}
  local modelDashboard = type(modelPrefs) == "table" and modelPrefs.dashboard or nil
  if type(modelDashboard) ~= "table" then return out end
  local global = (type(prefs) == "table" and type(prefs.dashboard) == "table") and prefs.dashboard or {}

  local prefixes = {}
  if type(themes) == "table" then
    for i = 1, #themes do
      local prefix = sanitizeThemeKey(themes[i].path)
      if prefix then
        prefixes[#prefixes + 1] = { prefix = "cfg_" .. prefix .. "_", theme = themes[i] }
      end
    end
  end

  for key, value in pairs(modelDashboard) do
    if type(key) == "string" and string.sub(key, 1, 4) == "cfg_" then
      local theme, setting = nil, string.sub(key, 5)
      local best = 0
      for i = 1, #prefixes do
        local p = prefixes[i].prefix
        if #p > best and string.sub(key, 1, #p) == p then
          best = #p
          theme = prefixes[i].theme
          setting = string.sub(key, #p + 1)
        end
      end
      out[#out + 1] = { key = key, theme = theme, setting = setting, value = value, standard = global[key] }
    end
  end

  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- Removes one override (`key`) or all of them (`key` nil) from a model's file; the caller saves.
function M.clearModelOverride(modelPrefs, key)
  local modelDashboard = type(modelPrefs) == "table" and modelPrefs.dashboard or nil
  if type(modelDashboard) ~= "table" then return end
  if key ~= nil then
    modelDashboard[key] = nil
    return
  end
  local keys = {}
  for k in pairs(modelDashboard) do
    if type(k) == "string" and string.sub(k, 1, 4) == "cfg_" then keys[#keys + 1] = k end
  end
  for i = 1, #keys do modelDashboard[keys[i]] = nil end
end

return M
