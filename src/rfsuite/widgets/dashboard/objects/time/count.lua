local Render = {}

function Render.render(nodes, rect, box, state, themeCommon, utils)
  local lastVal = nil
  local cachedText = nil
  local textGetter = function()
    local val = (state and state.flights) or 0
    if val == lastVal and cachedText ~= nil then
      return cachedText
    end
    lastVal = val
    local valueText = nil
    if themeCommon and type(themeCommon.formatInteger) == "function" then
      local ok, res = pcall(themeCommon.formatInteger, val, "")
      if ok and res ~= nil then valueText = res end
    end
    if valueText == nil then
      valueText = tostring(math.floor((tonumber(val) or 0) + 0.5))
    end
    if utils and type(utils.applyLowResMaxChars) == "function" then
      valueText = utils.applyLowResMaxChars(valueText, box, state, "max_chars_lowres")
    end
    cachedText = valueText or "0"
    return cachedText
  end

  local fontRef = nil
  if utils and type(utils.staticFont) == "function" then
    fontRef = utils.staticFont(box, state, MIDSIZE, "font", "font_lowres")
  end
  if fontRef == nil then
    fontRef = function()
      if utils and type(utils.resolveFont) == "function" then
        return utils.resolveFont(box, state, MIDSIZE, "font", "font_lowres")
      end
      return (box and box.font) or MIDSIZE
    end
  end

  local colorRef = nil
  if utils and type(utils.staticTextColor) == "function" then
    colorRef = utils.staticTextColor(box, state, WHITE)
  end
  if colorRef == nil then
    local lastColorCount = nil
    local cachedColor = nil
    colorRef = function()
      local count = (state and state.sessionFlights) or 0
      if count == lastColorCount and cachedColor ~= nil then
        return cachedColor
      end
      lastColorCount = count
      if utils and type(utils.resolveTextColor) == "function" then
        cachedColor = utils.resolveTextColor(box, state, WHITE, count)
        return cachedColor
      end
      cachedColor = (box and box.textcolor) or WHITE
      return cachedColor
    end
  end

  if utils and type(utils.pushLabel) == "function" then
    utils.pushLabel(nodes, rect.x + 4, (utils.defaultValueY and utils.defaultValueY(rect, box)) or (rect.y + 4), rect.w - 8, textGetter, colorRef, box.valuealign or box.titlealign or CENTER, fontRef)
  end
end

return Render
