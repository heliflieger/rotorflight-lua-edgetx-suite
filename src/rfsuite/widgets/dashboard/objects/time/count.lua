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
    local valueText = themeCommon.formatInteger(val, "")
    valueText = utils.applyLowResMaxChars(valueText, box, state, "max_chars_lowres")
    cachedText = valueText or "0"
    return cachedText
  end

  local fontGetter = function()
    return utils.resolveFont(box, state, MIDSIZE, "font", "font_lowres")
  end

  local colorGetter = function()
    return utils.resolveTextColor(box, state, WHITE)
  end

  utils.pushLabel(nodes, rect.x + 4, utils.defaultValueY(rect, box), rect.w - 8, textGetter, colorGetter, box.valuealign or box.titlealign or CENTER, fontGetter)
end

return Render
