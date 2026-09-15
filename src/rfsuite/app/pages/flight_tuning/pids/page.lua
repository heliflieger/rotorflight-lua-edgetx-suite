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
local PidTuningApi = nil
local LoadingOverlay = nil
local Sensors = nil
local Profile = nil
local t = nil
local getSession = nil

M.eepromWrite = true

local FIELD_KEYS = {
	"pid_0_P", "pid_0_I", "pid_0_D", "pid_0_F", "pid_0_O", "pid_0_B",
	"pid_1_P", "pid_1_I", "pid_1_D", "pid_1_F", "pid_1_O", "pid_1_B",
	"pid_2_P", "pid_2_I", "pid_2_D", "pid_2_F", "pid_2_B"
}

local FIELD_LIMITS = {
	min = 0,
	max = 1000
}

local ROWS = {
	{
		key = "roll",
		labelKey = "roll",
		fields = {
			"pid_0_P", "pid_0_I", "pid_0_D", "pid_0_F", "pid_0_O", "pid_0_B"
		}
	},
	{
		key = "pitch",
		labelKey = "pitch",
		fields = {
			"pid_1_P", "pid_1_I", "pid_1_D", "pid_1_F", "pid_1_O", "pid_1_B"
		}
	},
	{
		key = "yaw",
		labelKey = "yaw",
		fields = {
			"pid_2_P", "pid_2_I", "pid_2_D", "pid_2_F", nil, "pid_2_B"
		}
	}
}

local COLUMNS = { "p", "i", "d", "f", "o", "b" }

local function newRuntime()
	return {
		readPending = false,
		requestRebuild = nil,
		fieldSetters = {},
		lastSessionSignature = nil
	}
end

