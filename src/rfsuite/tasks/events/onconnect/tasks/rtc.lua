-- OnConnect task: RTC der Flight Controller mit Senderzeit synchronisieren
local M = {}

local done = false
local requestSent = false
local RtcApi = nil
local Log = nil
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

function M.wakeup(args)
  if Log == nil then
    Log = loadModule("lib/log.lua") or false
  end

  if done then return end

  if requestSent then return end
  requestSent = true

  -- RTC API laden
  if not RtcApi then
    RtcApi = loadModule("tasks/msp/api/rtc.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadModule("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not RtcApi or type(RtcApi.buildWritePayload) ~= "function" then 
    done = true
    return 
  end

  local mspState = type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    done = true
    return
  end

  -- Helper: convert calendar date to Unix timestamp (seconds since 1970-01-01 UTC).
  -- Used as fallback when getRtcTime() is not available.
  local function dateToUnix(year, month, day, hour, min, sec)
    local dpm = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    local days = 0
    for y = 1970, year - 1 do
      if (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0) then
        days = days + 366
      else
        days = days + 365
      end
    end
    local isLeap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
    for m = 1, month - 1 do
      days = days + dpm[m]
      if m == 2 and isLeap then days = days + 1 end
    end
    days = days + day - 1
    return days * 86400 + hour * 3600 + min * 60 + sec
  end

  -- Prefer getRtcTime() (returns Unix timestamp directly).
  -- Fall back to getDateTime() with manual conversion.
  local unixSecs = nil
  if type(getRtcTime) == "function" then
    local ok, ts = pcall(getRtcTime)
    if ok and type(ts) == "number" and ts > 0 then
      unixSecs = ts
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.rtc", "Using getRtcTime() = " .. tostring(unixSecs), "debug")
      end
    end
  end

  if not unixSecs then
    if type(getDateTime) ~= "function" then
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.rtc", "Neither getRtcTime nor getDateTime available, skipping RTC sync", "warn")
      end
      done = true
      return
    end
    local dt = getDateTime()
    if type(dt) ~= "table" then
      done = true
      return
    end
    unixSecs = dateToUnix(dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec)
    if type(Log) == "table" and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.tasks.rtc", "Using getDateTime() converted to Unix = " .. tostring(unixSecs), "debug")
    end
  end

  local payloadData = {
    seconds = unixSecs,
    milliseconds = 0
  }

  local payload = RtcApi.buildWritePayload(payloadData)

  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.rtc", "MSP request for RTC sync (cmd=" .. tostring(RtcApi.writeCommand) .. ") via queue", "debug")
  end

  mspState.queue:add({
    command = RtcApi.writeCommand,
    payload = payload,
    simulatorResponse = {}, -- we don't expect a meaningful response from writing
    timeout = 3.0,
    isWrite = true,
    processReply = function(self, buf)
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.rtc", "RTC successfully synced", "info")
      end
    end,
    errorHandler = function(msg, reason)
      -- "cleared" is the queue dropping this request, not the flight controller refusing it:
      -- nothing was sent, so the request is still owed. Leaving the task incomplete with its latch
      -- open is what lets the runner ask for it again on a later pass.
      if reason == "cleared" then
        requestSent = false
        return
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then 
        pcall(Log.emit, "rfsuite.tasks.rtc", "RTC sync failed", "warn") 
      end
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  requestSent = false
end

return M
