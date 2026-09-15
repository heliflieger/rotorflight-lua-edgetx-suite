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

  -- Compiled once, here where the box is rendered, rather than on every value change in the
  -- reactive sweep -- the argument for why that is the same answer is on Utils.renderThresholds.
  local compiledThresholds = nil
  if utils and type(utils.renderThresholds) == "function" then
    compiledThresholds = utils.renderThresholds(box, state, false, WHITE)
  end

  local colorRef = nil
  if utils and type(utils.staticTextColor) == "function" then
    colorRef = utils.staticTextColor(box, state, WHITE)
  end
  if colorRef == nil then
    local lastColorSecs = nil
    local cachedColor = nil
    colorRef = function()
      local totalSecs = (state and state.totalFlightSeconds) or 0
      if totalSecs == lastColorSecs and cachedColor ~= nil then
        return cachedColor
      end
      lastColorSecs = totalSecs
      if utils and type(utils.resolveTextColor) == "function" then
        cachedColor = utils.resolveTextColor(box, state, WHITE, totalSecs, nil, compiledThresholds)
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