local ui = {
	loaded = false,
	dirty = false,
	config = {},
	runtime = newRuntime(),
	loading = false,
	progress = 0,
	baseTitle = nil
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
	if not PidTuningApi then PidTuningApi = loadModule("tasks/msp/api/pid_tuning.lua") end
	if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
	if not Sensors then Sensors = loadModule("lib/sensors.lua") end
	if not Profile then Profile = loadModule("lib/profile.lua") end
	if not t then t = Common and Common.pageT("flight_tuning_pids") or nil end
	if Common and not ui.runtimeBase then
		ui.runtimeBase = Common.createProfileAwareRuntime({ profileType = "pid" })
		if type(ui.runtime) ~= "table" then
			ui.runtime = newRuntime()
		end
		setmetatable(ui.runtime, { __index = ui.runtimeBase })
	end
end

local function pageText(i18n, key, fallback)
	if t then
		local translated = t(i18n, key, fallback)
		if translated ~= nil and translated ~= "" and translated ~= key then
			return translated
		end
	end
	return fallback
end

local function pageHelpText(i18n, key, fallback)
	return pageText(i18n, key, fallback)
end

function getSession()
	local root = _G and _G.rfsuite
	return root and root.session or nil
end

local function getPidConfig(session)
	if type(session) ~= "table" then return nil end
	if type(session.pid_tuning) ~= "table" then
		if type(session.pidTuning) == "table" then
			session.pid_tuning = session.pidTuning
		else
			session.pid_tuning = {}
		end
	end
	session.pidTuning = session.pid_tuning
	return session.pid_tuning
end

local function markDirty()
	ui.dirty = true
end

local function getFieldSetter(fieldName)
	local setter = ui.runtime.fieldSetters[fieldName]
	if setter then return setter end
	setter = function(value)
		local nextValue = clampInt(value, FIELD_LIMITS.min, FIELD_LIMITS.max, 0)
		if ui.config[fieldName] == nextValue then return end
		ui.config[fieldName] = nextValue
		markDirty()
	end
	ui.runtime.fieldSetters[fieldName] = setter
	return setter
end

local function getLiveProfile()
	return Profile and Profile.getActivePidProfile(1) or 1
end

local function buildSessionSignature()
	return tostring(getLiveProfile())
end

local function loadFromSession()
	local session = getSession()
	local pidConfig = getPidConfig(session)
	for i = 1, #FIELD_KEYS do
		local key = FIELD_KEYS[i]
		ui.config[key] = clampInt(pidConfig and pidConfig[key], FIELD_LIMITS.min, FIELD_LIMITS.max, 0)
	end
end

local function getBaseTitle()
	local root = _G and _G.rfsuite
	local app = root and root.app or nil
	local title = nil
	if app and type(app.lastTitle) == "string" and app.lastTitle ~= "" then
		title = app.lastTitle
	elseif app and app.Page and type(app.Page.title) == "string" and app.Page.title ~= "" then
		title = app.Page.title
	else
		title = "PIDs"
	end
	return title
end

local function queuePidRead()
	ensureRuntime()
	if ui.runtime.readPending then
		return false, "read_pending"
	end
	ui.runtime.readComplete = false
	if not PidTuningApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
		return false, "msp_runtime_unavailable"
	end

	local session = getSession()
	local mspState = MspRuntime.getState()
	local queue = mspState and mspState.queue
	if not queue or type(queue.add) ~= "function" then
		return false, "msp_queue_unavailable"
	end

	local readValid = type(getSession()) == "table"
	ui.runtime.readPending = true
	ui.loading = true
	ui.progress = 0
	queue:add({
		command = PidTuningApi.command,
		simulatorResponse = PidTuningApi.simulatorResponse,
		timeout = 5.0,
		processReply = function(_, buf)
			ui.runtime.readPending = false
			ui.loading = false
			ui.progress = 1
			local parsed = PidTuningApi.parse and PidTuningApi.parse(buf) or nil
			if type(parsed) ~= "table" then return Common.failPageRead(ui) end
			if type(session) == "table" and type(parsed) == "table" then
				session.pid_tuning = parsed
				session.pidTuning = parsed
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
			if type(ui.runtime.requestRebuild) == "function" then
				ui.runtime.requestRebuild()
			end
		end
	})

	return true, nil
end

local function ensureLoaded()
	ensureRuntime()
	if ui.loaded then return end
	loadFromSession()
	ui.loaded = true
	ui.dirty = false
	ui.runtime.lastSessionSignature = buildSessionSignature()
	ui.baseTitle = getBaseTitle()
	queuePidRead()
end

local function queuePidWrite(session)
	if not PidTuningApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
		return false, "msp_runtime_unavailable"
	end

	local mspState = MspRuntime.getState()
	local queue = mspState and mspState.queue
	if not queue or type(queue.add) ~= "function" then
		return false, "msp_queue_unavailable"
	end

	local pidConfig = getPidConfig(session)
	if not pidConfig then
		return false, "pid_config_unavailable"
	end

	queue:add({
		command = PidTuningApi.writeCommand,
		payload = PidTuningApi.buildWritePayload(pidConfig),
		timeout = 5.0,
		isWrite = true,
		processReply = function() end,
		errorHandler = function() end
	})

	return true, nil
end

local function applyConfigToSession(session)
	local pidConfig = getPidConfig(session)
	if not pidConfig then return nil end
	for i = 1, #FIELD_KEYS do
		local key = FIELD_KEYS[i]
		pidConfig[key] = clampInt(ui.config[key], FIELD_LIMITS.min, FIELD_LIMITS.max, 0)
	end
	session.pid_tuning = pidConfig
	session.pidTuning = pidConfig
	return pidConfig
end


local function getGridMetrics(w)
	local labelMin = 84
	local labelMax = 132
	local gapMin = 3
	local gapMax = 8
	local cellMin = 54
	if w >= 700 then
		labelMin = 96
		labelMax = 152
		gapMin = 5
		gapMax = 10
		cellMin = 62
	end

	if Controls and type(Controls.computeGridMetrics) == "function" then
		local m = Controls.computeGridMetrics(w, #COLUMNS, {
			labelRatio = 0.24,
			labelMin = labelMin,
			labelMax = labelMax,
			gapMin = gapMin,
			gapMax = gapMax,
			cellMin = cellMin
		})
		return m.labelW, m.gap, m.cellW
	end
	local labelW = math.floor(w * 0.24)
	local gap = 8
	local cellW = math.floor((w - labelW - (gap * (#COLUMNS - 1))) / #COLUMNS)
	return labelW, gap, cellW
end

local function getLayoutProfile(w, h)
	local profile = {
		headerFont = SMLSIZE,
		headerTextY = 0,
		headerLineY = 24,
		headerH = 30,
		rowFont = SMLSIZE,
		rowH = 42,
		rowLabelY = 10,
		cellTop = 5,
		afterHeaderGap = 6
	}

	if w >= 700 then
		profile.headerFont = SMLSIZE
		profile.headerTextY = 2
		profile.headerLineY = 32
		profile.headerH = 38
		profile.rowFont = SMLSIZE
		profile.rowH = 50
		profile.rowLabelY = 10
		profile.cellTop = 3
		profile.afterHeaderGap = 6
	elseif w < 560 then
		profile.headerFont = SMLSIZE
		profile.headerTextY = 0
		profile.headerLineY = 22
		profile.headerH = 26
		profile.rowFont = SMLSIZE
		profile.rowH = 40
		profile.rowLabelY = 9
		profile.cellTop = 4
		profile.afterHeaderGap = 4
	end

	return profile
end

local function getColumnTitle(i18n, key)
	if key == "p" then return pageText(i18n, "p") end
	if key == "i" then return pageText(i18n, "i") end
	if key == "d" then return pageText(i18n, "d") end
	if key == "f" then return pageText(i18n, "f") end
	if key == "o" then return pageText(i18n, "o") end
	if key == "b" then return pageText(i18n, "b") end
	return string.upper(key)
end

local function getRowTitle(i18n, key)
	if key == "roll" then return pageText(i18n, "roll") end
	if key == "pitch" then return pageText(i18n, "pitch") end
	if key == "yaw" then return pageText(i18n, "yaw") end
	return key
end

local function drawColumnHeader(children, x, y, w, i18n, layout)
	local labelW, gap, cellW = getGridMetrics(w)
	local headerFont = (layout and layout.headerFont) or MIDSIZE
	local headerTextY = (layout and layout.headerTextY) or 0
	local headerLineY = (layout and layout.headerLineY) or 28
	local headerH = (layout and layout.headerH) or 34

	children[#children + 1] = {
		type = "rectangle",
		x = x,
		y = y + headerLineY,
		w = w,
		h = 1,
		color = COLOR_THEME_SECONDARY2,
		filled = true
	}

	for i = 1, #COLUMNS do
		local cellX = x + labelW + ((i - 1) * (cellW + gap))
		local headerText = getColumnTitle(i18n, COLUMNS[i])
		children[#children + 1] = {
			type = "label",
			x = cellX,
			y = y + headerTextY,
			w = cellW,
			text = headerText,
			color = COLOR_THEME_PRIMARY1,
			font = headerFont,
			align = CENTER
		}
	end

	return headerH
end

local function addGroup(children, x, y, w, i18n, group, layout)
	local labelW, gap, cellW = getGridMetrics(w)
	local rowH = (layout and layout.rowH) or 42
	local rowLabelFont = (layout and layout.rowFont) or MIDSIZE
	local rowLabelY = (layout and layout.rowLabelY) or 8
	local cellTop = (layout and layout.cellTop) or 4

	children[#children + 1] = {
		type = "label",
		x = x,
		y = y + rowLabelY,
		w = labelW - 8,
		text = getRowTitle(i18n, group.key),
		color = COLOR_THEME_PRIMARY1,
		font = rowLabelFont
	}

	local cellY = y + cellTop
	for i = 1, #group.fields do
		local fieldKey = group.fields[i]
		local cellX = x + labelW + ((i - 1) * (cellW + gap))
		if fieldKey then
			children[#children + 1] = {
				type = "numberEdit",
				x = cellX,
				y = cellY,
				w = cellW,
				min = FIELD_LIMITS.min,
				max = FIELD_LIMITS.max,
				active = function()
					return true
				end,
				get = function()
					return clampInt(ui.config[fieldKey], FIELD_LIMITS.min, FIELD_LIMITS.max, 0)
				end,
				set = function(val)
					getFieldSetter(fieldKey)(val)
				end,
				display = function(val)
					return tostring(tonumber(val) or 0)
				end
			}
		end
	end

	return rowH
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
	if not session then
		return false
	end

	applyConfigToSession(session)
	local okMsp = false
	local errMsp = nil
	okMsp, errMsp = queuePidWrite(session)

	if ctx and type(ctx.reportSave) == "function" then
		if okMsp then
			ctx.reportSave({
				ok = true,
				title = pageText(ctx and ctx.i18n, "saved_title", "@i18n(app.pages.flight_tuning_pids.saved_title)@"),
				message = pageText(ctx and ctx.i18n, "saved_message", "@i18n(app.pages.flight_tuning_pids.saved_message)@")
			})
		else
			ctx.reportSave({
				title = pageText(ctx and ctx.i18n, "warning_title", "@i18n(app.pages.flight_tuning_pids.warning_title)@"),
				message = pageText(ctx and ctx.i18n, "saved_local_only_message", "@i18n(app.pages.flight_tuning_pids.saved_local_only_message)@") .. (errMsp and (": " .. tostring(errMsp)) or "")
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
	if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
		ui.runtime.syncHeaderTitle(ui.baseTitle or getBaseTitle(), ctx and ctx.navButtons or nil)
	end
	if ui.dirty then return end

	local signature = buildSessionSignature()
	if signature ~= ui.runtime.lastSessionSignature then
		ui.runtime.lastSessionSignature = signature
		queuePidRead()
		if type(ui.runtime.requestRebuild) == "function" then
			ui.runtime.requestRebuild()
		end
	end
end

function M.build(ctx)
	ensureDeps()
	ensureLoaded()
	ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

	local children = ctx.children
	local x = ctx.x
	local y = ctx.y
	local w = ctx.w
	local h = ctx.h or 200
	local i18n = ctx.i18n
	local profileDisplay = getLiveProfile()
	local layout = getLayoutProfile(w, h)

	if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
		ui.runtime.syncHeaderTitle(ui.baseTitle or getBaseTitle(), ctx and ctx.navButtons or nil)
	end

	local sectionHeaderH = (Controls and Controls.STATIC_SECTION_H) or 38
	local cursorY = y
	if Controls and type(Controls.appendStaticSectionHeader) == "function" then
		local headingTitle = string.format("%s #%d", ui.baseTitle or getBaseTitle(), profileDisplay)
		Controls.appendStaticSectionHeader(children, x, cursorY, w, headingTitle)
		cursorY = cursorY + sectionHeaderH
	end
	cursorY = cursorY + drawColumnHeader(children, x, cursorY, w, i18n, layout)
	cursorY = cursorY + layout.afterHeaderGap
	for i = 1, #ROWS do
		cursorY = cursorY + addGroup(children, x, cursorY, w, i18n, ROWS[i], layout)
	end

	if ui.loading and LoadingOverlay then
		LoadingOverlay.append(children, {
			x = x,
			y = y,
			w = w,
			h = h,
			title = pageText(i18n, "loading_title"),
			message = pageText(i18n, "loading_message"),
			progress = ui.progress
		})
	end
end

function M.onClose()
	if Common and Common.resetPageState then
		Common.resetPageState(ui, {
			tablesToWipe = { "runtime" }
		})
	else
		ui.loaded = false
		ui.dirty = false
	end
	ui.loading = false
	ui.progress = 0
	ui.runtimeBase = nil
	ui.baseTitle = nil
	Controls = nil
	Common = nil
	MspRuntime = nil
	PidTuningApi = nil
	LoadingOverlay = nil
	Sensors = nil
	t = nil
end

return M