-- OnConnect task: read MCU UID and load model preferences
local M = {}

local done = false
local requestSent = false
local UidApi = nil
local ModelPreferences = nil
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

function M.wakeup()
  if done then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  -- If MspRuntime has already resolved UID and model preferences, reuse it immediately
  if session.mcu_id and session.mcu_id ~= "" then
    if not ModelPreferences then ModelPreferences = loadModule("lib/model_preferences.lua") end
    if not session.modelPreferences and ModelPreferences and type(ModelPreferences.loadByMcuId) == "function" then
      local prefs, filePath = ModelPreferences.loadByMcuId(session.mcu_id, true)
      session.modelPreferences = prefs
      session.modelPreferencesFile = filePath
    end
    session.modelPreferencesResolved = true
    done = true
    return
  end

  if not requestSent then
    if MspRuntime == nil then
      MspRuntime = loadModule("tasks/msp/runtime.lua") or false
    end
    local msp = MspRuntime or nil
    local mspState = msp and type(msp.getState) == "function" and msp.getState()
    if not mspState or not mspState.queue then return end

    if not UidApi then UidApi = loadModule("tasks/msp/api/uid.lua") end
    if not ModelPreferences then ModelPreferences = loadModule("lib/model_preferences.lua") end
    if not UidApi then
      if session then session.modelPreferencesResolved = true end
      done = true
      return
    end

    mspState.queue:add({
      command = UidApi.command,
      simulatorResponse = UidApi.simulatorResponse,
      timeout = 5.0,
      -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
      -- is given up by the queue before the runner re-queues the task that owns it.
      maxRetries = 2,
      processReply = function(self, buf)
        local parsed = UidApi.parse(buf)
        if parsed and parsed.mcuId and parsed.mcuId ~= "" then
          local mcuId = tostring(parsed.mcuId)
          session.mcu_id = mcuId
          if type(root.diagnostics) == "table" then root.diagnostics.mcu_id = mcuId end
          if ModelPreferences and type(ModelPreferences.loadByMcuId) == "function" then
            local prefs, filePath = ModelPreferences.loadByMcuId(mcuId, true)
            session.modelPreferences = prefs
            session.modelPreferencesFile = filePath
          end
        end
        session.modelPreferencesResolved = true
        done = true
      end,
      errorHandler = function()
        if session then session.modelPreferencesResolved = true end
        done = true
      end
    })
    requestSent = true
  end
end

function M.isComplete() return done end
function M.reset() 
  done = false; requestSent = false
  local root = _G and _G.rfsuite
  if root and type(root.session) == "table" then
    root.session.mcu_id = nil
    root.session.modelPreferences = nil
    root.session.modelPreferencesFile = nil
    root.session.modelPreferencesResolved = nil
  end
  if root and type(root.diagnostics) == "table" then root.diagnostics.mcu_id = nil end
end
return M
