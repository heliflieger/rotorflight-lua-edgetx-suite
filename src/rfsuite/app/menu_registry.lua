local MenuRegistry = {}
local EMPTY_ENTRIES = {}

local function wipeTable(t)
  if type(t) ~= "table" then return end
  for k in pairs(t) do t[k] = nil end
end

function MenuRegistry.new(manifest, i18n, options)
  options = options or {}
  local iconByMenuId = options.iconByMenuId or {}
  local iconByMenuIdProvider = options.iconByMenuIdProvider
  local apiVersionProvider = options.apiVersionProvider

  local menus = manifest.menus or {}
  local dashboardBuilder = nil

  local function ensureDynamicMenu(menuId)
    if type(menuId) ~= "string" or menuId == "" then return end
    local menu = menus[menuId]
    if type(menu) ~= "table" or menu._dynamicThemes ~= true then
      return
    end
    if menu._dynamicThemesLoaded == true then
      return
    end

    if not dashboardBuilder then
      dashboardBuilder = assert(loadScript("/SCRIPTS/TOOLS/rfsuite-core/app/lib/dashboard_builder.lua", "t"))()
    end

    local entries, themeMenus = dashboardBuilder.buildDashboardSettingsThemeMenus()
    menu.pages = entries
    menu._dynamicThemesLoaded = true

    if type(themeMenus) == "table" then
      for dynamicMenuId, menuDef in pairs(themeMenus) do
        menus[dynamicMenuId] = menuDef
      end
    end
  end

  local self = {
    i18n = i18n,
    sections = manifest.sections or {},
    menus = menus,
    conditions = options.conditions or {},
    activeSectionId = nil,
    currentMenuId = nil,
    currentEntryId = nil,
    breadcrumbStack = {},
    _titleCache = {},
    _cachedLocale = nil,
    _conditionsVersion = 0,
    _apiVersionKey = nil,
    _rootCache = {locale = nil, iconRoot = nil, version = -1, data = nil},
    _cardsCache = {locale = nil, iconRoot = nil, menuId = nil, version = -1, data = nil}
  }

  local function parseApiVersion(value)
    if type(value) == "table" then
      local major = tonumber(value[1])
      local minor = tonumber(value[2])
      local patch = tonumber(value[3]) or 0
      if not major or not minor then return nil end
      return { major, minor, patch }
    end

    if type(value) ~= "string" then
      return nil
    end

    local major, minor, patch = string.match(value, "^(%d+)%.(%d+)%.(%d+)$")
    if major then
      return { tonumber(major), tonumber(minor), tonumber(patch) }
    end

    major, minor = string.match(value, "^(%d+)%.(%d+)$")
    if major then
      return { tonumber(major), 0, tonumber(minor) }
    end

    return nil
  end

  local function isAtLeastVersion(current, required)
    local a = type(current) == "table" and current or parseApiVersion(current)
    local b = type(required) == "table" and required or parseApiVersion(required)
    if type(a) ~= "table" or type(b) ~= "table" then
      return true
    end

    for i = 1, 3 do
      local av = tonumber(a[i]) or 0
      local bv = tonumber(b[i]) or 0
      if av > bv then return true end
      if av < bv then return false end
    end

    return true
  end

  local function getApiVersionRaw()
    if type(apiVersionProvider) == "function" then
      return apiVersionProvider()
    end
    return nil
  end

  local function apiVersionKey(value)
    if type(value) == "table" then
      return tostring(value[1] or "") .. "." .. tostring(value[2] or "") .. "." .. tostring(value[3] or 0)
    end
    if value == nil then return "" end
    return tostring(value)
  end

  local invalidateCaches

  local function refreshApiVersionCache()
    local raw = getApiVersionRaw()
    local key = apiVersionKey(raw)
    if self._apiVersionKey ~= key then
      self._apiVersionKey = key
      invalidateCaches()
    end
    return raw
  end

  local function currentLocale()
    if i18n and i18n.getLocale then
      return i18n.getLocale()
    end
    return nil
  end

  invalidateCaches = function()
    self._rootCache.locale = nil
    self._rootCache.iconRoot = nil
    self._rootCache.version = -1
    self._rootCache.data = nil

    self._cardsCache.locale = nil
    self._cardsCache.iconRoot = nil
    self._cardsCache.menuId = nil
    self._cardsCache.version = -1
    self._cardsCache.data = nil
  end

  local function refreshLocaleCaches()
    local locale = currentLocale()
    if self._cachedLocale ~= locale then
      self._cachedLocale = locale
      wipeTable(self._titleCache)
      invalidateCaches()
    end
  end

  -- Whether the armed state is a reason this entry is unavailable. Kept apart from
  -- isEntryEnabled because "disabled" has more than one cause and the card has to be able to
  -- say which: a tile greyed because no flight controller answered is a different message to
  -- the pilot than a tile locked because the craft is in the air.
  local function isEntryLockedByArm(entry)
    if type(entry) ~= "table" then
      return false
    end
    return entry.lockedWhileArmed == true and self.conditions.modelArmed == true
  end

  -- Whether the entry is on the menu at all, which is a different question from whether it can
  -- be entered. `hideWhenDisabled` cannot answer it: that flag hides an entry for ANY reason it
  -- is disabled, so an entry that must disappear on one condition and merely grey out on another
  -- -- no flight controller has answered, the craft is armed -- has no way to say so.
  -- `visibleWhen` names the single condition that decides whether the entry exists, and an entry
  -- it hides is not merely undrawn: navigation refuses it and the cursor skips it, so an id that
  -- cannot be seen cannot be opened either.
  local function isEntryVisible(entry)
    if type(entry) ~= "table" then
      return false
    end

    local conditionKey = entry.visibleWhen
    if conditionKey == nil then
      return true
    end

    if type(conditionKey) == "string" then
      return self.conditions[conditionKey] == true
    end

    if type(conditionKey) == "function" then
      return conditionKey(self.conditions, entry) == true
    end

    return true
  end

  local function isEntryEnabled(entry)
    if type(entry) ~= "table" then
      return false
    end

    -- AND-ed with whatever the entry already carries, and checked first because it is the
    -- one reason that outranks the others: entering such an entry can put MSP on the wire,
    -- and every pushed MSP frame is sent instead of an RC channels frame for that slot.
    if isEntryLockedByArm(entry) then
      return false
    end

    local minApiVersion = entry.minApiVersion
    if minApiVersion ~= nil then
      local currentApi = refreshApiVersionCache()
      if not isAtLeastVersion(currentApi, minApiVersion) then
        return false
      end
    end

    if entry.enabled == false then
      return false
    end

    local conditionKey = entry.enabledWhen
    if conditionKey == nil then
      -- Default to enabled if no condition is present
      return entry.enabled ~= false
    end

    if type(conditionKey) == "string" then
      return self.conditions[conditionKey] == true
    end

    if type(conditionKey) == "function" then
      return conditionKey(self.conditions, entry) == true
    end

    return true
  end

  local function resolveTitle(entry)
    if type(entry) ~= "table" then
      return ""
    end

    refreshLocaleCaches()

    local cached = self._titleCache[entry]
    if cached ~= nil then return cached end

    local resolved = ""

    if entry.titleKey then
      -- Two things this has to survive. `i18n` is optional -- MenuRegistry.new takes it as an
      -- argument and the locale helper above already guards it -- and `ctx.t` ends at
      -- `return fallback or key`, so a lookup that finds nothing hands the key straight back.
      -- A packaged install carries no locale table at all, which makes that the normal case
      -- rather than the exceptional one: an entry with a titleKey would put its own key on the
      -- menu. No entry in the tree sets one today, so this is a trap for the first that does.
      local key = entry.titleKey
      local value = nil
      if i18n and i18n.t then
        value = i18n.t(key, entry.titleFallback)
      end
      if type(value) == "string" and value ~= "" and value ~= key then
        resolved = value
      else
        resolved = entry.titleFallback or entry.title or ""
      end
    elseif entry.title then
      if i18n and i18n.resolve then
        resolved = i18n.resolve(entry.title)
      else
        resolved = entry.title
      end
    end

    self._titleCache[entry] = resolved or ""
    return self._titleCache[entry]
  end

  local function resolveIconPath(iconRoot, icon, menuId)
    if type(icon) == "string" and icon ~= "" then
      if string.sub(icon, 1, 1) == "/" then
        return icon
      end
      if string.sub(icon, 1, 7) == "@pages/" then
        return "/SCRIPTS/TOOLS/rfsuite-core/app/pages/" .. string.sub(icon, 8)
      end
      return iconRoot .. icon
    end

    if type(iconByMenuIdProvider) == "function" then
      local provided = iconByMenuIdProvider()
      if type(provided) == "table" then
        iconByMenuId = provided
        iconByMenuIdProvider = nil
      end
    end

    local pageIcon = menuId and iconByMenuId[menuId] or nil
    if type(pageIcon) == "string" and pageIcon ~= "" then
      return "/SCRIPTS/TOOLS/rfsuite-core/app/pages/" .. pageIcon
    end

    return nil
  end

  local function getSectionById(id)
    for i = 1, #self.sections do
      if self.sections[i].id == id then
        return self.sections[i]
      end
    end
    return nil
  end

  local function getCurrentContainer()
    if self.currentMenuId then
      ensureDynamicMenu(self.currentMenuId)
      return self.menus[self.currentMenuId]
    end
    return nil
  end

  local function getCurrentEntries()
    local container = getCurrentContainer()
    if not container then return EMPTY_ENTRIES end
    return container.pages or {}
  end

  local function syncCurrentEntry()
    local entries = getCurrentEntries()
    local firstVisible = nil

    for i = 1, #entries do
      local entry = entries[i]
      if isEntryVisible(entry) then
        if entry.id == self.currentEntryId then
          return
        end
        if firstVisible == nil then
          firstVisible = entry.id
        end
      end
    end

    self.currentEntryId = firstVisible
  end

  local function pushBreadcrumb(kind, id, title)
    self.breadcrumbStack[#self.breadcrumbStack + 1] = {
      kind = kind,
      id = id,
      title = title
    }
  end

  local function resetBreadcrumbForSection(section)
    self.breadcrumbStack = {}
    pushBreadcrumb("section", section.id, resolveTitle(section))
  end

  if #self.sections > 0 then
    local firstSection = self.sections[1]
    self.activeSectionId = firstSection.id
    self.currentMenuId = nil
    self.breadcrumbStack = {}
    self.currentEntryId = nil
  end

  function self.getActiveSection()
    return getSectionById(self.activeSectionId)
  end

  function self.setActiveSection(id)
    local section = getSectionById(id)
    if not section then return false end

    self.activeSectionId = id
    self.currentMenuId = nil
    resetBreadcrumbForSection(section)
    syncCurrentEntry()
    return true
  end

  function self.isRoot()
    return self.currentMenuId == nil
  end

  function self.getRootGroups(iconRoot)
    refreshLocaleCaches()
    refreshApiVersionCache()
    local cache = self._rootCache
    if cache.data and cache.locale == self._cachedLocale and cache.iconRoot == iconRoot and cache.version == self._conditionsVersion and cache.apiVersionKey == self._apiVersionKey then
      return cache.data
    end

    local groups = {}
    for i = 1, #self.sections do
      local section = self.sections[i]
      local entries = section.pages or {}
      local cards = {}

      for j = 1, #entries do
        local p = entries[j]
        local enabled = isEntryEnabled(p)
        if isEntryVisible(p) and not (enabled == false and p.hideWhenDisabled == true) then
          cards[#cards + 1] = {
          id = p.id,
          sectionId = section.id,
          row = p.row or 1,
          col = p.col or j,
          data = {
            text = resolveTitle(p),
            icon = resolveIconPath(iconRoot, p.icon, p.menuId),
            isMenu = p.menuId ~= nil,
            enabled = enabled,
            lockedByArm = isEntryLockedByArm(p)
          }
        }
        end
      end

      groups[i] = {
        id = section.id,
        title = resolveTitle(section),
        cards = cards
      }
    end

    cache.locale = self._cachedLocale
    cache.iconRoot = iconRoot
    cache.version = self._conditionsVersion
    cache.apiVersionKey = self._apiVersionKey
    cache.data = groups

    return groups
  end

  function self.openRootEntry(sectionId, entryId)
    local section = getSectionById(sectionId)
    if not section then return false end

    local entries = section.pages or {}
    for i = 1, #entries do
      local entry = entries[i]
      if entry.id == entryId then
        if not isEntryVisible(entry) or not isEntryEnabled(entry) then
          return false
        end

        self.activeSectionId = sectionId
        self.currentEntryId = entryId
        ensureDynamicMenu(entry.menuId)
        resetBreadcrumbForSection(section)

        if entry.menuId and self.menus[entry.menuId] then
          self.currentMenuId = entry.menuId
          pushBreadcrumb("menu", entry.menuId, resolveTitle(self.menus[entry.menuId]))
          syncCurrentEntry()
        end

        self._cardsCache.data = nil

        return true
      end
    end

    return false
  end

  function self.openEntry(id)
    local entries = getCurrentEntries()
    for i = 1, #entries do
      local entry = entries[i]
      if entry.id == id then
        if not isEntryVisible(entry) or not isEntryEnabled(entry) then
          return false
        end

        self.currentEntryId = id
        ensureDynamicMenu(entry.menuId)
        if entry.menuId and self.menus[entry.menuId] then
          self.currentMenuId = entry.menuId
          pushBreadcrumb("menu", entry.menuId, resolveTitle(self.menus[entry.menuId]))
          syncCurrentEntry()
          self._cardsCache.data = nil
        end
        return true
      end
    end
    return false
  end

  function self.goBack()
    if not self.currentMenuId then
      return false
    end

    self.breadcrumbStack[#self.breadcrumbStack] = nil
    local parent = self.breadcrumbStack[#self.breadcrumbStack]

    if not parent then
      self.currentMenuId = nil
      local section = self.getActiveSection()
      if section then
        resetBreadcrumbForSection(section)
      end
      syncCurrentEntry()
      return true
    end

    if parent.kind == "section" then
      self.currentMenuId = nil
      self.currentEntryId = nil
    elseif parent.kind == "menu" then
      self.currentMenuId = parent.id
    end

    syncCurrentEntry()
    self._cardsCache.data = nil
    return true
  end

  function self.getBreadcrumb()
    local parts = {}
    for i = 1, #self.breadcrumbStack do
      local title = self.breadcrumbStack[i].title
      if title and title ~= "" then
        parts[#parts + 1] = title
      end
    end

    return table.concat(parts, " / ")
  end

  function self.getHeaderTitle()
    if self:isRoot() then
      local section = self.getActiveSection()
      return section and resolveTitle(section) or ""
    end

    local top = self.breadcrumbStack[#self.breadcrumbStack]
    return (top and top.title) or ""
  end

  function self.getHeaderBreadcrumb()
    if self:isRoot() then
      return ""
    end

    local parts = {}
    for i = 1, (#self.breadcrumbStack - 1) do
      local title = self.breadcrumbStack[i].title
      if title and title ~= "" then
        parts[#parts + 1] = title
      end
    end

    return table.concat(parts, " / ")
  end

  function self.getCards(iconRoot)
    refreshLocaleCaches()
    refreshApiVersionCache()
    local cache = self._cardsCache
    if cache.data and cache.locale == self._cachedLocale and cache.iconRoot == iconRoot and cache.menuId == self.currentMenuId and cache.version == self._conditionsVersion and cache.apiVersionKey == self._apiVersionKey then
      return cache.data
    end

    local entries = getCurrentEntries()
    local cards = {}
    for i = 1, #entries do
      local p = entries[i]
      local enabled = isEntryEnabled(p)
      if isEntryVisible(p) and not (enabled == false and p.hideWhenDisabled == true) then
      local row = p.row or math.floor((i - 1) / 3) + 1
      local col = p.col or ((i - 1) % 3) + 1
      cards[#cards + 1] = {
        id = p.id,
        row = row,
        col = col,
        data = {
          text = resolveTitle(p),
          icon = resolveIconPath(iconRoot, p.icon, p.menuId),
          isMenu = p.menuId ~= nil,
          enabled = enabled,
          lockedByArm = isEntryLockedByArm(p)
        }
      }
      end
    end

    cache.locale = self._cachedLocale
    cache.iconRoot = iconRoot
    cache.menuId = self.currentMenuId
    cache.version = self._conditionsVersion
    cache.apiVersionKey = self._apiVersionKey
    cache.data = cards

    return cards
  end

  function self.getCurrentEntryId()
    return self.currentEntryId
  end

  function self.getCurrentMenuId()
    return self.currentMenuId
  end

  function self.isRootEntryEnabled(sectionId, entryId)
    local section = getSectionById(sectionId)
    if not section then
      return false
    end

    local entries = section.pages or {}
    for i = 1, #entries do
      local entry = entries[i]
      if entry.id == entryId then
        return isEntryEnabled(entry)
      end
    end

    return false
  end

  function self.isEntryEnabled(entryId)
    local entries = getCurrentEntries()
    for i = 1, #entries do
      local entry = entries[i]
      if entry.id == entryId then
        return isEntryEnabled(entry)
      end
    end

    return false
  end

  function self.setCondition(key, value)
    local nextValue = value == true
    if self.conditions[key] == nextValue then return end
    self.conditions[key] = nextValue
    self._conditionsVersion = self._conditionsVersion + 1
    invalidateCaches()
  end

  return self
end

return MenuRegistry
