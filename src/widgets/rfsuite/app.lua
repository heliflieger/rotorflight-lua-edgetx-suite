local zone, options = ...

local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
local runtimeChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/runtime.lua", mode)
if not runtimeChunk then return nil end

local ok, Runtime = pcall(runtimeChunk)
if ok and type(Runtime) == "table" and type(Runtime.new) == "function" then
  return Runtime.new(zone, options)
end

return nil
