local Render = {}

function Render.render(nodes, rect, box, state, themeCommon, utils)
  local lastSecs = nil
  local cachedText = nil
  local textGetter = function()
    local val = (state and state.flightSeconds) or 0
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

  local valueY = utils.defaultValueY(rect, box)
  local valuePosition = utils.resolveValue(box.valueposition, box, state)
  if valuePosition == "center" then
    local valuePaddingTop = utils.toNumber(utils.resolveValue(box.valuepaddingtop, box, state), 0)
    local textHeight = utils.toNumber(utils.resolveValue(box.valueheight, box, state), 18)
    valueY = rect.y + math.floor((rect.h - textHeight) / 2) + valuePaddingTop
  end
  utils.pushLabel(nodes, rect.x + 4, valueY, rect.w - 8, textGetter, colorGetter, box.valuealign or box.titlealign or CENTER, fontGetter)
end

return Render
