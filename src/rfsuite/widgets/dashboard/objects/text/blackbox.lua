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

    local valueText = themeCommon.blackboxLabel(state)
    valueText = utils.applyLowResMaxChars(valueText, box, state, "max_chars_lowres")
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

    local autoSizeChars = utils.resolveValue(box.autosize_chars, box, state)
    if type(autoSizeChars) == "number" and type(valueText) == "string" and #valueText > autoSizeChars then
      local autoSizeFont = utils.resolveValue(box.autosize_font, box, state)
      cachedFont = autoSizeFont or SMLSIZE
      return cachedFont
    end
    cachedFont = utils.resolveFont(box, state, MIDSIZE, "font", "font_lowres")
    return cachedFont
  end

  local colorGetter = function()
    return utils.resolveTextColor(box, state, WHITE)
  end

  utils.pushLabel(
    nodes,
    rect.x + 4,
    utils.defaultValueY(rect, box),
    rect.w - 8,
    textGetter,
    colorGetter,
    box.valuealign or box.titlealign or CENTER,
    fontGetter
  )
end

return Render
