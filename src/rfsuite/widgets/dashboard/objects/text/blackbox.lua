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

  -- Without autosize_chars the font never depends on the text, so a font that is not a function
  -- leaves nothing for a getter to answer -- and the label's text is then computed once per pass
  -- rather than twice, since this getter calls textGetter as well.
  local fontRef = nil
  if box and box.autosize_chars == nil and utils and type(utils.staticFont) == "function" then
    fontRef = utils.staticFont(box, state, MIDSIZE, "font", "font_lowres")
  end
  if fontRef == nil then
    local lastFontText = nil
    local cachedFont = nil

    fontRef = function()
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
    local lastColorPct = nil
    local cachedColor = nil
    colorRef = function()
      local pct = nil
      local df = state and state.dataflash
      if df and type(df.total) == "number" and df.total > 0 then
        pct = ((df.used or 0) / df.total) * 100
      end
      if pct == lastColorPct and cachedColor ~= nil then
        return cachedColor
      end
      lastColorPct = pct
      if utils and type(utils.resolveTextColor) == "function" then
        cachedColor = utils.resolveTextColor(box, state, WHITE, pct, nil, compiledThresholds)
        return cachedColor
      end
      cachedColor = (box and box.textcolor) or WHITE
      return cachedColor
    end
  end

  if utils and type(utils.pushLabel) == "function" then
    utils.pushLabel(
      nodes,
      rect.x + 4,
      (utils.defaultValueY and utils.defaultValueY(rect, box)) or (rect.y + 4),
      rect.w - 8,
      textGetter,
      colorRef,
      box.valuealign or box.titlealign or CENTER,
      fontRef
    )
  end
end

return Render
