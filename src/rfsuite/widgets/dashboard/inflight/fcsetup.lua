-- Writing the standard adjustment set onto the flight controller.
--
-- This is the one place in the in-flight tuning feature that changes the BOARD. The overlay's
-- widget half never does: it moves two global variables and the board's own adjustment slots do
-- the rest, so nothing it does needs MSP at all. What lives here belongs to the settings page,
-- which is reached on the ground with the model disarmed, and it does exactly what their own
-- Adjustments page does when it saves -- MSP_SET_ADJUSTMENT_RANGE per slot, chained one reply at
-- a time, then a single MSP_EEPROM_WRITE -- with the payload built from the standard set instead
-- of from a screenful of fields.
--
-- Four steps, and the middle one is the pilot's:
--
--   1 READ    the receiver map (64) and the function id of every slot (167). TWO round trips, and
--             that is the whole of the read: 167 answers all forty-two slots in one forty-two byte
--             reply. Never 52 -- over CRSF that reply overruns the flight controller's own
--             reassembly buffer, which is why their page reads the table one slot at a time.
--   2 PLAN    what each slot of the set holds now and what it would hold, and which of them are
--             therefore being overwritten. Nothing is written to build a plan and the plan is what
--             the confirmation is worded from.
--   3 WRITE   the thirty-six records, one MSP 53 each, chained from the previous reply, then one
--             MSP 250 to commit. Refused before it starts and abandoned mid-chain if the model
--             arms.
--   4 VERIFY  read the same slots back with 156 and hold them against the set field by field.
--
-- The read used to ask 156 for every populated slot as well -- thirty-six further round trips at
-- roughly three-quarters of a second each on a pilot's own radio, with nothing on the screen while
-- they ran. What those records bought the PLAN was the channel each slot watches, which is one
-- sentence in a confirmation; what they cost was thirty-six seconds in front of a button press.
-- They are gone from the read and the sentence is gone with them: the plan says which slots hold
-- another function and that their channel fields were not looked at, and the VERIFY step -- which
-- reads the same records anyway, after the write, when their answer is the one that matters --
-- does the field-by-field comparison.
--
-- The armed rule is the same one the ground half of the overlay follows and for the same reason:
-- tasks/msp/runtime.lua clears its whole queue on every armed tick, so a write sent to an armed
-- model is dropped without an error and the caller would be told nothing. The check here fails
-- CLOSED -- a model whose arming flags cannot be read at all is refused rather than written to,
-- because "cannot tell" is not "safe to proceed" in front of a write.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if rChunk then
    local ok, res = pcall(rChunk)
    if ok and type(res) == "function" then
      requireModule = res
    end
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Functions = requireModule("widgets/dashboard/inflight/functions.lua")
local Log = requireModule("lib/log.lua")

-- A dependency that did not load must not leave a WORKING-LOOKING module behind.
--
-- lib/require.lua caches whatever a chunk RETURNS. Its own load of a dependency goes through
-- pcall, and a pcall catches the firmware's instruction-limit error like any other -- so a widget
-- pass that runs out of budget while one of the files above is being read leaves the require
-- answering nil, this chunk running on to its end with a nil upvalue, and the broken table cached
-- for the rest of the session. Every call into it then raises
--   ?:0: attempt to index a nil value (upvalue '?')
-- on every pass, for ever, and the widget's refresh is abandoned each time. That is what the
-- pilot's card log recorded 913 times after a start with no flight controller: the overlay's
-- modules were first loaded on the pass the connect chain and the theme reload were already
-- filling, and the load that lost the race was cached.
--
-- Raising here instead means the pcall in lib/require.lua fails, NOTHING is cached, and the next
-- pass loads the file again on a budget that may well be quieter. A missing file behaves the same
-- way and is answered by the caller, which keeps its own retry.
if type(Functions) ~= "table" then
  error("inflight/fcsetup.lua: a dependency did not load", 0)
end

local function logSetup(fmt, ...)
  if not (Log and type(Log.wanted) == "function" and Log.wanted("info")) then return end
  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  Log.emit("rfsuite.inflight", msg, "info")
end

