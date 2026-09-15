local Theme = {}

Theme.layout = { cols = 2, rows = 3, padding = 2, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, type = "text", subtype = "stats", source = "voltage", stattype = "min", title = "@i18n(widgets.dashboard.min_voltage):upper()@", unit = "V", decimals = 1, titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
  { col = 2, row = 1, type = "text", subtype = "stats", source = "voltage", stattype = "max", title = "@i18n(widgets.dashboard.max_voltage):upper()@", unit = "V", decimals = 1, titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
  { col = 1, row = 2, type = "text", subtype = "stats", source = "current", stattype = "min", title = "@i18n(widgets.dashboard.min_current):upper()@", unit = "A", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
  { col = 2, row = 2, type = "text", subtype = "stats", source = "current", stattype = "max", title = "@i18n(widgets.dashboard.max_current):upper()@", unit = "A", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
  { col = 1, row = 3, type = "text", subtype = "stats", source = "mcu_temp", stattype = "max", title = "@i18n(widgets.dashboard.max_tmcu):upper()@", unit = "°C", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
  { col = 2, row = 3, type = "text", subtype = "stats", source = "esc_temp", stattype = "max", title = "@i18n(widgets.dashboard.max_emcu):upper()@", unit = "°C", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK }
}

return Theme