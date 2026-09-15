local Theme = {}

local function loadAercCommon()
  if type(_G) == "table" and type(_G.__rfsuiteThemeAercCommonModule) == "table" then
    return _G.__rfsuiteThemeAercCommonModule
  end

  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("widgets/dashboard/themes/@aerc/common.lua")
    if mod and type(mod) == "table" then
      return mod
    end
  end

  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/@aerc/common.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then
    return mod
  end
  return nil
end

local AercCommon = loadAercCommon() or {}

local function cfgValue(key, fallback, state)
  local cfg = state and state.themeConfig or nil
  local value = cfg and cfg[key] or nil
  if type(value) == "number" then
    return value
  end
  return fallback
end

Theme.layout = { cols = 3, rows = 10, padding = 1, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, colspan = 1, rowspan = 2, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.flight_time):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font = AercCommon.compactStatsFont, value_offset_y = -6 },
  AercCommon and AercCommon.batteryBar and AercCommon.batteryBar("fuel", {
    col = 2,
    row = 1,
    colspan = 2,
    rowspan = 2,
    title = "@i18n(widgets.dashboard.battery):upper()@",
    titlepos = "bottom",
    title_offset_y = function(_, state)
      if AercCommon and AercCommon.isCompactDisplay and AercCommon.isCompactDisplay(state) then
        return 8
      end
      return 0
    end,
    battadvsingleline = true
  }),
  {
    col = 1,
    row = 3,
    colspan = 1,
    rowspan = 8,
    type = "gauge",
    subtype = "arc",
    source = "throttle_percent",
    arcmax = true,
    maxprefix = "Max: ",
    title = "@i18n(widgets.dashboard.throttle):upper()@",
    titlepos = "bottom",
    unit = "%",
    min = 0,
    max = 100,
    transform = "floor",
    maxtextcolor = "orange",
    maxposition = "bottom",
    maxalign = CENTER,
    maxpaddingbottom = 26,
    maxpaddingleft = 0,
    maxpaddingright = 0,
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    bgcolor = BLACK,
    fillbgcolor = COLOR_THEME_SECONDARY2,
    value_font = AercCommon.gaugeValueFont,
    value_offset_y = AercCommon.gaugeValueOffset
  },
  {
    col = 2,
    row = 3,
    colspan = 1,
    rowspan = 8,
    type = "gauge",
    subtype = "arc",
    source = "rpm",
    arcmax = true,
    maxprefix = "Max: ",
    title = "@i18n(widgets.dashboard.headspeed):upper()@",
    titlepos = "bottom",
    min = 0,
    max = function(_, state) return cfgValue("rpm_max", 3000, state) end,
    transform = "floor",
    maxtextcolor = "orange",
    maxposition = "bottom",
    maxalign = CENTER,
    maxpaddingbottom = 26,
    maxpaddingleft = 0,
    maxpaddingright = 0,
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    bgcolor = BLACK,
    fillbgcolor = COLOR_THEME_SECONDARY2,
    value_font = AercCommon.gaugeValueFont,
    value_offset_y = AercCommon.gaugeValueOffset
  },
  {
    col = 3,
    row = 3,
    colspan = 1,
    rowspan = 8,
    type = "gauge",
    subtype = "arc",
    source = "esc_temp",
    arcmax = true,
    maxprefix = "Max: ",
    title = "@i18n(widgets.dashboard.esc_temp):upper()@",
    titlepos = "bottom",
    unit = "°C",
    min = 20,
    max = function(_, state) return cfgValue("esctemp_max", 140, state) end,
    transform = "floor",
    maxtextcolor = "orange",
    maxposition = "bottom",
    maxalign = CENTER,
    maxpaddingbottom = 26,
    maxpaddingleft = 0,
    maxpaddingright = 0,
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    bgcolor = BLACK,
    fillbgcolor = COLOR_THEME_SECONDARY2,
    value_font = AercCommon.gaugeValueFont,
    value_offset_y = AercCommon.gaugeValueOffset
  }
}

return Theme
