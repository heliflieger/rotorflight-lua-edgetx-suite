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
local MspRuntime = nil
local SmartfuelApi = nil
local ApiVersion = nil
local Log = nil
local LoadingOverlay = nil
local t = nil

M.eepromWrite = true

local function newRuntime()
	return {
		localSourceSet = nil,
		firmwareModeSet = nil,
		voltageSet = nil,
		chargeSet = nil,
		sagSet = nil,
		inlineHelpHandler = nil,
		openHelp = nil,
		readPending = false,
		requestRebuild = nil,
		lastSessionSignature = nil
	}
end

local ui = {
	loaded = false,
	dirty = false,
	config = {
		local_source = 0,
		firmware_mode = 0,
		voltage_drop_rate = 10,
		charge_drop_rate = 50,
		sag_gain = 40
	},
	support = {
		firmware = false
	},
	runtime = newRuntime(),
	loading = false,
	progress = 0
}

local function ensureRuntime()
	if type(ui.runtime) ~= "table" then
		ui.runtime = newRuntime()
	end
end

local function getSession()
	local root = _G and _G.rfsuite
	return root and root.session or nil
end

local function parseApiVersionSafe(raw)
	if ApiVersion and type(ApiVersion.parse) == "function" then
		local parsed = ApiVersion.parse(raw)
		if type(parsed) == "table" then return parsed end
	end

	if type(raw) ~= "string" then return nil end
	local a, b, c = string.match(raw, "^(%d+)%.(%d+)%.(%d+)$")
	if a then return { tonumber(a), tonumber(b), tonumber(c) } end
	a, b = string.match(raw, "^(%d+)%.(%d+)$")
	if a then return { tonumber(a), 0, tonumber(b) } end
	return nil
end

local function isFirmwareSupported(session)
	local rawApiVersion = session and session.apiVersion
	if rawApiVersion == nil or rawApiVersion == "" or tostring(rawApiVersion) == "0" then
		-- Do not hard-block SmartFuel before API version is published.
		return true
	end
	local apiVersion = parseApiVersionSafe(rawApiVersion)
	if type(apiVersion) ~= "table" then
		-- Unknown formatting should not disable read/write permanently.
		return true
	end
	return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(apiVersion, { 12, 0, 9 }) or true
end

local function clampInt(value, minValue, maxValue, fallback)
	local n = tonumber(value)
	if n == nil then n = fallback end
	n = math.floor((n or fallback or minValue) + 0.5)
	if n < minValue then n = minValue end
	if n > maxValue then n = maxValue end
	return n
end

local function ensureDeps()
	if not Common then Common = loadModule("app/pages/settings/common.lua") end
	if not Controls then Controls = loadModule("ui/controls.lua") end
	if not PowerModelPreferences then PowerModelPreferences = loadModule("app/pages/setup/power/model_preferences.lua") end
	if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
	if not SmartfuelApi then SmartfuelApi = loadModule("tasks/msp/api/smartfuel_config.lua") end
	if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
	if not Log then Log = loadModule("lib/log.lua") end
	if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
	if not t then t = Common and Common.pageT("setup_power_smartfuel") or nil end
end

local function logDebug(message)
	if Log and type(Log.emit) == "function" then
		pcall(Log.emit, "rfsuite.smartfuel.page", tostring(message), "debug")
	end
end

local function logWarn(message)
	if Log and type(Log.emit) == "function" then
		pcall(Log.emit, "rfsuite.smartfuel.page", tostring(message), "warn")
	end
end

local function pageText(i18n, key, fallback)
	if t then
		return t(i18n, key, fallback)
	end
	return fallback
end

local function pageHelpText(i18n, key, fallback)
	return pageText(i18n, key, fallback)
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

local function buildModeOptions()
	return {
		{ value = 0, label = "OFF (LOCAL)" },
		{ value = 1, label = "VOLTAGE" },
		{ value = 2, label = "CURRENT" },
		{ value = 3, label = "COMBINED" }
	}
end

