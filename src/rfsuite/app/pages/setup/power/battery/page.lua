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
local BatteryConfigApi = nil
local BatteryProfileApi = nil
local Sensors = nil
local SmartFuelReserve = nil
local t = nil

M.eepromWrite = true

local PROFILE_MIN = 0
local PROFILE_MAX = 5
local CAPACITY_MIN = 0
local CAPACITY_MAX = 40000
local CELL_COUNT_MIN = 0
local CELL_COUNT_MAX = 24
local RESERVE_MIN = 15
local RESERVE_MAX = 60

local function newRuntime()
	return {
		capacitySets = {},
		profileSet = nil,
		maxCellSet = nil,
		fullCellSet = nil,
		warnCellSet = nil,
		minCellSet = nil,
		cellCountSet = nil,
		reserveSet = nil,
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
	-- Tracks whether the pilot has actively changed the Consumption reserve field
	-- in this session. Only when true will onSave write consumptionWarningPercentage
	-- back to the flight controller, preventing silent overwrites of cbat_alert_percent.
	reserveDirty = false,
	-- Tracks whether the pilot has actively changed the Selected Battery combo in this
	-- session. Only when true does onSave send MSP_SET_BATTERY_PROFILE, so a page that has
	-- no source for the active profile never switches the profile the board is running.
	profileDirty = false,
	config = {
		selectedBatteryProfile = 0,
		capacities = { 0, 0, 0, 0, 0, 0 },
		vbatmaxcellvoltage = 420,
		vbatfullcellvoltage = 410,
		vbatwarningcellvoltage = 350,
		vbatmincellvoltage = 330,
		batteryCellCount = 0,
		consumption_warning_percentage = 35
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
	if not PowerModelPreferences then PowerModelPreferences = loadModule("app/pages/setup/power/model_preferences.lua") end
	if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
	if not BatteryConfigApi then BatteryConfigApi = loadModule("tasks/msp/api/battery_config.lua") end
	if not BatteryProfileApi then BatteryProfileApi = loadModule("tasks/msp/api/battery_profile.lua") end
	if not Sensors then Sensors = loadModule("lib/sensors.lua") end
	if not SmartFuelReserve then SmartFuelReserve = loadModule("lib/smartfuel_reserve.lua") end
	if not t then t = Common and Common.pageT("setup_power_battery") or nil end
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

local function optionalPageHelpText(i18n, key)
	local value = pageHelpText(i18n, key, nil)
	if type(value) ~= "string" or value == "" then return nil end
	if string.sub(value, 1, 10) == "app.pages." then return nil end
	return value
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

local function markDirty()
	ui.dirty = true
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

local function getActiveProfileFromSensor()
	if Sensors and type(Sensors.getValue) == "function" then
		-- The flight controller reports this sensor as index + 1, so a live reading is 1..6.
		-- A sensor the radio has stopped receiving reads 0 rather than nothing, and 0 is not a
		-- value the sensor can carry: it means the reading is gone, not that profile 1 is
		-- active. Anything outside 1..6 is therefore no answer at all.
		local raw = tonumber(Sensors.getValue("battery_profile"))
		if raw and raw >= 1 and raw <= 6 then
			return math.floor(raw) - 1
		end
	end
	return nil
end

-- Returns the active battery profile as a 0-based index, or nil where the page has no source
-- for it. Nil is a real answer here rather than a failure: BATTERY_PROFILE is a custom CRSF
-- sensor and does not exist on a native CRSF link, MSP_BATTERY_CONFIG carries no profile
-- field, and nothing in the suite issues MSP_BATTERY_PROFILE -- so on such a setup the page
-- genuinely cannot know which profile the board is running. clampInt cannot express that,
-- because it floors a nil input onto its fallback, so each source is tested before it is
-- clamped.
local function resolveProfile(session, batteryConfig)
	local sensorProfile = getActiveProfileFromSensor()
	if sensorProfile ~= nil then return sensorProfile end
	if session ~= nil and tonumber(session.activeBatteryType) ~= nil then
		return clampInt(session.activeBatteryType, PROFILE_MIN, PROFILE_MAX, PROFILE_MIN)
	end
	if batteryConfig ~= nil and tonumber(batteryConfig.batteryProfile) ~= nil then
		return clampInt(batteryConfig.batteryProfile, PROFILE_MIN, PROFILE_MAX, PROFILE_MIN)
	end
	return nil
end

local function buildSessionSignature()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	local batteryConfig = getBatteryConfig(session)
	if not batteryConfig then return "nil" end

	local parts = {
		tostring(resolveProfile(session, batteryConfig)),
		tostring(batteryConfig.vbatmaxcellvoltage or ""),
		tostring(batteryConfig.vbatfullcellvoltage or ""),
		tostring(batteryConfig.vbatwarningcellvoltage or ""),
		tostring(batteryConfig.vbatmincellvoltage or ""),
		tostring(batteryConfig.batteryCellCount or ""),
		tostring((batteryPrefs and batteryPrefs.consumption_warning_percentage) or batteryConfig.consumptionWarningPercentage or "")
	}
	for i = 0, 5 do
		parts[#parts + 1] = tostring(batteryConfig["batteryCapacity_" .. tostring(i)] or "")
	end
	return table.concat(parts, "|")
end

local function loadFromSession()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	local batteryConfig = getBatteryConfig(session)
	-- With no source the combo still shows the first profile, as it always has; what changed
	-- is that nothing is written to the board on the strength of that display.
	ui.config.selectedBatteryProfile = resolveProfile(session, batteryConfig) or PROFILE_MIN

	for i = 0, 5 do
		ui.config.capacities[i + 1] = clampInt(batteryConfig and batteryConfig["batteryCapacity_" .. tostring(i)], CAPACITY_MIN, CAPACITY_MAX, 0)
	end

	ui.config.vbatmaxcellvoltage = clampInt(batteryConfig and batteryConfig.vbatmaxcellvoltage, 250, 500, 420)
	ui.config.vbatfullcellvoltage = clampInt(batteryConfig and batteryConfig.vbatfullcellvoltage, 250, 500, 410)
	ui.config.vbatwarningcellvoltage = clampInt(batteryConfig and batteryConfig.vbatwarningcellvoltage, 250, 500, 350)
	ui.config.vbatmincellvoltage = clampInt(batteryConfig and batteryConfig.vbatmincellvoltage, 250, 500, 330)
	ui.config.batteryCellCount = clampInt(batteryConfig and batteryConfig.batteryCellCount, CELL_COUNT_MIN, CELL_COUNT_MAX, 0)

	-- Resolve consumption reserve: SmartFuelReserve.pick prioritizes explicit per-model
	-- preference when set by the pilot, then falls through to the FC's cbat_alert_percent.
	-- Since defaultModelPreferences() no longer seeds 35, unedited models will pick the board value.
	local reserve = SmartFuelReserve and SmartFuelReserve.pick(session, batteryConfig)
	if reserve == nil then
		reserve = batteryConfig and batteryConfig.consumptionWarningPercentage
		if reserve == nil then
			reserve = batteryPrefs and batteryPrefs.consumption_warning_percentage
		end
	end
	ui.config.consumption_warning_percentage = clampInt(reserve, RESERVE_MIN, RESERVE_MAX, 35)
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
local function getCapacitySetter(index)
	local setter = ui.runtime.capacitySets[index]
	if setter then return setter end
	setter = function(value)
		local nextValue = clampInt(value, CAPACITY_MIN, CAPACITY_MAX, 0)
		if ui.config.capacities[index] == nextValue then return end
		ui.config.capacities[index] = nextValue
		markDirty()
	end
	ui.runtime.capacitySets[index] = setter
	return setter
end

local function getProfileSetter()
	if ui.runtime.profileSet then return ui.runtime.profileSet end
	ui.runtime.profileSet = function(value)
		local nextValue = clampInt(value, PROFILE_MIN, PROFILE_MAX, PROFILE_MIN)
		if ui.config.selectedBatteryProfile == nextValue then return end
		ui.config.selectedBatteryProfile = nextValue
		ui.profileDirty = true
		markDirty()
	end
	return ui.runtime.profileSet
end

local function getMaxCellSetter()
	if ui.runtime.maxCellSet then return ui.runtime.maxCellSet end
	ui.runtime.maxCellSet = function(value)
		local nextValue = clampInt(value, 250, 500, 420)
		if ui.config.vbatmaxcellvoltage == nextValue then return end
		ui.config.vbatmaxcellvoltage = nextValue
		markDirty()
	end
	return ui.runtime.maxCellSet
end

local function getFullCellSetter()
	if ui.runtime.fullCellSet then return ui.runtime.fullCellSet end
	ui.runtime.fullCellSet = function(value)
		local nextValue = clampInt(value, 250, 500, 410)
		if ui.config.vbatfullcellvoltage == nextValue then return end
		ui.config.vbatfullcellvoltage = nextValue
		markDirty()
	end
	return ui.runtime.fullCellSet
end

local function getWarnCellSetter()
	if ui.runtime.warnCellSet then return ui.runtime.warnCellSet end
	ui.runtime.warnCellSet = function(value)
		local nextValue = clampInt(value, 250, 500, 350)
		if ui.config.vbatwarningcellvoltage == nextValue then return end
		ui.config.vbatwarningcellvoltage = nextValue
		markDirty()
	end
	return ui.runtime.warnCellSet
end

local function getMinCellSetter()
	if ui.runtime.minCellSet then return ui.runtime.minCellSet end
	ui.runtime.minCellSet = function(value)
		local nextValue = clampInt(value, 250, 500, 330)
		if ui.config.vbatmincellvoltage == nextValue then return end
		ui.config.vbatmincellvoltage = nextValue
		markDirty()
	end
	return ui.runtime.minCellSet
end

local function getCellCountSetter()
	if ui.runtime.cellCountSet then return ui.runtime.cellCountSet end
	ui.runtime.cellCountSet = function(value)
		local nextValue = clampInt(value, CELL_COUNT_MIN, CELL_COUNT_MAX, 0)
		if ui.config.batteryCellCount == nextValue then return end
		ui.config.batteryCellCount = nextValue
		markDirty()
	end
	return ui.runtime.cellCountSet
end

local function getReserveSetter()
	if ui.runtime.reserveSet then return ui.runtime.reserveSet end
	ui.runtime.reserveSet = function(value)
		local nextValue = clampInt(value, RESERVE_MIN, RESERVE_MAX, 35)
		if ui.config.consumption_warning_percentage == nextValue then return end
		ui.config.consumption_warning_percentage = nextValue
		ui.reserveDirty = true
		markDirty()
	end
	return ui.runtime.reserveSet
end

local function saveModelPreferences(session)
	if not PowerModelPreferences or type(PowerModelPreferences.save) ~= "function" then
		return false, "model_preferences_unavailable"
	end
	return PowerModelPreferences.save(session)
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
	ui.dirty = false
	ui.reserveDirty = false
	ui.profileDirty = false
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
	local batteryPrefs = getBatteryPrefs(session)
	local batteryConfig = getBatteryConfig(session)
	if not batteryPrefs or not batteryConfig then
		return false
	end

	local reserve = clampInt(ui.config.consumption_warning_percentage, RESERVE_MIN, RESERVE_MAX, 35)
	local activeProfile = clampInt(ui.config.selectedBatteryProfile, PROFILE_MIN, PROFILE_MAX, PROFILE_MIN)
	-- True where the profile shown is one the page can stand behind: either the pilot picked it
	-- on this page, or a source answered for it. Otherwise it is the combo's fallback and says
	-- nothing about the board.
	local profileKnown = ui.profileDirty or resolveProfile(session, batteryConfig) ~= nil
	local activeCapacity = clampInt(ui.config.capacities[activeProfile + 1], CAPACITY_MIN, CAPACITY_MAX, 0)

	batteryConfig.batteryCellCount = clampInt(ui.config.batteryCellCount, CELL_COUNT_MIN, CELL_COUNT_MAX, 0)
	batteryConfig.vbatmaxcellvoltage = clampInt(ui.config.vbatmaxcellvoltage, 250, 500, 420)
	batteryConfig.vbatfullcellvoltage = clampInt(ui.config.vbatfullcellvoltage, 250, 500, 410)
	batteryConfig.vbatwarningcellvoltage = clampInt(ui.config.vbatwarningcellvoltage, 250, 500, 350)
	batteryConfig.vbatmincellvoltage = clampInt(ui.config.vbatmincellvoltage, 250, 500, 330)
	-- Fix for issue #52: only overwrite consumptionWarningPercentage in batteryConfig
	-- when the pilot explicitly edited the Consumption reserve spinner.
	-- If unedited, preserve the existing FC value; if batteryConfig has no value yet,
	-- populate from ui.config so we never write 0 to the FC.
	if ui.reserveDirty then
		batteryConfig.consumptionWarningPercentage = reserve
	elseif batteryConfig.consumptionWarningPercentage == nil then
		batteryConfig.consumptionWarningPercentage = reserve
	end
	for i = 0, 5 do
		batteryConfig["batteryCapacity_" .. tostring(i)] = clampInt(ui.config.capacities[i + 1], CAPACITY_MIN, CAPACITY_MAX, 0)
	end
	-- All three of these name the active profile, so none may be set from the combo's fallback.
	-- batteryCapacity is the active profile's capacity: the read filled it from the board, and
	-- replacing it with the capacity of a guessed profile makes the session copy describe a
	-- profile the board is not running. It costs nothing on the wire either way, because
	-- MSP_SET_BATTERY_CONFIG writes its first field into the board's own active slot and the
	-- six capacities at the tail of the same payload then overwrite all of them.
	if profileKnown then
		batteryConfig.batteryProfile = activeProfile
		batteryConfig.batteryCapacity = activeCapacity
		session.activeBatteryType = activeProfile
	end
	session.battery_config = batteryConfig
	session.batteryConfig = batteryConfig

	-- Only persist the reserve preference when the pilot explicitly changed it.
	if ui.reserveDirty then
		batteryPrefs.consumption_warning_percentage = reserve
	end
	local okPrefs, errPrefs = saveModelPreferences(session)

	local okMsp = false
	if MspRuntime and BatteryConfigApi and type(MspRuntime.getState) == "function" then
		local mspState = MspRuntime.getState()
		local queue = mspState and mspState.queue
		if queue and type(queue.add) == "function" then
			okMsp = true
			-- Only send the profile where the pilot selected one on this page. The page cannot
			-- read the active profile back from the flight controller, so sending the combo's
			-- fallback switches the board to profile 1 on every save made on a setup with no
			-- BATTERY_PROFILE sensor, and M.eepromWrite makes that permanent.
			if ui.profileDirty and BatteryProfileApi and type(BatteryProfileApi.buildWritePayload) == "function" then
				queue:add({
					command = BatteryProfileApi.writeCommand,
					payload = BatteryProfileApi.buildWritePayload({ batteryProfile = activeProfile }),
					timeout = 5.0,
					isWrite = true,
					processReply = function() end,
					errorHandler = function() end
				})
			end

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

	if _G and _G.rfsuite and _G.rfsuite.tasks and _G.rfsuite.tasks.events then
		local bg = _G.rfsuite.tasks.events.telemetry_bg
		if type(bg) == "table" and type(bg.reset) == "function" then
			pcall(bg.reset)
		end
	end

	if ctx and type(ctx.reportSave) == "function" then
		if okMsp and okPrefs then
			ctx.reportSave({
				ok = true,
				title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
				message = pageText(ctx and ctx.i18n, "saved_message", "Battery settings saved")
			})
		elseif okMsp and not okPrefs then
			ctx.reportSave({
				title = pageText(ctx and ctx.i18n, "warning_title", "Warning"),
				message = "Battery values sent to FC. Model prefs save failed: " .. tostring(errPrefs or "io")
			})
		elseif (not okMsp) and okPrefs then
			ctx.reportSave({
				title = pageText(ctx and ctx.i18n, "warning_title", "Warning"),
				message = pageText(ctx and ctx.i18n, "saved_local_only_message", "Saved locally; FC write pending")
			})
		else
			ctx.reportSave({
				title = pageText(ctx and ctx.i18n, "warning_title", "Warning"),
				message = "FC write pending and model prefs save failed: " .. tostring(errPrefs or "io")
			})
		end
	end

	ui.dirty = false
	ui.reserveDirty = false
	ui.profileDirty = false
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
	Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "section_profiles", "Profiles"))
	cursorY = cursorY + Controls.STATIC_SECTION_H

	local profileOptions = {}
	for i = 1, 6 do
		profileOptions[i] = {
			value = i - 1,
			label = pageText(i18n, "battery_slot", "Battery") .. " " .. tostring(i)
		}
	end

	cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
		pageText(i18n, "selected", "Selected") .. " " .. pageText(i18n, "battery_slot", "Battery"),
		profileOptions,
		ui.config.selectedBatteryProfile,
		getProfileSetter(), {
			helpText = optionalPageHelpText(i18n, "help_selected_battery"),
			helpTitle = pageText(i18n, "selected", "Selected") .. " " .. pageText(i18n, "battery_slot", "Battery"),
			onHelp = getInlineHelpHandler()
		})

	for i = 1, 6 do
		local label = pageText(i18n, "battery_slot", "Battery") .. " " .. tostring(i)
		cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
			label, {
				min = CAPACITY_MIN,
				max = CAPACITY_MAX,
				get = function() return ui.config.capacities[i] end,
				set = getCapacitySetter(i),
				helpText = optionalPageHelpText(i18n, "help_capacity"),
				helpTitle = label,
				onHelp = getInlineHelpHandler(),
				display = function(v) return tostring(v) .. " mAh" end
			})
	end

	cursorY = cursorY + 8
	Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "section_battery", "Battery"))
	cursorY = cursorY + Controls.STATIC_SECTION_H

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "max_cell_voltage", "Max cell voltage"), {
			min = 250,
			max = 500,
			get = function() return ui.config.vbatmaxcellvoltage end,
			set = getMaxCellSetter(),
			helpText = optionalPageHelpText(i18n, "help_max_cell_voltage"),
			helpTitle = pageText(i18n, "max_cell_voltage", "Max cell voltage"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return string.format("%.2f V", (tonumber(v) or 0) / 100) end
		})

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "full_cell_voltage", "Full cell voltage"), {
			min = 250,
			max = 500,
			get = function() return ui.config.vbatfullcellvoltage end,
			set = getFullCellSetter(),
			helpText = optionalPageHelpText(i18n, "help_full_cell_voltage"),
			helpTitle = pageText(i18n, "full_cell_voltage", "Full cell voltage"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return string.format("%.2f V", (tonumber(v) or 0) / 100) end
		})

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "warn_cell_voltage", "Warn cell voltage"), {
			min = 250,
			max = 500,
			get = function() return ui.config.vbatwarningcellvoltage end,
			set = getWarnCellSetter(),
			helpText = optionalPageHelpText(i18n, "help_warn_cell_voltage"),
			helpTitle = pageText(i18n, "warn_cell_voltage", "Warn cell voltage"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return string.format("%.2f V", (tonumber(v) or 0) / 100) end
		})

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "min_cell_voltage", "Min cell voltage"), {
			min = 250,
			max = 500,
			get = function() return ui.config.vbatmincellvoltage end,
			set = getMinCellSetter(),
			helpText = optionalPageHelpText(i18n, "help_min_cell_voltage"),
			helpTitle = pageText(i18n, "min_cell_voltage", "Min cell voltage"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return string.format("%.2f V", (tonumber(v) or 0) / 100) end
		})

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "cell_count", "Cell count"), {
			min = CELL_COUNT_MIN,
			max = CELL_COUNT_MAX,
			get = function() return ui.config.batteryCellCount end,
			set = getCellCountSetter(),
			helpText = optionalPageHelpText(i18n, "help_cell_count"),
			helpTitle = pageText(i18n, "cell_count", "Cell count"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return tostring(v) end
		})

	cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
		pageText(i18n, "consumption_warning_percentage", "Consumption reserve"), {
			min = RESERVE_MIN,
			max = RESERVE_MAX,
			get = function() return ui.config.consumption_warning_percentage end,
			set = getReserveSetter(),
			helpText = optionalPageHelpText(i18n, "help_consumption_warning_percentage"),
			helpTitle = pageText(i18n, "consumption_warning_percentage", "Consumption reserve"),
			onHelp = getInlineHelpHandler(),
			display = function(v) return tostring(v) .. "%" end
		})

	if ui.loading then
		local title = pageText(i18n, "loading_title", "Loading")
		local message = pageText(i18n, "loading_message", "Reading battery config")
		local LoadingOverlay = loadModule("ui/loading_overlay.lua")
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
	ui.reserveDirty = false
	ui.profileDirty = false
	ui.loading = false
	ui.progress = 0
	Controls = nil
	Common = nil
	PowerModelPreferences = nil
	MspRuntime = nil
	BatteryConfigApi = nil
	BatteryProfileApi = nil
	Sensors = nil
	SmartFuelReserve = nil
	t = nil
end

return M
