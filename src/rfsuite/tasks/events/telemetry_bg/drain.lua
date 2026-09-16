-- The custom-telemetry drain: pop the flight controller's custom telemetry frames off the
-- CRSF link, decode the sensors they carry, and publish them as radio sensors.
--
-- A module of its own rather than part of tasks.lua beside it, because the work has more than
-- one possible host. Nothing here reads a clock: the caller passes the time in, since it needs
-- it for its own bookkeeping anyway and two readings of getTime() in one pass would be two
-- different answers for one moment.

local M = {}

local RFSensors = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local telemetryFrameId = 0
local telemetryFrameSkip = 0
local telemetryFrameCount = 0

-- A published sensor stays valid on the radio for TELEMETRY_SENSOR_TIMEOUT_START, so an
-- unchanged value does not have to be re-sent every frame. It matters because every
-- setTelemetryValue() call marks the model dirty, which moves the model file's write
-- deadline forward rather than the write itself: publishing every sensor of every frame
-- starves the flush for as long as telemetry flows, and a setting the pilot changes in
-- that window is not persisted. Publish on change, and refresh an unchanged sensor well
-- inside its timeout. Same contract as publishTelemetryValue() in smart.lua.
local FORCE_REFRESH_INTERVAL = 2.0

local lastPublishedValue = {}
local lastPublishedAt = {}

-- The decoder's own two counters, and they need a publisher of their own rather than the one
-- above. `publishSensorValue` throttles by CHANGE, and the frame count changes in every single
-- frame by construction -- so through that publisher it would go out at the full frame rate and
-- defeat the throttle exactly as it did before this fix. Measured rather than reasoned: over
-- 20 s at 8 frames/s the change-based publisher writes *Cnt 160 times, this one writes it 10.
--
-- So these two are RATE limited instead. The cost is that the reading can be up to
-- FORCE_REFRESH_INTERVAL stale, which is the right trade for a decoder diagnostic.
local lastCounterAt = 0

local function publishCounters(count, skip, now)
    if (now - lastCounterAt) < FORCE_REFRESH_INTERVAL then return end
    lastCounterAt = now
    setTelemetryValue(0xEE01, 0, 0, count, 0, 0, "*Cnt")
    setTelemetryValue(0xEE02, 0, 0, skip, 0, 0, "*Skp")
end

local function publishSensorValue(sid, value, sensor, now)
    local stale = (now - (lastPublishedAt[sid] or 0)) >= FORCE_REFRESH_INTERVAL
    if lastPublishedValue[sid] == value and not stale then return end
    setTelemetryValue(sid, 0, 0, value, sensor.unit or 0, sensor.prec or 0, sensor.name or "")
    lastPublishedValue[sid] = value
    lastPublishedAt[sid] = now
end

local function decU8(data, pos)
    return data[pos], pos+1
end

local function decU16(data, pos)
    return bit32.lshift(data[pos],8) + data[pos+1], pos+2
end

local CrsfManager = nil

-- Per-pass bounds for the custom-telemetry drain. Popping a frame is a handful of C calls;
-- DECODING one is a Lua walk over every sensor it carries -- the expensive term. So the
-- drain looks at up to POP_CAP frames per wakeup to keep the queue from backing up, but
-- fully decodes only the newest DECODE_CAP of them: telemetry is values, not commands, and
-- the next frame carries the current state, so under a backlog the oldest frames are the
-- right ones to skip. Both are provisional counts, to be calibrated by offline instruction
-- accounting.
local POP_CAP = 15
local DECODE_CAP = 4

-- The cheap half: pop one frame and keep the frame counters honest. The id bookkeeping runs
-- for EVERY popped frame, decoded or not -- `*Skp` means "the link skipped", and a decode
-- the drain chose to skip must never read as a link problem.
local function popAndAccount()
    local CRSF_FRAME_CUSTOM_TELEM = 0x88
    if not CrsfManager then
      CrsfManager = loadModule("lib/crsf.lua")
    end
    if not CrsfManager then return nil end

    local data = CrsfManager.popFrame(CRSF_FRAME_CUSTOM_TELEM)
    if not data then return nil end

    local fid, ptr
    ptr = 3
    fid, ptr = decU8(data, ptr)
    local delta = bit32.band(fid - telemetryFrameId, 0xFF)
    if delta > 1 then
        telemetryFrameSkip = telemetryFrameSkip + 1
    end
    telemetryFrameId = fid
    telemetryFrameCount = telemetryFrameCount + 1
    return data
end

-- The expensive half: the byte walk through the per-sensor decoders. The frame id at byte 3
-- was consumed by popAndAccount, so the walk starts at byte 4.
local function decodeFrame(data, now)
    local sid, val
    local ptr = 4
    while ptr < #data do
        sid,ptr = decU16(data, ptr)
        local sensor = RFSensors[sid]
        if sensor and type(sensor.dec) == "function" then
            val,ptr = sensor.dec(data, ptr)
            if val then
                publishSensorValue(sid, val, sensor, now)
            end
        else
            break
        end
    end
end

-- Which of EdgeTX's sixteen shared-memory slots carries the drain's liveness. The slots are a
-- static array outside every Lua state, so they are the one channel a widget and a permanent
-- script have between them; the last one is taken because the low ids are the ones a pilot's
-- own script reaches for first.
M.SHM_LIVENESS_ID = 16

