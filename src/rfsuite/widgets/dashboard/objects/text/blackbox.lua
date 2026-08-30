local Render = {}

function Render.render(nodes, rect, box, state, themeCommon, utils)
  local lastArmed = nil
  local lastDfUsed = nil
  local lastDfTotal = nil
  local lastHadArmed = nil
  local cachedText = nil

  local textGetter = function()
    local armed = state and state.armed
    local df = state and state.dataflash
    local dfUsed = df and df.used
    local dfTotal = df and df.total
    local hadArmed = state and state.hadArmedFlight

    if armed == lastArmed and dfUsed == lastDfUsed and dfTotal == lastDfTotal and hadArmed == lastHadArmed and cachedText ~= nil then
      return cachedText
    end

    lastArmed = armed
    lastDfUsed = dfUsed
    lastDfTotal = dfTotal
    lastHadArmed = hadArmed

    local valueText = nil
    if themeCommon and type(themeCommon.blackboxLabel) == "function" then
      local ok, res = pcall(themeCommon.blackboxLabel, state)
      if ok and res ~= nil then valueText = res end
    end
    if valueText == nil then
      valueText = (state and state.armed) and "REC" or ((state and state.hadArmedFlight) and "LOGGED" or "READY")
    end
    if utils and type(utils.applyLowResMaxChars) == "function" then
      valueText = utils.applyLowResMaxChars(valueText, box, state, "max_chars_lowres")
    end
    cachedText = valueText or "--"
    return cachedText
  end

  local lastFontText = nil
  local cachedFont = nil

  local fontGetter = function()
    local valueText = textGetter()
    if valueText == lastFontText and cachedFont ~= nil then
      return cachedFont
    end
    lastFontText = valueText

    local autoSizeChars = (utils and type(utils.resolveValue) == "function") and utils.resolveValue(box.autosize_chars, box, state) or box.autosize_chars
    if type(autoSizeChars) == "number" and type(valueText) == "string" and #valueText > autoSizeChars then
      local autoSizeFont = (utils and type(utils.resolveValue) == "function") and utils.resolveValue(box.autosize_font, box, state) or box.autosize_font
      cachedFont = autoSizeFont or SMLSIZE
      return cachedFont
    end
    if utils and type(utils.resolveFont) == "function" then
      cachedFont = utils.resolveFont(box, state, MIDSIZE, "font", "font_lowres")
    else
      cachedFont = (box and box.font) or MIDSIZE
    end
    return cachedFont
  end

  local colorGetter = function()
    if utils and type(utils.resolveTextColor) == "function" then
      return utils.resolveTextColor(box, state, WHITE)
    end
    return (box and box.textcolor) or WHITE
  end

  if utils and type(utils.pushLabel) == "function" then
    utils.pushLabel(
      nodes,
      rect.x + 4,
      (utils.defaultValueY and utils.defaultValueY(rect, box)) or (rect.y + 4),
      rect.w - 8,
      textGetter,
      colorGetter,
      box.valuealign or box.titlealign or CENTER,
      fontGetter
    )
  end
end

return Render