-- The name every message of this action carries. The overlay's own ground half uses a different
-- one: they are two separate pieces of work reaching the same board, and a log line or a queue
-- clear naming one of them should not be read as naming the other.
M.CLIENT = "inflight-setup"

local CMD_RX_MAP = 64
local CMD_ADJ_FUNCTION_IDS = 167
local CMD_ADJ_RANGE = 156
local CMD_SET_ADJ_RANGE = 53
local CMD_EEPROM_WRITE = 250

-- The board's table is 42 slots, the length of the 167 reply.
local SLOT_COUNT = 42
M.SLOT_COUNT = SLOT_COUNT

-- Slots 0 and 1 are the profile selects of the documented layout -- rate profile and PID profile,
-- on a switch of their own and continuous rather than stepped. They are never written and never
-- read in full; what they hold is reported from the function id reply so that the plan can say
-- they are being kept.
local KEPT_SLOTS = { 0, 1 }
local FN_RATE_PROFILE = 1
local FN_PID_PROFILE = 2

-- MSP_GET_ADJUSTMENT_RANGE and MSP_GET_ADJUSTMENT_FUNCTION_IDS were added in this API version.
-- Below it the paged accessors do not exist, and the only way to read the table is the whole-table
-- command that must not be sent over this transport. Their own Adjustments page gates on the same
-- number for the same reason.
local PAGED_READ_API = { 12, 0, 9 }

-- The range a window edge is encoded into: a signed byte of five-microsecond steps either side of
-- centre. Their page clamps to this before it makes the byte, and so does this one.
local STEP_US = 5
local CENTRE_US = 1500
local STEP_LIMIT = 125

M.PHASE_IDLE = "idle"
M.PHASE_RXMAP = "rxmap"
M.PHASE_FUNCTION_IDS = "functionIds"
M.PHASE_PLANNED = "planned"
M.PHASE_WRITING = "writing"
M.PHASE_COMMIT = "commit"
M.PHASE_VERIFY = "verify"
M.PHASE_DONE = "done"
M.PHASE_ERROR = "error"

-- ---------------------------------------------------------------------------
-- The seams: everything outside this module that it touches
-- ---------------------------------------------------------------------------

local MspRuntime = nil
local Sensors = nil
local ApiVersion = nil
local apiCache = {}

local function apiModule(name)
  if name == nil then return nil end
  if apiCache[name] == nil then
    apiCache[name] = requireModule("tasks/msp/api/" .. name .. ".lua") or false
  end
  if apiCache[name] == false then return nil end
  return apiCache[name]
end

local function session()
  local root = _G.rfsuite
  return (type(root) == "table") and root.session or nil
end

local function queueOf()
  if MspRuntime == nil then
    MspRuntime = requireModule("tasks/msp/runtime.lua") or false
  end
  if MspRuntime == false or type(MspRuntime.getState) ~= "function" then return nil end
  local state = MspRuntime.getState()
  local queue = state and state.queue
  if type(queue) ~= "table" or type(queue.add) ~= "function" then return nil end
  return queue
end

--- Whether the flight controller answers the paged reads of the adjustment table.
--
-- Unknown counts as no. A version that has not arrived yet is a connect sequence that has not
-- finished, and a write is not something to start on the assumption that the board will turn out
-- to be new enough.
local function hasPagedReads()
  if ApiVersion == nil then
    ApiVersion = requireModule("lib/api_version.lua") or false
  end
  if ApiVersion == false or type(ApiVersion.isAtLeast) ~= "function" then return false end
  local s = session()
  local current = s and s.apiVersion
  if current == nil or current == "" or tostring(current) == "0" then return false end
  return ApiVersion.isAtLeast(current, PAGED_READ_API) == true
end

