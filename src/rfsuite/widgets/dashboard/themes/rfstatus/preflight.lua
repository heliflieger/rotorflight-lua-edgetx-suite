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
  { col = 1, row = 1, colspan = 6, rowspan = 3, type = "image", subtype = "model", bgcolor = BLACK },
  { col = 7, row = 1, colspan = 7, rowspan = 3, type = "text", subtype = "telemetry", source = "voltage", decimals = 1, unit = "V", title = "@i18n(widgets.dashboard.voltage):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, value_offset_y = -2 },
  { col = 14, row = 1, colspan = 7, rowspan = 3, type = "text", subtype = "telemetry", source = "smartfuel", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.battery):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, value_offset_y = -2 },
  { col = 1, row = 4, colspan = 3, rowspan = 2, type = "text", subtype = "telemetry", source = "link", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.lq):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 4 },
  { col = 4, row = 4, colspan = 3, rowspan = 2, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.timer):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 5 },
  { col = 1, row = 6, colspan = 6, rowspan = 3, type = "text", subtype = "governor", title = "@i18n(widgets.dashboard.governor):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, activecolor = WHITE, warningcolor = RED, max_chars_lowres = 10 },
  { col = 7, row = 4, colspan = 7, rowspan = 5, type = "text", subtype = "telemetry", source = "current", unit = "A", transform = "floor", title = "@i18n(widgets.dashboard.current):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, title_max_chars_lowres = 6 },
  { col = 14, row = 4, colspan = 7, rowspan = 5, type = "text", subtype = "telemetry", source = "rpm", unit = "rpm", transform = "floor", title = "@i18n(widgets.dashboard.rpm):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, title_max_chars_lowres = 4 }
}

return Theme