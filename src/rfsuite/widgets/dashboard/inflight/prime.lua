-- The in-flight tuning overlay's ground half: what it reads off the flight controller before a
-- flight, and the undo it lays down before the pilot turns anything.
--
-- Everything in this file speaks MSP, and MSP is only spoken on the ground. tasks/msp/runtime.lua
-- clears its whole queue on every armed tick and pump() refuses while armed, so a read started in
-- the air is dropped without an answer and a write is lost silently. This module therefore
-- refuses to start while armed and abandons a run that is armed into -- and it treats the queue's
-- own "cleared" reason as that abandon rather than as a failure, because the clear IS the runtime
-- enforcing the same rule.
--
-- It does NOT attach a client of its own. Runtime.attach() records the id and brings the runtime
-- up, and widgets/dashboard/runtime.lua's tickMspRuntime already does both on every pass, along
-- with the tick and the pump these replies arrive on. Nothing in the queue schedules by client id
-- -- it is one FIFO, and the id is what a clear and a log line name -- so a second registration
-- would add an id that something would afterwards have to detach, and the widget has no teardown
-- point that could. The messages still carry `client`, which is the part that has an effect.
--
-- Two things are read off the board rather than assumed. The SET is the board's own adjustment
-- slot table: which parameter sits in which bank and row is whatever the pilot configured there,
-- and the documented layout is only the fallback for a board that yields nothing usable. The
-- VALUES are the nine reads that between them answer every adjustment function id, so the screen
-- can show a number before the first step is made -- AdjF/AdjV only report what has just moved.

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
local Setup = requireModule("widgets/dashboard/inflight/setup.lua")
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
if type(Functions) ~= "table" or type(Setup) ~= "table" then
  error("inflight/prime.lua: a dependency did not load", 0)
end

local function logPrime(fmt, ...)
  if not (Log and type(Log.wanted) == "function" and Log.wanted("info")) then return end
  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  Log.emit("rfsuite.inflight", msg, "info")
end

-- The name every message of this module carries. The queue clears and logs by it; nothing
-- schedules by it.
M.CLIENT = "inflight-tuning"

-- MSP_RX_MAP, MSP_GET_ADJUSTMENT_FUNCTION_IDS and MSP_GET_ADJUSTMENT_RANGE. The whole-table read
-- (52) is deliberately absent: over CRSF its reply overruns the reassembly buffer, which is why
-- their own adjustments page reads the table one slot at a time as well.
local CMD_RX_MAP = 64
local CMD_ADJ_FUNCTION_IDS = 167
local CMD_ADJ_RANGE = 156

-- MSP_COPY_PROFILE and MSP_EEPROM_WRITE, the pair their app/pages/tools/copy_profiles page uses.
-- 183 carries { type, destination, source } and 0 is the PID profile type; the copy lives in RAM
-- until 250 commits it, so the two always travel together.
local CMD_COPY_PROFILE = 183
local CMD_EEPROM_WRITE = 250
local PROFILE_TYPE_PID = 0

-- MSP_STATUS, the one value read that also says how many profiles the board has.
local CMD_STATUS = 101

-- The board's table is 42 slots, the length of the 167 reply.
local SLOT_COUNT = 42

-- How many slot records one widget pass may turn into the set. The whole derivation is 7 471 VM
-- instructions on the pilot's own board (33 populated slots) against a call budget of 20 000 that
-- the LVGL reactive sweep also comes out of, so it is taken in slices; eight records is about
-- 1 800 instructions, which is the same order as the widget's other bounded work.
local DERIVE_SLICE = 8

-- How long the connect chain has to have been FINISHED before the automatic prime runs, in
-- getTime ticks of 10 ms.
--
-- The wait used to be measured from the link coming up, and two seconds of link is not the same
-- thing at all: measured against a board, the chain was still running sixteen seconds in, the
-- prime's forty-odd round trips went into the same single queue beside it, and the chain the
-- dashboard is waiting for took fifty-nine seconds instead of sixteen -- long enough for the
-- widget's own splash timeout to fire. So the chain is what is waited for, and this is only the
-- settle on top of it.
local AUTO_DELAY_TICKS = 100

-- The drive's GROUND phase, as widgets/dashboard/inflight/drive.lua spells it.
--
-- Not required from there: the two modules are loaded beside each other rather than one under the
-- other -- this one speaks MSP and the drive does not -- and one word is not worth a dependency
-- edge between them.
local DRIVE_PHASE_GROUND = "ground"

-- How many times the automatic prime is started again after a run that FAILED, within one link.
--
-- A run that was ABANDONED is retried without a limit: an abandon is the pilot arming, which is
-- allowed and which he may do as often as he likes. A FAILURE can be permanent -- a board that
-- answers an error answers it again -- so it is retried this many times and then left alone with
-- the error on the screen rather than asked the same question for the rest of the session.
local AUTO_RETRY_LIMIT = 2

-- How many profiles a board has, when neither the status read nor the session says. Their own
-- status reply carries `pid_profile_count`, which is where the real number comes from; this is
-- only what the refusal falls back on, and it is the count every current target ships.
local PROFILE_COUNT_FALLBACK = 6

-- Every read this module makes is a read, and 250 is a write with an empty payload. The queue
-- infers `isWrite` from a non-empty payload (tasks/msp/queue.lua), which is wrong for both: 156
-- carries a slot index and is still a read, 250 carries nothing and is still a write. Both are
-- therefore stated rather than inferred, everywhere below.

-- ---------------------------------------------------------------------------
-- The link
-- ---------------------------------------------------------------------------

local MspRuntime = nil
local function mspState()
  if MspRuntime == nil then
    MspRuntime = requireModule("tasks/msp/runtime.lua") or false
  end
  if MspRuntime == false or type(MspRuntime.getState) ~= "function" then return nil end
  local state = MspRuntime.getState()
  if type(state) ~= "table" then return nil end
  return state
end

local function queueOf()
  local state = mspState()
  if state == nil or type(state.queue) ~= "table" or type(state.queue.add) ~= "function" then return nil end
  return state.queue
end

-- The rotor is turning, whatever the arm sensor says. The thresholds are the ones
-- widgets/dashboard/runtime.lua's own computeFlightMode uses to decide that a model has left the
-- ground: a governor in one of its running states, or a head speed that nothing on a bench
-- produces. They are read straight off the telemetry state rather than through `armed`, which is
-- the point -- this is a SECOND witness and it has to be independent of the first.
local GOVERNOR_RUNNING_FROM = 4
local GOVERNOR_RUNNING_TO = 8
local RPM_RUNNING = 500

--- Whether the board is armed -- or cannot be shown not to be.
--
-- The widget's own copy is what the screen is drawn from; the MSP runtime's is what actually
-- gates the queue. Either one saying armed is enough: the two are read from the same sensor a
-- pass apart, and the cost of believing the earlier of them is a prime that starts a moment
-- later, while the cost of believing the later one is a request the runtime throws away.
--
-- It FAILS CLOSED, and that is the part worth stating. `armed` is false on a model whose arm
-- sensor was never selected in the telemetry list, exactly as it is on a model sitting disarmed
-- on the bench, and the two are not distinguishable from the flag alone. Answering "not armed"
-- there means sending MSP to a helicopter in the air. So until the sensor has answered once --
-- `armedSeen`, set by the widget's telemetry read and cleared on the reconnect edge -- everything
-- that asks this question is refused, and the ground screen says which sensor is missing rather
-- than showing buttons that would do the wrong thing.
--
-- The rotor test underneath it is the second witness. It is deliberately NOT the widget's
-- `hadInflightFlight` latch, although that is the flag this reading came from: that latch can
-- only ever be set while `armed` is already true, so it adds no independent evidence, and it
-- STAYS true from touchdown until the next arming -- which is the whole window in which a pilot
-- wants the restore this module exists to offer. The live reading refuses while the machine is
-- turning and stops refusing when it stops.
local function isArmed(widget)
  local state = widget and widget.state
  if type(state) == "table" then
    if state.armed == true then return true end
    if state.armedSeen ~= true then return true end
    local governor = tonumber(state.governor)
    if governor ~= nil and governor >= GOVERNOR_RUNNING_FROM and governor <= GOVERNOR_RUNNING_TO then
      return true
    end
    if (tonumber(state.rpm) or 0) >= RPM_RUNNING then return true end
  end
  local msp = mspState()
  return type(msp) == "table" and msp.lastArmed == true
end

--- Why the ground half is refusing, when it is not simply that the board is armed. The screen
-- turns this into a sentence; nil means the ordinary armed/disarmed reading applies.
function M.groundRefusal(widget)
  local state = widget and widget.state
  if type(state) ~= "table" then return nil end
  if state.armed == true then return nil end
  if state.armedSeen ~= true then return "no_arm_sensor" end
  return nil
end

local function apiModule(name)
  if type(name) ~= "string" or name == "" then return nil end
  return requireModule("tasks/msp/api/" .. name .. ".lua")
end

-- ---------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------

M.PHASE_IDLE = "idle"
M.PHASE_RXMAP = "rxmap"
M.PHASE_FUNCTION_IDS = "functionIds"
M.PHASE_SLOTS = "slots"
--- The board's table is in and is being turned into the set, a slice per widget pass.
M.PHASE_DERIVE = "derive"
M.PHASE_VALUES = "values"
M.PHASE_DONE = "done"
M.PHASE_ERROR = "error"

