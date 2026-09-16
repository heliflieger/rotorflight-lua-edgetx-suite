-- EdgeTX MSP API: RX_CONFIG (ported)

local Api = {
  command = 44,
  writeCommand = 45
}

local FIELD_SPEC = {
  {"serialrx_provider", "U8"},
  {"serialrx_inverted", "U8"},
  {"halfDuplex", "U8"},
  {"rx_pulse_min", "U16", nil, nil, nil, "us"},
  {"rx_pulse_max", "U16", nil, nil, nil, "us"},
  {"rx_spi_protocol", "U8"},
  {"rx_spi_id", "U32"},
  {"rx_spi_rf_channel_count", "U8"},
  {"pinSwap", "U8"}
}

local SIM_RESPONSE = { 0,0,0, 107,3, 77,8, 0,0,0,0, 0, 0 }

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

local function read_u16_le(buf, pos)
  local lo = tonumber(buf[pos]) or 0
  local hi = tonumber(buf[pos+1]) or 0
  return lo + hi * 256
end

local function read_u32_le(buf, pos)
  local b1 = tonumber(buf[pos]) or 0
  local b2 = tonumber(buf[pos+1]) or 0
  local b3 = tonumber(buf[pos+2]) or 0
  local b4 = tonumber(buf[pos+3]) or 0
  return b1 + b2*256 + b3*65536 + b4*16777216
end

local function pack_u16_le(v)
  v = tonumber(v) or 0
  local lo = v % 256
  local hi = math.floor(v / 256) % 256
  return lo, hi
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
  parsed.serialrx_provider = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.serialrx_inverted = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.halfDuplex = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.rx_pulse_min = read_u16_le(buf, pos); pos = pos + 2
  parsed.rx_pulse_max = read_u16_le(buf, pos); pos = pos + 2
  parsed.rx_spi_protocol = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.rx_spi_id = read_u32_le(buf, pos); pos = pos + 4
  parsed.rx_spi_rf_channel_count = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.pinSwap = tonumber(buf[pos]) or 0; pos = pos + 1
  return parsed
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[#payload+1] = tonumber(data.serialrx_provider) or 0
  payload[#payload+1] = tonumber(data.serialrx_inverted) or 0
  payload[#payload+1] = tonumber(data.halfDuplex) or 0
  local lo, hi = pack_u16_le(tonumber(data.rx_pulse_min) or 0)
  payload[#payload+1] = lo; payload[#payload+1] = hi
  lo, hi = pack_u16_le(tonumber(data.rx_pulse_max) or 0)
  payload[#payload+1] = lo; payload[#payload+1] = hi
  payload[#payload+1] = tonumber(data.rx_spi_protocol) or 0
  local b1,b2,b3,b4 = pack_u32_le(tonumber(data.rx_spi_id) or 0)
  payload[#payload+1] = b1; payload[#payload+1] = b2; payload[#payload+1] = b3; payload[#payload+1] = b4
  payload[#payload+1] = tonumber(data.rx_spi_rf_channel_count) or 0
  payload[#payload+1] = tonumber(data.pinSwap) or 0
  return payload
end

return Api
