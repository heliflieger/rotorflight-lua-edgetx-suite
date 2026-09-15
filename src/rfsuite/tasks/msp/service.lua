-- A request surface other scripts on the radio may use, published as rfsuite.msp.
--
-- Why this exists rather than a second queue somewhere else: the transmit side is one slot for
-- the whole radio. crossfireTelemetryPush writes a single global buffer and answers false while
-- it is occupied, so a script that brings its own MSP queue does not get a second channel, it
-- gets contention with this one and both sides lose replies. Asking this runtime instead is the
-- only arrangement in which two consumers both work.
--
-- What it is not: a transport. Everything below is a facade over the runtime and the queue that
-- are already there. It holds no buffers, does no polling and adds no state beyond the registry
-- of who is currently attached.
--
-- Which Lua state you get it in matters. The tool runs standalone and the dashboard widget runs
-- in the widget state; they have separate globals and therefore separate runtimes, and this
-- module is a singleton per state like the runtime under it. A widget reaches the widget state's
-- copy, which is the one the dashboard widget is already pumping.
--
--   local msp = rfsuite and rfsuite.msp
--   if msp then
--     local client = msp.register("mywidget", 1)
--     client:request({
--       command = 101,
--       simulatorResponse = { 0, 0 },
--       onReply = function(buf) ... end,
--       onError = function(reason) ... end,
--     })
--   end

if type(_G) == "table" and type(_G.__rfsuite_msp_service_module) == "table" then
  return _G.__rfsuite_msp_service_module
end

local Service = {}

-- The contract the names below are part of. A caller passes the version it was written against
-- to register(), which refuses when this module has moved on -- so a script built for an older
-- surface fails at the door with a reason instead of half-working somewhere further in. It is
-- raised when a published name changes meaning, not when the code behind it moves.
Service.VERSION = 1

local Runtime = nil
local runtimeLoadAttempted = false
local taggedLog = nil

local clients = {}
local clientSerial = 0
local requestSerial = 0

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then
    return nil
  end
  local ok, mod = pcall(chunk)
  if not ok then
    return nil
  end
  return mod
end

-- The logging core's tagged emitter, bound on first use: the default level and the
-- console flag are lib/log.lua's, and this file states only its tag.
local function log(msg, level)
  if not taggedLog then
    local rf = _G.rfsuite
    local L = rf and rf.Log
    if type(L) ~= "table" or type(L.tagged) ~= "function" then return end
    taggedLog = L.tagged("rfsuite.msp.service")
  end
  taggedLog(msg, level)
end

-- Loaded on first use rather than at the top of the chunk, because the runtime loads this module
-- in turn. By the time anything calls in, both chunks have finished and this is a table read.
local function runtime()
  if not runtimeLoadAttempted then
    runtimeLoadAttempted = true
    Runtime = loadModule("tasks/msp/runtime.lua")
  end
  return Runtime
end

-- Two instances of the same widget are two consumers, not one, so the name a caller gives is a
-- label and the serial is what makes the id. A caller that goes away without releasing leaves
-- one entry behind and nothing else; a caller that reappears is a new client with its own work.
local function makeClientId(name)
  clientSerial = clientSerial + 1
  -- The function form, not the method form: indexing a string fails on the radio, which is why
  -- every string call in this tree is written string.f(s, ...).
  local label = string.gsub(tostring(name or "client"), "[^%w%-_%.]", "")
  if label == "" then
    label = "client"
  end
  return label .. "#" .. tostring(clientSerial)
end

local Client = {}
Client.__index = Client

