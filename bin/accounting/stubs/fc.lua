-- A scripted flight controller on the far side of the CRSF link.
--
-- It answers MSP requests at the WIRE, not above it: the measured tree keeps its real
-- transport (tasks/msp/transports/crsf.lua), its real chunked framing and its real poll
-- loop, and only the peer is scripted. Replacing the transport instead would have taken
-- the framing and the poll loop out of every number this check reports.
--
-- The replies are the repository's own: every module under tasks/msp/api/ that carries a
-- `simulatorResponse` is indexed by its command, so the payload sizes a pass parses are
-- the sizes the firmware actually sends. Nothing is invented here, and a reply that drifts
-- drifts with the API definition that owns it.

local FC = {}

local ADDR_FC = 0xC8
local ADDR_RADIO = 0xEA
local FT_MSP_REQ = 0x7A
local FT_MSP_WRITE = 0x7C
local FT_MSP_RESP = 0x7B

-- transports/crsf.lua reads at most this many MSP bytes out of one response frame.
local MAX_RX_BYTES = 58

FC.replies = {}       -- command -> payload table, from the api modules
FC.sources = {}       -- command -> module file the payload came from
FC.collisions = {}    -- command -> the other modules that claim it
FC.unanswered = {}    -- command -> how often it was asked with no scripted payload
FC.served = 0

local rx = { active = false, cmd = 0, len = 0, data = {} }
local pushFrame = nil

--- Index every API definition that carries a canned payload.
--
-- `files` is the sorted file list; sorted, because two modules claiming one command must
-- resolve the same way on every host or the numbers stop being comparable. The loser is
-- recorded rather than dropped silently.
function FC.loadReplies(apiDir, files)
  FC.replies, FC.sources, FC.collisions = {}, {}, {}
  local indexed = 0
  for _, file in ipairs(files) do
    local chunk, err = loadfile(apiDir .. "/" .. file)
    if not chunk then
      error("accounting: api module will not load: " .. apiDir .. "/" .. file .. ": " .. tostring(err))
    end
    local mod = chunk()
    if type(mod) == "table" and type(mod.command) == "number" and type(mod.simulatorResponse) == "table" then
      local cmd = mod.command
      if FC.replies[cmd] == nil then
        FC.replies[cmd] = mod.simulatorResponse
        FC.sources[cmd] = file
        indexed = indexed + 1
      else
        FC.collisions[cmd] = FC.collisions[cmd] or {}
        FC.collisions[cmd][#FC.collisions[cmd] + 1] = file
      end
    end
  end
  return indexed
end

function FC.reset()
  rx = { active = false, cmd = 0, len = 0, data = {} }
  FC.unanswered = {}
  FC.served = 0
end

local function sendReply(cmd, data)
  local len = #data
  local seq = 0
  local idx = 1
  local first = true
  repeat
    local frame = { ADDR_RADIO, ADDR_FC }
    local status = 0x40 | (seq & 0x0F)
    if first then status = status | 0x10 end
    frame[3] = status
    local n = 4
    if first then
      frame[4] = 0
      frame[5] = cmd & 0xFF
      frame[6] = (cmd >> 8) & 0xFF
      frame[7] = len & 0xFF
      frame[8] = (len >> 8) & 0xFF
      n = 9
    end
    -- Two address bytes, then MSP byte 1..MAX_RX_BYTES: frame index 3 through 60.
    while n <= 2 + MAX_RX_BYTES and idx <= len do
      frame[n] = data[idx]
      n = n + 1
      idx = idx + 1
    end
    pushFrame(FT_MSP_RESP, frame)
    seq = (seq + 1) & 0x0F
    first = false
  until idx > len
end

--- One outgoing chunk from the radio. Returns what crossfireTelemetryPush returns.
local function onPush(frameType, payload)
  if frameType ~= FT_MSP_REQ and frameType ~= FT_MSP_WRITE then return true end

  local i = 3
  local status = payload[i]
  if status == nil then return true end
  i = i + 1

  if (status & 0x10) ~= 0 then
    rx.data = {}
    rx.cmd = (payload[i + 1] or 0) | ((payload[i + 2] or 0) << 8)
    rx.len = (payload[i + 3] or 0) | ((payload[i + 4] or 0) << 8)
    rx.active = true
    i = i + 5
  elseif not rx.active then
    return true
  end

  while payload[i] ~= nil and #rx.data < rx.len do
    rx.data[#rx.data + 1] = payload[i]
    i = i + 1
  end

  if #rx.data >= rx.len then
    rx.active = false
    local reply = FC.replies[rx.cmd]
    if reply == nil then
      -- Answered empty rather than left to time out: a request nobody answers costs the
      -- queue a retry ladder, and a pass spent waiting is not the pass this gate is about.
      -- Every instance is counted and printed, so an empty answer can never pass for a
      -- scripted one.
      FC.unanswered[rx.cmd] = (FC.unanswered[rx.cmd] or 0) + 1
      reply = {}
    end
    FC.served = FC.served + 1
    sendReply(rx.cmd, reply)
  end

  return true
end

--- Wire the peer to the frame queue the EdgeTX stub serves crossfireTelemetryPop from.
function FC.install(stubs)
  pushFrame = function(command, data) stubs.pushFrame(command, data) end
  stubs.onPush = onPush
end

return FC
