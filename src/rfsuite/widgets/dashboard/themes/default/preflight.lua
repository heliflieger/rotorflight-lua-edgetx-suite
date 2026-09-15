local Theme = {}

local function autoFont(box, state)
  return (state and (state.zoneW or 0) <= 480) and SMLSIZE or MIDSIZE
end

Theme.layout = { cols = 20, rows = 8, padding = 1, bgcolor = WHITE }

Theme.boxes = function(_, state)
	-- autoFont answers from state.zoneW alone, and the zone size is part of the render key
	-- (Engine.renderKey in widgets/dashboard/engine.lua), so a zone that changes size tears this
	-- scene down and builds the next one from the size it then has. Resolved here, each of these
	-- boxes hands lvgl a number instead of a reference the firmware calls once per box on every
	-- foreground pass.
	local valueFont = autoFont(nil, state)
	return {
		{ col = 1, row = 1, colspan = 12, rowspan = 4, type = "image", subtype = "model", bgcolor = BLACK, textcolor = WHITE, titlecolor = COLOR_THEME_DISABLED },
		{ col = 1, row = 5, colspan = 6, rowspan = 2, type = "time", subtype = "flight", font = valueFont, title = "@i18n(widgets.dashboard.time)@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
		{ col = 7, row = 5, colspan = 6, rowspan = 2, type = "text", subtype = "blackbox", font = valueFont, title = "@i18n(widgets.dashboard.blackbox)@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK, autosize_chars = 12 },
		{ col = 1, row = 7, colspan = 3, rowspan = 2, type = "text", subtype = "telemetry", font = valueFont, source = "pid_profile", title = "@i18n(widgets.dashboard.profile)@", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
		{ col = 4, row = 7, colspan = 3, rowspan = 2, type = "text", subtype = "telemetry", font = valueFont, source = "rate_profile", title = "@i18n(widgets.dashboard.rates)@", titlepos = "bottom", transform = "floor", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
		{ col = 7, row = 7, colspan = 3, rowspan = 2, type = "time", subtype = "count", font = valueFont, title = "@i18n(widgets.dashboard.flights)@", titlepos = "bottom", titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
		{ col = 10, row = 7, colspan = 3, rowspan = 2, type = "text", subtype = "telemetry", font = valueFont, source = "link", unit = "%", title = "@i18n(widgets.dashboard.link)@", titlepos = "bottom", transform = "floor", autosize_chars = 3, titlecolor = COLOR_THEME_DISABLED, textcolor = WHITE, bgcolor = BLACK },
		{
			col = 13,
			row = 1,
			colspan = 8,
			rowspan = 8,
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
end

return Theme
