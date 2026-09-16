--[[
  Lightweight events manager for RFSuite (EdgeTX port)
  - Monitors MSP runtime and sets `rfsuite.session.isConnected` with hysteresis
  - Minimal dependency set to avoid heavy startup costs
]]

if type(_G) == "table" and type(_G.__rfsuite_events_module) == "table" then
  return _G.__rfsuite_events_module
end

local Events = {}

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local MspRuntime = nil
local Log = nil
local Env = nil
local ModelNameStore = nil
local FlightRecord = nil

-- Per-category task runners cache will be stored at `_G.rfsuite.tasks.events`
local function ensureEventRunner(name)
  if type(name) ~= "string" then return nil end
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.tasks = _G.rfsuite.tasks or {}
  _G.rfsuite.tasks.events = _G.rfsuite.tasks.events or {}
  local cached = _G.rfsuite.tasks.events[name]
  if type(cached) == "table" then return cached end
  if cached == false then return nil end

  local ok, mod = pcall(loadModule, "tasks/events/" .. name .. "/tasks.lua")
  if not ok or type(mod) ~= "table" then
    if Log and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.events", "no runner for events/" .. tostring(name), "debug")
    end
    _G.rfsuite.tasks.events[name] = false
    return nil
  end

  _G.rfsuite.tasks.events[name] = mod
  return mod
end

local CONNECT_STABLE_SECONDS = 0.6
local DISCONNECT_STABLE_SECONDS = 2.0

local state = {
  linkUpSince = nil,
  linkDownSince = nil,
  linkStableUp = false,
  lastArmed = nil,
  -- Which arm/disarm category still has work, if either does. See driveEdgeRunner below.
  edgeRunner = nil,
}

-- One pass of an arm or disarm runner, and whether it still has work.
--
-- The runner completes AT MOST ONE task per wakeup by design: it takes the first eligible entry
-- of the manifest, calls it and returns. So an edge that wakes it exactly once runs the first
-- entry and nothing else -- and not even that one to the end, because a task waiting on an MSP
-- reply needs a later pass to report itself complete. Measured on the disarm chain: `flight_stats`
-- was started and never marked complete, and `dataflash_summary` behind it was never started at
-- all. `onconnect` above does not have this problem because it is called on every pass while it
-- says it is active; this is the same shape for the two edge categories.
local function driveEdgeRunner(category, context)
  local runner = ensureEventRunner(category)
  if not runner then return false end

  if type(runner.wakeup) == "function" then
    local ok, err = pcall(runner.wakeup, { context = context })
    if not ok and Log and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.events", category .. ".wakeup error: " .. tostring(err), "error")
    end
  end

  if type(runner.active) == "function" then
    local ok, active = pcall(runner.active)
    return ok and active == true
  end
  return false
end

local function ensureDeps()
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Log then Log = loadModule("lib/log.lua") end
  if not Env then Env = loadModule("lib/env.lua") end
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
  return 0
end

local function ensureSession()
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.session = _G.rfsuite.session or {}
end

local function modelNameStore()
  if ModelNameStore == nil then
    ModelNameStore = loadModule("lib/model_name_store.lua") or false
  end
  if type(ModelNameStore) ~= "table" then return nil end
  return ModelNameStore
end

local function publishConnected(val)
  ensureSession()
  local session = _G.rfsuite.session
  if session.isConnected == val then return end
  session.isConnected = val
  session.rfConnected = val
  if val == false then
    session.fblConnected = false
    -- The flight log's pending entry belongs to the connection: which battery was picked for it,
    -- and whether a use has already been counted against that pack. A link that comes back is, as
    -- far as anything here can tell, a fresh pack, so the entry is dropped rather than carried
    -- into it. An entry still open goes with it -- nothing disarmed, so there is no honest duration.
    session.flightlog = nil
    -- The flight statistics and the board's flight count are deliberately NOT dropped here. The
    -- link going down is what unplugging the pack after a flight looks like, and the dashboard's
    -- post-flight page reads rfsuite.session.flight for its tiles: a reset at this edge blanked
    -- them the moment the battery came off. Both are dropped when the next session begins, below.
    -- The tool and each widget are separate Lua states holding their own copy of what the card
    -- said, and the state that renames is usually not the state that puts the name back. One
    -- that first read the file while it was still empty would answer "nothing to do" for the
    -- rest of its life, including for a record another state wrote in the meantime. The link
    -- going down is the one moment where re-reading it is both cheap and certain to be worth it,
    -- and it comes before the runner resets below, which read the store themselves.
    local nameStore = modelNameStore()
    if nameStore and type(nameStore.invalidate) == "function" then
      pcall(nameStore.invalidate)
    end
    -- Reset the arm-edge detector so that a reconnect while still armed is seen as a fresh
    -- arm edge (false → true) and triggers Record.open() via the onarm manifest.  Without this,
    -- both `armed` and `state.lastArmed` are still true on the reconnect, the condition
    -- `armed ~= state.lastArmed` is false, and the record is never reopened for the rest of the
    -- flight — leaving Record.close() at the real disarm to overwrite `flight.last` with an
    -- empty record. (#278)
    --
    -- `false` rather than `nil`: the nil-guard two lines above the edge condition silently
    -- initialises `state.lastArmed` to the current armed value without firing an edge, which
    -- would defeat the purpose of the reset.
    state.lastArmed = false
  end
  if val == true then
    -- A link coming up is, as far as anything here can tell, a fresh pack and a fresh session,
    -- and that is what ends the record of the one before it: the statistics and the flight clock
    -- go, and the board's flight count is zeroed until the connect chain has read this board's.
    -- A record still open has no honest end to it and goes with them.
    session.flightcount = 0
    if FlightRecord and type(FlightRecord.reset) == "function" then
      pcall(FlightRecord.reset)
    end
  end
  if Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.events", "session.isConnected=" .. tostring(val), "info")
  end
  if val == false and _G.rfsuite and _G.rfsuite.tasks and _G.rfsuite.tasks.events then
    for name, runner in pairs(_G.rfsuite.tasks.events) do
      if type(runner) == "table" and type(runner.reset) == "function" then
        pcall(runner.reset)
        if Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "reset runner " .. tostring(name), "debug")
        end
      end
    end
    if type(collectgarbage) == "function" then
      collectgarbage("collect")
    end
  end
