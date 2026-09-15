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
  { col = 1, row = 1, colspan = 8, rowspan = 3, type = "image", subtype = "model", bgcolor = BLACK },
  { col = 1, row = 4, colspan = 4, rowspan = 3, type = "text", subtype = "governor", title = "@i18n(widgets.dashboard.governor):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, warningcolor = RED, bgcolor = BLACK, font = 0 },
  { col = 5, row = 4, colspan = 4, rowspan = 3, type = "text", subtype = "telemetry", source = "rpm", transform = "floor", title = "@i18n(widgets.dashboard.headspeed):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
  { col = 1, row = 7, colspan = 2, rowspan = 2, type = "text", subtype = "telemetry", source = "pid_profile", title = "@i18n(widgets.dashboard.profile):upper()@", title_lowres = "PROF", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 6 },
  { col = 3, row = 7, colspan = 2, rowspan = 2, type = "text", subtype = "telemetry", source = "rate_profile", title = "@i18n(widgets.dashboard.rates):upper()@", title_lowres = "RATE", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 6 },
  { col = 5, row = 7, colspan = 2, rowspan = 2, type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 6 },
  { col = 7, row = 7, colspan = 2, rowspan = 2, type = "text", subtype = "telemetry", source = "link", unit = "%", autosize_chars = 3, title = "@i18n(widgets.dashboard.lq):upper()@", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 4, max_chars_lowres = 5 },
  { col = 9, row = 7, colspan = 6, rowspan = 2, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.time):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 6 },
  { col = 9, row = 1, colspan = 6, rowspan = 6, type = "gauge", subtype = "arc", source = "smartfuel", unit = "%", decimals = 0, min = 0, max = 100, title = "@i18n(widgets.dashboard.battery):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, fillbgcolor = COLOR_THEME_SECONDARY2, value_offset_y = -4 },
  { col = 15, row = 1, colspan = 6, rowspan = 6, type = "gauge", subtype = "arc", source = "voltage", min = voltageMin, max = voltageMax, title = "@i18n(widgets.dashboard.voltage):upper()@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, fillbgcolor = COLOR_THEME_SECONDARY2, value_offset_y = -4 },
  { col = 15, row = 7, colspan = 6, rowspan = 2, type = "text", subtype = "blackbox", title = "@i18n(widgets.dashboard.blackbox):upper()@", titlepos = "bottom", autosize_chars = 10, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, font_lowres = SMLSIZE, title_max_chars_lowres = 8 }
}

return Theme
