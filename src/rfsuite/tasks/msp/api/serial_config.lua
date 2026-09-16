-- EdgeTX MSP API: SERIAL_CONFIG (ported)

local Api = {
  command = 54,
  writeCommand = 55
}

local MAX_SERIAL_PORTS = 12

local READ_FIELD_SPEC = {}
for i = 1, MAX_SERIAL_PORTS do
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"port_" .. i .. "_identifier", "U8"}
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"port_" .. i .. "_function_mask", "U32"}
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"port_" .. i .. "_msp_baud_index", "U8"}
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"port_" .. i .. "_gps_baud_index", "U8"}
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"port_" .. i .. "_telem_baud_index", "U8"}
  READ_FIELD_SPEC[#READ_FIELD_SPEC + 1] = {"port_" .. i .. "_blackbox_baud_index", "U8"}
end

local WRITE_FIELD_SPEC = {
  {"identifier", "U8"}, {"function_mask", "U32"}, {"msp_baud_index", "U8"}, {"gps_baud_index", "U8"}, {"telem_baud_index", "U8"}, {"blackbox_baud_index", "U8"}
}

local function buildSimResponse()
  local bytes = {}
  for i = 1, MAX_SERIAL_PORTS do
    bytes[#bytes+1] = i - 1
    bytes[#bytes+1] = 0
    bytes[#bytes+1] = 0
    bytes[#bytes+1] = 0
    bytes[#bytes+1] = 0
    bytes[#bytes+1] = 0
    bytes[#bytes+1] = 0
    bytes[#bytes+1] = 0
    bytes[#bytes+1] = 0
  end
  return bytes
end

Api.fields = READ_FIELD_SPEC
Api.simulatorResponse = buildSimResponse()

local function read_u32_le(buf, pos)
  local b1 = tonumber(buf[pos]) or 0
  local b2 = tonumber(buf[pos+1]) or 0
  local b3 = tonumber(buf[pos+2]) or 0
  local b4 = tonumber(buf[pos+3]) or 0
  return b1 + b2*256 + b3*65536 + b4*16777216
end

local function pack_u32_le(v)
  v = tonumber(v) or 0
  local b1 = v % 256
  local b2 = math.floor(v / 256) % 256
  local b3 = math.floor(v / 65536) % 256
  local b4 = math.floor(v / 16777216) % 256
  return b1, b2, b3, b4
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local parsed = {}
  local pos = 1
  for i = 1, MAX_SERIAL_PORTS do
    if buf[pos] == nil then break end
    local identifier = tonumber(buf[pos]) or 0
    if identifier == 255 then break end
    parsed["port_" .. i .. "_identifier"] = identifier; pos = pos + 1
    parsed["port_" .. i .. "_function_mask"] = read_u32_le(buf, pos); pos = pos + 4
    parsed["port_" .. i .. "_msp_baud_index"] = tonumber(buf[pos]) or 0; pos = pos + 1
    parsed["port_" .. i .. "_gps_baud_index"] = tonumber(buf[pos]) or 0; pos = pos + 1
    parsed["port_" .. i .. "_telem_baud_index"] = tonumber(buf[pos]) or 0; pos = pos + 1
    parsed["port_" .. i .. "_blackbox_baud_index"] = tonumber(buf[pos]) or 0; pos = pos + 1
  end
  return parsed
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[#payload+1] = tonumber(data.identifier) or 0
  local b1,b2,b3,b4 = pack_u32_le(tonumber(data.function_mask) or 0)
  payload[#payload+1] = b1; payload[#payload+1] = b2; payload[#payload+1] = b3; payload[#payload+1] = b4
  payload[#payload+1] = tonumber(data.msp_baud_index) or 0
  payload[#payload+1] = tonumber(data.gps_baud_index) or 0
  payload[#payload+1] = tonumber(data.telem_baud_index) or 0
  payload[#payload+1] = tonumber(data.blackbox_baud_index) or 0
  return payload
end

return Api