--- Ask the flight controller something.
--
-- request.command            MSP command number. Required.
-- request.payload            byte array for a write. Optional.
-- request.onReply(buf, info) called with the reply body. info carries command and retries.
-- request.onError(reason)    "timeout", "max_retries", "cancelled" or "aborted" -- the last when
--                            the link dropped and everything in flight was invalidated at once.
-- request.timeout            seconds to wait for a reply before a retry. Optional.
-- request.simulatorResponse  byte array the simulator answers with. See status().simulator:
--                            with no simulator there the radio never sends the request at all.
--
-- Returns a request id, which cancel() takes, or nil and a reason.
function Client:request(request)
  if self.released then
    return nil, "released"
  end
  if type(request) ~= "table" then
    return nil, "bad_request"
  end
  if type(request.command) ~= "number" then
    return nil, "bad_command"
  end

  local rt = runtime()
  if not rt or type(rt.enqueue) ~= "function" then
    return nil, "unavailable"
  end

  requestSerial = requestSerial + 1
  local requestId = requestSerial

  -- Captured rather than read off the request table inside the handlers, so the caller's table
  -- is not held alive by a closure for as long as the message sits in the queue.
  local command = request.command
  local onReply = request.onReply
  local onError = request.onError

  local message = {
    client = self.id,
    requestId = requestId,
    command = command,
    payload = request.payload,
    timeout = request.timeout,
    simulatorResponse = request.simulatorResponse,
  }

  if type(onReply) == "function" then
    message.processReply = function(msg, buf)
      -- A consumer's callback runs inside the queue's own processing. It is wrapped so that an
      -- error in somebody else's script cannot take down the pump that every other consumer,
      -- and this suite's own reads, depend on.
      local ok, err = pcall(onReply, buf, { command = msg.command, retries = msg.__retryCount })
      if not ok then
        log("client " .. tostring(self.id) .. " reply handler failed: " .. tostring(err), "warn")
      end
    end
  end

  message.errorHandler = function(msg, reason)
    if type(onError) ~= "function" then
      return
    end
    -- clear() with no client calls the handlers with no arguments at all, which is how a
    -- disconnect or an unsupported API version invalidates everything at once. That case has no
    -- reason of its own, and it is not a timeout.
    local ok, err = pcall(onError, reason or "aborted", { command = command })
    if not ok then
      log("client " .. tostring(self.id) .. " error handler failed: " .. tostring(err), "warn")
    end
  end

  if not rt.enqueue(message) then
    return nil, "unavailable"
  end

  return requestId
end

--- Drop one of this client's own requests. Its onError runs with "cancelled".
function Client:cancel(requestId)
  if self.released or requestId == nil then
    return false
  end
  local rt = runtime()
  if not rt or type(rt.cancel) ~= "function" then
    return false
  end
  return rt.cancel(self.id, requestId) == true
end

--- Give the client up. Everything it still has queued goes with it; work belonging to anything
--- else keeps its place. Calling it twice is harmless.
function Client:release()
  if self.released then
    return
  end
  self.released = true
  clients[self.id] = nil

  local rt = runtime()
  if rt and type(rt.detach) == "function" then
    rt.detach(self.id)
  end
  log("client " .. tostring(self.id) .. " released", "info")
end

--- Take a client id on this runtime.
--
-- name             a label for the log; it does not have to be unique.
-- requiredVersion  the Service.VERSION the caller was written against. Optional, and passing it
--                  is what turns a changed contract into a clean refusal.
--
-- Returns a client, or nil and a reason.
function Service.register(name, requiredVersion)
  if requiredVersion ~= nil then
    if type(requiredVersion) ~= "number" or requiredVersion > Service.VERSION then
      return nil, "version"
    end
  end

  local rt = runtime()
  if not rt or type(rt.attach) ~= "function" then
    return nil, "unavailable"
  end

  local id = makeClientId(name)
  local client = setmetatable({ id = id, name = tostring(name or "client"), released = false }, Client)
  clients[id] = client

  rt.attach(id)
  log("client " .. id .. " registered", "info")
  return client
end

--- What the link is doing, as a copy. The runtime's own state table is not handed out: it is
--- live and mutable, and a consumer holding it can change what this suite is doing by accident.
function Service.status()
  local rt = runtime()
  if not rt or type(rt.getState) ~= "function" then
    return { available = false }
  end

  local state = rt.getState()
  if type(state) ~= "table" then
    return { available = false }
  end

  local values = state.values or {}
  local queueIdle = true
  if state.queue and type(state.queue.isProcessed) == "function" then
    queueIdle = state.queue:isProcessed() == true
  end

  return {
    available = state.available == true,
    simulator = state.isSimulator == true,
    protocol = state.protocol,
    apiVersion = values.apiVersion,
    apiSupported = not state.unsupportedApi,
    fcVersion = values.fcVersion,
    rfVersion = values.rfVersion,
    queueIdle = queueIdle,
    lastError = state.mspLastError,
  }
end

--- Drive the runtime one step.
--
-- The dashboard widget already does this on every one of its own passes, so a consumer that
-- runs while it is on screen needs nothing. One that cannot rely on that -- a widget on a
-- screen this suite is not on -- calls this from its own refresh, and then the link is pumped
-- whether the dashboard is there or not.
function Service.pump()
  local rt = runtime()
  if not rt or type(rt.tick) ~= "function" then
    return false
  end
  return rt.tick() ~= false
end

if type(_G) == "table" then
  _G.__rfsuite_msp_service_module = Service
end

return Service