--- What stands between this model and a write, or nil when nothing does.
--
-- Deliberately not their ui/home.lua `isModelArmed`, which is a local of that file and answers
-- false for three different reasons -- not armed, no sensor, no link. That is the right default
-- for the warning it paints and the wrong one here, where a "no" that means "cannot tell" would
-- send fifty MSP writes at a helicopter in the air. Each of the three is separated and named.
function M.armRefusal()
  if Sensors == nil then
    Sensors = requireModule("lib/sensors.lua") or false
  end
  if Sensors == false or type(Sensors.getValue) ~= "function" then return "no_sensors" end

  local isSim = false
  if type(Sensors.isSimulator) == "function" then
    local ok, res = pcall(Sensors.isSimulator)
    isSim = ok and res == true
  end

  -- Reached through _G rather than as a bare global: their ui/home.lua asks the same question the
  -- same way, and the name is not one the project declares to its linter.
  local rssiFn = _G.getRSSI
  if not isSim and type(rssiFn) == "function" then
    local ok, rssi = pcall(rssiFn)
    if ok and type(rssi) == "number" and rssi <= 0 then return "no_link" end
  end

  local value = Sensors.getValue("armflags")
  if value == nil then
    -- Under the simulator there is no arming sensor and no helicopter either, which is the one
    -- case where an unreadable arming state is not a reason to refuse.
    if isSim then return nil end
    return "arm_unknown"
  end
  if type(value) == "string" then value = tonumber(value) end
  if type(value) == "boolean" then
    if value then return "armed" end
    return nil
  end
  if type(value) == "number" then
    if type(bit32) == "table" and type(bit32.btest) == "function" then
      if bit32.btest(value, 1) then return "armed" end
      return nil
    end
    if value ~= 0 then return "armed" end
    return nil
  end
  return "arm_unknown"
end

-- ---------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------

--- A run with nothing read and nothing written.
function M.newRun(settings)
  return {
    settings = settings,
    phase = M.PHASE_IDLE,
    -- The records the READ-BACK collects. The read before the plan collects none: there is no
    -- `records` table here any more, and a caller finding one is looking at a verify.
    verifyRecords = {},
    functionIds = nil,
    map = nil,
    slotList = {},
    slotAt = 1,
    writeAt = 1,
    written = 0,
    done = 0,
    total = 0,
    plan = nil,
    report = nil,
    error = nil
  }
end

local function callHandler(handlers, name, ...)
  local fn = handlers and handlers[name]
  if type(fn) == "function" then pcall(fn, ...) end
end

local function fail(run, handlers, reason)
  -- A run the caller gave up on is not a run that failed. Its own queue clear comes back through
  -- the error handlers a moment later, and without this the pilot would be told the write was
  -- refused for something he never did.
  if run.cancelled == true then return false end
  if run.phase == M.PHASE_ERROR then return false end
  run.phase = M.PHASE_ERROR
  run.error = tostring(reason or "failed")
  logSetup("fc setup failed: %s", run.error)
  callHandler(handlers, "onError", run, run.error)
  return false
end

--- The queue clears itself on every armed tick and tells every waiting caller so with this
-- reason. That is not a failure of the write, it is the runtime enforcing the same rule this
-- module enforces at its own door, and it is reported as the abandon it is.
local function replyFailed(run, handlers, where)
  return function(_, reason)
    if tostring(reason) == "cleared" then
      return fail(run, handlers, "armed")
    end
    return fail(run, handlers, where)
  end
end

--- The one check that is made again before every single message, not only at the door.
--
-- A chain of thirty-seven writes takes seconds, and a pilot can arm inside it. The runtime would
-- drop the rest silently; this stops and says which slot it stopped at.
local function stillAllowed(run, handlers)
  if run.cancelled == true then return false end
  local refusal = M.armRefusal()
  if refusal ~= nil then
    fail(run, handlers, refusal)
    return false
  end
  return true
end

--- The phases a run may be abandoned in: the READ, and the plan waiting for an answer.
--
-- Nothing past them is on this list and that is the point. A write chain stopped half way leaves
-- the flight controller holding part of one adjustment set and part of another -- a state no
-- screen describes and the pilot has no way of recognising in the air -- so a page that is left
-- during the write lets the queue finish it. Which is why the screen says so while it runs.
local CANCELLABLE = {
  [M.PHASE_RXMAP] = true,
  [M.PHASE_FUNCTION_IDS] = true,
  [M.PHASE_PLANNED] = true
}

