-- Simple onconnect task: wait for API version read and show unsupported dialog
local M = {}

local Log = nil
local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local done = false

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
  return 0
end

function M.wakeup()
  if done then return end
  if Log == nil then
    Log = loadModule("lib/log.lua") or false
  end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  local msp = loadModule("tasks/msp/runtime.lua")
  local mspState = msp and type(msp.getState) == "function" and msp.getState()

  -- Wait until API version has been read or MSP runtime decided it won't be read
  local apiVersion = session.apiVersion
  if (not apiVersion or apiVersion == "" or tostring(apiVersion) == "0")
      and mspState
      and (mspState.pendingVersionRead == true or mspState.versionReadCompleted ~= true) then
    return
  end

  -- If API unsupported, show the unsupported dialog
  if session.apiSupported == false or (mspState and mspState.unsupportedApi == true) then
    local I18n = loadModule("i18n/init.lua")
    local tfn = (I18n and I18n.t) or function(_, k, f) return f end
    local title = tfn(nil, "unsupported_title", "Unsupported MSP API")
    local msg = (tfn(nil, "unsupported_message_prefix", "MSP API version ") or "") .. tostring(session.apiVersion or "?") .. (tfn(nil, "unsupported_message_suffix", " is not supported.") or "")

    local dialog = loadModule("ui/msp_unsupported_dialog.lua")
    if dialog and type(dialog.show) == "function" then
      pcall(dialog.show, {
        title = title,
        message = msg,
        version = tostring(session.apiVersion or "?"),
        onFallback = function(t, m)
          if type(Log) == "table" and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.tasks.apiversion", "Unsupported MSP API: " .. tostring(session.apiVersion), "warn", true)
          end
        end
      })
    end
  end

  done = true
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
end

return M
