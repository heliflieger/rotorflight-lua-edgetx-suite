-- OnConnect task wrapper: status
local M = {}

local shared = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

function M.wakeup(args)
  if not shared then
    shared = loadModule("tasks/events/common/status.lua")
  end
  if shared and type(shared.wakeup) == "function" then
    shared.wakeup(args)
  end
end

function M.isComplete()
  return shared and type(shared.isComplete) == "function" and shared.isComplete()
end

function M.reset()
  if shared and type(shared.reset) == "function" then
    shared.reset()
  end
end

return M
