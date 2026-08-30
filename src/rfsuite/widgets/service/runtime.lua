-- Runtime for the service widget.
--
-- The suite's background work -- the MSP runtime and the event runtime that drives the onconnect
-- chain and the custom telemetry decoder -- only advances while something calls into it. The tool
-- does that while it is open, and the dashboard widget does it from its own passes. A radio that
-- runs neither has no link: no custom sensors, no connect events, no session values.
--
-- This widget is that caller and nothing else. It ticks the same two runtimes the dashboard ticks
-- and draws a small status tile, so a pilot who does not want the dashboard can still have the
-- suite's background service on the model.

local Runtime = {}

-- The runtimes are advanced at most this often, and the tile is repainted at most this often. The
-- tick interval is the dashboard's; the paint interval is longer because a status line does not
-- change faster than that and every rebuild costs a full LVGL tree.
local TICK_INTERVAL_SECONDS = 0.1
local UI_INTERVAL_SECONDS = 0.5

local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", "t")
  if rChunk then
    requireModule = rChunk()
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")
local MspRuntime = requireModule("tasks/msp/runtime.lua")
local EventsRuntime = requireModule("tasks/events/runtime.lua")
local I18nModule = requireModule("i18n/init.lua")
local PreferencesModule = requireModule("lib/preferences.lua")
local LogSink = requireModule("lib/log_sink.lua")
if LogSink and type(LogSink.configure) == "function" then
  -- This state's ring and this state's files. The tool holds a ring of its own and names its
  -- own pair, so neither state appends to a file the other one has open.
  LogSink.configure("widget")
end

-- Tasks read their settings from rfsuite.preferences, and that table is per Lua state: the tool
-- publishes it in the script state and the dashboard widget in the widget state. Without a
-- publisher here, a task that asks whether a feature is switched on gets nothing and behaves as
-- if it were off -- in exactly the arrangement this widget exists for. Re-read on an interval
-- rather than once, so a setting changed in the tool takes effect without a restart, and never
-- while armed.
local PREFERENCES_INTERVAL_SECONDS = 30

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then return value / 100 end
  end
  return 0
end

local function log(msg, level)
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.service", msg, level or "debug")
  end
end

local function session()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil end
  return _G.rfsuite.session
end

local function isArmed()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return false end
  local runtimeState = MspRuntime.getState()
  return type(runtimeState) == "table" and runtimeState.lastArmed == true
end

local function refreshPreferences(self, force)
  if not PreferencesModule or type(PreferencesModule.load) ~= "function" then return end

  local now = nowSeconds()
  if not force and (now - (self._lastPreferencesLoad or 0)) < PREFERENCES_INTERVAL_SECONDS then return end
  if not force and isArmed() then return end
  self._lastPreferencesLoad = now

  local ok, prefs = pcall(PreferencesModule.load)
  if ok and type(prefs) == "table" then
    self.preferences = prefs
    _G.rfsuite = _G.rfsuite or {}
    _G.rfsuite.preferences = prefs
  end
end

-- One pass of the background work: the same two calls the dashboard makes, bracketed by the same
-- event context, so tasks that behave differently in a widget see what they expect.
local function tickRuntimes(self)
  local now = nowSeconds()
  if self._lastWorkTick == now then return end
  self._lastWorkTick = now

  if (now - (self._lastLogicTick or 0)) < TICK_INTERVAL_SECONDS then return end
  self._lastLogicTick = now

  refreshPreferences(self, false)

  -- This widget owns the card sink for the widget state. It is the better owner of the two that
  -- run here: background() keeps calling this while it is off screen, so the ring keeps reaching
  -- the card when the dashboard is not the page being looked at. The dashboard runtime writes
  -- only where this widget is not on the model, and finds that out from the client list below.
  if LogSink and type(LogSink.tick) == "function" then
    pcall(LogSink.tick, isArmed())
  end

  if not MspRuntime then return end

  if not self.mspAttached and type(MspRuntime.attach) == "function" then
    MspRuntime.attach("service-widget")
    self.mspAttached = true
    log("service widget attached to the MSP runtime", "info")
  end

  if type(MspRuntime.tick) ~= "function" then return end

  local s = session()
  if s then s.event_context = "widget" end

  MspRuntime.tick()
  if EventsRuntime and type(EventsRuntime.wakeup) == "function" then
    pcall(EventsRuntime.wakeup)
  end

  -- The wakeup above is what FILLS the queue while the connect chain runs. Without a second
  -- turn here every request it enqueues waits for the next host tick before it is even looked
  -- at, which on a chain of a dozen serial round trips is a dozen ticks of pure waiting.
  if type(MspRuntime.pump) == "function" then
    MspRuntime.pump()
  end

  if s then s.event_context = nil end
end

