-- MSP_ACC_CALIBRATION acknowledges the start. The firmware saves the result itself;
-- only a subsequent CALIBRATING -> clear transition confirms completion.
local M = {}

local CLIENT = "accelerometer-calibration"
local CALIBRATING = 1 << 12
local ACC_CALIBRATION = 1 << 23
local TIMEOUT_TICKS = 1500
local REQUEST_TICKS = 500
local POLL_TICKS = 25
local POLL_TIMEOUT_SECONDS = 0.5

function M.start(queue, statusApi, session, getSession, done, phaseChanged)
  local run = { pending = false, phase = "check", seenActive = false }
  local deadline = getTime() + REQUEST_TICKS
  local nextPoll = 0

  local function connected()
    return getSession() == session and session.isConnected == true
  end

  local function finish(result)
    if run.finished then return end
    run.finished = true
    -- Retire this run before clear() invokes any of its error handlers.
    queue:clear(CLIENT)
    done(result, run.phase)
  end

  local function valid()
    if run.finished then return false end
    if not connected() then finish("disconnected"); return false end
    if getTime() >= deadline then
      if run.phase == "check" then finish("check_failed")
      elseif run.phase == "start" then finish("start_failed")
      else finish(run.seenActive and "timeout_active" or "timeout_unseen") end
      return false
    end
    return true
  end

  function run.cancel()
    run.finished = true
    queue:clear(CLIENT)
  end

  local function setPhase(phase)
    run.phase = phase
    if phaseChanged then phaseChanged() end
  end

  local function calibrate()
    deadline = getTime() + REQUEST_TICKS
    setPhase("start")
    run.pending = true
    queue:add({
      command = 205, -- MSP_ACC_CALIBRATION
      payload = {},
      isWrite = true,
      client = CLIENT,
      maxRetries = 0, -- a lost ACK must not restart the averaging
      simulatorResponse = {},
      processReply = function()
        if not valid() then return end
        run.pending = false
        -- Preflight and queueing must not consume the observation window.
        deadline = getTime() + TIMEOUT_TICKS
        setPhase("poll")
        nextPoll = 0
      end,
      errorHandler = function(_, reason)
        if valid() then finish(reason == "cleared" and "interrupted" or "start_failed") end
      end
    })
  end

  function run.wakeup()
    if not valid() or run.pending or getTime() < nextPoll then return end
    run.pending = true
    local checking = run.phase == "check"
    local settled = false
    local function nextSample()
      run.pending = false
      nextPoll = getTime() + POLL_TICKS
    end
    -- The simulator's own STATUS reply, with the two fields this page reads made explicit:
    -- byte 17 is arming_disable_flags_count and has to reach 24 for bit 23 to exist at all,
    -- and bytes 18..21 are arming_disable_flags, little-endian. Byte 19 therefore carries
    -- bits 8..15, so 16 is bit 12 of the word: CALIBRATING, the flag a run waits to see set
    -- and then cleared.
    local sim = {}
    for i, value in ipairs(statusApi.simulatorResponse) do sim[i] = value end
    sim[17] = 27
    sim[18], sim[19], sim[20], sim[21] = 0, 0, 0, 0
    if not checking and not run.seenActive then sim[19] = 16 end
    queue:add({
      command = statusApi.command,
      client = CLIENT,
      maxRetries = 0,
      timeout = not checking and POLL_TIMEOUT_SECONDS or nil,
      simulatorResponse = sim,
      processReply = function(_, buf)
        if settled or not valid() then return end
        settled = true
        nextSample()
        -- STATUS's parser defaults missing bytes to zero. That cannot prove a flag
        -- cleared. This firmware format has no extra flight-mode flag bytes.
        if type(buf) ~= "table" or #buf < 21 then return end
        for i = 1, 21 do
          local value = buf[i]
          if type(value) ~= "number" or value < 0 or value > 255 or value % 1 > 0 then
            return
          end
        end
        -- Byte 16 is extra_flight_mode_flags_count and byte 17 arming_disable_flags_count. A
        -- reply announcing extra flight-mode flag bytes is a layout this parser does not
        -- follow, and one announcing fewer than 24 arming flags does not carry bit 23, so
        -- neither can answer the question this page is asking.
        if buf[16] ~= 0 or buf[17] < 24 then return end
        local status = statusApi.parse(buf)
        if not status then return end
        if (status.flight_mode_flags & 1) ~= 0 then finish("armed"); return end
        if (status.sensor_status & 1) == 0 then finish("no_acc"); return end
        local active = (status.arming_disable_flags & CALIBRATING) ~= 0
        if checking then
          if active then finish("busy"); return end
          calibrate()
        elseif active then
          run.seenActive = true
        elseif run.seenActive and (status.arming_disable_flags & ACC_CALIBRATION) == 0 then
          finish("complete")
        end
      end,
      errorHandler = function(_, reason)
        if settled or not valid() then return end
        settled = true
        if reason == "cleared" then finish("interrupted"); return end
        -- A single missed sample (including the firmware's EEPROM pause) says
        -- nothing about completion. Keep observing until the phase deadline.
        nextSample()
      end
    })
  end

  return run
end

return M
