-- ui/preferences.lua
-- Safe wrapper around lib/preferences.lua.
-- Provides lazy loading, pcall guards, and default fallback.
--
-- Usage:
--   local PreferencesSafe = loadModule("ui/preferences.lua")
--   local Prefs = PreferencesSafe.new(loadModule)
--   local data  = Prefs.load()
--   local ok, err = Prefs.save(data)

local PreferencesSafe = {}

local UNAVAILABLE = "Preferences unavailable in this build"

-- The defaults are not declared here. They belong to lib/preferences.lua, and a second
-- copy in this file could only ever be reached in a build where that library is missing,
-- which is also a build where nothing can be saved (see save() below). A copy that is
-- unreachable while the tool works is a copy that drifts without anyone noticing.
local function defaultsFrom(m)
  if not m or type(m.defaults) ~= "function" then return nil end
  local ok, defaults = pcall(m.defaults)
  if ok and type(defaults) == "table" then return defaults end
  return nil
end

-- Returns a { load, save, defaults } object.
-- `loadModuleFn` is the host's loadModule function so the path resolution
-- stays consistent with the rest of the build.
function PreferencesSafe.new(loadModuleFn)
  local module = nil   -- nil = not yet attempted, false = failed

  local function getModule()
    if module == false then return nil end
    if module ~= nil   then return module end

    local ok, result = pcall(loadModuleFn, "lib/preferences.lua")
    if ok and type(result) == "table" then
      module = result
      return module
    end
    module = false
    return nil
  end

  local function defaults()
    return defaultsFrom(getModule())
  end

  local function load()
    local m = getModule()
    if m and type(m.load) == "function" then
      local ok, loaded = pcall(m.load)
      if ok and type(loaded) == "table" then return loaded end
    end
    -- The library is there but could not read the card: its own defaults are still the
    -- right answer. If it is not there at all, say so rather than inventing a table.
    local fallback = defaultsFrom(m)
    if fallback then return fallback end
    return {}, UNAVAILABLE
  end

  local function save(prefs)
    local m = getModule()
    if not m or type(m.save) ~= "function" then
      return false, UNAVAILABLE
    end
    local ok, saveOk, err = pcall(m.save, prefs)
    if not ok then return false, tostring(saveOk) end
    return saveOk, err
  end

  return { load = load, save = save, defaults = defaults }
end

return PreferencesSafe
