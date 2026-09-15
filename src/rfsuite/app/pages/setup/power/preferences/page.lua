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

local MODEL_TYPE_MIN = 0
local MODEL_TYPE_MAX = 2
local LOCAL_SOURCE_MIN = 0
local LOCAL_SOURCE_MAX = 2

local function newRuntime()
	return {
		modelTypeSet = nil,
		localSourceSet = nil,
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
		smartfuel_model_type = 0,
		smartfuel_source = 0
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
	if not t then t = Common and Common.pageT("setup_power_preferences") or nil end
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
	return tostring(batteryPrefs.smartfuel_model_type or "") .. "|" .. tostring(batteryPrefs.smartfuel_source or batteryPrefs.calc_local or "")
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

	ui.config.smartfuel_model_type = clampInt(batteryPrefs and batteryPrefs.smartfuel_model_type, MODEL_TYPE_MIN, MODEL_TYPE_MAX, 0)
	ui.config.smartfuel_source = clampInt((batteryPrefs and batteryPrefs.smartfuel_source) or (batteryPrefs and batteryPrefs.calc_local), LOCAL_SOURCE_MIN, LOCAL_SOURCE_MAX, 0)
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

local function getModelTypeSetter()
	if ui.runtime.modelTypeSet then return ui.runtime.modelTypeSet end
	ui.runtime.modelTypeSet = function(value)
		local nextValue = clampInt(value, MODEL_TYPE_MIN, MODEL_TYPE_MAX, 0)
		if ui.config.smartfuel_model_type == nextValue then return end
		ui.config.smartfuel_model_type = nextValue
		markDirty()
	end
	return ui.runtime.modelTypeSet
end

local function getLocalSourceSetter()
	if ui.runtime.localSourceSet then return ui.runtime.localSourceSet end
	ui.runtime.localSourceSet = function(value)
		local nextValue = clampInt(value, LOCAL_SOURCE_MIN, LOCAL_SOURCE_MAX, 0)
		if ui.config.smartfuel_source == nextValue then return end
		ui.config.smartfuel_source = nextValue
		markDirty()
	end
	return ui.runtime.localSourceSet
end

local function buildModelTypeOptions(i18n)
	return {
		{ value = 0, label = pageText(i18n, "value_auto", "AUTO") },
		{ value = 1, label = pageText(i18n, "value_electric", "ELECTRIC") },
		{ value = 2, label = pageText(i18n, "value_nitro", "NITRO") }
	}
end

local function buildLocalSourceOptions(i18n)
	return {
		{ value = 0, label = pageText(i18n, "value_current", "CURRENT") },
		{ value = 1, label = pageText(i18n, "value_voltage", "VOLTAGE") },
		{ value = 2, label = pageText(i18n, "value_combined", "COMBINED") }
	}
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

	batteryPrefs.smartfuel_model_type = clampInt(ui.config.smartfuel_model_type, MODEL_TYPE_MIN, MODEL_TYPE_MAX, 0)
	batteryPrefs.smartfuel_source = clampInt(ui.config.smartfuel_source, LOCAL_SOURCE_MIN, LOCAL_SOURCE_MAX, 0)
	batteryPrefs.calc_local = batteryPrefs.smartfuel_source

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
			message = pageText(ctx and ctx.i18n, "saved_message", "Power preferences saved")
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
	Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "section_preferences", "Preferences"))
	cursorY = cursorY + Controls.STATIC_SECTION_H

	cursorY = cursorY + Controls.appendComboSelect(
		children, x, cursorY, w,
		pageText(i18n, "model_type", "Model Type"),
		buildModelTypeOptions(i18n),
		ui.config.smartfuel_model_type,
		getModelTypeSetter(),
		{
			helpText = optionalPageHelpText(i18n, "help_model_type"),
			helpTitle = pageText(i18n, "model_type", "Model Type"),
			onHelp = getInlineHelpHandler()
		}
	)

	Controls.appendComboSelect(
		children, x, cursorY, w,
		pageText(i18n, "calcfuel_local", "Local SmartFuel Source"),
		buildLocalSourceOptions(i18n),
		ui.config.smartfuel_source,
		getLocalSourceSetter(),
		{
			helpText = optionalPageHelpText(i18n, "help_calcfuel_local"),
			helpTitle = pageText(i18n, "calcfuel_local", "Local SmartFuel Source"),
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
