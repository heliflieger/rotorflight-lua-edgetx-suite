local Theme = {}

Theme.layout = { cols = 3, rows = 3, padding = 2, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.flight_duration)@", titlepos = "bottom", bgcolor = BLACK, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE },
  { col = 2, row = 1, type = "text", subtype = "stats", source = "min_link", unit = "%", title = "@i18n(widgets.dashboard.link_min)@", titlepos = "bottom", bgcolor = BLACK, textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED },
  { col = 3, row = 1, type = "text", subtype = "telemetry", source = "bec_voltage", unit = "V", decimals = 2, title = "@i18n(widgets.dashboard.voltage)@", titlepos = "bottom", bgcolor = BLACK, unitpos = "right", textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED },
  { col = 1, row = 2, type = "time", subtype = "total", title = "@i18n(widgets.dashboard.total_flight_duration)@", titlepos = "bottom", bgcolor = BLACK, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE },
  { col = 2, row = 2, type = "text", subtype = "stats", stattype = "max", source = "link", unit = "%", title = "@i18n(widgets.dashboard.link_max)@", titlepos = "bottom", bgcolor = BLACK, transform = "floor", textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED },
  { col = 3, row = 2, type = "text", subtype = "stats", source = "min_voltage_cell", title = "@i18n(widgets.dashboard.min_volts_cell)@", titlepos = "bottom", bgcolor = BLACK, textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED },
  { col = 1, row = 3, type = "text", subtype = "stats", stattype = "min", source = "rpm", title = "@i18n(widgets.dashboard.rpm_min)@", unit = " rpm", titlepos = "bottom", bgcolor = BLACK, transform = "floor", textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED },
  { col = 2, row = 3, type = "text", subtype = "stats", stattype = "max", source = "rpm", title = "@i18n(widgets.dashboard.rpm_max)@", unit = " rpm", titlepos = "bottom", bgcolor = BLACK, transform = "floor", textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED },
  { col = 3, row = 3, type = "text", subtype = "stats", stattype = "max", source = "throttle_percent", title = "@i18n(widgets.dashboard.throttle_max)@", unit = "%", titlepos = "bottom", bgcolor = BLACK, transform = "floor", textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED }
}

return Theme
