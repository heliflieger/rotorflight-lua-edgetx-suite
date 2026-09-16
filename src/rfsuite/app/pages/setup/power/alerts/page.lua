local M = {}

local function loadModule(path)
	local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
	local chunk = loadScript(fullPath, "t")
	if type(chunk) ~= "function" then return nil end
	local ok, mod = pcall(chunk)
	if not ok then return nil end
	return mod
end

local Controls = nil
local Common = nil
local PowerModelPreferences = nil
local t = nil

local ALERT_TYPE_MIN = 0
local ALERT_TYPE_MAX = 2
local ALERT_TIMER_MIN = 0
local ALERT_TIMER_MAX = 3600
local ALERT_VOLT_MIN = 30
local ALERT_VOLT_MAX = 140

local function newRuntime()
	return {
		alertTypeSet = nil,
		flightTimeSet = nil,
		becAlertSet = nil,
		rxAlertSet = nil,
		requestRebuild = nil,
		openHelp = nil,
		inlineHelpHandler = nil,
		lastSessionSignature = nil
	}
end

local ui = {
	loaded = false,
	dirty = false,
	config = {
		alert_type = 0,
		flighttime = 300,
		becalertvalue = 65,
		rxalertvalue = 75
	},
	runtime = newRuntime()
}

local function clampInt(value, minValue, maxValue, fallback)
	local n = tonumber(value)
	if n == nil then n = fallback end
	n = math.floor((n or fallback or minValue) + 0.5)
	if n < minValue then n = minValue end
	if n > maxValue then n = maxValue end
	return n
end

local function ensureRuntime()
	if type(ui.runtime) ~= "table" then
		ui.runtime = newRuntime()
	end
end

local function ensureDeps()
	if not Common then Common = loadModule("app/pages/settings/common.lua") end
	if not Controls then Controls = loadModule("ui/controls.lua") end
	if not PowerModelPreferences then PowerModelPreferences = loadModule("app/pages/setup/power/model_preferences.lua") end
	if not t then t = Common and Common.pageT("setup_power_alerts") or nil end
end

local function pageText(i18n, key, fallback)
	if t then
		return t(i18n, key, fallback)
	end
	return fallback
end

local function optionalPageHelpText(i18n, key)
	local value = pageText(i18n, key, nil)
	if type(value) ~= "string" or value == "" then return nil end
	if string.sub(value, 1, 10) == "app.pages." then return nil end
	return value
end

local function getSession()
	local root = _G and _G.rfsuite
	return root and root.session or nil
end

local function getBatteryPrefs(session)
	if type(session) ~= "table" then return nil end
	if type(session.modelPreferences) ~= "table" then
		session.modelPreferences = {}
	end
	if type(session.modelPreferences.battery) ~= "table" then
		session.modelPreferences.battery = {}
	end
	return session.modelPreferences.battery
end

local function buildSessionSignature()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	if not batteryPrefs then return "nil" end
	local parts = {
		tostring(batteryPrefs.alert_type or ""),
		tostring(batteryPrefs.flighttime or ""),
		tostring(batteryPrefs.becalertvalue or ""),
		tostring(batteryPrefs.rxalertvalue or "")
	}
	return table.concat(parts, "|")
end

local function markDirty()
	ui.dirty = true
end

local function getInlineHelpHandler()
	if ui.runtime.inlineHelpHandler then return ui.runtime.inlineHelpHandler end
	ui.runtime.inlineHelpHandler = function(helpText, helpTitle)
		if type(helpText) ~= "string" or helpText == "" then return end
		local openHelp = ui.runtime.openHelp
		if type(openHelp) == "function" then
			openHelp(helpText, helpTitle)
		end
	end
	return ui.runtime.inlineHelpHandler
end

local function loadFromSession()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)

	ui.config.alert_type = clampInt(batteryPrefs and batteryPrefs.alert_type, ALERT_TYPE_MIN, ALERT_TYPE_MAX, 0)
	ui.config.flighttime = clampInt(batteryPrefs and batteryPrefs.flighttime, ALERT_TIMER_MIN, ALERT_TIMER_MAX, 300)
	ui.config.becalertvalue = clampInt(batteryPrefs and batteryPrefs.becalertvalue, ALERT_VOLT_MIN, ALERT_VOLT_MAX, 65)
	ui.config.rxalertvalue = clampInt(batteryPrefs and batteryPrefs.rxalertvalue, ALERT_VOLT_MIN, ALERT_VOLT_MAX, 75)
