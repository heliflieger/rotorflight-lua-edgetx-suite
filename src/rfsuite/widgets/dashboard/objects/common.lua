if type(_G) == "table" and type(_G.__rfsuiteObjectsCommonModule) == "table" then
  return _G.__rfsuiteObjectsCommonModule
end

local Utils = {}

local i18nModule = nil
local i18nContext = nil
local i18nLocale = nil
local resolvedLocale = nil
local sensorsModule = nil
local localeModule = nil
local titleCache = {}

local function rgb(hex, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local r = math.floor(hex / 65536) % 256
    local g = math.floor(hex / 256) % 256
    local b = hex % 256
    local ok, col = pcall(lcd.RGB, r, g, b)
    if ok and col then return col end
  end
  return fallback
end

local COLOR_NAME_MAP = {
  black = BLACK,
  white = WHITE,
  red = RED,
  green = GREEN,
  yellow = YELLOW,
  grey = COLOR_THEME_SECONDARY2,
  gray = COLOR_THEME_SECONDARY2,
  orange = rgb(0xFF8000, 0xFF8000),
  blue = rgb(0x3399FF, 0x3399FF)
}

local function detectSimulator()
  if type(getVersion) ~= "function" then return false end
  local ok, _, fw = pcall(getVersion)
  if not ok or type(fw) ~= "string" then return false end
  return string.sub(string.lower(fw), -4) == "simu"
end

local IS_SIMULATOR = detectSimulator()

local function getLocaleModule()
  if localeModule then
    return localeModule
  end

  if type(_G) == "table" and type(_G.__rfsuite_system_locale_module) == "table" then
    localeModule = _G.__rfsuite_system_locale_module
    return localeModule
  end

  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then
      localeModule = mod
      if type(_G) == "table" then
        _G.__rfsuite_system_locale_module = mod
      end
    end
  end

  return localeModule
end

local function resolveLocale()
  if resolvedLocale and resolvedLocale ~= "" then
    return resolvedLocale
  end

  local mod = getLocaleModule()
  if mod and type(mod.resolveSystemLanguage) == "function" then
    local ok, locale = pcall(mod.resolveSystemLanguage, "en")
    if ok and type(locale) == "string" and locale ~= "" then
      resolvedLocale = locale
      return resolvedLocale
    end
  end

  resolvedLocale = "en"
  return resolvedLocale
end

local function getI18nContext()
  local locale = resolveLocale()
  if i18nContext and i18nLocale == locale then
    return i18nContext
  end

  if not i18nModule then
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/i18n/init.lua", "t")
    if chunk then
      local ok, mod = pcall(chunk)
      if ok and type(mod) == "table" and type(mod.new) == "function" then
        i18nModule = mod
      end
    end
  end

  if i18nModule and type(i18nModule.new) == "function" then
    local ok, ctx = pcall(i18nModule.new, locale)
    if ok and type(ctx) == "table" then
      i18nContext = ctx
      i18nLocale = locale
      return i18nContext
    end
  end

  return nil
end

function Utils.clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

function Utils.resolveValue(value, box, state)
  if type(value) == "function" then
    local ok, resolved = pcall(value, box, state)
    if ok then return resolved end
    return nil
  end
  return value
end

function Utils.normalizeTitle(raw, i18nCtx)
  if type(raw) ~= "string" or raw == "" then return nil end

  local ctxLocale = nil
  if type(i18nCtx) == "table" and type(i18nCtx.getLocale) == "function" then
    local ok, v = pcall(i18nCtx.getLocale)
    if ok and type(v) == "string" then ctxLocale = v end
  end

  local cacheLocale = ctxLocale or i18nLocale or resolveLocale()
  local cacheKey = cacheLocale .. "|" .. raw
  local cached = titleCache[cacheKey]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end

  if string.find(raw, "@i18n(", 1, true) then
    if i18nCtx and type(i18nCtx.resolve) == "function" then
      local ok, resolved = pcall(i18nCtx.resolve, raw)
      if ok and type(resolved) == "string" and resolved ~= "" then
        titleCache[cacheKey] = resolved
        return resolved
      end
    end

    if not IS_SIMULATOR then
      local i18n = getI18nContext()
      if i18n and type(i18n.resolve) == "function" then
        local ok, resolved = pcall(i18n.resolve, raw)
        if ok and type(resolved) == "string" and resolved ~= "" then
          titleCache[cacheKey] = resolved
          return resolved
        end
      end
    end
  end

  local token = string.match(raw, "@i18n%(([^)]+)%)")
  if token then
    local key = string.match(token, "([^.]+)$") or token
    if string.find(raw, ":upper%(", 1, false) then
      local out = string.upper(key)
      titleCache[cacheKey] = out
      return out
    end
    titleCache[cacheKey] = key
    return key
  end

  titleCache[cacheKey] = raw
  return raw
end

function Utils.toNumber(value, fallback)
  if type(value) == "number" then return value end
  return fallback
end

function Utils.mapTelemetrySource(source, state)
  if type(source) ~= "string" then return nil end

  if source == "model_name" then
    if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
      local name = _G.rfsuite.session.modelName
      if type(name) == "string" and name ~= "" then
        return name
      end
    end
    if model and type(model.getInfo) == "function" then
      local info = model.getInfo()
      if info and type(info.name) == "string" and info.name ~= "" then
        return info.name
      end
    end
    return "--"
  end

  -- Fast-path hot dashboard values from runtime state to avoid file/telemetry
  -- lookups in every refresh.
  if source == "pid_profile" then return state and state.profile end
  if source == "rate_profile" then return state and state.rateProfile end
  if source == "battery_profile" then return state and state.batteryProfile end
  if source == "link" then return state and state.lq end
  if source == "voltage" then return state and state.voltage end
  if source == "bec_voltage" then return state and state.bec_voltage end
  if source == "rpm" then return state and state.rpm end
  if source == "fuel" then return state and state.fuel end
  if source == "governor" then return state and state.governor end
  if source == "esc_temp" then return state and state.escTemp end
  if source == "mcu_temp" then return state and state.mcuTemp end
  if source == "throttle_percent" then return state and state.throttlePercent end
  if source == "current" then return state and state.current end
  if source == "watts" then return state and state.watts end
  if source == "altitude" then return state and state.altitude end
  if source == "smartfuel" then return state and state.fuel end
  if source == "smartconsumption" then return state and state.consumedMah end

  -- Load sensors module lazily
  if not sensorsModule then
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/sensors.lua", "t")
    if chunk then
      local ok, mod = pcall(chunk)
      if ok and type(mod) == "table" then
        sensorsModule = mod
      end
    end
  end

  if sensorsModule and type(sensorsModule.getValue) == "function" then
    local value = sensorsModule.getValue(source)
    if type(value) == "number" then return value end
  end

  return nil
end

function Utils.applyTransform(value, transform)
  if value == nil then return value end
  if transform == "floor" and type(value) == "number" then
    return math.floor(value)
  end
  if transform == "ceil" and type(value) == "number" then
    return math.ceil(value)
  end
  if transform == "round" and type(value) == "number" then
    return math.floor(value + 0.5)
  end
  if type(transform) == "number" and type(value) == "number" then
    return value * transform
  end
  return value
end

function Utils.formatDisplayValue(value, decimals)
  if value == nil then return "--" end
  if type(value) == "number" then
    if type(decimals) == "number" then
      return string.format("%." .. tostring(decimals) .. "f", value)
    end
    return tostring(math.floor(value + 0.5))
  end
  return tostring(value)
end

function Utils.appendUnit(valueText, unit)
  if unit == nil or unit == "" then return valueText end
  return valueText .. tostring(unit)
end

function Utils.normalizeAlign(align, fallback)
  if type(align) == "function" then
    return function()
      local a = align()
      if type(a) == "number" then return a end
      if type(a) == "string" then
        local token = string.lower(a)
        if token == "left" then return LEFT end
        if token == "right" then return RIGHT end
        if token == "center" or token == "centre" then return CENTER end
      end
      return fallback or CENTER
    end
  end
  if type(align) == "number" then return align end
  if type(align) ~= "string" then return fallback or CENTER end

  local token = string.lower(align)
  if token == "left" then return LEFT end
  if token == "right" then return RIGHT end
  if token == "center" or token == "centre" then return CENTER end
  return fallback or CENTER
end

function Utils.normalizeColor(color, fallback)
  if type(color) == "function" then
    return function()
      local c = color()
      if type(c) == "number" then return c end
      if type(c) == "string" then
        local mapped = COLOR_NAME_MAP[string.lower(c)]
        if type(mapped) == "number" then
          return mapped
        end
      end
      return fallback or WHITE
    end
  end
  if type(color) == "number" then return color end
  if type(color) == "string" then
    local mapped = COLOR_NAME_MAP[string.lower(color)]
    if type(mapped) == "number" then
      return mapped
    end
  end
  if type(fallback) == "number" then return fallback end
  return WHITE
end

function Utils.resolveTextColor(box, state, fallback)
  local color = Utils.resolveValue(box and box.textcolor, box, state)
  if type(color) == "number" then
    return color
  end

  local bgColor = Utils.resolveValue(box and box.bgcolor, box, state)
  if bgColor == BLACK or bgColor == COLOR_THEME_SECONDARY2 then
    return WHITE
  end

  if type(fallback) == "number" then
    return fallback
  end

  return WHITE
end

function Utils.pushLabel(nodes, x, y, w, text, color, align, font)
  nodes[#nodes + 1] = {
    type = "label",
    x = x,
    y = y,
    w = w,
    text = text,
    color = Utils.normalizeColor(color, WHITE),
    align = Utils.normalizeAlign(align, CENTER),
    font = font
  }
end

function Utils.isLowResolution(state)
  local w = tonumber(state and state.zoneW) or tonumber(LCD_W) or 0
  local h = tonumber(state and state.zoneH) or tonumber(LCD_H) or 0
  return (w > 0 and w <= 480) or (h > 0 and h <= 176)
end

function Utils.truncateText(text, maxChars)
  if type(text) ~= "string" then return text end
  local limit = tonumber(maxChars)
  if not limit or limit <= 0 then return text end
  if #text <= limit then return text end
  if limit <= 3 then
    return string.sub(text, 1, limit)
  end
  return string.sub(text, 1, limit - 3) .. "..."
end

function Utils.applyLowResMaxChars(text, box, state, prop)
  if not Utils.isLowResolution(state) then return text end
  local key = prop or "max_chars_lowres"
  local limit = Utils.resolveValue(box and box[key], box, state)
  return Utils.truncateText(text, limit)
end

function Utils.resolveFont(box, state, defaultFont, fontProp, lowResFontProp)
  local mainKey = fontProp or "font"
  local lowKey = lowResFontProp or "font_lowres"

  local font = Utils.resolveValue(box and box[mainKey], box, state)
  if Utils.isLowResolution(state) then
    local lowFont = Utils.resolveValue(box and box[lowKey], box, state)
    if lowFont ~= nil then
      return lowFont
    end
  end

  return font or defaultFont
end

function Utils.defaultValueY(rect, box)
  local titlePos = box and box.titlepos or "top"
  local valueY = rect.y + math.max(14, math.floor(rect.h * 0.45))
  if titlePos == "bottom" then
    valueY = rect.y + math.max(8, math.floor(rect.h * 0.35)) - 4
  end
  local valueOffsetY = Utils.toNumber(Utils.resolveValue(box and box.value_offset_y, box, nil), 0)
  valueY = valueY + valueOffsetY
  return valueY
end

function Utils.drawContainer(nodes, rect, box, state)
  nodes[#nodes + 1] = {
    type = "rectangle",
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
    color = box.bgcolor or WHITE,
    filled = true
  }

  -- Titel-Cache pro Box
  box._lastTitleRaw = box._lastTitleRaw or nil
  box._lastTitle = box._lastTitle or nil
  local rawTitle = Utils.resolveValue(box.title, box, state)
  if box._lastTitleRaw ~= rawTitle then
    box._lastTitle = Utils.normalizeTitle(rawTitle, state and state.i18n)
    box._lastTitleRaw = rawTitle
  end
  local title = box._lastTitle
  if not title then return end

  if Utils.isLowResolution(state) then
    local lowTitle = Utils.resolveValue(box.title_lowres, box, state)
    if type(lowTitle) == "string" and lowTitle ~= "" then
      title = lowTitle
    end
  end

  title = Utils.applyLowResMaxChars(title, box, state, "title_max_chars_lowres")

  local titlePos = box.titlepos or "top"
  local titleY = titlePos == "bottom" and (rect.y + rect.h - 24) or (rect.y + 4)
  local titleOffsetY = Utils.toNumber(Utils.resolveValue(box and box.title_offset_y, box, state), 0)
  if Utils.isLowResolution(state) then
    titleOffsetY = Utils.toNumber(
      Utils.resolveValue(box and box.title_offset_y_lowres, box, state),
      titleOffsetY
    )
  end
  titleY = titleY + titleOffsetY
  Utils.pushLabel(
    nodes,
    rect.x + 4,
    titleY,
    rect.w - 8,
    title,
    box.titlecolor or COLOR_THEME_DISABLED,
    box.titlealign or CENTER,
    Utils.resolveFont(box, state, SMLSIZE, "titlefont", "titlefont_lowres")
  )
end

if type(_G) == "table" then _G.__rfsuiteObjectsCommonModule = Utils end
return Utils
