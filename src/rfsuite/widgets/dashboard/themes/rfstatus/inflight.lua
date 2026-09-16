local Theme = {}

local function voltageMin(_, state)
  local cfg = state and state.themeConfig or nil
  return tonumber(cfg and cfg.v_min) or 18.0
end

local function voltageMax(_, state)
  local cfg = state and state.themeConfig or nil
  return tonumber(cfg and cfg.v_max) or 25.2
end

Theme.layout = { cols = 20, rows = 8, padding = 2, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, colspan = 10, rowspan = 6, type = "gauge", subtype = "arc", source = "voltage", min = voltageMin, max = voltageMax, title = "@i18n(widgets.dashboard.voltage):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, fillbgcolor = COLOR_THEME_SECONDARY2, value_offset_y = -4 },
  { col = 11, row = 1, colspan = 10, rowspan = 6, type = "gauge", subtype = "arc", source = "smartfuel", unit = "%", decimals = 0, min = 0, max = 100, title = "@i18n(widgets.dashboard.battery):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, fillbgcolor = COLOR_THEME_SECONDARY2, value_offset_y = -4 },
  { col = 1, row = 7, colspan = 5, rowspan = 2, type = "text", subtype = "governor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, activecolor = WHITE, warningcolor = RED, font_lowres = SMLSIZE, max_chars_lowres = 10 },
  { col = 6, row = 7, colspan = 5, rowspan = 2, type = "text", subtype = "telemetry", source = "link", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.lq):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 4 },
  { col = 11, row = 7, colspan = 5, rowspan = 2, type = "text", subtype = "telemetry", source = "rpm", unit = "rpm", transform = "floor", title = "@i18n(widgets.dashboard.rpm):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 4 },
  { col = 16, row = 7, colspan = 5, rowspan = 2, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.timer):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 5 }
}

return Theme