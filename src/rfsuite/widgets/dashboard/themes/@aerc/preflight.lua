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

Theme.layout = { cols = 7, rows = 12, padding = 1, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, colspan = 3, rowspan = 9, type = "image", subtype = "model", bgcolor = BLACK },
  { col = 1, row = 10, colspan = 1, rowspan = 3, type = "text", subtype = "telemetry", source = "rate_profile", title = "@i18n(widgets.dashboard.rates):upper()@", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font = AercCommon.compactStatsFont, autosize_chars = 2, autosize_font = SMLSIZE },
  { col = 2, row = 10, colspan = 1, rowspan = 3, type = "text", subtype = "telemetry", source = "pid_profile", title = "@i18n(widgets.dashboard.profile):upper()@", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font = AercCommon.compactStatsFont, autosize_chars = 2, autosize_font = SMLSIZE },
  { col = 3, row = 10, colspan = 1, rowspan = 3, type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font = AercCommon.compactStatsFont, autosize_chars = 3, autosize_font = SMLSIZE },
  AercCommon and AercCommon.batteryBar and AercCommon.batteryBar("smartfuel", {
    col = 4,
    row = 1,
    colspan = 4,
    rowspan = 3,
    title = "@i18n(widgets.dashboard.battery):upper()@",
    titlepos = "bottom"
  }),
  {
    col = 4,
    row = 4,
    colspan = 2,
    rowspan = 6,
    type = "gauge",
    subtype = "arc",
    source = "bec_voltage",
    unit = "V",
    title = "@i18n(widgets.dashboard.bec_voltage):upper()@",
    titlepos = "bottom",
    min = function(_, state) return cfgValue("bec_min", 3.0, state) end,
    max = function(_, state) return cfgValue("bec_max", 13.0, state) end,
    -- `bec_min` and `bec_max` are the scale, above; `bec_warn` is the one of the three that is
    -- a warning level, so it is the one the fill colour is keyed on. Without a threshold list
    -- the arc falls into the generic fill.
    thresholds = {
      { value = function(_, state) return cfgValue("bec_warn", 6.0, state) end, fillcolor = RED },
      { value = 1000, fillcolor = GREEN }
    },
    decimals = 1,
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    bgcolor = BLACK,
    fillbgcolor = COLOR_THEME_SECONDARY2,
    value_font = AercCommon.gaugeValueFont,
    value_offset_y = AercCommon.gaugeValueOffset
  },
  {
    col = 4,
    row = 10,
    colspan = 2,
    rowspan = 3,
    type = "text",
    subtype = "blackbox",
    title = "@i18n(widgets.dashboard.blackbox):upper()@",
    titlepos = "bottom",
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    bgcolor = BLACK,
    autosize_chars = 10,
    font = AercCommon.compactStatsFont
  },
  {
    col = 6,
    row = 4,
    colspan = 2,
    rowspan = 6,
    type = "gauge",
    subtype = "arc",
    source = "esc_temp",
    unit = "°C",
    title = "@i18n(widgets.dashboard.esc_temp):upper()@",
    titlepos = "bottom",
    min = 20,
    max = function(_, state) return cfgValue("esctemp_max", 140, state) end,
    unit = "°C",
    transform = "floor",
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    bgcolor = BLACK,
    fillbgcolor = COLOR_THEME_SECONDARY2,
    value_font = AercCommon.gaugeValueFont,
    value_offset_y = AercCommon.gaugeValueOffset
  },
  {
    col = 6,
    row = 10,
    colspan = 2,
    rowspan = 3,
    type = "text",
    subtype = "governor",
    title = "@i18n(widgets.dashboard.governor):upper()@",
    titlepos = "bottom",
    titlecolor = COLOR_THEME_DISABLED,
    textcolor = WHITE,
    warningcolor = RED,
    activecolor = GREEN,
    bgcolor = BLACK
  }
}

return Theme
