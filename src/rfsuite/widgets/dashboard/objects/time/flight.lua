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
    local valueText = nil
    if themeCommon and type(themeCommon.formatDuration) == "function" then
      local ok, res = pcall(themeCommon.formatDuration, val)
      if ok and res ~= nil then valueText = res end
    end
    if valueText == nil then
      local totalSecs = math.max(0, math.floor(tonumber(val) or 0))
      local mins = math.floor(totalSecs / 60)
      local secs = totalSecs % 60
      valueText = string.format("%02d:%02d", mins, secs)
    end
    if utils and type(utils.applyLowResMaxChars) == "function" then
      valueText = utils.applyLowResMaxChars(valueText, box, state, "max_chars_lowres")
    end
    cachedText = valueText or "00:00"
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

  local valueY = (utils and utils.defaultValueY and utils.defaultValueY(rect, box)) or (rect.y + 4)
  local valuePosition = (utils and type(utils.resolveValue) == "function") and utils.resolveValue(box.valueposition, box, state) or box.valueposition
  if valuePosition == "center" then
    local valuePaddingTop = (utils and utils.toNumber and utils.resolveValue and utils.toNumber(utils.resolveValue(box.valuepaddingtop, box, state), 0)) or 0
    local textHeight = (utils and utils.toNumber and utils.resolveValue and utils.toNumber(utils.resolveValue(box.valueheight, box, state), 18)) or 18
    valueY = rect.y + math.floor((rect.h - textHeight) / 2) + valuePaddingTop
  end
  if utils and type(utils.pushLabel) == "function" then
    utils.pushLabel(nodes, rect.x + 4, valueY, rect.w - 8, textGetter, colorGetter, box.valuealign or box.titlealign or CENTER, fontGetter)
  end
end

return Render