-- And which one carries the DASHBOARD WIDGET's heartbeat, for whoever is watching from outside
-- that Lua state. Allocated here rather than where it is used, because the sixteen slots are a
-- radio-wide resource and a map kept in two files is a collision waiting to happen. Counting
-- down from the top for the same reason the one above does: a pilot's own script reaches for the
-- low ids first.
--
-- The slot carries `pass * 256 + usage`: the widget's pass counter in the high bits and the
-- percentage of the instruction budget its previous pass cost in the low eight. Eight bits is
-- exactly what the firmware can report -- luaGetUsage stores it in a uint8_t -- so nothing is
-- lost by packing, and one integer means one write per pass instead of two.
M.SHM_WIDGET_PASS_ID = 15
M.SHM_WIDGET_PASS_SHIFT = 256

-- How long a counter that has stopped moving still counts as alive. It has to cover the gap
-- between two turns of whatever is bumping it, and it is also how long a host keeps skipping
-- its own drain after the other side has gone away -- so it is short: a tool session pauses
-- the radio's permanent scripts for its whole length, and one stale window is the whole cost
-- of noticing that.
M.REMOTE_STALE_SECONDS = 1.0

-- The counter wraps well inside the firmware's signed int, and it never lands on zero: a slot
-- that was never written reads zero, and a writer that produced one would be indistinguishable
-- from that.
local LIVENESS_WRAP = 0x40000000

local liveness = 0
local remoteValue = nil
local remoteMovedAt = nil

--- Say that this Lua state is TAKING FRAMES OFF THE WIRE, for whoever is watching the slot.
--
-- A moving counter rather than a flag, because nothing ever clears the slots -- not a model
-- change, not the interpreter being torn down. A flag left set by a state that has since
-- disappeared would silence every other decoder on the radio for good.
--
-- The counter says that frames are being consumed here, and deliberately not that this host is
-- alive. The two come apart whenever something else in the SAME Lua state pops the wire first:
-- permanent scripts have no script manager of their own, so the firmware gives all of them one
-- shared telemetry queue, and the first one whose drain empties it leaves the rest with nothing.
-- A host that published on being called would then keep every other decoder on the radio stood
-- down while decoding nothing itself. Published on frames taken, that failure closes itself: the
-- counter stops within one stale window and whoever was standing aside resumes.
function M.publishLiveness()
    if type(setShmVar) ~= "function" then return end
    liveness = liveness + 1
    if liveness >= LIVENESS_WRAP then liveness = 1 end
    setShmVar(M.SHM_LIVENESS_ID, liveness)
end

--- Is another Lua state draining right now?
--
-- The reader is deliberately without memory of anything but the last value it saw: it has to
-- work out for itself whether the counter MOVES, because the value alone says nothing. Only a
-- host that has seen it move, recently, may leave the drain to somebody else.
function M.remoteAlive(now)
    if type(getShmVar) ~= "function" then return false end
    local value = getShmVar(M.SHM_LIVENESS_ID)
    if type(value) ~= "number" then return false end

    if remoteValue == nil then
        -- The first read records and never counts. The slot outlives the state that wrote it,
        -- so what is in it at the first read may be a leftover from a previous session.
        remoteValue = value
        return false
    end
    if value ~= remoteValue then
        remoteValue = value
        remoteMovedAt = now
    end
    return remoteMovedAt ~= nil and (now - remoteMovedAt) < M.REMOTE_STALE_SECONDS
end

--- One drain pass: pop what is waiting, decode it, publish what changed.
--
-- Returns how many frames the pass took off the wire. A caller that publishes liveness needs
-- that number rather than the fact that it was called: a host can be running perfectly and
-- receiving nothing, and the two have to be told apart by whoever is deciding whether to leave
-- the drain to it.
--
-- `decodeAll` lifts DECODE_CAP. It is for a host whose long call is yielded rather than killed
-- -- the radio's script state, where a permanent script runs -- and there dropping the older
-- frames of a backlog buys nothing. A call billed against a hard per-call ceiling keeps the cap.
function M.wakeup(now, decodeAll)
    if not RFSensors then
        RFSensors = loadModule("lib/rf2tlm_sensors.lua")
        if not RFSensors then return 0 end
    end

    -- Pop up to POP_CAP, keep the newest DECODE_CAP in arrival order, decode only those --
    -- on a same-sensor conflict the newest value lands last. POP_CAP bounds the pass whether
    -- or not the decode is capped, so one call stays finite however far behind the queue is.
    local kept = {}
    local popped = 0
    while popped < POP_CAP do
        local data = popAndAccount()
        if not data then break end
        popped = popped + 1
        kept[#kept + 1] = data
        if not decodeAll and #kept > DECODE_CAP then
            table.remove(kept, 1)
        end
    end

    if popped == 0 then return 0 end

    for i = 1, #kept do
        decodeFrame(kept[i], now)
    end
    -- Published unconditionally, and that is deliberate: the sibling project creates the
    -- same two sensors and treats a missing `*Cnt` as "the pilot deleted the telemetry
    -- sensors", so a radio carrying both suites needs them to keep meaning what they mean.
    -- A pilot who does not want the two rows can delete them on the telemetry page; outside
    -- a discovery window nothing here creates them again. Once per wakeup: the publisher
    -- rate-limits itself, and per-frame publication was redundancy, not information.
    publishCounters(telemetryFrameCount, telemetryFrameSkip, now)
    return popped
end

-- What a lost link invalidates, and nothing else. The liveness state above is deliberately not
-- cleared: it is what another Lua state is doing, and that state does not restart because this
-- one lost its flight controller.
function M.reset()
    telemetryFrameId = 0
    telemetryFrameSkip = 0
    telemetryFrameCount = 0
    lastPublishedValue = {}
    lastPublishedAt = {}
    lastCounterAt = 0
end

return M
