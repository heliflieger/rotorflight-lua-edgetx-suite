if type(_G) == "table" and type(_G.__rfsuiteThemeAercCommonModule) == "table" then
  return _G.__rfsuiteThemeAercCommonModule
end

local Common = {}

local LOGO_FILE = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/gfx/logo.png"

local i18nModule = nil
local i18nContext = nil
local i18nLocale = nil
local localeModule = nil

local function getLocaleModule()
  if localeModule then
    return localeModule
  end

  if type(_G) == "table" and type(_G.__rfsuite_system_locale_module) == "table" then
    localeModule = _G.__rfsuite_system_locale_module
    return localeModule
  end

  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("lib/system_locale.lua")
    if mod and type(mod) == "table" then
      localeModule = mod
      return localeModule
    end
  end

  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", mode)
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
  local mod = getLocaleModule()
  if mod and type(mod.resolveSystemLanguage) == "function" then
    local ok, locale = pcall(mod.resolveSystemLanguage, "en")
    if ok and type(locale) == "string" and locale ~= "" then
      return locale
    end
  end

  return "en"
end

local function getI18nContext()
  local locale = resolveLocale()
  if i18nContext and i18nLocale == locale then
    return i18nContext
  end

  if not i18nModule then
    if _G.rfsuite and type(_G.rfsuite.require) == "function" then
      local mod = _G.rfsuite.require("i18n/init.lua")
      if mod and type(mod) == "table" and type(mod.new) == "function" then
        i18nModule = mod
      end
    end
    if not i18nModule then
      local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/i18n/init.lua", mode)
      if chunk then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" and type(mod.new) == "function" then
          i18nModule = mod
        end
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

local function t(key, fallback)
  local ctx = getI18nContext()
  if ctx and type(ctx.t) == "function" then
    local ok, translated = pcall(ctx.t, key)
    if ok and type(translated) == "string" and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback or key
end

local function append(nodes, extra)
  for index = 1, #extra do
    nodes[#nodes + 1] = extra[index]
  end
end

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function merge(dst, src)
  if type(src) ~= "table" then return dst end
  for key, value in pairs(src) do
    dst[key] = value
  end
  return dst
end

local function isTx16Mk3(state)
  local w = tonumber(state and state.zoneW) or tonumber(_G and _G.LCD_W) or 0
  return w >= 760
end

function Common.isCompactDisplay(state)
  return not isTx16Mk3(state)
end

function Common.compactStatsFont(_, state)
  if isTx16Mk3(state) then
    return MIDSIZE
  end
  return SMLSIZE
end

function Common.gaugeValueFont(_, state)
  if isTx16Mk3(state) then
    return DBLSIZE
  end
  return MIDSIZE
end

function Common.gaugeValueOffset(_, state)
  if isTx16Mk3(state) then
    return 0
  end
  return -10
end

function Common.batteryBar(source, overrides)
  local box = {
    type = "gauge",
    subtype = "bar",
    source = source or "smartfuel",
    unit = "%",
    min = 0,
    max = 100,
    transform = "floor",
    valuealign = LEFT,
    valuepaddingleft = 8,
    valuepaddingtop = function(_, state)
      if isTx16Mk3(state) then
        return -25
      end
      return -6
    end,
    title_offset_y = function(_, state)
      if isTx16Mk3(state) then
        return 0
      end
      return 8
    end,
    valuefont = function(_, state)
      if isTx16Mk3(state) then
        return DBLSIZE
      end
      return SMLSIZE
    end,
    battadv = true,
    battadvsingleline = function(_, state)
      return Common.isCompactDisplay(state)
    end,
    battadvvaluealign = RIGHT,
    battadvpaddingright = function(_, state)
      if isTx16Mk3(state) then
        return 12
      end
      return 8
    end,
    battadvpaddingtop = function(_, state)
      if isTx16Mk3(state) then
        return 0
      end
      return -1
    end,
    battadvfont = function(_, state)
      if isTx16Mk3(state) then
        return 0
      end
      return SMLSIZE
    end,
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    bgcolor = BLACK,
    fillbgcolor = COLOR_THEME_SECONDARY2,
    thresholds = {
      { value = 10, fillcolor = RED },
      { value = 45, fillcolor = YELLOW }
    }
  }

  return merge(box, overrides)
end

Common.LOGO_FILE = LOGO_FILE
Common.t = t
Common.append = append
Common.clamp = clamp

if type(_G) == "table" then
  _G.__rfsuiteThemeAercCommonModule = Common
end

return Common