local function buildLocalOptions()
	return {
		{ value = 0, label = "CURRENT" },
		{ value = 1, label = "VOLTAGE" },
		{ value = 2, label = "COMBINED" }
	}
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

local function loadFromSession()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	local cfg = (type(session) == "table" and type(session.smartfuel_config) == "table") and session.smartfuel_config or nil

	ui.support.firmware = isFirmwareSupported(session)
	ui.config.local_source = clampInt((batteryPrefs and batteryPrefs.smartfuel_source) or (batteryPrefs and batteryPrefs.calc_local), 0, 2, 0)
	ui.config.firmware_mode = clampInt(cfg and cfg.smartfuel_mode, 0, 3, 0)

	local voltageDrop = (cfg and cfg.voltage_drop_rate) or (batteryPrefs and batteryPrefs.voltage_drop_rate)
	local chargeDrop = (cfg and cfg.charge_drop_rate) or (batteryPrefs and batteryPrefs.charge_drop_rate)
	local sagGain = (cfg and cfg.sag_gain) or (batteryPrefs and batteryPrefs.sag_gain)
	ui.config.voltage_drop_rate = clampInt(voltageDrop, 0, 250, 10)
	ui.config.charge_drop_rate = clampInt(chargeDrop, 0, 250, 50)
	ui.config.sag_gain = clampInt(sagGain, 0, 100, 40)
end

local function buildSessionSignature()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	local cfg = (type(session) == "table" and type(session.smartfuel_config) == "table") and session.smartfuel_config or nil
	local apiVersion = session and session.apiVersion or ""
	return table.concat({
		tostring(apiVersion or ""),
		tostring(ui.support.firmware and 1 or 0),
		tostring(cfg and cfg.smartfuel_mode or ""),
		tostring(cfg and cfg.voltage_drop_rate or ""),
		tostring(cfg and cfg.charge_drop_rate or ""),
		tostring(cfg and cfg.sag_gain or ""),
		tostring(batteryPrefs and batteryPrefs.smartfuel_source or batteryPrefs and batteryPrefs.calc_local or ""),
		tostring(batteryPrefs and batteryPrefs.voltage_drop_rate or ""),
		tostring(batteryPrefs and batteryPrefs.charge_drop_rate or ""),
		tostring(batteryPrefs and batteryPrefs.sag_gain or "")
	}, "|")
end