end

local function ensureLoaded()
	ensureRuntime()
	if ui.loaded then return end
	loadFromSession()
	ui.runtime.lastSessionSignature = buildSessionSignature()
	ui.loaded = true
	ui.dirty = false
end

local function saveModelPreferences(session)
	if not PowerModelPreferences or type(PowerModelPreferences.save) ~= "function" then
		return false, "model_preferences_unavailable"
	end
	return PowerModelPreferences.save(session)
end

local function getAlertTypeSetter()
	if ui.runtime.alertTypeSet then return ui.runtime.alertTypeSet end
	ui.runtime.alertTypeSet = function(value)
		local nextValue = clampInt(value, ALERT_TYPE_MIN, ALERT_TYPE_MAX, 0)
		if ui.config.alert_type == nextValue then return end
		ui.config.alert_type = nextValue
		markDirty()
	end
	return ui.runtime.alertTypeSet
end

local function getFlightTimeSetter()
	if ui.runtime.flightTimeSet then return ui.runtime.flightTimeSet end
	ui.runtime.flightTimeSet = function(value)
		local nextValue = clampInt(value, ALERT_TIMER_MIN, ALERT_TIMER_MAX, 300)
		if ui.config.flighttime == nextValue then return end
		ui.config.flighttime = nextValue
		markDirty()
	end
	return ui.runtime.flightTimeSet
end

local function getBecAlertSetter()
	if ui.runtime.becAlertSet then return ui.runtime.becAlertSet end
	ui.runtime.becAlertSet = function(value)
		local nextValue = clampInt(value, ALERT_VOLT_MIN, ALERT_VOLT_MAX, 65)
		if ui.config.becalertvalue == nextValue then return end
		ui.config.becalertvalue = nextValue
		markDirty()
	end
	return ui.runtime.becAlertSet
end

local function getRxAlertSetter()
	if ui.runtime.rxAlertSet then return ui.runtime.rxAlertSet end
	ui.runtime.rxAlertSet = function(value)
		local nextValue = clampInt(value, ALERT_VOLT_MIN, ALERT_VOLT_MAX, 75)
		if ui.config.rxalertvalue == nextValue then return end
		ui.config.rxalertvalue = nextValue
		markDirty()
	end
	return ui.runtime.rxAlertSet
end

local function isBecAlertEnabled()
	return ui.config.alert_type == 1
end

local function isRxAlertEnabled()
	return ui.config.alert_type == 2
end

local function buildAlertTypeOptions(i18n)
	return {
		{ value = 0, label = pageText(i18n, "value_alert_off", "OFF") },
		{ value = 1, label = pageText(i18n, "value_alert_bec", "BEC") },
		{ value = 2, label = pageText(i18n, "value_alert_rxbatt", "RX BATT") }
	}
end

local function formatSeconds(totalSeconds)
	local seconds = clampInt(totalSeconds, ALERT_TIMER_MIN, ALERT_TIMER_MAX, 0)
	local mm = math.floor(seconds / 60)
	local ss = seconds % 60
	if ss < 10 then
		return tostring(mm) .. ":0" .. tostring(ss)
	end
	return tostring(mm) .. ":" .. tostring(ss)
end

local function formatDeciVolts(value)
	local deci = clampInt(value, ALERT_VOLT_MIN, ALERT_VOLT_MAX, ALERT_VOLT_MIN)
	return string.format("%.1fV", deci / 10)
end

function M.getHeaderActions()
	ensureDeps()
	return {
		save = true,
		reload = true,
		help = true,
		menu = true
	}
end


function M.onReload()
	ensureDeps()
	ui.loaded = false
	ensureLoaded()
	return false
end

