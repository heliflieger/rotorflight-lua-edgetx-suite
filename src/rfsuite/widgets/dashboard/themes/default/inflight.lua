local Theme = {}

Theme.layout = { cols = 2, rows = 2, padding = 2, bgcolor = WHITE }

Theme.boxes = {
	{ col = 1, row = 1, colspan = 1, rowspan = 1, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.time)@", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
	{ col = 1, row = 2, colspan = 1, rowspan = 1, type = "text", subtype = "telemetry", source = "link", unit = "%", title = "@i18n(widgets.dashboard.link)@", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
	{
		col = 2,
		row = 1,
		colspan = 1,
		rowspan = 2,
		type = "gauge",
		subtype = "arc",
		source = "voltage",
		title = "@i18n(widgets.dashboard.voltage)@",
		titlepos = "bottom",
		textcolor = WHITE,
		bgcolor = BLACK,
		min = function(_, runtimeState)
			local cfg = runtimeState and runtimeState.themeConfig or nil
			return tonumber(cfg and cfg.v_min) or 18.0
		end,
		max = function(_, runtimeState)
			local cfg = runtimeState and runtimeState.themeConfig or nil
			return tonumber(cfg and cfg.v_max) or 25.2
		end
	}
}

return Theme
