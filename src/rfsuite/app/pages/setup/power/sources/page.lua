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
local MspRuntime = nil
local BatteryConfigApi = nil
local LoadingOverlay = nil
local t = nil

M.eepromWrite = true

local SOURCE_MIN = 0
local SOURCE_MAX = 255

local function newRuntime()
	return {
		readPending = false,
		requestRebuild = nil,
		openHelp = nil,
		voltageSourceSet = nil,
		currentSourceSet = nil,
		inlineHelpHandler = nil,
		lastSessionSignature = nil
	}
end

local ui = {
	loaded = false,
	dirty = false,
	config = {
		voltageMeterSource = 0,
		currentMeterSource = 0
	},
	runtime = newRuntime(),
	loading = false,
	progress = 0
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
	if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
	if not BatteryConfigApi then BatteryConfigApi = loadModule("tasks/msp/api/battery_config.lua") end
	if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
	if not t then t = Common and Common.pageT("setup_power_sources") or nil end
end

local function pageText(i18n, key, fallback)
	if t then return t(i18n, key, fallback) end
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

local function getBatteryConfig(session)
	if type(session) ~= "table" then return nil end
	if type(session.battery_config) ~= "table" then
		if type(session.batteryConfig) == "table" then
			session.battery_config = session.batteryConfig
		else
			session.battery_config = {}
		end
	end
	session.batteryConfig = session.battery_config
	return session.battery_config
end

local function markDirty()
	ui.dirty = true
end

local function buildSessionSignature()
	local session = getSession()
	local batteryConfig = getBatteryConfig(session)
	if not batteryConfig then return "nil" end
	return tostring(batteryConfig.voltageMeterSource or "") .. "|" .. tostring(batteryConfig.currentMeterSource or "")
end

local function loadFromSession()
	local session = getSession()
	local batteryConfig = getBatteryConfig(session)
	ui.config.voltageMeterSource = clampInt(batteryConfig and batteryConfig.voltageMeterSource, SOURCE_MIN, SOURCE_MAX, 0)
	ui.config.currentMeterSource = clampInt(batteryConfig and batteryConfig.currentMeterSource, SOURCE_MIN, SOURCE_MAX, 0)
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

local function queueBatteryRead()
	ensureRuntime()
	if ui.runtime.readPending then
		return false
	end
	ui.runtime.readComplete = false
	if not MspRuntime or not BatteryConfigApi or type(MspRuntime.getState) ~= "function" then
		return false
	end

	local session = getSession()
	local mspState = MspRuntime.getState()
	local queue = mspState and mspState.queue
	if not queue or type(queue.add) ~= "function" then
		return false
	end

	local readValid = type(getSession()) == "table"
	ui.runtime.readPending = true
	ui.loading = true
	ui.progress = 0

	queue:add({
		command = BatteryConfigApi.command,
		simulatorResponse = BatteryConfigApi.simulatorResponse,
		timeout = 5.0,
		processReply = function(_, buf)
			ui.runtime.readPending = false
			ui.loading = false
			ui.progress = 1
			if type(session) == "table" then
				local parsed = BatteryConfigApi.parse and BatteryConfigApi.parse(buf) or nil
				if type(parsed) ~= "table" then return Common.failPageRead(ui) end
				if type(parsed) == "table" then
					session.battery_config = parsed
					session.batteryConfig = parsed
				end
			end
			if not ui.dirty then
				loadFromSession()
			end
			ui.runtime.readComplete = readValid
			if type(ui.runtime.requestRebuild) == "function" then
				ui.runtime.requestRebuild()
			end
		end,
		errorHandler = function()
			readValid = false
			ui.runtime.readPending = false
			ui.loading = false
			ui.progress = 1
		end
	})

	return true
end

local function ensureLoaded()
	ensureRuntime()
	if ui.loaded then return end
	loadFromSession()
	ui.runtime.lastSessionSignature = buildSessionSignature()
	ui.loaded = true
	ui.dirty = false
	queueBatteryRead()
end

local function getVoltageSourceSetter()
	if ui.runtime.voltageSourceSet then return ui.runtime.voltageSourceSet end
	ui.runtime.voltageSourceSet = function(value)
		local nextValue = clampInt(value, SOURCE_MIN, SOURCE_MAX, 0)
		if ui.config.voltageMeterSource == nextValue then return end
		ui.config.voltageMeterSource = nextValue
		markDirty()
	end
	return ui.runtime.voltageSourceSet
end

local function getCurrentSourceSetter()
	if ui.runtime.currentSourceSet then return ui.runtime.currentSourceSet end
	ui.runtime.currentSourceSet = function(value)
		local nextValue = clampInt(value, SOURCE_MIN, SOURCE_MAX, 0)
		if ui.config.currentMeterSource == nextValue then return end
		ui.config.currentMeterSource = nextValue
		markDirty()
	end
	return ui.runtime.currentSourceSet
end

local function buildSourceOptions(i18n, selectedValue)
	local options = {
		{ value = 0, label = pageText(i18n, "source_none", "NONE") },
		{ value = 1, label = pageText(i18n, "source_adc", "ADC") },
		{ value = 2, label = pageText(i18n, "source_esc", "ESC") },
		{ value = 3, label = pageText(i18n, "source_fbus", "FBUS") }
	}

	local known = false
	for i = 1, #options do
		if options[i].value == selectedValue then
			known = true
			break
		end
	end

	if not known and type(selectedValue) == "number" then
		options[#options + 1] = {
			value = selectedValue,
			label = pageText(i18n, "source_unknown", "Unknown") .. " (" .. tostring(selectedValue) .. ")"
		}
	end

	return options
end

local function buildBatteryPayload(batteryConfig)
	local caps = {}
	for i = 0, 5 do
		caps[i + 1] = tonumber(batteryConfig["batteryCapacity_" .. tostring(i)]) or 0
	end

	return BatteryConfigApi.buildWritePayload({
		batteryCapacity = tonumber(batteryConfig.batteryCapacity) or 0,
		batteryCellCount = tonumber(batteryConfig.batteryCellCount) or 0,
		voltageMeterSource = tonumber(batteryConfig.voltageMeterSource) or 0,
		currentMeterSource = tonumber(batteryConfig.currentMeterSource) or 0,
		vbatmincellvoltage = tonumber(batteryConfig.vbatmincellvoltage) or 330,
		vbatmaxcellvoltage = tonumber(batteryConfig.vbatmaxcellvoltage) or 420,
		vbatfullcellvoltage = tonumber(batteryConfig.vbatfullcellvoltage) or 410,
		vbatwarningcellvoltage = tonumber(batteryConfig.vbatwarningcellvoltage) or 350,
		lvcPercentage = tonumber(batteryConfig.lvcPercentage) or 100,
		consumptionWarningPercentage = tonumber(batteryConfig.consumptionWarningPercentage) or 35,
		batteryCapacities = caps
	})
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

function M.canSave()
	return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
	if not M.canSave() then return false, "loaded_data_missing" end
	ensureDeps()
	ensureLoaded()

	local session = getSession()
	local batteryConfig = getBatteryConfig(session)
	if not batteryConfig then
		return false
	end

	batteryConfig.voltageMeterSource = clampInt(ui.config.voltageMeterSource, SOURCE_MIN, SOURCE_MAX, 0)
	batteryConfig.currentMeterSource = clampInt(ui.config.currentMeterSource, SOURCE_MIN, SOURCE_MAX, 0)
	session.battery_config = batteryConfig
	session.batteryConfig = batteryConfig

	local okMsp = false
	if MspRuntime and BatteryConfigApi and type(MspRuntime.getState) == "function" then
		local mspState = MspRuntime.getState()
		local queue = mspState and mspState.queue
		if queue and type(queue.add) == "function" then
			okMsp = true
			queue:add({
				command = BatteryConfigApi.writeCommand,
				payload = buildBatteryPayload(batteryConfig),
				timeout = 5.0,
				isWrite = true,
				processReply = function() end,
				errorHandler = function() end
			})

		end
	end

	if ctx and type(ctx.reportSave) == "function" then
		if okMsp then
			ctx.reportSave({
				ok = true,
				title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
				message = pageText(ctx and ctx.i18n, "saved_message", "Power sources saved")
			})
		else
			ctx.reportSave({
				title = pageText(ctx and ctx.i18n, "warning_title", "Warning"),
				message = pageText(ctx and ctx.i18n, "saved_local_only_message", "Saved locally; FC write pending")
			})
		end
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
	local h = ctx.h or 200
	local i18n = ctx.i18n

	local cursorY = y
	Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "section_sources", "Sources"))
	cursorY = cursorY + Controls.STATIC_SECTION_H

	cursorY = cursorY + Controls.appendComboSelect(
		children, x, cursorY, w,
		pageText(i18n, "voltage_meter_source", "Voltage Source"),
		buildSourceOptions(i18n, ui.config.voltageMeterSource),
		ui.config.voltageMeterSource,
		getVoltageSourceSetter(),
		{
			helpText = optionalPageHelpText(i18n, "help_voltage_meter_source"),
			helpTitle = pageText(i18n, "voltage_meter_source", "Voltage Source"),
			onHelp = getInlineHelpHandler()
		}
	)

	Controls.appendComboSelect(
		children, x, cursorY, w,
		pageText(i18n, "current_meter_source", "Current Source"),
		buildSourceOptions(i18n, ui.config.currentMeterSource),
		ui.config.currentMeterSource,
		getCurrentSourceSetter(),
		{
			helpText = optionalPageHelpText(i18n, "help_current_meter_source"),
			helpTitle = pageText(i18n, "current_meter_source", "Current Source"),
			onHelp = getInlineHelpHandler()
		}
	)

	if ui.loading and LoadingOverlay then
		LoadingOverlay.append(children, {
			x = x,
			y = y,
			w = w,
			h = h,
			title = pageText(i18n, "loading_title", "Loading"),
			message = pageText(i18n, "loading_message", "Reading battery config"),
			progress = ui.progress
		})
	end
end

function M.onClose()
	if Common and Common.resetPageState then
		Common.resetPageState(ui)
	else
		ui.loaded = false
		ui.dirty = false
	end
	ui.loading = false
	ui.progress = 0
	Controls = nil
	Common = nil
	MspRuntime = nil
	BatteryConfigApi = nil
	LoadingOverlay = nil
	t = nil
end

return M