--- Give a run up, if it is in a phase that may be given up.
--
-- Answers whether it was. The messages still in the queue are dropped by client id -- the ground
-- half of the overlay uses a different one, so a prime running beside this is not touched -- and
-- the flag above keeps their error handlers from reporting the drop as a refusal.
function M.cancel(run)
  if type(run) ~= "table" then return false end
  if CANCELLABLE[run.phase] ~= true then return false end
  run.cancelled = true
  run.phase = M.PHASE_IDLE
  local queue = queueOf()
  if queue ~= nil and type(queue.clear) == "function" then
    pcall(queue.clear, queue, M.CLIENT)
  end
  logSetup("fc setup cancelled: nothing had been written")
  return true
end

-- ---------------------------------------------------------------------------
-- Reading the board
-- ---------------------------------------------------------------------------

--- One record of the READ-BACK. The only place in this module that asks 156 for anything.
local function sendVerifyRead(run, handlers, slot)
  local queue = queueOf()
  if queue == nil then return fail(run, handlers, "no_link") end
  local api = apiModule("get_adjustment_range")
  if api == nil then return fail(run, handlers, "no_api") end

  queue:add({
    command = CMD_ADJ_RANGE,
    -- The slot index is 0-based on the wire, and a payload does not make this a write: it says
    -- which slot to answer for. The queue infers `isWrite` from a non-empty payload, so both are
    -- stated rather than left to it.
    payload = { slot - 1 },
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = function(_, buf)
      local parsed = api.parse(buf)
      local decoded = type(parsed) == "table" and parsed.adjustment_range or nil
      if type(decoded) == "table" then run.verifyRecords[slot] = decoded end
      run.done = run.done + 1
      run.slotAt = run.slotAt + 1
      -- The counters move here and the next record goes out from the same reply; whether anything
      -- is REDRAWN for it is the caller's decision, and after the pilot's round-3 log it is not
      -- taken per record. See fcaction.lua.
      callHandler(handlers, "onProgress", run)
      M.stepVerify(run, handlers)
    end,
    errorHandler = replyFailed(run, handlers, "verify")
  })
  return true
end

--- The read is over: build the plan and hand it to the pilot.
local function planned(run, handlers)
  run.plan = M.buildPlan(run)
  run.phase = M.PHASE_PLANNED
  logSetup("fc setup planned: %s", run.plan.ok and "ok" or tostring(run.plan.refused))
  callHandler(handlers, "onPlan", run, run.plan)
  return true
end

local function sendFunctionIds(run, handlers)
  local queue = queueOf()
  if queue == nil then return fail(run, handlers, "no_link") end
  local api = apiModule("get_adjustment_function_ids")
  if api == nil then return fail(run, handlers, "no_api") end

  run.phase = M.PHASE_FUNCTION_IDS
  queue:add({
    command = CMD_ADJ_FUNCTION_IDS,
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = function(_, buf)
      if run.cancelled == true then return end
      local parsed = api.parse(buf)
      local ids = type(parsed) == "table" and parsed.adjustment_function_ids or nil
      if type(ids) ~= "table" then return fail(run, handlers, "no_function_ids") end
      run.functionIds = ids
      run.done = 2
      callHandler(handlers, "onProgress", run)
      -- The whole read, in two replies. Everything the plan says about what a slot holds today
      -- comes out of this one table.
      planned(run, handlers)
    end,
    errorHandler = replyFailed(run, handlers, "functionIds")
  })
  return true
end

--- Start the read. Refused before a single message goes out when the model is armed, when the
-- arming state cannot be read at all, when there is no link, or when the flight controller is too
-- old to answer the paged reads.
function M.begin(run, handlers)
  if type(run) ~= "table" then return false end
  local refusal = M.armRefusal()
  if refusal ~= nil then return fail(run, handlers, refusal) end
  if not hasPagedReads() then return fail(run, handlers, "old_api") end

  local queue = queueOf()
  if queue == nil then return fail(run, handlers, "no_link") end
  local api = apiModule("rx_map")
  if api == nil then return fail(run, handlers, "no_api") end

  run.phase = M.PHASE_RXMAP
  run.verifyRecords = {}
  run.done = 0
  -- Two, and only two: the receiver map and the whole function-id table.
  run.total = 2
  logSetup("fc setup: reading the board (2 replies)")

  queue:add({
    command = CMD_RX_MAP,
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = function(_, buf)
      if run.cancelled == true then return end
      run.map = api.parse(buf)
      run.done = 1
      callHandler(handlers, "onProgress", run)
      if not stillAllowed(run, handlers) then return end
      sendFunctionIds(run, handlers)
    end,
    errorHandler = replyFailed(run, handlers, "rxmap")
  })
  return true
