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

local function logGv(fmt, ...)
  -- Same gate as the dashboard runtime's copy of this function. Ungated, every call opens,
  -- appends to and closes a file on the SD card. The callers here are the reload path rather
  -- than a per-frame one, so it costs less than the other copy -- but it is the same defect
  -- and it is not switchable either.
  --
  -- Variadic for the same reason as the other copy, and kept in the same shape as it: with
  -- the test inside the function, a caller pays for a message the gate then drops.
  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local general = prefs and prefs.general
  local debugLevel = general and general.debug_level
  if debugLevel ~= "debug" and debugLevel ~= "info" then return end

  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end

  local fLog = io.open("/SCRIPTS/TOOLS/rfsuite.user/gv_debug.log", "a")
  if fLog then
    local t = (getTime and getTime()) or 0
    io.write(fLog, string.format("[%.2f][Widget.main] %s\n", t / 100, msg))
    io.close(fLog)
  end
  if print then pcall(print, "[Widget.main] " .. msg) end
end

--- The global preference file's size and mtime, as one string.
--
-- The same state comparison the dashboard runtime makes, kept here rather than shared:
-- this file is loaded for every widget at boot and deliberately pulls in nothing. It
-- watches only the global file, because the per-model one's path is not known here --
-- the runtime watches both, and it is the half that does the reloading.
local PREFERENCES_FILE = "/SCRIPTS/TOOLS/rfsuite.user/preferences.ini"
local PREFS_STAT_INTERVAL = 1.0

-- `fstat` returns the modification time as a TABLE -- year, mon, day, hour, min, sec
-- (radio/src/lua/api_filesystem.cpp) -- not as a number. `tostring()` on that table is an
-- address, which can differ between two calls on the same unchanged file, so a stamp built
-- from it reports a change that never happened and the reload below runs for nothing --
-- preferences re-read, theme scripts re-loaded, the scene rebuilt. The fields are what
-- identify the file, so the stamp is built from the fields, the same way
-- widgets/dashboard/runtime.lua builds its own.
local function preferencesStamp()
  if type(fstat) ~= "function" then return nil end
  local okg, g = pcall(fstat, PREFERENCES_FILE)
  if not okg or type(g) ~= "table" then return nil end
  local t = g.time
  if type(t) ~= "table" then
    -- Not the documented shape. Whatever it is, it is at least not an address.
    return tostring(g.size) .. ":" .. tostring(t)
  end
  return string.format("%s:%s-%s-%s.%s.%s.%s",
    tostring(g.size), tostring(t.year), tostring(t.mon), tostring(t.day),
    tostring(t.hour), tostring(t.min), tostring(t.sec))
end

local function shouldReloadWidget(widget)
  local now = nowSeconds()
  if (now - (widget._lastPrefsStatAt or 0)) < PREFS_STAT_INTERVAL then
    return false
  end
  widget._lastPrefsStatAt = now

  local stamp = preferencesStamp()
  if stamp == nil then
    return false
  end
  if widget._lastPrefsStamp == nil then
    -- First look: a baseline, never a reload.
    widget._lastPrefsStamp = stamp
    return false
  end
  if stamp == widget._lastPrefsStamp then
    return false
  end
  widget._lastPrefsStamp = stamp
  logGv("Reload triggered: preferences.ini changed (%s)", stamp)
  return true
end

local function refresh(widget, event, touchState)
  if widget and shouldReloadWidget(widget) then
    widget._cpuBackoffUntil = 0
    logGv("Calling widget.reload()")
    if type(widget.reload) == "function" then
      pcall(widget.reload, widget, true)
    else
      widget.built = false
      widget.theme = nil
      widget.themePath = nil
      widget.renderKey = nil
      widget._cachedRenderKey = nil
    end
  end

  if widget and widget.refresh then
    local now = nowSeconds()
    local backoffUntil = tonumber(widget._cpuBackoffUntil) or 0
    if backoffUntil > 0 and now < backoffUntil then
      return
    end

    local ok, err = pcall(widget.refresh, widget, event, touchState)
    if not ok then
      logFault("widget.refresh", err)
      if isCpuLimitError(err) then
        widget._cpuBackoffUntil = now + 1.2
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
