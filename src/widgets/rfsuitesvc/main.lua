-- Keep main.lua lightweight; it is loaded for all widgets at boot.
local name = "RFSuite Service"

if lvgl == nil then
  return {
    name = name,
    options = {},
    create = function() end,
    refresh = function()
      lcd.drawText(10, 10, "LVGL support required", COLOR_THEME_WARNING)
    end,
  }
end

local function create(zone, options)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local requireChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if requireChunk then
    pcall(requireChunk)
  end
  local appChunk = loadScript("/WIDGETS/rfsuitesvc/app.lua", mode)
  if not appChunk then
    appChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/service/runtime.lua", mode)
    if appChunk then
      local ok, Runtime = pcall(appChunk)
      if ok and type(Runtime) == "table" and type(Runtime.new) == "function" then
        return Runtime.new(zone, options)
      end
    end
    return nil
  end
  local ok, factory = pcall(appChunk)
  if ok and type(factory) == "function" then
    return factory(zone, options)
  elseif ok and type(factory) == "table" and type(factory.new) == "function" then
    return factory.new(zone, options)
  end
  return nil
end

-- A caught error, on its way to the card, so the reason a pass failed outlives the pass. The
-- module is loaded here rather than at the top of the file because this one is read for every
-- widget at boot and a fault is not the common case; lib/log_sink.lua then makes the same check
-- again itself and writes nothing while the option is off.
local function logFault(context, err)
  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local general = prefs and prefs.general
  if type(general) ~= "table" or general.log_to_card ~= true then return end

  local requireModule = _G.rfsuite and _G.rfsuite.require
  if type(requireModule) ~= "function" then return end

  local okLoad, sink = pcall(requireModule, "lib/log_sink.lua")
  if okLoad and type(sink) == "table" and type(sink.fault) == "function" then
    pcall(sink.fault, context, err)
  end
end

-- Every entry point is wrapped: this widget exists to keep the background service running, so an
-- error in one pass must not be the last pass. The next call rebuilds what it needs.
local function update(widget, options)
  if widget and widget.update then
    local ok, err = pcall(widget.update, widget, options)
    if not ok then logFault("service.update", err) end
  end
end

local function refresh(widget, event, touchState)
  if widget and widget.refresh then
    local ok, err = pcall(widget.refresh, widget, event, touchState)
    if not ok then
      logFault("service.refresh", err)
      widget.built = false
    end
  end
end

local function background(widget)
  if widget and widget.background then
    local ok, err = pcall(widget.background, widget)
    if not ok then logFault("service.background", err) end
  end
end

return {
  useLvgl = true,
  name = name,
  options = {},
  create = create,
  update = update,
  refresh = refresh,
  background = background,
}
