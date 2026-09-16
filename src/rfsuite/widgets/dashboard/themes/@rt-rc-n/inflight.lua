local Theme = {}

local function voltageMin(_, state)
  local cfg = state and state.themeConfig or nil
  return tonumber(cfg and cfg.v_min) or 7.0
end

local function voltageMax(_, state)
  local cfg = state and state.themeConfig or nil
  return tonumber(cfg and cfg.v_max) or 8.4
end

Theme.layout = { cols = 8, rows = 14, padding = 2, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, colspan = 4, rowspan = 12, type = "gauge", subtype = "arc", source = "bec_voltage", unit = "V", decimals = 2, min = voltageMin, max = voltageMax, title = "@i18n(widgets.dashboard.voltage):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, fillbgcolor = COLOR_THEME_SECONDARY2 },
  { col = 5, row = 1, colspan = 4, rowspan = 12, type = "gauge", subtype = "arc", source = "throttle_percent", unit = "%", decimals = 0, min = 0, max = 100, title = "@i18n(widgets.dashboard.throttle):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, fillbgcolor = COLOR_THEME_SECONDARY2 },
  { col = 1, row = 13, colspan = 2, rowspan = 2, type = "text", subtype = "governor", bgcolor = BLACK, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, activecolor = WHITE, warningcolor = RED, font_lowres = SMLSIZE, max_chars_lowres = 8, value_offset_y = -6 },
  { col = 3, row = 13, colspan = 2, rowspan = 2, type = "text", subtype = "telemetry", source = "link", unit = "%", transform = "floor", bgcolor = BLACK, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, font_lowres = SMLSIZE, value_offset_y = -6 },
  { col = 5, row = 13, colspan = 2, rowspan = 2, type = "text", subtype = "telemetry", source = "rpm", unit = "rpm", transform = "floor", bgcolor = BLACK, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, font_lowres = SMLSIZE, value_offset_y = -6 },
  { col = 7, row = 13, colspan = 2, rowspan = 2, type = "time", subtype = "flight", bgcolor = BLACK, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, font_lowres = SMLSIZE, value_offset_y = -6 }
}

return Theme