function M.onSave(ctx)
	ensureDeps()
	ensureLoaded()

	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	if not batteryPrefs then
		return false
	end

	batteryPrefs.alert_type = clampInt(ui.config.alert_type, ALERT_TYPE_MIN, ALERT_TYPE_MAX, 0)
	batteryPrefs.flighttime = clampInt(ui.config.flighttime, ALERT_TIMER_MIN, ALERT_TIMER_MAX, 300)
	batteryPrefs.becalertvalue = clampInt(ui.config.becalertvalue, ALERT_VOLT_MIN, ALERT_VOLT_MAX, 65)
	batteryPrefs.rxalertvalue = clampInt(ui.config.rxalertvalue, ALERT_VOLT_MIN, ALERT_VOLT_MAX, 75)

	local okPrefs, errPrefs = saveModelPreferences(session)
	if not okPrefs then
		if ctx and type(ctx.reportSave) == "function" then
			ctx.reportSave({
				title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
				message = pageText(ctx and ctx.i18n, "save_error_message", "Save failed") .. ": " .. tostring(errPrefs or "io")
			})
		end
		return false
	end

	if ctx and type(ctx.reportSave) == "function" then
		ctx.reportSave({
			ok = true,
			title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
			message = pageText(ctx and ctx.i18n, "saved_message", "Power alerts saved")
		})
	end

	ui.dirty = false
	ui.runtime.lastSessionSignature = buildSessionSignature()
	return true
end

function M.wakeup(ctx)
	ensureDeps()
	ensureLoaded()
	if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
		ui.runtime.requestRebuild = ctx.requestRebuild
	end
	if ui.dirty then return end

	local signature = buildSessionSignature()
	if signature ~= ui.runtime.lastSessionSignature then
		loadFromSession()
		ui.runtime.lastSessionSignature = signature
		if type(ui.runtime.requestRebuild) == "function" then
			ui.runtime.requestRebuild()
		end
	end
end

function M.build(ctx)
	ensureDeps()
	ensureLoaded()
	ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
	ui.runtime.openHelp = ctx and ctx.openHelp or nil

	local children = ctx.children
	local x = ctx.x
	local y = ctx.y
	local w = ctx.w
	local i18n = ctx.i18n

	local cursorY = y
	Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "section_alerts", "Alerts"))
	cursorY = cursorY + Controls.STATIC_SECTION_H

	cursorY = cursorY + Controls.appendNumberField(
		children, x, cursorY, w,
		pageText(i18n, "timer", "Timer"), {
			min = ALERT_TIMER_MIN,
			max = ALERT_TIMER_MAX,
			get = function() return ui.config.flighttime end,
			set = getFlightTimeSetter(),
			display = formatSeconds,
			helpText = optionalPageHelpText(i18n, "help_timer"),
			helpTitle = pageText(i18n, "timer", "Timer"),
			onHelp = getInlineHelpHandler()
		}
	)

	cursorY = cursorY + Controls.appendComboSelect(
		children, x, cursorY, w,
		pageText(i18n, "alert_type", "Alert Type"),
		buildAlertTypeOptions(i18n),
		ui.config.alert_type,
		getAlertTypeSetter(),
		{
			helpText = optionalPageHelpText(i18n, "help_alert_type"),
			helpTitle = pageText(i18n, "alert_type", "Alert Type"),
			onHelp = getInlineHelpHandler()
		}
	)

	cursorY = cursorY + Controls.appendNumberField(
		children, x, cursorY, w,
		pageText(i18n, "bec_voltage_alert", "BEC Voltage Alert"), {
			min = ALERT_VOLT_MIN,
			max = ALERT_VOLT_MAX,
			enabled = isBecAlertEnabled,
			get = function() return ui.config.becalertvalue end,
			set = getBecAlertSetter(),
			display = formatDeciVolts,
			helpText = optionalPageHelpText(i18n, "help_bec_voltage_alert"),
			helpTitle = pageText(i18n, "bec_voltage_alert", "BEC Voltage Alert"),
			onHelp = getInlineHelpHandler()
		}
	)

	Controls.appendNumberField(
		children, x, cursorY, w,
		pageText(i18n, "rx_voltage_alert", "RX Voltage Alert"), {
			min = ALERT_VOLT_MIN,
			max = ALERT_VOLT_MAX,
			enabled = isRxAlertEnabled,
			get = function() return ui.config.rxalertvalue end,
			set = getRxAlertSetter(),
			display = formatDeciVolts,
			helpText = optionalPageHelpText(i18n, "help_rx_voltage_alert"),
			helpTitle = pageText(i18n, "rx_voltage_alert", "RX Voltage Alert"),
			onHelp = getInlineHelpHandler()
		}
	)
end

function M.onClose()
	if Common and Common.resetPageState then
		Common.resetPageState(ui)
	else
		ui.loaded = false
		ui.dirty = false
	end
	Controls = nil
	Common = nil
	PowerModelPreferences = nil
	t = nil
end

return M