local RUNNING = {
  [M.PHASE_RXMAP] = true, [M.PHASE_FUNCTION_IDS] = true,
  [M.PHASE_SLOTS] = true, [M.PHASE_DERIVE] = true, [M.PHASE_VALUES] = true
}

--- Whether a run is still expecting a reply.
function M.isRunning(drive)
  local prime = type(drive) == "table" and drive.prime or nil
  return type(prime) == "table" and RUNNING[prime.phase] == true
end

--- Whether the board HAS BEEN READ, which is not the same question as what the last run did.
--
-- The evidence is a completed read that left something in the cache, and everything that used to
-- ask `prime.phase == PHASE_DONE` asks this instead. The difference is a defect measured on a
-- radio: a re-read that was abandoned when the pilot armed -- the MSP runtime clears its whole
-- queue on every armed tick, which this module takes as the abandon it is -- set the phase back to
-- idle over a full cache, and from there the backup refused as `unprimed` and the surface said the
-- values had never been read. An abandoned read invalidates nothing: what it did not do is REPLACE
-- values that were already there.
--
-- `readAt` is not the flag, deliberately. It is the radio's wall clock and a radio that answers
-- none leaves it nil, so a read would stop counting on exactly the models whose clock is not set.
function M.hasRead(drive)
  if type(drive) ~= "table" or drive.valuesRead ~= true then return false end
  return type(drive.values) == "table" and next(drive.values) ~= nil
end

local function bump(drive)
  drive.valueEpoch = (drive.valueEpoch or 0) + 1
end

--- Everything stored for a run that is over, or whose phase has been reset under it.
--
-- Replies are stored where they arrive and parsed a pass later (see "The phases" below), so a run
-- that ends can be holding answers it will never look at.
local function dropStored(prime)
  local pending = prime.pending
  if type(pending) ~= "table" then
    prime.pending, prime.pendingHead, prime.pendingTail = {}, 1, 0
    prime.chainPaused = false
    return
  end
  for i = prime.pendingHead or 1, prime.pendingTail or 0 do pending[i] = nil end
  prime.pendingHead, prime.pendingTail = 1, 0
  prime.chainPaused = false
end

--- The reply belongs to the run that is still current, or it belongs to nothing.
--
-- A prime that was restarted, abandoned or failed leaves its messages in the queue, and their
-- callbacks close over the run they were made for. Comparing the run rather than a flag is what
-- keeps a late reply from a previous attempt out of the current one's counters.
local function stillCurrent(drive, prime)
  return type(drive) == "table" and drive.prime == prime and RUNNING[prime.phase] == true
end

local function fail(drive, prime, reason)
  if not stillCurrent(drive, prime) then return false end
  prime.phase = M.PHASE_ERROR
  prime.error = tostring(reason or "failed")
  -- A reply already stored is a parse this run will never make. Dropping it here is what keeps
  -- the passes after a failure free of work for a run that is over.
  dropStored(prime)
  -- Counted so that the automatic run can be offered again a bounded number of times. See
  -- AUTO_RETRY_LIMIT: an abandon is not counted here, because it is not a failure of the board's.
  drive._primeFails = (drive._primeFails or 0) + 1
  bump(drive)
  logPrime("prime failed in %s: %s", tostring(prime.failedIn or "?"), prime.error)
  return false
end

--- A run given up rather than failed: the board was armed into, or the runtime cleared the queue,
-- which while armed is the same event seen from the other side. It is not an error and it is not
-- shown as one -- the pilot armed, which is allowed.
local function abandon(drive, prime, why)
  if not stillCurrent(drive, prime) then return end
  prime.phase = M.PHASE_IDLE
  prime.error = nil
  dropStored(prime)
  -- Recorded on the DRIVE and not on the run, because the run it describes is over and the two
  -- questions it answers are about the next one: whether the automatic run may start again, and
  -- what the ground surface says beside a read that is older than the last attempt at one.
  drive.primeInterrupted = true
  bump(drive)
  logPrime("prime abandoned: %s", tostring(why))
end

--- One more reply is in. The counter moves and the epoch does NOT.
--
-- This is the pilot's third radio round, and it is the failure that froze his radio rather than
-- merely slowing it. The epoch is in the widget's tuning render key, so every bump asked for the
-- whole surface to be torn down and built again -- forty-five objects, throttled to twice a second,
-- which is once per reply for a prime whose replies arrive every half second. His widget_2.log has
-- the instruction budget climbing 35 -> 60 -> 70 % of a five-second peak across a prime and then
-- stopping mid-record with no fault line at all: the firmware's LVGL sweep of the tree runs in the
-- same 20 000-instruction call and OUTSIDE the pcall the entry point wraps refresh in, so nothing
-- of ours can ever see it and the only witness is the screen.
--
-- What the pilot needs to see while a prime runs is a counter, and a counter does not need a tree.
-- The counters travel on the published snapshot, which Drive's publish swaps atomically whenever
-- they move, and the ground surface reads them through a reactive text closure -- one formatted
-- string per frame, no objects. The surface is rebuilt when the prime STARTS and when it ENDS,
-- because those change what is on it.
local function advanced(_drive, prime)
  prime.done = (prime.done or 0) + 1
end

--- One handler for every message this module sends: the queue's own clear is an abandon, and
-- everything else -- a timeout, the retry budget, a board that answered with an error -- is a
-- failure the screen names.
local function replyFailed(drive, prime, where)
  return function(_, reason)
    if reason == "cleared" then
      abandon(drive, prime, "queue cleared")
      return
    end
    prime.failedIn = where
    fail(drive, prime, reason)
  end
end

-- ---------------------------------------------------------------------------
-- The board's own slot table, turned into a set
-- ---------------------------------------------------------------------------

-- Which wire channel an AUX field of a slot record names, and the inverse. Both live in
-- inflight/functions.lua, because the settings page's writer needs the inverse without loading
-- this file; re-exported here because the derivation below, the screens and the probes all reach
-- for the forward direction through this module.
M.auxToWireChannel = Functions.auxToWireChannel
M.wireToAuxField = Functions.wireToAuxField

local function windowKey(window)
  if type(window) ~= "table" then return nil end
  local from = tonumber(window.start)
  local to = tonumber(window["end"])
  if from == nil or to == nil then return nil end
  return tostring(from) .. ":" .. tostring(to), from, to
end

--- The set the board is actually configured for: which parameter answers which bank and row.
--
-- Nothing about the layout is assumed. The BANKS are the distinct enable windows the usable slots
-- name, in rising microseconds -- that is the order a switch or a variable walks them in. The
-- ROWS are the distinct INCREMENT windows, in FALLING microseconds, so row 1 is the one furthest
-- from centre: that is the row the documented layout drives with the largest trim throw, and a
-- board configured some other way still gets its own outermost pair as row 1.
--
-- A slot is usable only when it steps -- a continuous slot has no park position, so nothing on
-- this screen could leave it alone -- and when both of its channels are the ones this model
-- devotes to the pair. A slot on some other channel belongs to a switch the pilot flies with and
-- is none of the overlay's business.
--
-- Answers nil when nothing usable came back, which is what keeps the documented layout as the
-- fallback rather than replacing it with an empty table.
function M.deriveSet(records, map, bankChannel, valueChannel)
  local work = M.newDerivation(records, map, bankChannel, valueChannel)
  if work == nil then return nil, {} end
  local done, result, skipped
  repeat
    done, result, skipped = M.deriveStep(work)
  until done
  return result, skipped
end

--- The same derivation, prepared to run a SLICE at a time.
--
-- Measured on a desktop Lua with the pilot's own board -- 33 populated slots, 31 of them usable
-- -- the whole derivation costs 7 471 VM instructions. EdgeTX bills a widget call at 20 000
-- (lua_widget.cpp, MAX_INSTRUCTIONS) and the LVGL reactive sweep of the tree standing after the
-- call comes out of that same 20 000, on top of a background pass that already costs eleven and
-- a half thousand. Run whole, it therefore does not fit, and what fails is not the widget's own
-- pass: `refresh` returns and `callRefs` raises afterwards, outside the pcall the widget entry
-- point wraps everything in. On a radio that reads as `ERROR in foreground calRefs error` across
-- the frame, with nothing in any log the suite keeps, and the widget stops.
--
-- So it is taken in slices with a budget, like the trim walk in inflight/drive.lua and like the
-- scene build in widgets/dashboard/runtime.lua. The two sorts are not chunked and do not need to
-- be: they order at most `BANK_COUNT` bands and `ROW_COUNT` rows.
function M.newDerivation(records, map, bankChannel, valueChannel)
  if type(records) ~= "table" then return nil end
  return {
    records = records, map = map,
    bankCh = bankChannel, valueCh = valueChannel,
    phase = "scan", at = 0,
    usable = {}, skipped = {},
    bands = {}, bandSeen = {}, rows = {}, rowSeen = {},
    set = {}, placed = 0
  }
end

