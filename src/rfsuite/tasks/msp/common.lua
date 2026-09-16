local function loadTransport(protocol)
  if type(protocol) ~= "string" or protocol == "" then
    return nil
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/tasks/msp/transports/" .. protocol .. ".lua"
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, transport = pcall(chunk)
  if not ok or type(transport) ~= "table" then return nil end
  if type(transport.mspSend) ~= "function" or type(transport.mspPoll) ~= "function" then
    return nil
  end
  return transport
end

local Env = nil

local function getEnv()
  if Env == nil then
    if _G.rfsuite and _G.rfsuite.require then
      Env = _G.rfsuite.require("lib/env.lua") or false
    else
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/env.lua", "t")
      local ok, mod = pcall(chunk)
      Env = (ok and type(mod) == "table") and mod or false
    end
  end
  return Env or nil
end

local function new(protocol)
  local transport = loadTransport(protocol)
  if not transport then return nil end

  local function nowSeconds()
    if type(getTime) == "function" then
      local ok, v = pcall(getTime)
      if ok and type(v) == "number" then
        return v / 100
      end
    end
    if type(os) == "table" and type(os.clock) == "function" then
      return os.clock()
    end
    return 0
  end

  local mspSeq = 0
  local mspRemoteSeq = 0
  local mspRxBuf = {}
  local mspRxError = false
  local mspRxSize = 0
  local mspRxCRC = 0
  local mspRxReq = 0
  local mspStarted = false
  local mspLastReq = 0
  local mspTxBuf = {}
  local mspTxIdx = 1
  local mspTxCRC = 0
  local mspVersion = 2

  local maxTxBufferSize = transport.maxTxBufferSize or 8
  local maxRxBufferSize = transport.maxRxBufferSize or 58

  local function clearArray(tbl)
    for i = #tbl, 1, -1 do
      tbl[i] = nil
    end
  end

  local function pollBudget()
    local base = tonumber(transport.mspPollBudget) or 0.07
    local perPoll = tonumber(transport.maxRxBufferSize) or 6
    local pending = #mspRxBuf

    if mspRxSize and mspRxSize > pending then
      pending = mspRxSize
    end

    local thresholdWindows = 6
    local threshold = thresholdWindows * perPoll
    local boost = 0
    if perPoll > 0 and pending > threshold then
      local extraWindows = math.ceil((pending - threshold) / perPoll)
      boost = extraWindows * 0.03
    end

    local final = base + boost
    if final > 0.35 then final = 0.35 end
    return final
  end

  local function buildStatusByte(isStart)
    local versionBits = bit32.lshift(mspVersion == 2 and 2 or 1, 5)
    local status = bit32.bor(bit32.band(mspSeq, 0x0F), versionBits)
    if isStart then
      status = bit32.bor(status, 0x10)
    end
    mspSeq = bit32.band(mspSeq + 1, 0x0F)
    return status
  end

  local function mspProcessTxQ()
    if #mspTxBuf == 0 then return false end

    -- Where this chunk starts. `transport.mspSend` hands the frame to a ONE-SLOT uplink buffer
    -- that answers false while it is still occupied, and a chunk that was refused was never
    -- sent -- so the index must not move past it. Without this a request longer than one chunk
    -- loses its tail: the flight controller assembles nothing, answers nothing, and the whole
    -- message is retried from the beginning after the timeout.
    local chunkIdx = mspTxIdx
    local chunkCRC = mspTxCRC
    -- ... and the sequence, which buildStatusByte advances as a side effect of being called.
    -- A re-sent chunk has to carry the sequence it was built with: the receiver drops the whole
    -- request when the numbers skip, so restoring the index without the sequence turns a lost
    -- chunk into a lost message just the same.
    local chunkSeq = mspSeq

    local payload = {}
    payload[1] = buildStatusByte(mspTxIdx == 1)

    local i = 2
    while i <= maxTxBufferSize and mspTxIdx <= #mspTxBuf do
      payload[i] = mspTxBuf[mspTxIdx]
      mspTxIdx = mspTxIdx + 1
      if mspVersion == 1 then
        mspTxCRC = bit32.bxor(mspTxCRC, payload[i])
      end
      i = i + 1
    end

    if mspVersion == 1 then
      if i <= maxTxBufferSize then
        payload[i] = mspTxCRC
        for j = i + 1, maxTxBufferSize do
          payload[j] = 0
        end
        if not transport.mspSend(payload) then
          mspTxIdx = chunkIdx
          mspTxCRC = chunkCRC
          mspSeq = chunkSeq
          return true
        end
        clearArray(mspTxBuf)
        mspTxIdx = 1
        mspTxCRC = 0
        return false
      end

      if not transport.mspSend(payload) then
        mspTxIdx = chunkIdx
        mspTxCRC = chunkCRC
        mspSeq = chunkSeq
      end
      return true
    end

    for j = i, maxTxBufferSize do
      payload[j] = payload[j] or 0
    end

    if not transport.mspSend(payload) then
      mspTxIdx = chunkIdx
      mspTxCRC = chunkCRC
      mspSeq = chunkSeq
      return true
    end

    if mspTxIdx > #mspTxBuf then
      clearArray(mspTxBuf)
      mspTxIdx = 1
      mspTxCRC = 0
      return false
    end

    return true
  end

  local function mspSendRequest(cmd, reqPayload, opts)
    if #mspTxBuf ~= 0 or not cmd then
      return false
    end

    local payload = reqPayload or {}
    local payloadSize = #payload
    local isWrite = type(opts) == "table" and opts.write == true

    if type(transport.prepareRequest) == "function" then
      transport.prepareRequest(isWrite)
    end

    if mspVersion == 1 then
      mspTxBuf[1] = payloadSize
      mspTxBuf[2] = bit32.band(cmd, 0xFF)
      for i = 1, payloadSize do
        mspTxBuf[i + 2] = bit32.band(payload[i], 0xFF)
      end
    else
      -- MSP V2 request header: flags, cmd lo/hi, len lo/hi
      mspTxBuf[1] = 0
      mspTxBuf[2] = bit32.band(cmd, 0xFF)
      mspTxBuf[3] = bit32.band(bit32.rshift(cmd, 8), 0xFF)
      mspTxBuf[4] = bit32.band(payloadSize, 0xFF)
      mspTxBuf[5] = bit32.band(bit32.rshift(payloadSize, 8), 0xFF)
      for i = 1, payloadSize do
        mspTxBuf[i + 5] = bit32.band(payload[i], 0xFF)
      end
    end

    mspTxIdx = 1
    mspTxCRC = 0
    mspLastReq = cmd
    return true
  end

  local function mspReceivedReply(payload)
    local idx = 1
    local status = payload[idx]
    if status == nil then return nil end

    local version = bit32.rshift(bit32.band(status, 0x60), 5)
    local start = bit32.btest(status, 0x10)
    local seq = bit32.band(status, 0x0F)
    idx = idx + 1

    if start then
      clearArray(mspRxBuf)
      mspRxError = bit32.btest(status, 0x80)
      if version == 2 then
        local flags = payload[idx] or 0
        local cmdLow = payload[idx + 1] or 0
        local cmdHigh = payload[idx + 2] or 0
        local lenLow = payload[idx + 3] or 0
        local lenHigh = payload[idx + 4] or 0
        mspRxReq = bit32.bor(bit32.band(cmdLow, 0xFF), bit32.lshift(bit32.band(cmdHigh, 0xFF), 8))
        mspRxSize = bit32.bor(bit32.band(lenLow, 0xFF), bit32.lshift(bit32.band(lenHigh, 0xFF), 8))
        mspRxCRC = 0
        idx = idx + 5
        if flags ~= 0 then
          mspRxError = mspRxError or false
        end
      else
        mspRxSize = payload[idx] or 0
        mspRxReq = mspLastReq
        idx = idx + 1
        if version == 1 then
          mspRxReq = payload[idx] or mspRxReq
          idx = idx + 1
        end
        mspRxCRC = bit32.bxor(mspRxSize, mspRxReq)
      end

      if mspRxReq == mspLastReq then
        mspStarted = true
        mspRemoteSeq = seq
      else
        mspStarted = false
        return nil
      end
    elseif not mspStarted then
      return nil
    elseif bit32.band(mspRemoteSeq + 1, 0x0F) ~= seq then
      clearArray(mspRxBuf)
      mspRxSize = 0
      mspRxCRC = 0
      mspStarted = false
      mspRemoteSeq = 0
      return nil
    end

    while idx <= maxRxBufferSize and #mspRxBuf < mspRxSize do
      local b = payload[idx]
      if b == nil then break end
      mspRxBuf[#mspRxBuf + 1] = b
      if mspVersion == 1 then
        local v = tonumber(b)
        if v then
          mspRxCRC = bit32.bxor(mspRxCRC, v)
        end
      end
      idx = idx + 1
    end

    if #mspRxBuf < mspRxSize then
      mspRemoteSeq = seq
      return false
    end

    if mspVersion == 1 then
      local rxCRC = payload[idx] or 0
      if mspRxCRC ~= rxCRC and version == 0 then
        clearArray(mspRxBuf)
        mspStarted = false
        return nil
      end
    end

    mspStarted = false
    mspRemoteSeq = seq

    return true
  end

  local function mspPollReply()
    local budget = pollBudget()
    local nonBlocking = transport.mspNonBlocking ~= false
    local sliceSeconds = tonumber(transport.mspPollSliceSeconds) or 0.006
    local slicePolls = tonumber(transport.mspPollSlicePolls) or 4
    local idleCap = 0.02
    local inflight0 = mspStarted or (mspLastReq ~= 0)

    local window
    if nonBlocking then
      window = inflight0 and (sliceSeconds * 2) or sliceSeconds
    else
      window = inflight0 and budget or math.min(budget, idleCap)
    end

    local deadline = nowSeconds() + window
    local maxNilIdle = 4
    local maxNilInflight = nonBlocking and math.max(2, slicePolls) or 16
    local maxPolls = nonBlocking and slicePolls or 24

    local polls = 0
    local nilPolls = 0

    -- In the widget state the loop is bounded by counts alone (maxPolls and the nil caps):
    -- the firmware bills a widget call in instructions, not wall time, so the same time
    -- window costs more iterations on a faster board and cannot be accounted statically.
    -- The tool state has no instruction hook, wants throughput, and keeps the window.
    local env = getEnv()
    local countsOnly = env ~= nil and type(env.isWidget) == "function" and env.isWidget() == true

    while countsOnly or nowSeconds() < deadline do
      polls = polls + 1
      if polls > maxPolls then
        return nil
      end

      local mspData = transport.mspPoll()
      if mspData == nil then
        nilPolls = nilPolls + 1
        local inflight = mspStarted or (mspLastReq ~= 0)
        local maxNil = inflight and maxNilInflight or maxNilIdle
        if nilPolls >= maxNil then
          return nil
        end
      elseif type(mspData) == "table" then
        nilPolls = 0
        local ok, done = pcall(mspReceivedReply, mspData)
        if ok and done then
          local rxBuf = mspRxBuf
        mspLastReq = 0
          return mspRxReq, rxBuf, mspRxError
        end
      end
    end

    return nil
  end

  local function mspClearTxBuf()
    clearArray(mspTxBuf)
    mspTxIdx = 1
    mspTxCRC = 0
  end

  -- Drop a half-finished reassembly. Chunks of a reply whose request has been abandoned keep
  -- arriving; with the receive state left as it is they are still accepted, still complete,
  -- and still report the command id of the request that is gone -- so the completion is
  -- handed to whatever asks for that same command next.
  local function mspClearRxBuf()
    clearArray(mspRxBuf)
    mspRxSize = 0
    mspRxCRC = 0
    mspRxReq = 0
    mspRxError = false
    mspStarted = false
    mspRemoteSeq = 0
    mspLastReq = 0
  end

  return {
    sendRequest = mspSendRequest,
    processTxQ = mspProcessTxQ,
    pollReply = mspPollReply,
    clearTxBuf = mspClearTxBuf,
    clearRxBuf = mspClearRxBuf,
    setProtocolVersion = function(v)
      local n = tonumber(v)
      mspVersion = (n == 2) and 2 or 1
    end,
    getProtocolVersion = function()
      return mspVersion
    end,
  }
end

return {
  new = new
}
