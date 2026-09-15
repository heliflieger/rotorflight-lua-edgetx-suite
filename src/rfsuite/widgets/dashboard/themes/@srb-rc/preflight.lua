local Theme = {}

local function loadSrbCommon()
  if type(_G) == "table" and type(_G.__rfsuiteThemeSrbCommonModule) == "table" then
    return _G.__rfsuiteThemeSrbCommonModule
  end

  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("widgets/dashboard/themes/@srb-rc/common.lua")
    if mod and type(mod) == "table" then
      return mod
    end
  end

  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/@srb-rc/common.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then
    if type(_G) == "table" then
      _G.__rfsuiteThemeSrbCommonModule = mod
    end
    return mod
  end
  return nil
end

local SrbCommon = loadSrbCommon() or {}

local function cfgValue(key, fallback, state)
  local cfg = state and state.themeConfig or nil
  local value = cfg and cfg[key] or nil
  if type(value) == "number" then
    return value
  end
  return fallback
end

local function isCompactDisplay(state)
  local w = tonumber(state and state.zoneW) or tonumber(LCD_W)
  return not (w and w >= 760)
end

Theme.layout = { cols = 13, rows = 10, padding = 1, showstats = false, bgcolor = WHITE }

Theme.boxes = {
  { col = 1, row = 1, colspan = 4, rowspan = 3, type = "text", subtype = "telemetry", source = "model_name", title = "@i18n(widgets.dashboard.craft_name):upper()@", titlepos = "top", titlealign = CENTER, titlefont = SMLSIZE, font = DBLSIZE, textcolor = "orange", titlecolor = WHITE, bgcolor = BLACK },

  { col = 1, row = 4, colspan = 2, rowspan = 3, type = "text", subtype = "telemetry", source = "pid_profile", title = "@i18n(widgets.dashboard.profile):upper()@", titlepos = "top", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 3, row = 4, colspan = 2, rowspan = 3, type = "text", subtype = "telemetry", source = "rate_profile", title = "@i18n(widgets.dashboard.rates):upper()@", titlepos = "top", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },

  { col = 5, row = 1, colspan = 3, rowspan = 3, type = "text", subtype = "telemetry", source = "bec_voltage", title = "@i18n(widgets.dashboard.bec_voltage):upper()@", titlepos = "top", decimals = 1, unit = "V", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK, thresholds = { { value = function(_, state) return cfgValue("bec_warn", 6.5, state) end, textcolor = RED } } },
  { col = 5, row = 4, colspan = 3, rowspan = 3, type = "text", subtype = "telemetry", source = "esc_temp", title = "@i18n(widgets.dashboard.esc_temp):upper()@", titlepos = "top", unit = "°C", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },

  { col = 8, row = 1, colspan = 3, rowspan = 3, type = "text", subtype = "telemetry", source = "link", title = "@i18n(widgets.dashboard.lq):upper()@", titlepos = "top", unit = "%", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },
  { col = 8, row = 4, colspan = 3, rowspan = 3, type = "text", subtype = "telemetry", source = "current", title = "@i18n(widgets.dashboard.current):upper()@", titlepos = "top", unit = "A", transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },

  { col = 11, row = 1, colspan = 3, rowspan = 3, type = "text", subtype = "telemetry", source = "rpm", title = "@i18n(widgets.dashboard.rpm):upper()@", titlepos = "top", titlealign = CENTER, transform = "floor", titlefont = SMLSIZE, font = DBLSIZE, textcolor = BLACK, titlecolor = BLACK, bgcolor = WHITE },
  { col = 11, row = 4, colspan = 3, rowspan = 3, type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.timer):upper()@", titlepos = "top", titlefont = SMLSIZE, font = DBLSIZE, textcolor = WHITE, titlecolor = WHITE, bgcolor = BLACK },

  SrbCommon and SrbCommon.batteryBar and SrbCommon.batteryBar("smartfuel", {
    col = 1,
    row = 7,
    colspan = 13,
    rowspan = 4,
    valuepaddingtop = function(_, state)
      if isCompactDisplay(state) then
        return -18
      end
      return -22
    end,
    title = "@i18n(widgets.dashboard.flight_battery):upper()@",
    titlepos = "top",
    titlefont = SMLSIZE,
    font = DBLSIZE
  })
}

return Theme
