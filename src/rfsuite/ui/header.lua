-- ui/header.lua
-- Header action button rendering and action-visibility resolution.

local Header = {}

local DEFAULT_LAYOUT = {
  rightPad = 20,
  memW = 126,
  topButtonWSmall = 45,
  topButtonWAction = 45,
  topButtonH = 45,
  topButtonGap = 4,
  topButtonY = 8,
  topButtonBorder = 2,
  memYOffset = 13
}

function Header.getLuaMemLabel()
  local kb = collectgarbage and collectgarbage("count") or 0
  return string.format("LUA: %dKB", math.floor(kb + 0.5))
end

function Header.tAction(i18n, key, fallback)
  if i18n and i18n.t then
    return i18n.t("app.actions." .. key)
  end
  return fallback
end

-- Resolve which header actions are visible/enabled.
-- ctx: { headerActions, menu, i18n, preferences, PageRegistry, HelpRegistry, reportHookCrash }
function Header.resolveActions(ctx)
  local headerActions = ctx.headerActions
  local menu          = ctx.menu
  local PageRegistry  = ctx.PageRegistry
  local HelpRegistry  = ctx.HelpRegistry
  local defaults     = headerActions.defaults
  local rootDefaults = defaults.root or {}
  local menuDefaults = defaults.menu or {}
  local isRoot       = not menu or menu.isRoot()
  local base         = isRoot and rootDefaults or menuDefaults
  local actions = {
    back   = true,
    save   = base.save   == true,
    reload = base.reload == true,
    star   = base.star   == true,
    help   = base.help   ~= false
  }

  if menu and not isRoot then
    local menuId = menu.getCurrentMenuId and menu.getCurrentMenuId() or nil
    if menuId then
      local byMenu = headerActions.byMenuId and headerActions.byMenuId[menuId] or nil
      if type(byMenu) == "table" then
        if byMenu.save   ~= nil then actions.save   = byMenu.save   == true end
        if byMenu.reload ~= nil then actions.reload = byMenu.reload == true end
        if byMenu.star   ~= nil then actions.star   = byMenu.star   == true end
        if byMenu.help   ~= nil then actions.help   = byMenu.help   == true end
      end

      local pageModule = PageRegistry and PageRegistry.byMenuId and PageRegistry.byMenuId[menuId] or nil
      if pageModule and pageModule.getHeaderActions then
        -- This runs on every scene rebuild for whatever page is open, so a raise in it ends the
        -- tool without anybody having touched a control. Guarded, the page simply keeps the
        -- action set resolved above it.
        local okPage, fromPage = pcall(pageModule.getHeaderActions, {
          i18n        = ctx.i18n,
          preferences = ctx.preferences,
          menu        = menu
        })
        if not okPage then
          if type(ctx.reportHookCrash) == "function" then
            ctx.reportHookCrash("activePage.getHeaderActions", menuId, fromPage)
          end
          fromPage = nil
        end
        if type(fromPage) == "table" then
          if fromPage.save   ~= nil then actions.save   = fromPage.save   == true end
          if fromPage.reload ~= nil then actions.reload = fromPage.reload == true end
          if fromPage.star   ~= nil then actions.star   = fromPage.star   == true end
          if fromPage.help   ~= nil then actions.help   = fromPage.help   == true end
        end
      end

      if HelpRegistry and HelpRegistry.hasHelp and HelpRegistry.hasHelp(menuId) then
        actions.help = true
      end
    end

    local entryId = menu.getCurrentEntryId and menu.getCurrentEntryId() or nil
    if entryId then
      local override = headerActions.byEntryId[entryId]
      if type(override) == "table" then
        if override.save   ~= nil then actions.save   = override.save   == true end
        if override.reload ~= nil then actions.reload = override.reload == true end
        if override.star   ~= nil then actions.star   = override.star   == true end
        if override.help   ~= nil then actions.help   = override.help   == true end
      end
    end
  end

  return actions
end

local function appendButton(layout, cfg, x, w, text, enabled, pressHandler)
  -- Use `active` to signal enabled/disabled state to LVGL.
  -- When active=false, EdgeTX removes the button from the encoder focus group,
  -- so it cannot receive wheel focus and does not interfere with page scroll.
  -- Do NOT add border rectangles as additional siblings: overlapping rectangles
  -- on top of a button widget confuse LVGL's hit-testing during scroll, which
  -- was the root cause of the "erratic scroll" bug near header buttons.
  layout[#layout + 1] = {
    type  = "button",
    x = x, y = cfg.topButtonY, w = w, h = cfg.topButtonH,
    text  = text,
    active = function() return enabled == true end,
    press  = enabled and pressHandler or nil
  }
end

-- Append memory label and all action buttons to `lyt`.
-- ctx: { actions, i18n, onHelp, onStar, onReload, onSave, onBack }
function Header.appendToLayout(lyt, ctx)
  local actions = ctx.actions
  local i18n    = ctx.i18n
  local prefs   = ctx.preferences
  local cfg = ctx.layout or DEFAULT_LAYOUT
  local t = function(key, fb) return Header.tAction(i18n, key, fb) end

  local rightEdge = LCD_W - cfg.rightPad
  local xHelp   = rightEdge - cfg.topButtonWSmall
  local xStar   = xHelp    - cfg.topButtonGap - cfg.topButtonWSmall
  local xReload = xStar    - cfg.topButtonGap - cfg.topButtonWAction
  local xSave   = xReload  - cfg.topButtonGap - cfg.topButtonWAction
  local xBack   = xSave    - cfg.topButtonGap - cfg.topButtonWAction
  local general = type(prefs) == "table" and prefs.general or nil
  local showRamLabel = type(general) == "table" and general.show_header_memory == true
  if showRamLabel then
    local xMem = xBack - cfg.topButtonGap - cfg.memW
    lyt[#lyt + 1] = {
      type  = "label",
      x = xMem, y = cfg.topButtonY + cfg.memYOffset, w = cfg.memW,
      text  = Header.getLuaMemLabel(),
      color = COLOR_THEME_PRIMARY1, align = RIGHT, font = SMLSIZE
    }
  end

  appendButton(lyt, cfg, xBack,   cfg.topButtonWAction, t("back",   "BACK"),   true,           ctx.onBack)
  appendButton(lyt, cfg, xSave,   cfg.topButtonWAction, t("save",   "SAVE"),   actions.save,   ctx.onSave)
  appendButton(lyt, cfg, xReload, cfg.topButtonWAction, t("reload", "RELOAD"), actions.reload, ctx.onReload)
  appendButton(lyt, cfg, xStar,   cfg.topButtonWSmall,  t("star",   "*"),      actions.star,   ctx.onStar)
  appendButton(lyt, cfg, xHelp,   cfg.topButtonWSmall,  t("help",   "?"),      actions.help,   ctx.onHelp)
end

return Header
