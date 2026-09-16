local M = {}

local function loadModule(path)
	local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
	local chunk = loadScript(fullPath, "t")
	if type(chunk) ~= "function" then return nil end
	local ok, mod = pcall(chunk)
	if not ok then return nil end
	return mod
end

local ModelPreferences = nil
local MspRuntime = nil
local Log = nil

local function ensureDeps()
	if not ModelPreferences then ModelPreferences = loadModule("lib/model_preferences.lua") end
	if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
	if not Log then Log = loadModule("lib/log.lua") end
end

local function logWarn(msg)
	if Log and type(Log.emit) == "function" then
		pcall(Log.emit, "rfsuite.power.modelprefs", tostring(msg), "warn")
	end
end

local function resolveMcuId(session)
	if type(session) ~= "table" then return nil end

	local mcuId = session.mcu_id
	if type(mcuId) == "string" and mcuId ~= "" then return mcuId end

	ensureDeps()
	if MspRuntime and type(MspRuntime.getState) == "function" then
		local mspState = MspRuntime.getState()
		local values = mspState and mspState.values
		local runtimeMcuId = values and values.mcuId
		if type(runtimeMcuId) == "string" and runtimeMcuId ~= "" then
			session.mcu_id = runtimeMcuId
			return runtimeMcuId
		end
	end

	return nil
end

function M.resolveMcuId(session)
	return resolveMcuId(session)
end

function M.save(session)
	ensureDeps()
	if not session or not ModelPreferences or type(ModelPreferences.saveByMcuId) ~= "function" then
		logWarn("save skipped: model_preferences_unavailable")
		return false, "model_preferences_unavailable"
	end

	local mcuId = resolveMcuId(session)
	if type(mcuId) ~= "string" or mcuId == "" then
		logWarn("save failed: missing_mcu_id")
		return false, "missing_mcu_id"
	end

	local ok, err = ModelPreferences.saveByMcuId(mcuId, session.modelPreferences)
	if ok and type(ModelPreferences.buildPath) == "function" then
		session.modelPreferencesFile = ModelPreferences.buildPath(mcuId)
	else
		logWarn("save failed for mcu_id=" .. tostring(mcuId) .. ": " .. tostring(err or "io"))
	end
	return ok, err
end

return M