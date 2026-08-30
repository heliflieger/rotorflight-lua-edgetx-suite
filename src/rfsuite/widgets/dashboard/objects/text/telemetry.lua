local Render = {}

local boxConfigCache = setmetatable({}, { __mode = "k" })

local FAST_STATE_SOURCES = {
  pid_profile = "profile",
  rate_profile = "rateProfile",
  battery_profile = "batteryProfile",
  link = "lq",
  voltage = "voltage",
  rpm = "rpm",
  fuel = "fuel",
  governor = "governor",
  esc_temp = "escTemp",
  mcu_temp = "mcuTemp"
}

local function compileBoxConfig(box)
  local cfg = {
    source = box and box.source or nil,
    sourceDynamic = type(box and box.source) == "function",
    transform = box and box.transform or nil,
    transformDynamic = type(box and box.transform) == "function",
    decimals = box and box.decimals or nil,
    decimalsDynamic = type(box and box.decimals) == "function",
    unit = box and box.unit or nil,
    unitDynamic = type(box and box.unit) == "function",
    font = box and box.font or nil,
    fontDynamic = type(box and box.font) == "function",
    fontLowRes = box and box.font_lowres or nil,
    fontLowResDynamic = type(box and box.font_lowres) == "function",
    autoSizeChars = box and box.autosize_chars or nil,
    autoSizeCharsDynamic = type(box and box.autosize_chars) == "function",
    autoSizeFont = box and box.autosize_font or nil,
    autoSizeFontDynamic = type(box and box.autosize_font) == "function"
  }
  boxConfigCache[box] = cfg
  return cfg
end

local function getBoxConfig(box)
  local cfg = box and boxConfigCache[box] or nil
  if cfg then return cfg end
  return compileBoxConfig(box)
end

local function mapSourceFast(source, state, utils)
  if type(source) ~= "string" then
    return nil
  end

  local stateKey = FAST_STATE_SOURCES[source]
  if stateKey and type(state) == "table" then
    local direct = state[stateKey]
    if direct ~= nil then
      return direct
    end
  end

  return utils.mapTelemetrySource(source, state)
end

local function useFahrenheit()
  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local localizations = prefs and prefs.localizations or nil
  return tonumber(localizations and localizations.temperature_unit) == 1
end

function Render.render(nodes, rect, box, state, themeCommon, utils)
  local cfg = getBoxConfig(box)
  local lastRaw = nil
  local lastSource = nil
  local lastUnit = nil
  local lastDecimals = nil
  local lastTransform = nil
  local cachedText = nil

  local textGetter = function()
    local source = cfg.source
    if cfg.sourceDynamic then
      source = utils.resolveValue(source, box, state)
    end

    local raw = source ~= nil and mapSourceFast(source, state, utils) or nil

    local unit = cfg.unit
    if cfg.unitDynamic then
      unit = utils.resolveValue(unit, box, state)
    end

    local isTemp = (source == "esc_temp" or source == "mcu_temp")
    local isFahr = isTemp and useFahrenheit()
    if isTemp then
      if isFahr and type(raw) == "number" then
        raw = (raw * 9 / 5) + 32
        unit = "°F"
      else
        unit = "°C"
      end
    end

    local transform = cfg.transform
    if cfg.transformDynamic then
      transform = utils.resolveValue(transform, box, state)
    end
    raw = utils.applyTransform(raw, transform)

    local decimals = cfg.decimals
    if cfg.decimalsDynamic then
      decimals = utils.resolveValue(decimals, box, state)
    end

    if raw == lastRaw and source == lastSource and unit == lastUnit and decimals == lastDecimals and transform == lastTransform and cachedText ~= nil then
      return cachedText
    end

    lastRaw = raw
    lastSource = source
    lastUnit = unit
    lastDecimals = decimals
    lastTransform = transform

    local valueText = nil
    if source == "voltage" and themeCommon and type(themeCommon.formatVoltage) == "function" then
      local ok, res = pcall(themeCommon.formatVoltage, raw)
      if ok and res ~= nil then valueText = res end
    end

    if valueText == nil then
      valueText = utils.formatDisplayValue(raw, decimals)
      valueText = utils.appendUnit(valueText, unit)
    end

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

    local autoSizeChars = cfg.autoSizeChars
    if cfg.autoSizeCharsDynamic then
      autoSizeChars = utils.resolveValue(autoSizeChars, box, state)
    end

    if type(autoSizeChars) == "number" and type(valueText) == "string" and #valueText > autoSizeChars then
      local autoSizeFont = cfg.autoSizeFont
      if cfg.autoSizeFontDynamic then
        autoSizeFont = utils.resolveValue(autoSizeFont, box, state)
      end
      cachedFont = autoSizeFont or SMLSIZE
      return cachedFont
    end

    local valueFont = cfg.font
    if cfg.fontDynamic then
      valueFont = utils.resolveValue(valueFont, box, state)
    end
    if utils.isLowResolution(state) then
      local lowFont = cfg.fontLowRes
      if cfg.fontLowResDynamic then
        lowFont = utils.resolveValue(lowFont, box, state)
      end
      if lowFont ~= nil then
        valueFont = lowFont
      end
    end
    cachedFont = valueFont or MIDSIZE
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
