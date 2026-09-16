-- EdgeTX MSP API: RXFAIL_CONFIG (ported, simplified)

local Api = {
  command = 77,
  writeCommand = 78
}

local MAX_SUPPORTED_RC_CHANNEL_COUNT = 18

-- build FIELD_SPEC for read
local READ_FIELD_SPEC = {}
for i = 1, MAX_SUPPORTED_RC_CHANNEL_COUNT do
  local mandatory = (i == 1)
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"channel_" .. i .. "_mode", "U8", nil, nil, nil, nil, nil, nil, nil, nil}
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"channel_" .. i .. "_value", "U16", 885, 2115, 1500, "us"}
end

local WRITE_FIELD_SPEC = {
  {"index", "U8"},
  {"mode", "U8"},
  {"value", "U16"}
}

local function buildSimResponse()
  local bytes = {}
  for _ = 1, MAX_SUPPORTED_RC_CHANNEL_COUNT do
    bytes[#bytes + 1] = 0
    bytes[#bytes + 1] = 220
    bytes[#bytes + 1] = 5
  end
  return bytes
end

Api.fields = READ_FIELD_SPEC
Api.simulatorResponse = buildSimResponse()

local function read_u16_le(buf, pos)
  local lo = tonumber(buf[pos]) or 0
  local hi = tonumber(buf[pos+1]) or 0
  return lo + hi * 256
end

local function pack_u16_le(v)
  v = tonumber(v) or 0
  local lo = v % 256
  local hi = math.floor(v / 256) % 256
  return lo, hi
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local parsed = {}
  local pos = 1
  for i = 1, MAX_SUPPORTED_RC_CHANNEL_COUNT do
    local mode = tonumber(buf[pos]) or 0
    pos = pos + 1
    local val = read_u16_le(buf, pos)
    pos = pos + 2
    parsed["channel_" .. i .. "_mode"] = mode
    parsed["channel_" .. i .. "_value"] = val
  end
  return parsed
end

function Api.buildWritePayload(payloadData)
  if not payloadData then return nil end
  if payloadData.index ~= nil then
    local idx = tonumber(payloadData.index) or 0
    local mode = tonumber(payloadData.mode) or 0
    local value = tonumber(payloadData.value) or 1500
    local lo, hi = pack_u16_le(value)
    return { idx, mode, lo, hi }
  end

  -- detect channel_N_* keys
  for i = 1, MAX_SUPPORTED_RC_CHANNEL_COUNT do
    local modeKey = "channel_" .. i .. "_mode"
    local valKey = "channel_" .. i .. "_value"
    if payloadData[modeKey] ~= nil or payloadData[valKey] ~= nil then
      local mode = tonumber(payloadData[modeKey]) or 0
      local value = tonumber(payloadData[valKey]) or 1500
      local lo, hi = pack_u16_le(value)
      return { i - 1, mode, lo, hi }
    end
  end

  return nil
end

return Api
