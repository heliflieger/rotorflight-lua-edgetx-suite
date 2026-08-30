local Render = {}

function Render.render(nodes, rect, box, state, themeCommon, utils)
  local lastSecs = nil
  local cachedText = nil
  local textGetter = function()
    local val = (state and state.totalFlightSeconds) or 0
    if val == lastSecs and cachedText ~= nil then
      return cachedText
    end
    lastSecs = val
    local valueText = themeCommon.formatDuration(val)
    valueText = utils.applyLowResMaxChars(valueText, box, state, "max_chars_lowres")
    cachedText = valueText or "00:00"
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