-- What the tile reports. Three states, in the order a start goes through them: no link, link up
-- with the connect chain still running, and ready.
local function readStatus(self)
  local status = { link = false, tasksDone = true, done = nil, total = nil, craftName = nil }

  if MspRuntime and type(MspRuntime.getState) == "function" then
    local runtimeState = MspRuntime.getState()
    status.link = type(runtimeState) == "table" and runtimeState.lastConnected == true
  end

  if EventsRuntime and type(EventsRuntime.isOnconnectActive) == "function" then
    if EventsRuntime.isOnconnectActive() then
      status.tasksDone = false
    end
  end
  if EventsRuntime and type(EventsRuntime.getOnconnectProgress) == "function" then
    local progress = EventsRuntime.getOnconnectProgress()
    if type(progress) == "table" and type(progress.total) == "number" and type(progress.done) == "number" then
      status.done = progress.done
      status.total = progress.total
      if progress.total > 0 and progress.done >= progress.total then
        status.tasksDone = true
      end
    end
  end

  local s = session()
  if s and type(s.modelName) == "string" and s.modelName ~= "" then
    status.craftName = s.modelName
  end

  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local mspErr = (s and s.mspLastError) or (_G.rfsuite and _G.rfsuite.diagnostics and _G.rfsuite.diagnostics.mspLastError)
  local mspErrorKind = (s and s.mspErrorKind) or (_G.rfsuite and _G.rfsuite.diagnostics and _G.rfsuite.diagnostics.mspErrorKind)
  if not status.link then
    status.text = (t and t("widgets.service.waiting_for_link")) or "Waiting for MSP link"
  elseif not status.tasksDone then
    if mspErrorKind == "no_reply" or (mspErr and mspErr ~= "") then
      status.text = (t and t("widgets.service.no_msp_reply")) or "No MSP reply"
    else
      local text = (t and t("widgets.service.loading")) or "Loading data..."
      if status.total and status.total > 0 then
        text = text .. " (" .. tostring(status.done) .. "/" .. tostring(status.total) .. ")"
      end
      status.text = text
    end
  else
    status.text = (t and t("widgets.service.connected")) or "Connected"
  end

  return status
end

local function buildTile(self, status)
  local w = (self.zone and self.zone.w) or LCD_W or 320
  local h = (self.zone and self.zone.h) or LCD_H or 172
  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local title = (t and t("widgets.service.title")) or "SERVICE"

  -- Everything is placed from the top so the tile degrades on a short zone: the craft name is the
  -- first line to fall off the bottom, and it is the least important of the three.
  local titleY = math.max(2, math.floor(h * 0.08))
  local stateY = titleY + 20
  local craftY = stateY + 26

  local children = {
    {
      type = "rectangle",
      x = 0,
      y = 0,
      w = w,
      h = h,
      color = BLACK,
      filled = true
    },
    {
      type = "label",
      x = 0,
      y = titleY,
      w = w,
      text = title,
      align = CENTER,
      color = COLOR_THEME_DISABLED,
      font = SMLSIZE
    },
    {
      type = "label",
      x = 0,
      y = stateY,
      w = w,
      text = tostring(status.text),
      align = CENTER,
      color = WHITE,
      font = SMLSIZE
    }
  }

  if status.craftName and craftY + 16 <= h then
    children[#children + 1] = {
      type = "label",
      x = 0,
      y = craftY,
      w = w,
      text = status.craftName,
      align = CENTER,
      color = COLOR_THEME_DISABLED,
      font = SMLSIZE
    }
  end

  return children
end

function Runtime.new(zone, options)
  local widget = {
    zone = zone,
    options = options,
    built = false,
    renderKey = nil,
    mspAttached = false,
    _lastWorkTick = nil,
    _lastLogicTick = 0,
    _lastUIRefresh = 0,
    _lastPreferencesLoad = 0
  }

  refreshPreferences(widget, true)

  if I18nModule and type(I18nModule.new) == "function" then
    local locale = nil
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", "t")
    if chunk then
      local ok, localeMod = pcall(chunk)
      if ok and type(localeMod) == "table" and type(localeMod.resolveSystemLanguage) == "function" then
        local okResolve, resolved = pcall(localeMod.resolveSystemLanguage, "en")
        if okResolve and type(resolved) == "string" and resolved ~= "" then
          locale = resolved
        end
      end
    end
    local ok, ctx = pcall(I18nModule.new, locale)
    if ok and type(ctx) == "table" then
      widget.i18n = ctx
    end
  end

  function widget.update(self, newOptions)
    self.options = newOptions
    self.built = false
  end

  -- Called when the widget is not the one on screen. The background work is the point of this
  -- widget, so it happens here as well as in refresh().
  function widget.background(self)
    tickRuntimes(self)
    return 0
  end

  function widget.refresh(self, event, touchState)
    tickRuntimes(self)

    local now = nowSeconds()
    if self.built and (now - (self._lastUIRefresh or 0)) < UI_INTERVAL_SECONDS then
      return
    end
    self._lastUIRefresh = now

    local status = readStatus(self)
    local zoneW = (self.zone and self.zone.w) or 0
    local zoneH = (self.zone and self.zone.h) or 0
    local key = tostring(status.text) .. "|" .. tostring(status.craftName) .. "|" .. tostring(zoneW) .. "x" .. tostring(zoneH)
    if self.built and key == self.renderKey then
      return
    end

    self.renderKey = key
    lvgl.clear()
    lvgl.build(buildTile(self, status))
    self.built = true
  end

  return widget
end

return Runtime
