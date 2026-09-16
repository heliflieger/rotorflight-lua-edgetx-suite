if type(_G) == "table" and type(_G.__rfsuiteThemeDefaultCommonModule) == "table" then
  return _G.__rfsuiteThemeDefaultCommonModule
end

local Common = {}

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

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function asNumber(value, fallback)
  if type(value) == "number" then
    return value
  end
  return fallback
end

function Common.getVoltageColor(state)
  local cfg = state and state.themeConfig or nil
  local vMin = tonumber(cfg and cfg.v_min) or 18.0
  local vMax = tonumber(cfg and cfg.v_max) or 25.2
  local value = tonumber(state and state.voltage) or 0
  if value <= 0 then return BLACK end
  if value < vMin or value > vMax then return COLOR_THEME_WARNING end
  return COLOR_THEME_PRIMARY1
end

function Common.estimateCellCount(state)
  local stateCells = tonumber(state and state.batteryCellCount)
  if stateCells and stateCells > 0 then
    return clamp(math.floor(stateCells + 0.5), 1, 14)
  end

  local cfg = state and state.themeConfig or nil
  local vMax = tonumber(cfg and cfg.v_max) or 25.2
  local cells = math.floor((vMax / 4.2) + 0.5)
  return clamp(cells, 1, 14)
end

function Common.formatDuration(seconds)
  local value = math.max(0, math.floor(asNumber(seconds, 0) + 0.5))
  local hours = math.floor(value / 3600)
  local minutes = math.floor((value % 3600) / 60)
  local secs = value % 60
  if hours > 0 then
    return string.format("%d:%02d", hours, minutes)
  end
  return string.format("%02d:%02d", minutes, secs)
end

function Common.formatVoltage(value)
  local numeric = asNumber(value, 0)
  if numeric <= 0 then
    return "--.-V"
  end
  return string.format("%.1fV", numeric)
end

function Common.formatCellVoltage(state, value)
  local numeric = asNumber(value, 0)
  if numeric <= 0 then
    return "--.-V/c"
  end
  return string.format("%.2fV/c", numeric / Common.estimateCellCount(state))
end

function Common.formatInteger(value, suffix)
  if type(value) ~= "number" then
    return "--"
  end
  local text = tostring(math.floor(value + 0.5))
  if suffix and suffix ~= "" then
    text = text .. suffix
  end
  return text
end

function Common.blackboxLabel(state)
  if state and state.armed then return t("widgets.dashboard.bb_rec", "REC") end

  if state and state.dataflash and type(state.dataflash.total) == "number" and state.dataflash.total > 0 then
    -- Convert bytes to MB (using 1048576 = 1024 * 1024)
    local usedMB = (state.dataflash.used or 0) / 1048576
    local totalMB = state.dataflash.total / 1048576
    return string.format("%.1f/%.0fMB", usedMB, totalMB)
  end

  if state and state.hadArmedFlight then return t("widgets.dashboard.bb_logged", "LOGGED") end
  return t("widgets.dashboard.bb_ready", "READY")
end

function Common.statusLabel(state)
  if state and state.armed then return t("widgets.dashboard.status_armed", "ARMED") end
  return t("widgets.dashboard.status_disarmed", "DISARMED")
end

function Common.statusColor(state)
  if state and state.armed then return COLOR_THEME_WARNING end
  return COLOR_THEME_SECONDARY1
end

if type(_G) == "table" then _G.__rfsuiteThemeDefaultCommonModule = Common end
return Common