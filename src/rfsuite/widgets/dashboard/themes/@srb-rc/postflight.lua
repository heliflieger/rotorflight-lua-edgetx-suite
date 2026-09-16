local Theme = {}

Theme.layout = { cols = 3, rows = 3, padding = 1, showstats = false, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, colspan = 1, rowspan = 1, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.flight_duration):upper()@", titlepos = "top", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 1, row = 2, colspan = 1, rowspan = 1, type = "text", subtype = "stats", source = "smartfuel", stattype = "min", title = "@i18n(widgets.dashboard.fuel_remaining):upper()@", titlepos = "top", unit = "%", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 1, row = 3, colspan = 1, rowspan = 1, type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights):upper()@", titlepos = "top", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },

  { col = 2, row = 1, colspan = 1, rowspan = 1, type = "text", subtype = "stats", source = "current", stattype = "max", title = "@i18n(widgets.dashboard.current_max):upper()@", titlepos = "top", unit = "A", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 2, row = 2, colspan = 1, rowspan = 1, type = "text", subtype = "stats", source = "esc_temp", stattype = "max", title = "@i18n(widgets.dashboard.esc_max_temp):upper()@", titlepos = "top", unit = "°C", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 2, row = 3, colspan = 1, rowspan = 1, type = "text", subtype = "stats", source = "link", stattype = "min", title = "@i18n(widgets.dashboard.link_min):upper()@", titlepos = "top", unit = "%", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },

  { col = 3, row = 1, colspan = 1, rowspan = 1, type = "text", subtype = "stats", source = "current", stattype = "consumed", title = "@i18n(widgets.dashboard.consumed_mah):upper()@", titlepos = "top", unit = "mAh", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 3, row = 2, colspan = 1, rowspan = 1, type = "text", subtype = "stats", source = "voltage", stattype = "last", title = "@i18n(widgets.dashboard.ending_voltage):upper()@", titlepos = "top", unit = "V", decimals = 2, titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 3, row = 3, colspan = 1, rowspan = 1, type = "text", subtype = "stats", source = "voltage", stattype = "cell", title = "@i18n(widgets.dashboard.volts_per_cell):upper()@", titlepos = "top", unit = "V", decimals = 2, titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK }
}

return Theme
