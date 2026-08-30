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

  local fontGetter = function()
    if utils and type(utils.resolveFont) == "function" then
      return utils.resolveFont(box, state, MIDSIZE, "font", "font_lowres")
    end
    return (box and box.font) or MIDSIZE
  end

  local colorGetter = function()
    if utils and type(utils.resolveTextColor) == "function" then
      return utils.resolveTextColor(box, state, WHITE)
    end
    return (box and box.textcolor) or WHITE
  end

  if utils and type(utils.pushLabel) == "function" then
    utils.pushLabel(nodes, rect.x + 4, (utils.defaultValueY and utils.defaultValueY(rect, box)) or (rect.y + 4), rect.w - 8, textGetter, colorGetter, box.valuealign or box.titlealign or CENTER, fontGetter)
  end
end

return Render