--- One slice. Answers `done, result, skipped`; `result` is nil until the last slice, and nil at
-- the end means nothing usable came back -- which is what keeps the documented layout as the
-- fallback rather than replacing it with an empty table.
function M.deriveStep(work, budget)
  if type(work) ~= "table" then return true, nil, {} end
  local taken = 0

  if work.phase == "scan" then
    -- Classify and collect in one walk. A slot is usable only when it steps -- a continuous slot
    -- has no park position -- and when both of its channels are the ones this model devotes to
    -- the pair. A slot on some other channel belongs to a switch the pilot flies with.
    while work.at < SLOT_COUNT do
      if budget ~= nil and taken >= budget then return false, nil, nil end
      work.at = work.at + 1
      taken = taken + 1
      local slot = work.at
      local record = work.records[slot]
      if type(record) == "table" and (tonumber(record.adjFunction) or 0) ~= 0 then
        local enableCh = M.auxToWireChannel(record.enaChannel, work.map)
        local valueCh = M.auxToWireChannel(record.adjChannel, work.map)
        if enableCh == work.bankCh and valueCh == work.valueCh then
          if (tonumber(record.adjStep) or 0) > 0 then
            work.usable[#work.usable + 1] = record
            local bandKey, bandFrom, bandTo = windowKey(record.enaRange)
            if bandKey ~= nil and work.bandSeen[bandKey] == nil then
              work.bandSeen[bandKey] = true
              work.bands[#work.bands + 1] = { key = bandKey, min = bandFrom, max = bandTo }
            end
            local rowKey, rowFrom, rowTo = windowKey(record.adjRange2)
            if rowKey ~= nil and work.rowSeen[rowKey] == nil then
              work.rowSeen[rowKey] = true
              work.rows[#work.rows + 1] = { key = rowKey, min = rowFrom, max = rowTo }
            end
          else
            work.skipped[#work.skipped + 1] = slot
          end
        end
      end
    end
    if #work.usable == 0 then return true, nil, work.skipped end
    work.phase = "order"
    return false, nil, nil
  end

  if work.phase == "order" then
    -- The BANKS are the distinct enable windows, in rising microseconds -- the order a switch or
    -- a variable walks them in. The ROWS are the distinct increment windows in FALLING
    -- microseconds, so row 1 is the one furthest from centre: the row the documented layout
    -- drives with the largest trim throw, and a board configured some other way still gets its
    -- own outermost pair as row 1.
    table.sort(work.bands, function(a, b)
      if a.min ~= b.min then return a.min < b.min end
      return a.max < b.max
    end)
    table.sort(work.rows, function(a, b)
      if a.min ~= b.min then return a.min > b.min end
      return a.max > b.max
    end)

    work.bandIndex, work.rowIndex = {}, {}
    work.outBands, work.bankValues = {}, {}
    for i = 1, #work.bands do
      if i > Functions.BANK_COUNT then break end
      work.bandIndex[work.bands[i].key] = i
      work.outBands[i] = { min = work.bands[i].min, max = work.bands[i].max }
      work.bankValues[i] = Functions.bandMidGv(work.outBands[i])
    end
    for i = 1, #work.rows do
      if i > Functions.ROW_COUNT then break end
      work.rowIndex[work.rows[i].key] = i
    end
    work.phase = "place"
    work.at = 0
    return false, nil, nil
  end

  if work.phase == "place" then
    while work.at < #work.usable do
      if budget ~= nil and taken >= budget then return false, nil, nil end
      work.at = work.at + 1
      taken = taken + 1
      local record = work.usable[work.at]
      local bank = work.bandIndex[windowKey(record.enaRange) or ""]
      local row = work.rowIndex[windowKey(record.adjRange2) or ""]
      if bank ~= nil and row ~= nil then
        work.set[bank] = work.set[bank] or {}
        -- The first slot wins a cell it shares. Two slots on the same window pair are a
        -- configuration the board itself cannot resolve either -- it fires whichever it reaches
        -- first -- so guessing the other one here would only disagree with the flight controller.
        if work.set[bank][row] == nil then
          work.set[bank][row] = math.floor(tonumber(record.adjFunction) or 0)
          work.placed = work.placed + 1
        end
      end
    end
    if work.placed == 0 then return true, nil, work.skipped end
    return true, { bands = work.outBands, bankValues = work.bankValues,
                   set = work.set, placed = work.placed }, work.skipped
  end

  return true, nil, work.skipped
end

--- What the finished derivation does to the drive. Called on the slice that completed it.
local function applySet(drive, prime, derived, skipped)
  prime.skipped = skipped or {}
  if derived == nil then
    drive.setSource = "reference"
    logPrime("slot table yielded nothing usable; the documented layout stands")
    return
  end

  drive.bands = derived.bands
  drive.bankValues = derived.bankValues
  drive.set = derived.set
  drive.setSource = "board"
  -- The one place inside a run that must move the epoch. Everything else a prime does travels on
  -- the snapshot and is read by a closure, but the SET is the row list itself -- six names built
  -- into the tree -- and a tree built from the documented layout cannot show the board's.
  bump(drive)
  logPrime("slot table gave %d cell(s) over %d band(s)", derived.placed, #derived.bands)

  -- The selection may be pointing at a cell the board's own table does not have.
  if drive:functionId(drive.bank, drive.row) == nil then
    for bank = 1, Functions.BANK_COUNT do
      for row = 1, Functions.ROW_COUNT do
        if drive:functionId(bank, row) ~= nil then
          drive.bank, drive.row = bank, row
          return
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- The phases
--
-- A reply is STORED when it arrives and PARSED on a later widget pass, at most one per pass.
--
-- The firmware bills a widget call at 20 000 VM instructions (lua_widget.cpp, MAX_INSTRUCTIONS)
-- and the LVGL reactive sweep of the tree standing after the call comes out of the same 20 000,
-- on top of a background pass that already costs eleven and a half thousand. One reply of this
-- run parses for between 42 and 933 of those, so the question is not what a reply costs but how
-- many of them one pass can be made to carry -- and the answer used to be "as many as the link
-- delivers". The widget pass gives the MSP queue two turns (Runtime.tick and Runtime.pump,
-- widgets/dashboard/runtime.lua), a read the queue finds in its cache completes with no round
-- trip at all, and a retry can still be answered after its replacement has gone out. A bounded
-- pass may not rest on none of that happening.
--
-- So `processReply` copies the bytes, stores them and returns, and `M.tick` -- once per widget
-- pass -- parses exactly one stored reply. The worst pass carries one parse however the link
-- behaves.
--
-- What does NOT move is the request that follows. The next command is known from the run's own
-- cursor for every phase but one -- only the function-id reply says which slots are worth reading
-- -- so the chain is continued from the ARRIVAL, in the same queue turn it was continued from
-- before. That keeps the wire timing the one this module was measured with against a board: the
-- request goes out on the queue's second turn of the same pass, and its answer is picked up by
-- the first turn of the next one. Moving the send to the parse instead would put every request on
-- the first turn, where the custom-telemetry drain runs between the send and the second turn --
-- and lib/crsf.lua buffers a frame only for a type its OWN instance has been asked for, while the
-- drain and the MSP transport load that file separately and hold an instance each.
--
-- The copy is not avoidable. tasks/msp/common.lua reassembles every reply into one table and
-- clears it when the next reply's first frame arrives; the queue hands that same table to
-- `processReply` and to its read cache. The MSP runtime's own periodic reads share that
-- transport, so between the pass a reply lands on and the pass that parses it the buffer can
-- already hold somebody else's answer. A copy is a fraction of a parse -- one element loop over a
-- reply of 1 to 43 bytes, 17 to 143 instructions against 42 to 933 -- which is what makes the
-- trade worth making.
-- ---------------------------------------------------------------------------

--- How many replies may wait for their parse at once, before the chain waits for the parse.
--
-- A pass parses one reply and gives the queue two turns, so a link that answered both of them
-- would store two replies for every one parsed and the backlog would grow for the whole run.
-- Past this depth the arrival does not ask for the next command; the parse does, which is one
-- reply in flight per parse and cannot grow. On a link that answers one request per pass -- which
-- is every real one, and the offline check in bin/accounting too -- the depth never reaches it.
local PENDING_CHAIN_LIMIT = 1

--- The bytes of a reply, kept away from the transport's own buffer. See above.
local function copyBuf(buf)
  if type(buf) ~= "table" then return buf end
  local out = {}
  for i = 1, #buf do out[i] = buf[i] end
  return out
end

--- How many stored replies are waiting for their parse.
local function pendingDepth(prime)
  return (prime.pendingTail or 0) - (prime.pendingHead or 1) + 1
end

--- Put a reply's bytes and the context its parse needs at the tail of the run's parse queue.
--
-- Head and tail are counters rather than a table length: a queue drained to empty on most passes
-- must not allocate a fresh table to say so.
local function stash(prime, record)
  local tail = prime.pendingTail + 1
  prime.pendingTail = tail
  prime.pending[tail] = record
end

-- Assigned below the senders: the two halves of a reply, one on arrival and one on the parse.
local arrived, chain

--- The reply handler every message this module sends carries: copy, store, ask for the next.
--
-- A fresh record is built for every reply rather than the template being stored again, so a
-- handler that fires twice -- a late answer to a retry, an answer off the wire beside one out of
-- the read cache -- stores two replies with two buffers instead of two references to one buffer
-- that both read whichever answer arrived last.
local function stashHandler(widget, drive, prime, template)
  return function(_, buf)
    if not stillCurrent(drive, prime) then return end
    local record = {
      kind = template.kind, command = template.command, api = template.api,
      fields = template.fields, slot = template.slot, buf = copyBuf(buf)
    }
    stash(prime, record)
    arrived(widget, drive, prime, record)
  end
end

--- The run is over: everything the nine reads can answer is in the cache.
--
-- The snapshot the delta is measured against is taken here only when no backup has been made yet:
-- once one exists, THAT is what the flight is compared with, and re-priming must not quietly move
-- the baseline.
local function finishValues(drive, prime)
  if type(drive.backup) ~= "table" then
    local copy = {}
    for id, value in pairs(drive.values) do copy[id] = value end
    drive.primedValues = copy
  end
  prime.phase = M.PHASE_DONE
  -- When, on the radio's own wall clock. The ground surface says "values read 14:31" because a
  -- pilot standing beside the machine wants to know whether that was this session or the last
  -- one, and a tick count cannot tell him.
  drive.readAt = drive.radio.clock and drive.radio.clock() or nil
  -- and the evidence that it happened at all, which the line above cannot carry on a radio whose
  -- clock answers nothing. See M.hasRead.
  drive.valuesRead = true
  -- Whatever the last attempt did, this one finished: nothing is left to say about it.
  drive.primeInterrupted = nil
  bump(drive)
  logPrime("prime done: %d value(s) cached, %d id(s) unanswered", prime.mapped or 0, prime.unmapped or 0)
end

local function sendValueRead(widget, drive, prime, queue)
  local command = Functions.VALUE_READS[prime.valueAt]
  if command == nil then
    -- Nothing left to ask for. The run only ends here when nothing is still waiting to be parsed;
    -- otherwise the last parse ends it, because the values it holds belong in the snapshot.
    if pendingDepth(prime) <= 0 then finishValues(drive, prime) end
    return true
  end

  local moduleName, fields = Functions.fieldsForCommand(command)
  local api = apiModule(moduleName)
  if api == nil or type(api.parse) ~= "function" or type(api.simulatorResponse) ~= "table" then
    -- A module the tree does not have, or one with nothing to answer under the simulator, is
    -- skipped rather than fatal: the ids behind it stay unknown and the screen shows them so.
    prime.unmapped = (prime.unmapped or 0) + ((fields and #fields) or 0)
    prime.valueAt = prime.valueAt + 1
    advanced(drive, prime)
    return sendValueRead(widget, drive, prime, queue)
  end

  queue:add({
    command = command,
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = stashHandler(widget, drive, prime,
      { kind = "values", command = command, api = api, fields = fields }),
    errorHandler = replyFailed(drive, prime, "values")
  })
  return true
end

local function sendValues(widget, drive, prime)
  local queue = queueOf()
  if queue == nil then
    prime.failedIn = "values"
    return fail(drive, prime, "no_link")
  end
  return sendValueRead(widget, drive, prime, queue)
end

-- Moving from one phase of a run to the next changes a word on one line and nothing else on the
-- surface, and that line is a reactive closure. No epoch, so no rebuild -- see `advanced` above.
local function startValues(widget, drive, prime)
  prime.phase = M.PHASE_VALUES
  prime.valueAt = 1
  prime.mapped = 0
  prime.unmapped = 0
  return sendValues(widget, drive, prime)
end

--- Whether this model's set is the one this build knows rather than the one the board carries.
local function standardMode(drive)
  local settings = drive.settings
  return type(settings) == "table" and settings.set_mode ~= Setup.SET_MODE_CUSTOM
end

--- What the finished comparison does to the drive. The set is NOT touched: in the standard layout
-- the set is a constant of this build and the board's table is evidence about the board, not about
-- the set. A comparison that could not be made at all -- no field on this receiver map reaches the
-- configured channels -- is recorded as its own verdict rather than as a difference.
local function applyComparison(drive, prime, result)
  if result == nil then
    drive.compare = { verdict = "unmapped", count = 0 }
    logPrime("standard set: neither channel has a field on this receiver map")
    return
  end
  drive.compare = result
  logPrime("standard set: board %s (%d of %d slot(s) differ, %d of them empty)",
    result.verdict, result.count, result.total, result.empty)
end

--- The slot table is in: enter the phase that turns it into a set or into a verdict.
--
-- Reached from two places, and the second one is the case an empty board found: when 167 says no
-- slot at all carries a function there is nothing to read with 156, and a run that only ever
-- entered this phase from the last slot record would sit in the slot phase for ever -- no request
-- out, no reply due, no error. A flight controller with nothing configured is exactly the board
-- this feature exists to offer a set to.
local function startDerive(drive, prime)
  prime.phase = M.PHASE_DERIVE
  if standardMode(drive) then
    -- The set is known; what the board's table is read for is the verdict on the board.
    -- The steps are part of what a slot has to hold, so they are part of what the board is
    -- compared against: a board set up under one step and a radio configured with another
    -- disagree, and the verdict has to say so rather than call the pair a match. Both go, since
    -- the head speed's slot is written from the second of them.
    prime.comparison = Functions.newComparison(prime.records, prime.map,
      drive.settings.bank_ch, drive.settings.value_ch,
      { step = drive.settings.step, step_headspeed = drive.settings.step_headspeed })
  else
    prime.derivation = M.newDerivation(prime.records, prime.map,
      drive.settings.bank_ch, drive.settings.value_ch)
  end
end

--- One slice of the work that turns the board's slot table into something, taken from the widget's
-- own pass rather than from a reply. In the custom layout that is the SET; in the standard layout
-- the set is already known and what is derived is the verdict on the board.
--
-- Answers true while the prime is in this phase, so the caller knows the pass has been spent.
local function stepDerivation(widget, drive)
  local prime = drive.prime
  if type(prime) ~= "table" or prime.phase ~= M.PHASE_DERIVE then return false end

  if prime.comparison ~= nil then
    local done, result = Functions.compareStep(prime.comparison, Functions.COMPARE_SLICE)
    if not done then return true end
    prime.comparison = nil
    applyComparison(drive, prime, result)
    startValues(widget, drive, prime)
    return true
  end

  if standardMode(drive) then
    -- The standard layout with no comparison to run: the receiver map did not answer, or neither
    -- configured channel has a field that could carry the set. Said as its own verdict.
    applyComparison(drive, prime, nil)
    startValues(widget, drive, prime)
    return true
  end

  if type(prime.derivation) ~= "table" then
    -- Nothing to work on: fall through to the values as if the table had yielded nothing.
    applySet(drive, prime, nil, prime.skipped)
    startValues(widget, drive, prime)
    return true
  end
  local done, derived, skipped = M.deriveStep(prime.derivation, DERIVE_SLICE)
  if not done then return true end
  prime.derivation = nil
  applySet(drive, prime, derived, skipped)
  startValues(widget, drive, prime)
  return true
end

local function sendSlot(widget, drive, prime)
  local queue = queueOf()
  if queue == nil then
    prime.failedIn = "slots"
    return fail(drive, prime, "no_link")
  end

  local slot = prime.slotList[prime.slotAt]
  if slot == nil then return true end

  local api = prime.rangeApi
  queue:add({
    command = CMD_ADJ_RANGE,
    -- The slot index is 0-based on the wire, and this payload does not make the message a write:
    -- it carries which slot to answer for, and the queue is told so rather than left to infer it.
    payload = { slot - 1 },
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = stashHandler(widget, drive, prime,
      { kind = "slot", command = CMD_ADJ_RANGE, api = api, slot = slot }),
    errorHandler = replyFailed(drive, prime, "slots")
  })
  return true
end

local function sendFunctionIds(widget, drive, prime)
  local queue = queueOf()
  if queue == nil then
    prime.failedIn = "functionIds"
    return fail(drive, prime, "no_link")
  end
  local api = apiModule("get_adjustment_function_ids")
  if api == nil then
    prime.failedIn = "functionIds"
    return fail(drive, prime, "no_api")
  end

  queue:add({
    command = CMD_ADJ_FUNCTION_IDS,
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = stashHandler(widget, drive, prime,
      { kind = "functionIds", command = CMD_ADJ_FUNCTION_IDS, api = api }),
    errorHandler = replyFailed(drive, prime, "functionIds")
  })
  return true
end

local function sendRxMap(widget, drive, prime)
  local queue = queueOf()
  if queue == nil then
    prime.failedIn = "rxmap"
    return fail(drive, prime, "no_link")
  end
  local api = apiModule("rx_map")
  if api == nil then
    prime.failedIn = "rxmap"
    return fail(drive, prime, "no_api")
  end

  queue:add({
    command = CMD_RX_MAP,
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = stashHandler(widget, drive, prime,
      { kind = "rxmap", command = CMD_RX_MAP, api = api }),
    errorHandler = replyFailed(drive, prime, "rxmap")
  })
  return true
end

--- Ask the board for whatever the run's cursor now points at.
--
-- Called on a reply's arrival, and by a parse that found the arrival had held the chain back. The
-- END of a phase is never asked for from here: the last record of the slot table still has to be
-- decoded before the derivation reads them all, and the last of the nine values still has to be
-- decoded before the snapshot is taken from them. Both of those belong to the parse.
chain = function(widget, drive, prime)
  prime.chainPaused = false
  local phase = prime.phase
  if phase == M.PHASE_FUNCTION_IDS then
    return sendFunctionIds(widget, drive, prime)
  end
  if phase == M.PHASE_SLOTS then
    if prime.slotList[prime.slotAt] == nil then return false end
    return sendSlot(widget, drive, prime)
  end
  if phase == M.PHASE_VALUES then
    if Functions.VALUE_READS[prime.valueAt] == nil then return false end
    return sendValues(widget, drive, prime)
  end
  return false
end

--- What a reply does the moment it arrives. Nothing here decodes anything.
--
-- The cursor moves and the next command goes out, which is the half that has to stay in the queue
-- turn the reply landed on; the function-id reply is the one exception, because what comes after
-- it is not known until it has been parsed.
arrived = function(widget, drive, prime, record)
  local kind = record.kind
  if kind == "rxmap" then
    prime.phase = M.PHASE_FUNCTION_IDS
  elseif kind == "slot" then
    prime.slotAt = prime.slotAt + 1
  elseif kind == "values" then
    prime.valueAt = prime.valueAt + 1
  end
  advanced(drive, prime)

  if kind == "functionIds" then return end
  if pendingDepth(prime) > PENDING_CHAIN_LIMIT then
    prime.chainPaused = true
    return
  end
  chain(widget, drive, prime)
end

-- ---------------------------------------------------------------------------
-- The parses. One of these runs per widget pass, and never two.
-- ---------------------------------------------------------------------------

local function parseRxMap(widget, drive, prime, record)
  -- A receiver that does not answer its map is not fatal: without it AUX1 is taken to be the
  -- sixth channel, which is where every documented setup puts it. Nothing waits for this: the
  -- map is not read until the whole slot table has been.
  prime.map = record.api.parse(record.buf)
  if prime.chainPaused then chain(widget, drive, prime) end
end

local function parseFunctionIds(widget, drive, prime, record)
  local parsed = record.api.parse(record.buf)
  local ids = type(parsed) == "table" and parsed.adjustment_function_ids or nil
  if type(ids) ~= "table" then
    prime.failedIn = "functionIds"
    fail(drive, prime, "no_function_ids")
    return
  end
  -- Only the slots that name a function are read in full. An empty slot has nothing in its
  -- record worth 14 bytes and a round trip, and on this transport that is the whole cost.
  prime.slotList = {}
  for slot = 1, SLOT_COUNT do
    if (tonumber(ids[slot]) or 0) ~= 0 then prime.slotList[#prime.slotList + 1] = slot end
  end
  prime.slotAt = 1
  prime.rangeApi = apiModule("get_adjustment_range")
  if prime.rangeApi == nil then
    prime.failedIn = "slots"
    fail(drive, prime, "no_api")
    return
  end
  -- The estimate the run started with was the whole table; now the length is known.
  prime.total = 2 + #prime.slotList + #Functions.VALUE_READS
  if #prime.slotList == 0 then
    -- Nothing to read: the board carries no adjustment at all. Straight to the phase that would
    -- otherwise have been entered by the last slot record.
    startDerive(drive, prime)
    return
  end
  prime.phase = M.PHASE_SLOTS
  -- This is the one reply whose arrival could not ask for the next command, so its parse does.
  chain(widget, drive, prime)
end

local function parseSlot(widget, drive, prime, record)
  local parsed = record.api.parse(record.buf)
  local decoded = type(parsed) == "table" and parsed.adjustment_range or nil
  if type(decoded) == "table" then prime.records[record.slot] = decoded end

  if prime.slotList[prime.slotAt] == nil and pendingDepth(prime) <= 0 then
    -- The board's table is in AND every record of it is decoded. Turning it into the set does not
    -- happen here: it is the most expensive single thing this module does and the pass that just
    -- parsed a reply cannot carry it. The prime enters a phase of its own and the next tick takes
    -- the first slice.
    startDerive(drive, prime)
  elseif prime.chainPaused then
    chain(widget, drive, prime)
  end
end

local function parseValues(widget, drive, prime, record)
  local parsed = record.api.parse(record.buf)
  if type(parsed) == "table" then
    local fields = record.fields
    -- The status reply counts the profiles the way the WIRE does, from 0. Everything else on this
    -- screen that shows one of those two numbers counts them the way the pilot's own menus do: the
    -- header reads the PID profile off the PID# telemetry sensor, the backup line records both
    -- 1-based, and the range this build declares for the two ids is 1 to 6 -- which is the
    -- firmware's own (fc/rc_adjustments.c, ADJ_ENTRY(RATE_PROFILE, 1, 6) and its PID sibling). Left
    -- as they arrive, the two rows read one less than the header above them and than the row a step
    -- would land on.
    --
    -- They are moved onto that count here, at the one place they enter the cache, and there is no
    -- second writer to keep in step with: the same firmware file leaves all four profile
    -- adjustments out of the report AdjF and AdjV carry (updateAdjustmentData), so the live
    -- surface's own adoption path can never put a raw one in beside them.
    --
    -- `prime.status` below keeps the reply exactly as it came. The undo reads the active index off
    -- it and MSP_COPY_PROFILE has to be told the wire's own number.
    local base = (record.command == CMD_STATUS) and 1 or 0
    for i = 1, #fields do
      local entry = fields[i]
      local value = tonumber(parsed[entry.field])
      if value == nil then
        prime.unmapped = (prime.unmapped or 0) + 1
      else
        drive.values[entry.id] = value + base
        prime.mapped = (prime.mapped or 0) + 1
      end
    end
    -- The status reply is the only one that says how many profiles this board has and which of
    -- them is live, and the undo needs both.
    if record.command == CMD_STATUS then prime.status = parsed end
  end

  if Functions.VALUE_READS[prime.valueAt] == nil and pendingDepth(prime) <= 0 then
    finishValues(drive, prime)
  elseif prime.chainPaused then
    chain(widget, drive, prime)
  end
end

--- Parse ONE stored reply, and no more, however many are waiting.
--
-- Answers true when the pass was spent here, so the caller stops at it.
local function takeReply(widget, drive)
  local prime = drive.prime
  if type(prime) ~= "table" then return false end
  local head = prime.pendingHead
  if head == nil or head > prime.pendingTail then return false end

  local record = prime.pending[head]
  prime.pending[head] = nil
  prime.pendingHead = head + 1
  -- Drained: the counters go back to where a fresh run starts them, so a long prime does not
  -- walk them upward for a whole session.
  if prime.pendingHead > prime.pendingTail then
    prime.pendingHead, prime.pendingTail = 1, 0
  end

  -- A run that was restarted, abandoned or failed since the reply landed keeps none of it. The
  -- pass still counts as spent: discarding a stored reply is what this pass did.
  if not stillCurrent(drive, prime) or type(record) ~= "table" then return true end

  local kind = record.kind
  if kind == "values" then
    parseValues(widget, drive, prime, record)
  elseif kind == "slot" then
    parseSlot(widget, drive, prime, record)
  elseif kind == "functionIds" then
    parseFunctionIds(widget, drive, prime, record)
  elseif kind == "rxmap" then
    parseRxMap(widget, drive, prime, record)
  end
  return true
end

--- A profile change has been answered by a read, and on the ground the undo is due with it.
--
-- The backup is scoped to a PROFILE: the board's adjustments only ever move the one that is active,
-- so the spare slot holds a copy of the profile that was being flown before the change and is not
-- an undo for the one the pilot is about to fly. One slot and one undo is the shape this feature
-- has, so the fresh copy REPLACES it -- the ground line then names the new source, and the previous
-- profile's undo is gone. That is the trade the single slot makes, and it is the one the pilot
-- chose.
--
-- A request and no more, exactly as the interlock's own edge raises it: whether anything goes out
-- is M.tick's decision, and every refusal the button has applies there unchanged. A RATE profile
-- change moves no PID profile and this cannot tell the two apart, so the request is raised for
-- both and the existence test sends nothing for the one that changed nothing.
--
-- Raised where the change is ANSWERED rather than where it is seen. The flag it follows stands
-- until a read can serve it, so a test on the flag alone would raise this again on every pass of
-- that wait.
local function profileChangeAnswered(drive)
  if drive.phase ~= DRIVE_PHASE_GROUND then return end
  if drive.autoBackupWanted == true then return end
  drive.autoBackupWanted = true
  logPrime("profile changed on the ground: a fresh undo is due")
end

--- Read the board: the receiver map, the slot table, and the nine value reads.
--
-- Refused while armed and without a link. The counters start at the whole table's length and are
-- corrected down once 167 has said how many slots actually carry a function.
function M.start(widget, drive)
  if type(widget) ~= "table" or type(drive) ~= "table" then return false, "no_drive" end
  if isArmed(widget) then return false, "armed" end
  if queueOf() == nil then return false, "no_link" end

  local prime = {
    phase = M.PHASE_RXMAP,
    done = 0,
    total = 2 + SLOT_COUNT + #Functions.VALUE_READS,
    records = {},
    skipped = {},
    slotList = {},
    slotAt = 1,
    valueAt = 1,
    mapped = 0,
    unmapped = 0,
    pending = {},
    pendingHead = 1,
    pendingTail = 0,
    chainPaused = false
  }
  drive.prime = prime
  -- The verdict on the board belongs to the table that produced it, and this run is about to read
  -- that table again. Leaving the old one up would show a board as matching while its own answer
  -- was still on the wire.
  drive.compare = nil
  -- The wait the pass gate counts belongs to the run that is starting.
  widget._primeSkips = nil
  -- A full run reads the nine value commands as well, so a profile change waiting for a re-read of
  -- its own is answered by this one and must not send it a second time afterwards.
  if drive.profileChanged == true then profileChangeAnswered(drive) end
  drive.profileChanged = nil
  drive.primeInterrupted = nil
  bump(drive)
  logPrime("prime started")
  return sendRxMap(widget, drive, prime)
end

--- Read the values again, without the slot table. What a restore puts back on the board is a set
-- of values, not a layout, so re-reading 42 slot records to learn them would be 42 round trips
-- spent on something that cannot have moved.
--
-- A FRESH run table, and not the previous one under a new phase. `stillCurrent` tells a reply which
-- run it belongs to by the IDENTITY of this table -- it is the only thing that can, since the
-- callbacks close over the run they were made for -- so a refresh that reused the table accepted a
-- late reply of the PREVIOUS run into the new one: the answer to a read the queue had given up on,
-- retried and delivered after the refresh had gone out, counted as one of the nine and written into
-- the cache as whatever the board held before. Of everything the fourth radio round turned up, that
-- is the one mechanism that would genuinely read as "he only ever reads PARTS of it".
--
-- What carries over is what the refresh does not read: the slot table and the derivation's own
-- leavings. Both describe a LAYOUT, and a layout does not move when a profile does.
--
-- THE STATUS REPLY IS NOT AMONG THEM, and the first cut of this had it there with the reasoning that
-- a profile change moves none of the three. That was wrong about exactly one field: the status reply
-- is where the ACTIVE PROFILE INDEX comes from, so it is the one thing a profile change does move,
-- and carrying it across the re-read that answers that change carried the answer to the question
-- being asked. Measured against a real board: with the PID# sensor momentarily not delivering, the
-- undo was copied from the profile the board had been on BEFORE the change. Dropped here, the reply
-- this run holds is either the one that answered the change or nothing at all -- and nothing is
-- refused by name. The profile COUNT, which no profile change moves, comes from their own status
-- task's copy on the session in that window (see M.profileCount).
function M.refreshValues(widget, drive)
  if type(widget) ~= "table" or type(drive) ~= "table" then return false, "no_drive" end
  if isArmed(widget) then return false, "armed" end
  local previous = drive.prime
  if type(previous) ~= "table" or type(previous.records) ~= "table" then
    return M.start(widget, drive)
  end
  if queueOf() == nil then return false, "no_link" end
  local prime = {
    phase = M.PHASE_IDLE,
    done = 0,
    total = #Functions.VALUE_READS,
    records = previous.records,
    skipped = previous.skipped,
    slotList = previous.slotList,
    slotAt = previous.slotAt,
    rangeApi = previous.rangeApi,
    map = previous.map,
    valueAt = 1,
    mapped = 0,
    unmapped = 0,
    pending = {},
    pendingHead = 1,
    pendingTail = 0,
    chainPaused = false
  }
  drive.prime = prime
  -- The wait this gate counts belongs to the run that is starting, not to the one before it.
  widget._primeSkips = nil
  return startValues(widget, drive, prime)
end

-- ---------------------------------------------------------------------------
-- The undo
-- ---------------------------------------------------------------------------

--- Which PID profile the board is flying, 0-based.
--
-- The telemetry sensor counts from 1, the way the pilot's own menus do; the status reply counts
-- from 0, the way the wire does. The sensor is preferred because it is live even when nothing has
-- been primed this session.
--
-- A SENSOR THE RADIO IS NOT DELIVERING ANSWERS 0, AND NEVER NIL. That is EdgeTX's getValue, and it
-- is the whole of a defect measured against a real board: one profile change on the ground produced
-- two copies, the second of them naming the profile the pilot had just left. Read as a number, 0 is
-- not nil, so the question went PAST the last good reading the drive kept and landed on the status
-- reply -- and a status reply is the one thing in this module that can be older than the profile
-- change itself. 0 is not a profile either way: the pilot's menus and the firmware's own adjustment
-- range for this parameter both start at 1. So it is treated as no answer, which is what sends the
-- question on to the reading the drive kept, which is the freshest thing there is after the sensor.
--
-- The status reply stays as the LAST resort, for a model whose telemetry list has no PID# at all.
-- What makes it safe is at the other end: a value refresh no longer carries the previous run's
-- status (see M.refreshValues), so the reply this reads is either the one that answered the change
-- or nothing -- and nothing is refused by name rather than guessed at.
function M.activeProfile0(drive)
  local sensor = tonumber(drive.radio.sensor("PID#"))
  if sensor == nil or sensor < 1 then sensor = tonumber(drive.profile) end
  if sensor ~= nil and sensor >= 1 then return math.floor(sensor) - 1 end
  local status = drive.prime and drive.prime.status or nil
  local index = status and tonumber(status.current_pid_profile_index) or nil
  if index ~= nil then return math.floor(index) end
  return nil
end

--- How many PID profiles this board has. Their status reply carries the number, and their own
-- status task keeps the last one on the session. The constant is what is left when neither spoke.
function M.profileCount(drive)
  local status = drive.prime and drive.prime.status or nil
  local count = status and tonumber(status.pid_profile_count) or nil
  if count == nil then
    local session = _G.rfsuite and _G.rfsuite.session or nil
    count = type(session) == "table" and tonumber(session.pid_profile_count) or nil
  end
  if count == nil or count < 1 then count = PROFILE_COUNT_FALLBACK end
  return math.floor(count)
end

--- What stands between this model and a usable undo, or nil when nothing does.
function M.transferRefusal(widget, drive)
  if isArmed(widget) then return "armed" end
  local backup = math.floor(tonumber(drive.settings.backup_profile) or 0)
  if backup <= 0 then return "unset" end
  if backup > M.profileCount(drive) then return "range" end
  local active0 = M.activeProfile0(drive)
  if active0 == nil then return "no_active" end
  -- Copying a profile onto itself is not a no-op on the board: it is a write and an eeprom
  -- commit, and it would leave the pilot believing an undo exists where none does.
  if (backup - 1) == active0 then return "same" end
  if queueOf() == nil then return "no_link" end
  return nil
end

local function copyProfile(widget, drive, destination0, source0, kind, onDone)
  local queue = queueOf()
  if queue == nil then return false, "no_link" end

  drive.transfer = { kind = kind, state = "busy" }
  bump(drive)

  local function finished(ok, reason)
    if type(drive.transfer) ~= "table" or drive.transfer.kind ~= kind then return end
    drive.transfer.state = ok and "ok" or "error"
    drive.transfer.reason = ok and nil or tostring(reason or "failed")
    bump(drive)
    if ok and type(onDone) == "function" then onDone() end
  end

  queue:add({
    command = CMD_COPY_PROFILE,
    payload = { PROFILE_TYPE_PID, destination0, source0 },
    isWrite = true,
    simulatorResponse = {},
    client = M.CLIENT,
    processReply = function()
      -- The armed check the outer message made is not the armed check this one needs. It was made
      -- before the copy went out; the reply comes back a round trip later, and a pilot who armed
      -- in between would have the commit added to a queue that tasks/msp/runtime.lua clears on
      -- every armed tick -- dropped without a word, leaving the transfer reading "busy" for ever
      -- and the copy sitting in the board's RAM believing it is an undo.
      if isArmed(widget) then return finished(false, "armed") end
      -- The copy lives in RAM until the board is told to commit it, and the board commits nothing
      -- on its own until the next disarm -- by which time the flight this undo exists for has
      -- been flown. So the write follows immediately, as their copy-profiles page does it.
      queue:add({
        command = CMD_EEPROM_WRITE,
        payload = {},
        isWrite = true,
        simulatorResponse = {},
        client = M.CLIENT,
        processReply = function() finished(true) end,
        errorHandler = function(_, reason) finished(false, reason) end
      })
    end,
    errorHandler = function(_, reason) finished(false, reason) end
  })
  return true
end

--- Copy the flying profile into the spare one, and remember what it held.
--
-- The board writes an in-flight change into its own storage half a second after disarm, so the
-- copy has to exist BEFORE the flight; afterwards there is nothing left to copy. The values are
-- snapshotted at the same moment and for the same reason: after that save nothing on the radio
-- could still say what the profile used to hold, and the delta is measured against this.
--- A refusal the pilot can read, rather than one that came back as a return value nobody looked
-- at. It goes on the drive where every other outcome of a transfer goes, so the ground screen's
-- backup line says what the last press did.
local function refuseTransfer(drive, kind, reason)
  drive.transfer = { kind = kind, state = "refused", reason = reason }
  bump(drive)
  return false, reason
end

function M.backup(widget, drive)
  local refusal = M.transferRefusal(widget, drive)
  if refusal ~= nil then return refuseTransfer(drive, "backup", refusal) end

  -- A backup taken before the board has been read copies the profile and snapshots NOTHING, and
  -- the delta after the flight is then measured against an empty table. That reads on screen as
  -- "nothing has changed" for a flight that changed everything -- a wrong answer where a missing
  -- one was wanted, and the worst of the three states this screen can be in. An undo is only an
  -- undo once there is something to compare the flight with.
  --
  -- The question is whether the board HAS BEEN READ and not what the last run did, which is the
  -- whole of M.hasRead: a read the pilot armed into abandoned the run and left the cache alone,
  -- and refusing the undo for the rest of that link is refusing it for the flights it exists for.
  if not M.hasRead(drive) then
    return refuseTransfer(drive, "backup", "unprimed")
  end

  -- A read that is still on the wire is half of one answer and half of another. The snapshot is
  -- taken here, in this pass, and a cache being refilled parameter by parameter would put the
  -- values of two different profiles into it -- so the copy waits for the run rather than racing
  -- it. The request that asked for it is a state and survives the wait.
  if M.isRunning(drive) then
    return refuseTransfer(drive, "backup", "reading")
  end

  local backup0 = math.floor(tonumber(drive.settings.backup_profile) or 0) - 1
  local active0 = M.activeProfile0(drive)
  local snapshot = {}
  for id, value in pairs(drive.values) do snapshot[id] = value end
  local at = drive.radio.now()

  logPrime("backup: pid profile %d -> %d", active0, backup0)
  return copyProfile(widget, drive, backup0, active0, "backup", function()
    -- The profile the copy was taken FROM is kept with it. The board's adjustments act on
    -- whichever profile is active, so this backup describes that one and no other: it is what the
    -- ground surface names under the button, and what the restore below refuses to cross.
    drive.backup = { profile = backup0 + 1, source = active0 + 1, at = at, values = snapshot,
      clock = drive.radio.clock and drive.radio.clock() or nil }
    -- A fresh undo ends the postflight read-out. It is one of the three enders the pilot named,
    -- and it is the one that matters: the list the delta was measured against has just been
    -- replaced, so what stood on that screen described a comparison that no longer exists.
    if type(drive.endPost) == "function" then drive:endPost("backup") end
    bump(drive)
  end)
end

--- Put the copy back over the flying profile, and read the values again.
--
-- The cached values describe what the board held a moment ago, which after a restore is exactly
-- what it no longer holds; leaving them would show a delta against a profile that has been undone.
function M.restore(widget, drive)
  local refusal = M.transferRefusal(widget, drive)
  if refusal ~= nil then return refuseTransfer(drive, "restore", refusal) end

  local backup0 = math.floor(tonumber(drive.settings.backup_profile) or 0) - 1
  local active0 = M.activeProfile0(drive)

  -- A backup is an undo for the profile it was taken from and for no other. Put back over a
  -- different one it would not undo anything: it would overwrite a profile the copy never
  -- described, with values the pilot never flew there. Refused by name rather than silently, so
  -- the screen can say which profile to switch back to.
  --
  -- With NO RECORD AT ALL the answer is that refusal and not permission, which is the half this
  -- test used to get wrong. The record lives in memory and the per-model store beside it keeps the
  -- slot number alone, so after a restart -- or after any session that did not make the copy
  -- itself -- the spare profile holds a copy of SOME profile and nothing on the radio knows which.
  -- Allowing the restore there allowed exactly the write this guard exists to prevent, in the one
  -- state where nothing could warn the pilot about it.
  local source = (type(drive.backup) == "table") and tonumber(drive.backup.source) or nil
  if source == nil then
    return refuseTransfer(drive, "restore", "unknown_profile")
  end
  if active0 == nil or (source - 1) ~= active0 then
    return refuseTransfer(drive, "restore", "other_profile")
  end

  logPrime("restore: pid profile %d -> %d", backup0, active0)
  return copyProfile(widget, drive, active0, backup0, "restore", function()
    M.refreshValues(widget, drive)
  end)
end

-- ---------------------------------------------------------------------------
-- The delta
-- ---------------------------------------------------------------------------

--- Every parameter whose cached value has moved away from the snapshot, largest change first.
--
-- Cached against BOTH of the drive's counters, the way the setup check is cached against the
-- clock: the list is built into the tree rather than read by a closure, so it is wanted once per
-- rebuild and a rebuild happens exactly when the layout epoch moves. The report counter is in the
-- key as well because it is the one that moves when the board answers -- a last step reported just
-- after the disarm moves the values without moving the layout epoch, and a list cached against
-- that epoch alone would show the flight one step short.
--
-- Answers nil when there is no snapshot to measure against, which is a different thing from an
-- empty list and is said differently on screen. A second return value names the reason where there
-- is one to name: today the reference belonging to another profile, which is a refusal to compare
-- rather than an absence of anything to compare.
function M.delta(drive)
  if type(drive) ~= "table" then return nil end
  local backup = (type(drive.backup) == "table") and drive.backup or nil
  local reference = (backup ~= nil and backup.values) or drive.primedValues
  -- An EMPTY reference is no reference. A snapshot taken before anything had been read off the
  -- board is a table with nothing in it, and measuring against it yields an empty list -- which
  -- the screen reads as "nothing has changed", a wrong answer where a missing one was wanted.
  if type(reference) ~= "table" or next(reference) == nil then return nil end

  -- And a reference taken from ANOTHER PROFILE is not a reference either. This is the test the
  -- restore above has had all along and this comparison did not: the board's adjustments only ever
  -- moved the profile that was active, so a backup of profile 1 held against the values of profile
  -- 2 reports the difference between two profiles as though the flight had made it. The pilot's
  -- fourth radio round photographed exactly that -- twelve rows of "changed" after a flight that
  -- moved one of them, the rest of the list being what the two profiles disagree about.
  --
  -- Only a BACKUP can be from elsewhere. `primedValues` is this session's own read of whichever
  -- profile is active, and finishValues takes it again on every read while no backup stands.
  if backup ~= nil then
    local source = tonumber(backup.source)
    local active0 = M.activeProfile0(drive)
    if source ~= nil and active0 ~= nil and (source - 1) ~= active0 then
      return nil, "other_profile"
    end
  end

  if drive._deltaEpoch == drive.valueEpoch and drive._deltaReport == drive.reportEpoch
    and drive._deltaList ~= nil then return drive._deltaList end

  local list = {}
  for id, value in pairs(drive.values) do
    local was = reference[id]
    if was ~= nil and was ~= value then
      list[#list + 1] = {
        id = id,
        name = Functions.nameOf(id),
        old = was,
        new = value,
        size = math.abs(value - was)
      }
    end
  end
  -- Largest change first, and the id decides a tie: a list whose order depended on how the value
  -- table happened to be walked would reshuffle itself under the pilot between two rebuilds.
  table.sort(list, function(a, b)
    if a.size ~= b.size then return a.size > b.size end
    return a.id < b.id
  end)

  drive._deltaEpoch = drive.valueEpoch
  drive._deltaReport = drive.reportEpoch
  drive._deltaList = list
  return list
end

-- ---------------------------------------------------------------------------
-- The widget's side
-- ---------------------------------------------------------------------------

-- What the previous pass may have cost before this one refuses to parse anything.
--
-- The pilot's widget_5.log ends mid-prime -- record 3 of the automatic run right after connect --
-- on the ORDINARY dashboard with the interlock open and a heavy theme, on passes his own trace
-- reports at 84 to 93 per cent of the instruction budget. So keeping the prime from REBUILDING the
-- surface is not enough on a radio like that: the parse itself, priced at up to 933 instructions
-- for a value reply and 151 for a slot record, plus the firmware's sweep of whatever tree is
-- standing, lands on passes that are already close to the limit at start-up.
--
-- A pass killed by that limit is invisible to every sink in the tree -- the sweep runs outside the
-- pcall the entry point wraps refresh in -- so the only witness is a log that stops.
local PARSE_USAGE_LIMIT = 70

-- and how long the gate may hold a run up before it takes a slice anyway.
--
-- Stated rather than left open, because a widget that sits above the limit for ever would leave a
-- prime waiting for ever, and "Priming 3/44" on the screen with nothing moving is a worse answer
-- than one slow slice. At the widget's 50 ms cadence this is five seconds.
local PARSE_SKIP_LIMIT = 100

--- Whether this pass has room for the one piece of optional work the ground half does.
--
-- Two things are asked, and the first is an INVARIANT restated rather than a new rule: the
-- dispatcher in widgets/dashboard/runtime.lua serves a pending job and returns before it reaches
-- the background half at all, so a job pass cannot get here today. It is checked anyway, because
-- what it protects is a build sharing a call with a parse, and that is worth more than the two
-- table reads it costs.
--
-- The second is what the last pass actually cost. Answers false to skip.
--
-- The skips are counted as a TOTAL for the run being held up and not as a streak, and that is the
-- difference between an escape that fires and one that cannot. A streak was reset by every cheap
-- pass, so a widget alternating between an expensive pass and a cheap one -- which is the ordinary
-- shape of a dashboard that rebuilds something on one pass in two -- skipped every other pass for
-- as long as the run lasted and never came within reach of the limit. With no run in progress there
-- is nothing being held up, so the streak reading is kept for that case: it is what lets the
-- automatic run start at all on a widget that never comes below the limit.
function M.passHasRoom(widget, drive)
  if widget._job ~= nil then return false end

  local last = tonumber(widget._usageLast)
  if last == nil or last <= PARSE_USAGE_LIMIT then
    if drive == nil or not M.isRunning(drive) then widget._primeSkips = nil end
    return true
  end

  local skips = (widget._primeSkips or 0) + 1
  if skips >= PARSE_SKIP_LIMIT then
    widget._primeSkips = nil
    logPrime("prime: %d busy pass(es) waited out, taking a slice anyway at %d%%", skips, last)
    return true
  end
  widget._primeSkips = skips
  return false
end

--- One pass of the ground half.
--
-- Costs two table reads while armed or disconnected, which is what it does for the whole of a
-- flight. The automatic run fires once per connect, and only after the link has stood for long
-- enough that the connect chain is no longer competing for the same queue.
function M.tick(widget, drive)
  if type(widget) ~= "table" or type(drive) ~= "table" then return end
  if type(widget.state) ~= "table" then return end

  if isArmed(widget) then
    if M.isRunning(drive) then abandon(drive, drive.prime, "armed") end
    drive._primeLinkSince = nil
    return
  end

  if widget.state.fblConnected ~= true then
    drive._primeLinkSince = nil
    drive._primeAutoDone = false
    -- The retry budget is per link session, like the latch above it: a new board is a new answer
    -- to the question of whether it can be read at all.
    drive._primeFails = nil
    return
  end

  -- Neither the parse below nor the derivation slice after it may go on a pass that is already
  -- expensive. See M.passHasRoom: the pilot's widget_5.log stops mid-prime on an ordinary
  -- dashboard with a heavy theme, on passes his own trace puts at 84 to 93 per cent.
  --
  -- Everything ABOVE this line stays unconditional. The armed check, the abandon and the link
  -- check are what keep MSP away from a helicopter in the air, and they are three table reads.
  if not M.passHasRoom(widget, drive) then return end

  -- One stored reply, parsed here rather than where it arrived, and never more than one however
  -- many the link delivered into the same pass. This is the bound the whole section above exists
  -- for; the derivation slice below is the same rule for the one piece of work no reply drives.
  if takeReply(widget, drive) then return end

  -- The derivation is the one part of a prime that no reply drives, so it is stepped here. It
  -- comes before the auto-start gates below, which return as soon as a run has been started.
  if stepDerivation(widget, drive) then return end

  -- The connect chain owns the queue until it says otherwise. `tasksDone` is the widget's own
  -- reading of that (widgets/dashboard/runtime.lua, updateConnectionState): the onconnect runner
  -- is idle and the MSP progress is complete. Only the AUTOMATIC run is held here -- a pilot who
  -- asks for a prime from the ground screen still gets one straight away.
  if widget.state.tasksDone == false then
    drive._primeLinkSince = nil
    return
  end

  -- A profile change invalidated everything scoped to it, and the board is the only thing that
  -- can say what the new profile holds. On the GROUND that is the nine value reads again and
  -- nothing else: the slot table describes a LAYOUT, and a layout does not move when a profile
  -- does, so re-reading forty records would be forty round trips spent on something that cannot
  -- have changed. In the air this is never reached -- the armed gate at the top of this function
  -- returns first -- and the values simply stay unknown until the board reports each one on
  -- AdjV, which is the honest answer while nothing may be asked.
  --
  -- The flag is left standing while a run is on the wire: that run was started under the old
  -- profile and the next idle pass sends the reads again. It is left standing just as much when
  -- there is no finished run to refresh -- a read that was abandoned, one that failed, or none at
  -- all -- and that is a defect this round measured rather than reasoned about. It used to be
  -- cleared here whatever the phase was, so a profile change that arrived while a read was being
  -- abandoned was consumed by the one pass that could do nothing with it, and the new profile's
  -- values stayed unknown for the rest of the link. What answers it in that state is the automatic
  -- run the block below offers again, and M.start drops the flag itself because it reads the nine
  -- value commands too.
  if drive.profileChanged == true and not M.isRunning(drive) then
    if type(drive.prime) == "table" and drive.prime.phase == M.PHASE_DONE then
      drive.profileChanged = nil
      profileChangeAnswered(drive)
      logPrime("profile changed: the nine value reads are sent again")
      M.refreshValues(widget, drive)
      return
    end
  end

  -- The session was closed on the ground and has been opened again, so the board is read once more
  -- before anything else: the pilot's ruling is that closing the feature on the ground starts
  -- everything fresh, and the drive has already dropped the cache, the undo and the comparison
  -- (inflight/drive.lua, Drive:endSession).
  --
  -- Only the nine VALUE commands. The slot table describes a layout, a switch cannot move one, and
  -- re-reading forty records would be forty round trips on the one queue the connect chain shares
  -- for an answer that cannot have changed -- the same reasoning the re-read after a profile change
  -- and the re-read after a restore already run on. M.refreshValues falls back to a whole run by
  -- itself where no slot table has been read yet, so there is no second branch to keep in step.
  --
  -- Held until the surface is back ON THE GROUND: while the feature is closed this half sends
  -- nothing, which is the whole promise of the interlock. The flag is a STATE and is spent only by a
  -- read that actually went out, so a pass that could not serve it leaves it standing.
  if drive.readAgain == true and drive.phase == DRIVE_PHASE_GROUND and not M.isRunning(drive) then
    if M.refreshValues(widget, drive) then
      drive.readAgain = nil
      logPrime("the session was opened again: the value reads are sent")
      return
    end
  end

  -- The undo, made without being asked for.
  --
  -- The pilot's ruling after the third radio round: the interlock is the one entry, so turning it
  -- on before a flight is the moment the backup should exist -- not a button he has to remember
  -- on the flight line. The drive raises the request on the interlock's rising edge and knows
  -- nothing else; this is where the link, the arm state and the prime are known, and every
  -- refusal the button has applies here unchanged and lands on the same line of the screen.
  --
  -- Once per session and per ACTIVE PID profile, and the existing backup is what says so: it
  -- records the profile it was taken from, so a second interlock cycle on the same profile finds
  -- one already made and sends nothing, while a profile change makes the next cycle take a fresh
  -- one. No counter of its own, and nothing to reset.
  --
  -- THE REQUEST IS A STATE AND NOT A SIGNAL, and that distinction is a defect this round
  -- measured rather than reasoned about. The first cut cleared the flag on the line above the
  -- test below it, so an interlock thrown while the values were not yet read consumed the
  -- request and made no undo at all -- silently, for the rest of that interlock cycle. It is a
  -- pilot-plausible sequence and it was measured: a momentary arming on the bench cleared the
  -- MSP queue, the value re-read came back `abandoned`, and the interlock forty seconds later
  -- produced nothing. So the flag stands until a backup is actually asked for, or until there is
  -- one for this profile already, or until the phase leaves the ground -- which is where the
  -- drive clears it, on every transition that is not into `ground`.
  if drive.autoBackupWanted == true then
    -- The EVIDENCE of a read, and a run still on the wire waited out: both are M.backup's own
    -- conditions, restated here so that a pass which cannot serve the request leaves it standing
    -- instead of spending it.
    if M.hasRead(drive) and not M.isRunning(drive) then
      local active0 = M.activeProfile0(drive)
      local have = type(drive.backup) == "table" and tonumber(drive.backup.source) or nil
      if active0 ~= nil and have ~= nil and (have - 1) == active0 then
        -- There is one already, and it describes the profile being flown. Nothing to ask for,
        -- and nothing to keep asking about.
        drive.autoBackupWanted = false
      else
        drive.autoBackupWanted = false
        logPrime("automatic backup on the interlock")
        M.backup(widget, drive)
        return
      end
    end
  end

  -- A run that did not finish must not latch the automatic one off for the rest of the link.
  --
  -- `_primeAutoDone` is the once-per-connect latch, and until this round the only thing that reset
  -- it was the link going down. So an arming DURING a read left the phase idle with the latch
  -- still set, and nothing sent another read or another backup for the whole session: the pilot's
  -- own card log has two interlock cycles after such an abandon with no prime and no undo in
  -- either of them, and dashes where the profile-scoped values had stood.
  --
  -- An abandon is retried without a limit and a failure a bounded number of times; see
  -- AUTO_RETRY_LIMIT. Both go through the settle below rather than starting here, so a read is
  -- never sent on the pass the pilot disarmed on.
  if drive._primeAutoDone == true and not M.isRunning(drive) then
    local phase = (type(drive.prime) == "table") and drive.prime.phase or nil
    if phase == M.PHASE_IDLE and drive.primeInterrupted == true then
      drive._primeAutoDone = false
    elseif phase == M.PHASE_ERROR and (drive._primeFails or 0) <= AUTO_RETRY_LIMIT then
      drive._primeAutoDone = false
    end
  end

  local now = drive.radio.now()
  if drive._primeLinkSince == nil then drive._primeLinkSince = now end
  if drive._primeAutoDone == true then return end
  if (now - drive._primeLinkSince) < AUTO_DELAY_TICKS then return end
  if M.isRunning(drive) then return end

  drive._primeAutoDone = true
  M.start(widget, drive)
end

return M
