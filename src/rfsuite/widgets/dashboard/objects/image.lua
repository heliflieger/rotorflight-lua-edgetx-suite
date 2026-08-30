local Wrapper = {}

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    return _G.rfsuite.require(path)
  end
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local utils = requireModule("widgets/dashboard/objects/common.lua")
local themeCommon = requireModule("widgets/dashboard/themes/default/common.lua")

local folder = "widgets/dashboard/objects/image/"
local renders = {}
local missingRenders = {}

local function getRender(subtype)
  local key = subtype or "image"
  if renders[key] then return renders[key] end
  if missingRenders[key] then return nil end
  
  local mod = requireModule(folder .. key .. ".lua")
  if mod then
    renders[key] = mod
    return mod
  end
  missingRenders[key] = true
  return nil
end

function Wrapper.render(nodes, rect, box, state)
  if not utils then
    utils = requireModule("widgets/dashboard/objects/common.lua")
  end
  if not utils then return end
  
  utils.drawContainer(nodes, rect, box, state)
  
  local render = getRender(box and box.subtype)
  if render and type(render.render) == "function" then
    if not themeCommon then
      themeCommon = requireModule("widgets/dashboard/themes/default/common.lua")
    end
    render.render(nodes, rect, box, state, themeCommon, utils)
  end
end

return Wrapper