end

-- Put a model name back that the disconnect hook never got to.
--
-- `model_name_sync` restores from its own reset, and that reset is reached only through
-- publishConnected(false) -- i.e. only where something was ticking at the moment the link went.
-- Nothing is ticking when the radio is switched off with a craft still connected, so the model
-- comes back up wearing the craft's name and no event is ever going to say so. The reading side
-- therefore cannot be an event: it is a STATE, checked on a tick that has established there is no
-- craft, which a cold start reaches on its first pass.
--
-- The cost on that tick is one boolean. The store answers hasAny() from a flag after its first
-- call, and everything past it -- reading the model, writing to it, touching the card -- happens
-- only where a rename is actually outstanding.
local function restorePendingModelName()
  local nameStore = modelNameStore()
  if not nameStore then return end

  local okAny, any = pcall(nameStore.hasAny)
  if not okAny or not any then return end

  local ok, restored = pcall(nameStore.restore)
  if ok and restored and Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.events", "model name put back: " .. tostring(restored), "info")
  end
end

function Events.reset()
  state.linkUpSince = nil
  state.linkDownSince = nil
  state.linkStableUp = false
  ensureSession()
  _G.rfsuite.session.isConnected = false
  _G.rfsuite.session.rfConnected = false
  _G.rfsuite.session.fblConnected = false
  _G.rfsuite.session.modelName = nil
end

--- Make the connect tasks run again, and nothing else.
--
-- After a reboot the tasks are all still marked complete, so the work they do at connect --
-- sending the clock among it -- is not redone unless something resets them. The only place
-- that resets a runner today is publishConnected(false), which is reached from the link
-- detector: a reboot short enough not to hold the link down for DISCONNECT_STABLE_SECONDS
-- never gets there. Events.reset() looks like the way to force it and is not -- it clears the
-- link state directly, without touching a single runner.
--
-- This resets the connect runner alone. It leaves session state, the link detector and every
-- other category untouched, and it is idempotent: if the detector did notice the reboot and
-- already reset the runner, calling it again costs one pass over a queue that is going to be
-- rerun anyway.
function Events.rerunOnconnect()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.reset) == "function" then
    pcall(onconnect.reset)
    return true
  end
  return false
end

function Events.isOnconnectActive()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.active) == "function" then
    return onconnect.active()
  end
  return false
end

function Events.getOnconnectProgress()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.getProgress) == "function" then
    return onconnect.getProgress()
  end
  return nil
end

function Events.getOnconnectPendingTaskName()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.getPendingTaskName) == "function" then
    return onconnect.getPendingTaskName()
  end
  return nil
end

