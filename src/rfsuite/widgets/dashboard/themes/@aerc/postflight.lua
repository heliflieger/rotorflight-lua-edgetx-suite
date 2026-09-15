local Theme = {}

Theme.layout = { cols = 3, rows = 8, padding = 1, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, colspan = 1, rowspan = 2, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.flight_duration)@", titlepos = "top", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 1, row = 3, colspan = 1, rowspan = 2, type = "time", subtype = "total", title = "@i18n(widgets.dashboard.total_flight_duration)@", titlepos = "top", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 1, row = 5, colspan = 1, rowspan = 2, type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 1, row = 7, colspan = 1, rowspan = 2, type = "text", subtype = "stats", stattype = "max", source = "rpm", unit = " rpm", title = "@i18n(widgets.dashboard.rpm_max)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },

  { col = 2, row = 1, colspan = 1, rowspan = 2, type = "text", subtype = "stats", stattype = "max", source = "watts", unit = "W", title = "@i18n(widgets.dashboard.watts_max)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 2, row = 3, colspan = 1, rowspan = 2, type = "text", subtype = "stats", stattype = "max", unit = "A", source = "current", title = "@i18n(widgets.dashboard.current_max)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 2, row = 5, colspan = 1, rowspan = 2, type = "text", subtype = "stats", stattype = "max", unit = "°C", source = "esc_temp", title = "@i18n(widgets.dashboard.esc_max_temp)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 2, row = 7, colspan = 1, rowspan = 2, type = "text", subtype = "stats", stattype = "max", unit = "m", source = "altitude", title = "@i18n(widgets.dashboard.altitude_max)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },

  { col = 3, row = 1, colspan = 1, rowspan = 2, type = "text", subtype = "stats", stattype = "max", unit = "mAh", source = "smartconsumption", title = "@i18n(widgets.dashboard.consumed_mah)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 3, row = 3, colspan = 1, rowspan = 2, type = "text", subtype = "stats", stattype = "min", unit = "%", source = "smartfuel", title = "@i18n(widgets.dashboard.fuel_remaining)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 3, row = 5, colspan = 1, rowspan = 2, type = "text", subtype = "telemetry", source = "voltage", title = "@i18n(widgets.dashboard.volts_per_cell)@", titlepos = "top", unit = "V", decimals = 2, titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 3, row = 7, colspan = 1, rowspan = 2, type = "text", subtype = "stats", source = "min_link", title = "@i18n(widgets.dashboard.link_min)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK }
}

return Theme
