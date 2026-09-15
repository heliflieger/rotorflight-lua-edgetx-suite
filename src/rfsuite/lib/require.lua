-- lib/require.lua
-- Module and singleton memoizer for EdgeTX RFSuite.
--
-- Prevents repeated disk reads, bytecode compilation, and redundant
-- module execution of shared libraries and singletons across the suite.

local BASE_PATH = "/SCRIPTS/TOOLS/rfsuite-core/"

_G.rfsuite = _G.rfsuite or {}
_G.rfsuite.modules = _G.rfsuite.modules or {}

-- Load mode for every script the suite loads.
--
-- "b" is what lets EdgeTX read back the .luac beside a source once that bytecode is the newer
-- of the two, which is the point of having compiled it at all; "t" is the fallback for a
-- source that has no bytecode yet, and compiling it writes the .luac for the next start.
-- lib/precompile.lua fills the tree in at start time so that first compile does not fall on
-- the first page that happens to need it.
_G.rfsuite.loadMode = "bt"

local modules = _G.rfsuite.modules

local function normalizePath(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  if string.sub(path, 1, #BASE_PATH) == BASE_PATH then
    return path
  end
  if string.sub(path, 1, 1) == "/" then
    return path
  end
  return BASE_PATH .. path
end

local function requireModule(path, forceReload)
  local fullPath = normalizePath(path)
  if not fullPath then return nil end

  if not forceReload and modules[fullPath] ~= nil then
    return modules[fullPath]
  end

  local chunk, err = loadScript(fullPath, _G.rfsuite.loadMode)
  if not chunk then
    if type(err) == "string" then
      -- Raw print on purpose, here and below: this is the module loader reporting that a
      -- load failed, and the logger may be the very module that could not load.
      print("[require] Failed to load " .. tostring(fullPath) .. ": " .. err)
    end
    return nil, err
  end

  local ok, result = pcall(chunk)
  if not ok then
    print("[require] Error executing " .. tostring(fullPath) .. ": " .. tostring(result))
    return nil, result
  end

  -- If module returns nothing/nil, store true as sentinel
  local instance = (result == nil) and true or result
  modules[fullPath] = instance

  return instance
end

local function clearModule(path)
  local fullPath = normalizePath(path)
  if fullPath then
    modules[fullPath] = nil
  end
end

local function clearAllModules()
  for k in pairs(modules) do
    modules[k] = nil
  end
end

_G.rfsuite.require = requireModule
_G.rfsuite.clearModule = clearModule
_G.rfsuite.clearAllModules = clearAllModules

return requireModule
