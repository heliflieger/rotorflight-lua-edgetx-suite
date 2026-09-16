--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local Theme = {}

Theme.layout = { cols = 6, rows = 12, bgcolor = WHITE }

Theme.boxes = {
  -- Column 1: Flight times and counts (left)
  { col = 1, row = 1, colspan = 2, rowspan = 4, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.flight_duration)@", titlepos = "top", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 1, row = 5, colspan = 2, rowspan = 4, type = "time", subtype = "total", title = "@i18n(widgets.dashboard.total_flight_duration)@", titlepos = "top", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 1, row = 9, colspan = 2, rowspan = 4, type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },

  -- Column 2: RPM and throttle stats (middle-left)
  { col = 3, row = 1, colspan = 2, rowspan = 4, type = "text", subtype = "stats", stattype = "min", source = "rpm", unit = " rpm", title = "@i18n(widgets.dashboard.rpm_min)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 3, row = 5, colspan = 2, rowspan = 4, type = "text", subtype = "stats", stattype = "max", source = "rpm", unit = " rpm", title = "@i18n(widgets.dashboard.rpm_max)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 3, row = 9, colspan = 2, rowspan = 4, type = "text", subtype = "stats", stattype = "max", source = "throttle_percent", unit = "%", title = "@i18n(widgets.dashboard.throttle_max)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },

  -- Column 3: Voltage and altitude (right)
  { col = 5, row = 1, colspan = 2, rowspan = 4, type = "text", subtype = "telemetry", source = "bec_voltage", decimals = 2, unit = "V", title = "@i18n(widgets.dashboard.voltage)@", titlepos = "top", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 5, row = 5, colspan = 2, rowspan = 4, type = "text", subtype = "stats", stattype = "min", source = "bec_voltage", decimals = 2, unit = "V", title = "@i18n(widgets.dashboard.min_voltage)@", titlepos = "top", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK },
  { col = 5, row = 9, colspan = 2, rowspan = 4, type = "text", subtype = "stats", stattype = "max", source = "altitude", unit = "m", title = "@i18n(widgets.dashboard.altitude_max)@", titlepos = "top", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = "orange", bgcolor = BLACK }
}

return Theme
