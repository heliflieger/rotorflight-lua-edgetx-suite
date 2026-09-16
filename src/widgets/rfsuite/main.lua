-- Keep main.lua lightweight; it is loaded for all widgets at boot.
local name = "RFSuite"

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
  local appChunk = loadScript("/WIDGETS/rfsuite/app.lua", mode)
  if not appChunk then
    appChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/runtime.lua", mode)
  end
  if not appChunk then return nil end

  local ok, res = pcall(appChunk, zone, options)
  if ok and res ~= nil then
    if type(res) == "function" then
      local okFn, widget = pcall(res, zone, options)
      if okFn then return widget end
    elseif type(res) == "table" then
      if type(res.new) == "function" then
        local okNew, widget = pcall(res.new, zone, options)
        if okNew then return widget end
      else
        return res
      end
    end
  end
  return nil
end

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  return 0
end

local function isCpuLimitError(err)
  return type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil
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

local function update(widget, options)
  if widget and widget.update then
    local ok, err = pcall(widget.update, widget, options)
    if not ok then
      logFault("widget.update", err)
      if isCpuLimitError(err) then
        widget._cpuBackoffUntil = nowSeconds() + 0.8
      end
    end
  end
end

-- A widget that is holding something the radio must not be left holding, given the chance to let
-- go while it is backed off.
--
-- A back-off is not a pause. The dashboard's in-flight tuning overlay drives the flight
-- controller by writing two of the radio's global variables, and every path that takes them back
-- to zero lives inside widget.refresh or widget.background -- neither of which is called for the
-- 1.2 s below. Left standing, the flight controller goes on stepping that parameter roughly five
-- times a second with nothing driving it. The widget installs this closure itself and it does
-- nothing at all when there is nothing standing; the pcall is because a widget that has just
-- failed must not be able to fail here as well.
local function letGoWhileBackedOff(widget)
  local release = widget and widget._inflightPanic
  if type(release) == "function" then pcall(release) end
end

local function refresh(widget, event, touchState)
  if widget and widget.refresh then
    local now = nowSeconds()
    local backoffUntil = tonumber(widget._cpuBackoffUntil) or 0
    if backoffUntil > 0 and now < backoffUntil then
      letGoWhileBackedOff(widget)
      return
    end

    local ok, err = pcall(widget.refresh, widget, event, touchState)
    if not ok then
      logFault("widget.refresh", err)
      if isCpuLimitError(err) then
        widget._cpuBackoffUntil = now + 1.2
        letGoWhileBackedOff(widget)
      end
      widget.built = false
    end
  end
end

local function background(widget)
  if widget and widget.background then
    local ok, err = pcall(widget.background, widget)
    if not ok then
      logFault("widget.background", err)
      if isCpuLimitError(err) then
        widget._cpuBackoffUntil = nowSeconds() + 0.8
      end
    end
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
