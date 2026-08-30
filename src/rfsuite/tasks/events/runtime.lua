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
      pcall(Log.emit, "rfsuite.events", "no runner for events/" .. tostring(name), "debug", true)
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
}

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
    session.flightcount = 0
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
  end
  if Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.events", "session.isConnected=" .. tostring(val), "info", true)
  end
  if val == false and _G.rfsuite and _G.rfsuite.tasks and _G.rfsuite.tasks.events then
    for name, runner in pairs(_G.rfsuite.tasks.events) do
      if type(runner) == "table" and type(runner.reset) == "function" then
        pcall(runner.reset)
        if Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "reset runner " .. tostring(name), "debug", true)
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
    pcall(Log.emit, "rfsuite.events", "model name put back: " .. tostring(restored), "info", true)
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
            pcall(Log.emit, "rfsuite.events", "onconnect.wakeup error: " .. tostring(err), "error", true)
          end
        end
        if type(onconnect.active) == "function" then
          onconnectActive = onconnect.active()
        end
        if wasActive and not onconnectActive then
          if Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", "onconnect tasks finished, running GC", "info", true)
          end
          if type(collectgarbage) == "function" then
            collectgarbage("collect")
          end
        end
      end
    end

    -- Defer telemetry_bg until onconnect tasks are done to avoid blocking the Lua VM during startup
    -- Also run telemetry_bg when armed so CRSF custom frames are parsed to keep telemetry active and update disarm state
    if state.linkStableUp and (not onconnectActive or armed) then
      local telemetry_bg = ensureEventRunner("telemetry_bg")
      if telemetry_bg and type(telemetry_bg.wakeup) == "function" then
        local ok, err = pcall(telemetry_bg.wakeup)
        if not ok and Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "telemetry_bg.wakeup error: " .. tostring(err), "error", true)
        end
      end
    end

    -- arm/ disarm transitions: detect changes and call corresponding runners
    if state.lastArmed == nil then
      state.lastArmed = armed
    end
    if armed ~= state.lastArmed then
      state.lastArmed = armed
      if armed then
        local onarm = ensureEventRunner("onarm")
        if onarm and type(onarm.wakeup) == "function" then
          local ok, err = pcall(onarm.wakeup)
          if not ok and Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", "onarm.wakeup error: " .. tostring(err), "error", true)
          end
        end
      else
        local ondisarm = ensureEventRunner("ondisarm")
        if ondisarm then
          if type(ondisarm.resetAllTasks) == "function" then
            local ok, err = pcall(ondisarm.resetAllTasks)
            if not ok and Log and type(Log.emit) == "function" then
              pcall(Log.emit, "rfsuite.events", "ondisarm.resetAllTasks error: " .. tostring(err), "error", true)
            end
          end
          if type(ondisarm.wakeup) == "function" then
            local ok, err = pcall(ondisarm.wakeup, { context = context })
            if not ok and Log and type(Log.emit) == "function" then
              pcall(Log.emit, "rfsuite.events", "ondisarm.wakeup error: " .. tostring(err), "error", true)
            end
          end
        end
      end
    end
  end
end

if type(_G) == "table" then
  _G.__rfsuite_events_module = Events
end

return Events
