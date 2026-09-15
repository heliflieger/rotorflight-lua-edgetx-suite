local HelpRegistry = {}

function HelpRegistry.new(options)
  options = options or {}
  local pagePathByMenuId = options.pagePathByMenuId or {}

  local chunkByMenuId = {}
  local hasHelpByMenuId = {}
  local moduleByMenuId = {}

  local function getHelpScriptPath(menuId)
    local pagePath = pagePathByMenuId[menuId]
    if type(pagePath) ~= "string" or pagePath == "" then
      return nil
    end

    if string.sub(pagePath, -9) == "/page.lua" then
      return "/SCRIPTS/TOOLS/rfsuite-core/app/pages/" .. string.sub(pagePath, 1, -10) .. "/help.lua"
    end

    return "/SCRIPTS/TOOLS/rfsuite-core/app/pages/" .. pagePath .. "/help.lua"
  end

  local function ensureChunk(menuId)
    if hasHelpByMenuId[menuId] == false then
      return nil
    end

    local cached = chunkByMenuId[menuId]
    if type(cached) == "function" then
      return cached
    end

    local scriptPath = getHelpScriptPath(menuId)
    if not scriptPath then
      hasHelpByMenuId[menuId] = false
      return nil
    end

    local ok, chunk = pcall(loadScript, scriptPath, "t")
    if not ok or type(chunk) ~= "function" then
      hasHelpByMenuId[menuId] = false
      return nil
    end

    chunkByMenuId[menuId] = chunk
    hasHelpByMenuId[menuId] = true
    return chunk
  end

  local function loadModule(menuId)
    local cached = moduleByMenuId[menuId]
    if cached ~= nil then
      return cached
    end

    local chunk = ensureChunk(menuId)
    if not chunk then
      return nil
    end

    local ok, loaded = pcall(chunk)
    if not ok then
      moduleByMenuId[menuId] = false
      return nil
    end

    moduleByMenuId[menuId] = loaded
    return loaded
  end

  local self = {}

  function self.hasHelp(menuId)
    if type(menuId) ~= "string" or menuId == "" then
      return false
    end
    return ensureChunk(menuId) ~= nil
  end

  function self.get(menuId, ctx)
    if not self.hasHelp(menuId) then
      return nil
    end

    local loaded = loadModule(menuId)
    if loaded == nil or loaded == false then
      return nil
    end

    if type(loaded) == "string" then
      return { message = loaded }
    end

    if type(loaded) == "function" then
      local ok, resolved = pcall(loaded, ctx or {})
      if not ok then
        return nil
      end
      if type(resolved) == "string" then
        return { message = resolved }
      end
      if type(resolved) == "table" then
        return resolved
      end
      return nil
    end

    if type(loaded) == "table" then
      return loaded
    end

    return nil
  end

  return self
end

return HelpRegistry