local function queueSmartfuelRead()
	ensureRuntime()
	if ui.runtime.readPending then
		logDebug("read skipped: pending")
		return false, "read_pending"
	end
	if not ui.support.firmware then
		logDebug("read skipped: firmware_not_supported")
		return false, "firmware_not_supported"
	end
	if not SmartfuelApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
		logWarn("read skipped: msp runtime/api unavailable")
		return false, "msp_runtime_unavailable"
	end

	local session = getSession()
	local mspState = MspRuntime.getState()
	local queue = mspState and mspState.queue
	if not queue or type(queue.add) ~= "function" then
		logWarn("read skipped: msp queue unavailable")
		return false, "msp_queue_unavailable"
	end

	ui.runtime.readPending = true
	ui.loading = true
	ui.progress = 0
	local api = SmartfuelApi
	logDebug("read enqueue cmd=" .. tostring(api.command) .. " apiVersion=" .. tostring(session and session.apiVersion) .. " firmwareSupport=" .. tostring(ui.support.firmware))
	queue:add({
		command = api.command,
		simulatorResponse = api.simulatorResponse,
		timeout = 5.0,
		processReply = function(_, buf)
			logDebug("read reply cmd=" .. tostring(api.command) .. " bytes=" .. tostring(type(buf) == "table" and #buf or 0))
			ui.runtime.readPending = false
			ui.loading = false
			ui.progress = 1
			if type(session) == "table" then
				local parsed = api.parse and api.parse(buf) or nil
				if type(parsed) == "table" then
					session.smartfuel_config = parsed
					if type(session.battery_config) == "table" then
						session.battery_config.smartfuelRemoteSource = tonumber(session.smartfuel_config.smartfuel_mode) or 0
					end
				end
			end
			if not ui.dirty then
				loadFromSession()
			end
			if type(ui.runtime.requestRebuild) == "function" then
				ui.runtime.requestRebuild()
			end
		end,
		errorHandler = function()
			logWarn("read error cmd=" .. tostring(api.command))
			ui.runtime.readPending = false
			ui.loading = false
			ui.progress = 1
		end
	})

	return true, nil
end

local function ensureLoaded()
	ensureRuntime()
	if ui.loaded then return end
	loadFromSession()
	ui.runtime.lastSessionSignature = buildSessionSignature()
	ui.loaded = true
	ui.dirty = false
	queueSmartfuelRead()
end

local function saveModelPreferences(session)
	if not PowerModelPreferences or type(PowerModelPreferences.save) ~= "function" then
		return false, "model_preferences_unavailable"
	end
	return PowerModelPreferences.save(session)
end

local function queueSmartfuelWrite(session)
	if not ui.support.firmware then
		logDebug("write skipped: firmware_not_supported")
		return true, nil
	end
	if not SmartfuelApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
		logWarn("write skipped: msp runtime/api unavailable")
		return false, "msp_runtime_unavailable"
	end

	local mspState = MspRuntime.getState()
	local queue = mspState and mspState.queue
	if not queue or type(queue.add) ~= "function" then
		logWarn("write skipped: msp queue unavailable")
		return false, "msp_queue_unavailable"
	end

	local api = SmartfuelApi
	local payload = api.buildWritePayload({
		smartfuel_mode = ui.config.firmware_mode,
		voltage_drop_rate = ui.config.voltage_drop_rate,
		charge_drop_rate = ui.config.charge_drop_rate,
		sag_gain = ui.config.sag_gain
	})
	logDebug("write enqueue cmd=" .. tostring(api.writeCommand)
		.. " payload=["
		.. tostring(payload and payload[1]) .. ","
		.. tostring(payload and payload[2]) .. ","
		.. tostring(payload and payload[3]) .. ","
		.. tostring(payload and payload[4]) .. "]")

	queue:add({
		command = api.writeCommand,
		payload = payload,
		timeout = 5.0,
		isWrite = true,
		processReply = function()
			logDebug("write reply cmd=" .. tostring(api.writeCommand))
			if type(session) == "table" then
				session.smartfuel_config = session.smartfuel_config or {}
				session.smartfuel_config.smartfuel_mode = ui.config.firmware_mode
				session.smartfuel_config.voltage_drop_rate = ui.config.voltage_drop_rate
				session.smartfuel_config.charge_drop_rate = ui.config.charge_drop_rate
				session.smartfuel_config.sag_gain = ui.config.sag_gain
			end
		end,
		errorHandler = function()
			logWarn("write error cmd=" .. tostring(api.writeCommand))
			-- Keep local values; FC write can be retried with Save.
		end
	})

	return true, nil
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
	ui.support.firmware = isFirmwareSupported(session)
	logDebug("onSave firmwareSupport=" .. tostring(ui.support.firmware) .. " apiVersion=" .. tostring(session and session.apiVersion))
	local batteryPrefs = getBatteryPrefs(session)
	if not batteryPrefs then
		logWarn("onSave aborted: missing batteryPrefs")
		return false
	end

	if not ui.support.firmware then
		batteryPrefs.smartfuel_source = ui.config.local_source
		batteryPrefs.calc_local = ui.config.local_source
	end
	batteryPrefs.voltage_drop_rate = ui.config.voltage_drop_rate
	batteryPrefs.charge_drop_rate = ui.config.charge_drop_rate
	batteryPrefs.sag_gain = ui.config.sag_gain

	local okPrefs, errPrefs = saveModelPreferences(session)

	if ui.support.firmware then
		session.smartfuel_config = session.smartfuel_config or {}
		session.smartfuel_config.smartfuel_mode = ui.config.firmware_mode
		session.smartfuel_config.voltage_drop_rate = ui.config.voltage_drop_rate
		session.smartfuel_config.charge_drop_rate = ui.config.charge_drop_rate
		session.smartfuel_config.sag_gain = ui.config.sag_gain

		if type(session.battery_config) == "table" then
			session.battery_config.smartfuelRemoteSource = ui.config.firmware_mode
		end
	end

	local okMsp, errMsp = queueSmartfuelWrite(session)

	if ctx and type(ctx.reportSave) == "function" then
		if okMsp and okPrefs then
			local savedTitle = pageText(ctx and ctx.i18n, "saved_title", "Saved")
			local savedMessage = pageText(ctx and ctx.i18n, "saved_message", "SmartFuel settings saved")
			ctx.reportSave({ ok = true, title = savedTitle, message = savedMessage })
		elseif okMsp and not okPrefs then
			ctx.reportSave({ title = "Warning", message = "SmartFuel values sent to FC. Model prefs save failed: " .. tostring(errPrefs or "io") })
		elseif (not okMsp) and okPrefs then
			ctx.reportSave({ title = "Warning", message = "Saved local SmartFuel values. FC write pending: " .. tostring(errMsp or "msp") })
		else
			ctx.reportSave({ title = "Warning", message = "FC write pending and model prefs save failed: " .. tostring(errPrefs or "io") })
		end
	end

	-- Force smart calculator to pick up new config immediately.
	if _G and _G.rfsuite and _G.rfsuite.tasks and _G.rfsuite.tasks.events then
		local bg = _G.rfsuite.tasks.events.telemetry_bg
		if type(bg) == "table" and type(bg.reset) == "function" then
			pcall(bg.reset)
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

	local previousFirmwareSupport = ui.support.firmware
	loadFromSession()
	if ui.support.firmware and (not previousFirmwareSupport) then
		logDebug("firmware support became available; triggering read")
		queueSmartfuelRead()
	end

	local signature = buildSessionSignature()
	if signature ~= ui.runtime.lastSessionSignature then
		ui.runtime.lastSessionSignature = signature
		if type(ui.runtime.requestRebuild) == "function" then
			ui.runtime.requestRebuild()
		end
	end
end

local function getLocalSourceSetter()
	if ui.runtime.localSourceSet then return ui.runtime.localSourceSet end
	ui.runtime.localSourceSet = function(value)
		local nextValue = clampInt(value, 0, 2, 0)
		if ui.config.local_source == nextValue then return end
		ui.config.local_source = nextValue
		markDirty()
	end
	return ui.runtime.localSourceSet
end

local function getFirmwareModeSetter()
	if ui.runtime.firmwareModeSet then return ui.runtime.firmwareModeSet end
	ui.runtime.firmwareModeSet = function(value)
		local nextValue = clampInt(value, 0, 3, 0)
		if ui.config.firmware_mode == nextValue then return end
		ui.config.firmware_mode = nextValue
		markDirty()
	end
	return ui.runtime.firmwareModeSet
end

local function getVoltageSetter()
	if ui.runtime.voltageSet then return ui.runtime.voltageSet end
	ui.runtime.voltageSet = function(value)
		local nextValue = clampInt(value, 0, 250, 10)
		if ui.config.voltage_drop_rate == nextValue then return end
		ui.config.voltage_drop_rate = nextValue
		markDirty()
	end
	return ui.runtime.voltageSet
end

local function getChargeSetter()
	if ui.runtime.chargeSet then return ui.runtime.chargeSet end
	ui.runtime.chargeSet = function(value)
		local nextValue = clampInt(value, 0, 250, 50)
		if ui.config.charge_drop_rate == nextValue then return end
		ui.config.charge_drop_rate = nextValue
		markDirty()
	end
	return ui.runtime.chargeSet
end

local function getSagSetter()
	if ui.runtime.sagSet then return ui.runtime.sagSet end
	ui.runtime.sagSet = function(value)
		local nextValue = clampInt(value, 0, 100, 40)
		if ui.config.sag_gain == nextValue then return end
		ui.config.sag_gain = nextValue
		markDirty()
	end
	return ui.runtime.sagSet
end

local function isTuningEnabled()
	if not ui.support.firmware then return true end
	return ui.config.firmware_mode == 1 or ui.config.firmware_mode == 3
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
	local h = ctx.h or 200

	Controls.appendStaticSectionHeader(children, x, y, w, pageText(i18n, "section_mode", "SmartFuel Mode"))
	local cursorY = y + Controls.STATIC_SECTION_H

	if ui.support.firmware then
		cursorY = cursorY + Controls.appendComboSelect(
			children, x, cursorY, w,
			pageText(i18n, "firmware_mode", "Firmware Source"),
			buildModeOptions(),
			ui.config.firmware_mode,
			getFirmwareModeSetter(),
			{
				helpText = pageHelpText(i18n, "help_firmware_mode", "Choose whether firmware SmartFuel is disabled, voltage-estimated, current consumption based, or combined. Combined uses the more pessimistic of voltage and current consumption."),
				helpTitle = pageText(i18n, "firmware_mode", "Firmware Source"),
				onHelp = getInlineHelpHandler()
			}
		)
	end

	if not ui.support.firmware then
		cursorY = cursorY + Controls.appendComboSelect(
			children, x, cursorY, w,
			pageText(i18n, "local_mode", "Local Source"),
			buildLocalOptions(),
			ui.config.local_source,
			getLocalSourceSetter(),
			{
				helpText = pageHelpText(i18n, "help_local_mode", "Choose whether local SmartFuel uses current consumption, pack voltage, or combined mode. Combined uses the more pessimistic of voltage and current consumption."),
				helpTitle = pageText(i18n, "local_mode", "Local Source"),
				onHelp = getInlineHelpHandler()
			}
		)
	end

	cursorY = cursorY + 8
	Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "section_tuning", "SmartFuel Tuning"))
	cursorY = cursorY + Controls.STATIC_SECTION_H

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "voltage_drop_rate", "Voltage drop rate"), {
			min = 0,
			max = 250,
			get = function() return ui.config.voltage_drop_rate end,
			set = getVoltageSetter(),
			enabled = isTuningEnabled,
			helpText = pageHelpText(i18n, "help_voltage_drop_rate", "Limits how quickly filtered voltage may fall in voltage mode to reduce brief load-sag spikes affecting SmartFuel."),
			helpTitle = pageText(i18n, "voltage_drop_rate", "Voltage drop rate"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return tostring(v) .. " mV/s" end
		})

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "charge_drop_rate", "Charge drop rate"), {
			min = 0,
			max = 250,
			get = function() return ui.config.charge_drop_rate end,
			set = getChargeSetter(),
			enabled = isTuningEnabled,
			helpText = pageHelpText(i18n, "help_charge_drop_rate", "Maximum rate the reported SmartFuel value may recover in voltage mode after load is reduced."),
			helpTitle = pageText(i18n, "charge_drop_rate", "Charge drop rate"),
			onHelp = getInlineHelpHandler(),
			display = function(v)
				local value = (tonumber(v) or 0) / 100
				return string.format("%.2f %%/s", value)
			end
		})

	Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "sag_gain", "Sag gain"), {
			min = 0,
			max = 100,
			get = function() return ui.config.sag_gain end,
			set = getSagSetter(),
			enabled = isTuningEnabled,
			helpText = pageHelpText(i18n, "help_sag_gain", "Strength of load-sag compensation in voltage mode. Higher values compensate more aggressively."),
			helpTitle = pageText(i18n, "sag_gain", "Sag gain"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return tostring(v) .. "%" end
		})

	if ui.loading then
		local title = pageText(i18n, "loading_title", "Loading")
		local message = pageText(i18n, "loading_message", "Reading SmartFuel config")
		if LoadingOverlay then
			LoadingOverlay.append(children, {
				x = x,
				y = y,
				w = w,
				h = h,
				title = title,
				message = message,
				progress = ui.progress
			})
		end
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
	PowerModelPreferences = nil
	MspRuntime = nil
	SmartfuelApi = nil
	Log = nil
	LoadingOverlay = nil
	t = nil
end

return M
