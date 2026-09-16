-- EdgeTX MSP API: VTXTABLE_POWERLEVEL (ported)

local Api = {
  command = 138,
  writeCommand = 228
}

local FIELD_SPEC = {
  {"power_level", "U8"}, {"power_value", "U16"}, {"label_length", "U8"}, {"label_1", "U8"}, {"label_2", "U8"}, {"label_3", "U8"}
}

local WRITE_FIELD_SPEC = {
  {"power_level", "U8"}, {"power_value", "U16"}, {"label_length", "U8"}, {"label_1", "U8"}, {"label_2", "U8"}, {"label_3", "U8"}
}

local SIM_RESPONSE = {1, 25,0, 3, 50, 53, 77}

Api.fields = FIELD_SPEC
Api.writeFields = WRITE_FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

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

function Api.buildReadPayload(payloadData, _, _, _, powerLevel)
  local readPower = tonumber(powerLevel) or tonumber(payloadData and payloadData.power_level) or 1
  return { readPower }
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local parsed = {}
  local pos = 1
  parsed.power_level = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.power_value = read_u16_le(buf, pos); pos = pos + 2
  parsed.label_length = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.label_1 = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.label_2 = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.label_3 = tonumber(buf[pos]) or 0; pos = pos + 1
  return parsed
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[#payload+1] = tonumber(data.power_level) or 0
  local lo,hi = pack_u16_le(tonumber(data.power_value) or 0); payload[#payload+1]=lo; payload[#payload+1]=hi
  payload[#payload+1] = tonumber(data.label_length) or 0
  payload[#payload+1] = tonumber(data.label_1) or 0
  payload[#payload+1] = tonumber(data.label_2) or 0
  payload[#payload+1] = tonumber(data.label_3) or 0
  return payload
end

return Api