function Events.wakeup()
  ensureDeps()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return end
  local mspState = MspRuntime.getState()
  if type(mspState) ~= "table" then return end

  local connected = mspState.lastConnected == true
  local t = nowSeconds()

  if connected then
    state.linkDownSince = nil
    if not state.linkUpSince then state.linkUpSince = t end
    if not state.linkStableUp and (t - state.linkUpSince) >= CONNECT_STABLE_SECONDS then
      state.linkStableUp = true
      publishConnected(true)
    end
  else
    state.linkUpSince = nil
    if not state.linkDownSince then state.linkDownSince = t end
    if state.linkStableUp and (t - state.linkDownSince) >= DISCONNECT_STABLE_SECONDS then
      state.linkStableUp = false
      publishConnected(false)
    end
    -- Only once the link is HELD to be down. The two seconds above exist because a brief
    -- telemetry dropout is not a disconnect, and a restore inside one would rename the model in
    -- flight and spend the record -- while linkStableUp never changed, so the returning link
    -- publishes no connect and nothing writes the craft name back for the rest of the flight. A
    -- cold start is unaffected: linkStableUp starts false, so the first pass still restores.
    if not state.linkStableUp then
      restorePendingModelName()
    end
  end
  -- Trigger per-category runners
  do
    -- onconnect: call runner while linkStableUp is true (runner progresses internally)

    -- Determine context: widget/tool/both
    local context = Env and Env.get() or "tool"

    local armed = mspState and mspState.lastArmed == true

    local onconnectActive = false
    if state.linkStableUp and not armed then
      local onconnect = ensureEventRunner("onconnect")
      if onconnect then
        local wasActive = false
        if type(onconnect.active) == "function" then
          wasActive = onconnect.active()
        end
        if type(onconnect.wakeup) == "function" then
          local ok, err = pcall(onconnect.wakeup, { context = context })
          if not ok and Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", "onconnect.wakeup error: " .. tostring(err), "error")
          end
        end
        if type(onconnect.active) == "function" then
          onconnectActive = onconnect.active()
        end
        if wasActive and not onconnectActive then
          if Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", "onconnect tasks finished, running GC", "info")
          end
          if type(collectgarbage) == "function" then
            collectgarbage("collect")
          end
        end
      end
    end

    -- Defer telemetry_bg until onconnect tasks are done to avoid blocking the Lua VM during startup
    -- Also run telemetry_bg when armed so CRSF custom frames are parsed to keep telemetry active and update disarm state
    --
    -- The deferral is a WIDGET one, and the third term is what keeps it from reaching the tool.
    -- What it protects is the per-call instruction ceiling the firmware puts on a widget:
    -- lua_widget.cpp arms lsWidgets with a count hook of 20000/100 before every call, and
    -- standalone_lua.cpp creates lsStandalone with no count hook at all, so a tool call is not
    -- billed against that ceiling and has nothing to be deferred out of.
    --
    -- What a tool does have instead is a monopoly on the interpreter. Starting a standalone
    -- script sets luaState = INTERPRETER_PAUSED ("Pause function and mixer scripts"), and
    -- interface.cpp runs nothing in that state -- so SCRIPTS/FUNCTIONS/rfsbg.lua, which decodes
    -- the same custom telemetry frames for the rest of the radio, is stopped for as long as the
    -- tool is open. This drain is then the only decoder there is, and while it is deferred the
    -- tool publishes no sensor from frame 0x88 at all. The one that costs something is ARM:
    -- tasks/msp/runtime.lua reads the armed state off that sensor and empties the MSP queue on
    -- it, so with the drain deferred the gate cannot fire for the whole connect sequence and the
    -- sequence keeps sending -- including MSP_SET_RTC -- to a flight controller that has armed.
    if state.linkStableUp and (not onconnectActive or armed or context == "tool") then
      local telemetry_bg = ensureEventRunner("telemetry_bg")
      if telemetry_bg and type(telemetry_bg.wakeup) == "function" then
        local ok, err = pcall(telemetry_bg.wakeup)
        if not ok and Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "telemetry_bg.wakeup error: " .. tostring(err), "error")
        end
      end
    end

    -- arm/ disarm transitions: detect changes and call corresponding runners (linkStableUp only)
    if state.linkStableUp then
      if state.lastArmed == nil then
        state.lastArmed = armed
      end
      if armed ~= state.lastArmed then
        state.lastArmed = armed
        local category = armed and "onarm" or "ondisarm"
        local runner = ensureEventRunner(category)
        if runner and type(runner.resetAllTasks) == "function" then
          -- Reset on BOTH edges, because neither is a one-off. The runner marks a task complete
          -- when it reports itself finished and never looks at it again; without this the first
          -- arm of a session would be the only one an onarm task ever saw. A task that does not
          -- report itself finished fares no better: it is re-queued on a timeout it can only meet
          -- by being called twice inside 25 s, and the runner gives up on it after three rounds.
          local ok, err = pcall(runner.resetAllTasks)
          if not ok and Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", category .. ".resetAllTasks error: " .. tostring(err), "error")
          end
        end
        state.edgeRunner = category
      end
    end

    -- Driven until it says it has nothing left, not once at the edge -- see driveEdgeRunner.
    if state.edgeRunner then
      if not driveEdgeRunner(state.edgeRunner, context) then
        state.edgeRunner = nil
      end
    end

    -- The flight record, last: on the arm edge the runner above has just opened it in this same
    -- wakeup, so the first sample belongs to the new flight and not to the one before it; on the
    -- disarm edge it has just been closed, and `armed` is already false, so nothing is sampled
    -- into a record that has been put away.
    --
    -- Widget context only. The record belongs to the widget that runs this work; the tool has a
    -- clock of its own and is not a second writer.
    if context == "widget" then
      if FlightRecord == nil then
        FlightRecord = loadModule("tasks/events/telemetry/flight_record.lua") or false
      end
      if FlightRecord then
        local ok, err = pcall(FlightRecord.wakeup, armed)
        if not ok and Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "flight_record.wakeup error: " .. tostring(err), "error")
        end
      end
    end
  end
end

if type(_G) == "table" then
  _G.__rfsuite_events_module = Events
end

return Events