end

-- ---------------------------------------------------------------------------
-- The plan
-- ---------------------------------------------------------------------------

--- Everything the write would do, as a list, before any of it is done. Nothing here sends
-- anything; M.apply does, and only what this returned.
--
-- Three things the plan has to say, because none of them can be taken back afterwards:
--   * which slots are being OVERWRITTEN -- they hold a function today, and a different one after,
--     and what each of them holds is named so the pilot can recognise a control he flies with;
--   * that the plan is built from the FUNCTION IDS alone, so nothing here has looked at which
--     channel a slot watches or through which window -- the read-back after the write does that;
--   * that slots 0 and 1 are kept, since a pilot who has the documented layout has his profile
--     selects there and would otherwise have to take that on trust.
function M.buildPlan(run)
  local settings = run.settings or {}
  local plan = {
    slots = {}, keep = {}, overwritten = 0,
    -- What the plan was built from, so the confirmation can say it rather than imply it.
    idsOnly = true,
    bankCh = settings.bank_ch, valueCh = settings.value_ch
  }

  if settings.bank_ch == settings.value_ch then
    plan.refused = "same_channel"
    return plan
  end

  local enaField = Functions.wireToAuxField(settings.bank_ch, run.map)
  local adjField = Functions.wireToAuxField(settings.value_ch, run.map)
  if enaField == nil then
    plan.refused = "ena_channel"
    return plan
  end
  if adjField == nil then
    plan.refused = "adj_channel"
    return plan
  end
  plan.enaField, plan.adjField = enaField, adjField

  local cells = Functions.standardSlots(enaField, adjField,
    { step = settings.step, step_headspeed = settings.step_headspeed })
  if #cells == 0 then
    plan.refused = "no_set"
    return plan
  end

  for i = 1, #cells do
    local cell = cells[i]
    local slot = cell.slot0 + 1
    local heldFn = 0
    if type(run.functionIds) == "table" then
      heldFn = tonumber(run.functionIds[slot]) or 0
    end

    local entry = {
      slot0 = cell.slot0,
      bank = cell.bank,
      row = cell.row,
      id = cell.id,
      name = Functions.nameOf(cell.id),
      record = cell.record,
      heldFn = heldFn,
      heldName = (heldFn ~= 0) and Functions.nameOf(heldFn) or nil,
      overwritten = false
    }

    -- A slot holding a DIFFERENT function is the one the pilot has to recognise: it is a control
    -- he flies with, wherever its switch sits, and after the write it adjusts something else. It
    -- is named rather than counted, because a slot number is not something anybody recognises.
    --
    -- A slot already holding the right function is still written -- the record is replaced whole
    -- and its channels and windows were never read -- but nothing is lost by it, so it is not on
    -- the list of things that cannot be taken back.
    if heldFn ~= 0 and heldFn ~= cell.id then
      entry.overwritten = true
      plan.overwritten = plan.overwritten + 1
    end

    plan.slots[#plan.slots + 1] = entry
  end

  for i = 1, #KEPT_SLOTS do
    local slot0 = KEPT_SLOTS[i]
    local heldFn = 0
    if type(run.functionIds) == "table" then heldFn = tonumber(run.functionIds[slot0 + 1]) or 0 end
    plan.keep[#plan.keep + 1] = {
      slot0 = slot0,
      heldFn = heldFn,
      heldName = (heldFn ~= 0) and Functions.nameOf(heldFn) or nil,
      -- Whether it is one of the two profile selects the documented layout puts there. A slot
      -- holding something else is still kept -- the set has no cell for it -- and saying so is
      -- all this flag is for.
      profileSelect = (heldFn == FN_RATE_PROFILE or heldFn == FN_PID_PROFILE)
    }
  end

  -- What the board carries today, held against the set as a whole -- at the function id and no
  -- further, since that is all the read asked for. It carries `idsOnly`, and the sentence the
  -- confirmation words from it says so: a board whose every slot names the right function can
  -- still watch the wrong channel through the wrong window, and only the read-back sees that.
  plan.compare = Functions.compareFunctionIds(run.functionIds, run.map,
    settings.bank_ch, settings.value_ch)

  plan.writes = #plan.slots
  plan.ok = true
  return plan
end

-- ---------------------------------------------------------------------------
-- The fifteen bytes
-- ---------------------------------------------------------------------------

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function toS8Byte(value)
  local v = clamp(math.floor(value + 0.5), -128, 127)
  if v < 0 then return v + 256 end
  return v
end

local function toS16Bytes(value)
  local v = clamp(math.floor(value + 0.5), -32768, 32767)
  if v < 0 then v = v + 65536 end
  return v % 256, math.floor(v / 256)
end

local function windowSteps(window)
  return clamp((window.start - CENTRE_US) / STEP_US, -STEP_LIMIT, STEP_LIMIT),
         clamp((window["end"] - CENTRE_US) / STEP_US, -STEP_LIMIT, STEP_LIMIT)
end

--- The MSP_SET_ADJUSTMENT_RANGE payload for one slot.
--
-- Byte for byte what their own Adjustments page builds when it saves, including the arithmetic:
-- a window edge travels as a signed byte of five-microsecond steps from centre, clamped to +/-125
-- before the byte is made, and the two bounds travel as little-endian signed sixteen-bit pairs.
-- The order is the firmware's own record order, which is also the order
-- tasks/msp/api/get_adjustment_range.lua decodes a reply in -- so a payload built here and read
-- back through that module answers with the record it was built from.
function M.encodeSlot(slot0, record)
  if type(record) ~= "table" then return nil end
  local enaStart, enaEnd = windowSteps(record.enaRange)
  local decStart, decEnd = windowSteps(record.adjRange1)
  local incStart, incEnd = windowSteps(record.adjRange2)
  local minLo, minHi = toS16Bytes(record.adjMin)
  local maxLo, maxHi = toS16Bytes(record.adjMax)
  return {
    math.floor(slot0),
    clamp(math.floor(record.adjFunction or 0), 0, 255),
    clamp(math.floor(record.enaChannel or 0), 0, Functions.AUX_FIELD_COUNT - 1),
    toS8Byte(enaStart),
    toS8Byte(enaEnd),
    clamp(math.floor(record.adjChannel or 0), 0, Functions.AUX_FIELD_COUNT - 1),
    toS8Byte(decStart),
    toS8Byte(decEnd),
    toS8Byte(incStart),
    toS8Byte(incEnd),
    minLo,
    minHi,
    maxLo,
    maxHi,
    clamp(math.floor(record.adjStep or 0), 0, 255)
  }
end

-- ---------------------------------------------------------------------------
-- The write
-- ---------------------------------------------------------------------------

local function sendCommit(run, handlers)
  local queue = queueOf()
  if queue == nil then return fail(run, handlers, "no_link") end
  local api = apiModule("eeprom_write")

  run.phase = M.PHASE_COMMIT
  callHandler(handlers, "onProgress", run)

  queue:add({
    command = (api and api.writeCommand) or CMD_EEPROM_WRITE,
    -- An empty payload and still a write. The queue infers `isWrite` from a non-empty payload,
    -- which is wrong for exactly this message, so it is stated.
    payload = {},
    isWrite = true,
    simulatorResponse = {},
    client = M.CLIENT,
    processReply = function()
      run.done = run.done + 1
      logSetup("fc setup: %d slot(s) written and committed", run.written)
      M.startVerify(run, handlers)
    end,
    errorHandler = replyFailed(run, handlers, "commit")
  })
  return true
end

local function sendSlotWrite(run, handlers)
  local entry = run.plan.slots[run.writeAt]
  if entry == nil then return sendCommit(run, handlers) end
  if not stillAllowed(run, handlers) then return false end

  local queue = queueOf()
  if queue == nil then return fail(run, handlers, "no_link") end
  local api = apiModule("set_adjustment_range")
  local payload = M.encodeSlot(entry.slot0, entry.record)
  if payload == nil then return fail(run, handlers, "encode") end

  queue:add({
    command = (api and api.writeCommand) or CMD_SET_ADJ_RANGE,
    payload = payload,
    isWrite = true,
    simulatorResponse = {},
    client = M.CLIENT,
    processReply = function()
      run.written = run.written + 1
      run.done = run.done + 1
      run.writeAt = run.writeAt + 1
      callHandler(handlers, "onProgress", run)
      sendSlotWrite(run, handlers)
    end,
    -- Named per slot: a chain of thirty-six identical-looking messages that reports only "the
    -- write failed" leaves nobody able to say what the board is now holding.
    errorHandler = function(_, reason)
      if tostring(reason) == "cleared" then return fail(run, handlers, "armed") end
      return fail(run, handlers, "slot_" .. tostring(entry.slot0))
    end
  })
  return true
end

--- Carry out exactly what the plan listed. Only ever called with the pilot's answer in hand.
function M.apply(run, handlers)
  if type(run) ~= "table" or type(run.plan) ~= "table" or run.plan.ok ~= true then
    return fail(run or {}, handlers, "no_plan")
  end
  local refusal = M.armRefusal()
  if refusal ~= nil then return fail(run, handlers, refusal) end

  run.phase = M.PHASE_WRITING
  run.writeAt = 1
  run.written = 0
  run.done = 0
  -- The thirty-six writes, the commit, and the read-back of everything written.
  run.total = #run.plan.slots + 1 + #run.plan.slots
  logSetup("fc setup: writing %d slot(s)", #run.plan.slots)
  callHandler(handlers, "onProgress", run)
  return sendSlotWrite(run, handlers)
end

-- ---------------------------------------------------------------------------
-- The read-back
-- ---------------------------------------------------------------------------

--- Ask for the next slot record of the VERIFY, or finish when there are no more.
function M.stepVerify(run, handlers)
  local slot = run.slotList[run.slotAt]
  if slot == nil then
    local settings = run.settings or {}
    -- Held against the set the write was built from, STEPS INCLUDED. The step is one of the
    -- fields recordMatches compares and one of the fields the write puts in the record, so a
    -- comparison that does not name the pair falls back on functions.lua's own defaults and
    -- reports every slot written with any other step as a difference -- thirty-five of thirty-six
    -- on a board this very run has just written byte for byte. buildPlan names them at the same
    -- two keys; a read-back that named fewer would be measuring a different set.
    local steps = { step = settings.step, step_headspeed = settings.step_headspeed }
    local result = Functions.compare(run.verifyRecords, run.map, settings.bank_ch, settings.value_ch,
      steps)
    run.report = {
      written = run.written,
      verdict = (result and result.verdict) or "unmapped",
      count = (result and result.count) or 0,
      total = (result and result.total) or 0,
      -- The step is the one field of a slot a SETTING on the radio decides, so a difference in it
      -- alone is a difference the pilot can act on. Carried here rather than left in the
      -- comparison, because the screen that has to name it only ever sees this report.
      steps = (result and result.steps) or 0,
      stepOnly = (result and result.stepOnly) == true,
      slots = (result and result.slots) or {}
    }
    run.phase = M.PHASE_DONE
    logSetup("fc setup verified: board %s (%d slot(s) differ)", run.report.verdict, run.report.count)
    callHandler(handlers, "onDone", run, run.report)
    return true
  end
  if not stillAllowed(run, handlers) then return false end
  return sendVerifyRead(run, handlers, slot)
end

--- Read back every slot the write touched, and hold it against the set field by field.
--
-- Every one of them, not only the ones that were empty before: a board that accepted a write and
-- stored something else is exactly what a read-back exists to catch, and it cannot be told apart
-- from a board that stored what it was given by asking the writer.
function M.startVerify(run, handlers)
  run.phase = M.PHASE_VERIFY
  run.verifyRecords = {}
  run.slotList = {}
  for i = 1, #run.plan.slots do
    run.slotList[i] = run.plan.slots[i].slot0 + 1
  end
  run.slotAt = 1
  callHandler(handlers, "onProgress", run)
  return M.stepVerify(run, handlers)
end

return M
