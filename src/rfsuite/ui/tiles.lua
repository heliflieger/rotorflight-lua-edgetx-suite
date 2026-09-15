-- ui/tiles.lua
-- Pure tile rendering helpers: layout calculation, text wrapping, tile widget builder.

local Tiles = {}

local function resolveTileTextColor(isEnabled, focused)
  if not isEnabled or focused then
    return GREY_DARK or BLACK or COLOR_THEME_SECONDARY2
  end
  return COLOR_THEME_PRIMARY1 or WHITE
end

local function formatTileText(text)
  if type(text) ~= "string" then return "" end
  local len = string.len(text)
  if len <= 11 then return text end
  local bestSpace, mid = nil, math.floor(len / 2)
  for i = 1, len do
    if string.sub(text, i, i) == " " then
      if bestSpace == nil or math.abs(i - mid) < math.abs(bestSpace - mid) then
        bestSpace = i
      end
    end
  end
  if bestSpace then
    return string.sub(text, 1, bestSpace - 1) .. "\n" .. string.sub(text, bestSpace + 1)
  end
  return string.sub(text, 1, mid) .. "\n" .. string.sub(text, mid + 1)
end

-- The line height of one font, measured. `lcd.sizeText(text, flags)` answers for the font the
-- label is drawn in and is not gated on a drawing context, so it may be called while the child
-- list is being built. The fallback only has to be safe on a build that does not offer the call.
function Tiles.lineHeight(font, fallback)
  local fn = lcd and lcd.sizeText
  if type(fn) == "function" then
    local ok, _, th = pcall(fn, "0", font)
    th = tonumber(th)
    if ok and th and th > 0 then
      return th
    end
  end
  return fallback
end

local BADGE_INSET = 3

-- A badge in the tile's top-right corner. Drawn only for a tile whose card data asked for
-- one, on top of the disabled grey rather than instead of it: a tile a pilot cannot press
-- because nothing answered on MSP and a tile locked because the craft is flying are two
-- different answers to "why can I not press this", and they stay two different pictures.
local function appendCornerBadge(children, x, y, size, text)
  local diameter = math.max(14, math.floor(size * 0.22))
  local radius = math.floor(diameter / 2)
  Tiles.appendBadge(children, x + size - BADGE_INSET - radius, y + BADGE_INSET + radius, radius, text)
end

-- The badge itself, placed by its CENTRE. Public because the same mark is drawn twice -- once
-- per locked tile, and once at the left of the armed strip ui/home.lua puts above the content
-- -- and two drawings of one badge would drift apart.
function Tiles.appendBadge(children, cx, cy, radius, text)
  -- `circle` takes its CENTRE in x/y, unlike every other element in this file:
  -- LvglWidgetRoundObject::setPos subtracts the radius before placing the object
  -- (lua/lua_lvgl_widget.cpp), and LvglWidgetCircle::build sets width and height from it.
  children[#children + 1] = {
    type = "circle",
    x = cx, y = cy, radius = radius,
    color = RED or COLOR_THEME_WARNING,
    filled = true
  }

  local textH = Tiles.lineHeight(SMLSIZE, 14)
  children[#children + 1] = {
    type  = "label",
    x = cx - radius, y = cy - math.floor(textH / 2),
    w = radius * 2,
    text  = text,
    font  = SMLSIZE,
    color = WHITE or COLOR_THEME_PRIMARY2,
    align = CENTER
  }
end

function Tiles.computeColumns(width, minCardWidth, maxColumns)
  local cols = math.floor(width / minCardWidth)
  if cols < 1 then cols = 1 end
  if cols > maxColumns then cols = maxColumns end
  return cols
end

function Tiles.flattenRootCards(groups)
  local flat = {}
  for i = 1, #groups do
    local cards = groups[i].cards or {}
    for j = 1, #cards do flat[#flat + 1] = cards[j] end
  end
  return flat
end

-- Append LVGL widgets for a single tile into `children`.
-- LVGL handles focus/ENTER natively between button tiles via its built-in focus box.
-- `focused` is accepted for API compatibility but visual focus is handled by LVGL.
-- `badge` is the glyph of an optional corner badge, already resolved by the caller; nil draws
-- none. It is a string rather than a flag so this file stays a pure renderer with no i18n of
-- its own.
function Tiles.append(children, x, y, size, iconFile, text, focused, pressHandler, enabled, badge)
  local isEnabled = enabled ~= false

  children[#children + 1] = {
    type  = "button",
    x = x, y = y, w = size, h = size,
    text  = "",
    -- Disabled tiles must be excluded from wheel focus traversal.
    active = function()
      return isEnabled
    end,
    press = isEnabled and pressHandler or nil
  }

  if not isEnabled then
    children[#children + 1] = {
      type = "rectangle", x = x + 1, y = y + 1, w = size - 2, h = size - 2,
      color = COLOR_THEME_DISABLED, filled = true
    }
  end

  if iconFile then
    local iconSize = math.max(16, math.floor(size * 0.36))
    children[#children + 1] = {
      type = "image",
      x = x + math.floor((size - iconSize) / 2),
      y = y + math.max(5, math.floor(size * 0.08)),
      w = iconSize, h = iconSize,
      file = iconFile
    }
  end

  children[#children + 1] = {
    type  = "label",
    x = x + 4,
    y = y + math.floor(size * 0.56),
    w = size - 8,
    text  = formatTileText(text),
    font  = SMLSIZE,
    color = resolveTileTextColor(isEnabled, focused == true),
    align = CENTER
  }

  -- Last, so it is the topmost child and nothing above draws over it.
  if type(badge) == "string" and badge ~= "" then
    appendCornerBadge(children, x, y, size, badge)
  end
end

return Tiles
