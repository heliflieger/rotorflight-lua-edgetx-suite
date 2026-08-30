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

local folder = "widgets/dashboard/objects/text/"
local renders = {}
local missingRenders = {}

local function getRender(subtype)
  local key = subtype or "telemetry"
  if renders[key] then return renders[key] end
  if missingRenders[key] then return nil end

  -- Decorative background boxes use subtype="text" and do not need a subrenderer.
  if key == "text" then
    missingRenders[key] = true
    return nil
  end

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
    if themeCommon then
      render.render(nodes, rect, box, state, themeCommon, utils)
    end
  else
    local lastVal = nil
    local cachedText = nil
    local textGetter = function()
      local v = (box and type(box.value) == "function") and box.value(box, state) or (box and box.value or "--")
      if v == lastVal and cachedText ~= nil then
        return cachedText
      end
      lastVal = v
      cachedText = tostring(v)
      return cachedText
    end
    local colorGetter = function()
      local c = (box and type(box.textcolor) == "function") and box.textcolor(box, state) or (box and box.textcolor)
      return (c ~= nil) and c or WHITE
    end
    local align = (box and box.valuealign) or (box and box.titlealign) or CENTER
    local fontGetter = function()
      local f = (box and type(box.font) == "function") and box.font(box, state) or (box and box.font or MIDSIZE)
      return f
    end
    utils.pushLabel(nodes, rect.x + 4, utils.defaultValueY(rect, box), rect.w - 8, textGetter, colorGetter, align, fontGetter)
  end
end

return Wrapper
