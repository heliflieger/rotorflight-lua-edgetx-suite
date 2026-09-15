-- EdgeTX MSP API: VOLTAGE_METER_CONFIG (ported)

local Api = {
  command = 56,
  writeCommand = 57
}

local FIELD_SPEC = {
  {"meter_count", "U8"},
  {"frame_length_1", "U8"}, {"meter_id_1", "U8"}, {"meter_type_1", "U8"}, {"scale_1", "U16"}, {"divider_1", "U16"}, {"divmul_1", "U8"},
  {"frame_length_2", "U8"}, {"meter_id_2", "U8"}, {"meter_type_2", "U8"}, {"scale_2", "U16"}, {"divider_2", "U16"}, {"divmul_2", "U8"},
  {"frame_length_3", "U8"}, {"meter_id_3", "U8"}, {"meter_type_3", "U8"}, {"scale_3", "U16"}, {"divider_3", "U16"}, {"divmul_3", "U8"},
  {"frame_length_4", "U8"}, {"meter_id_4", "U8"}, {"meter_type_4", "U8"}, {"scale_4", "U16"}, {"divider_4", "U16"}, {"divmul_4", "U8"}
}

local WRITE_FIELD_SPEC = {
  {"meter_id", "U8"}, {"scale", "U16"}, {"divider", "U16"}, {"divmul", "U8"}
}

local SIM_RESPONSE = {4, 7,0, 0,1, 0,0, 1,0, 7, 1,1,0,0,1,0, 7, 2,1,0,0,1,0, 7, 3,1,0,0,1}

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

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local p = {}
  local pos = 1
  p.meter_count = tonumber(buf[pos]) or 0; pos = pos + 1
  for i = 1, 4 do
    p["frame_length_"..i] = tonumber(buf[pos]); pos = pos + 1
    p["meter_id_"..i] = tonumber(buf[pos]); pos = pos + 1
    p["meter_type_"..i] = tonumber(buf[pos]); pos = pos + 1
    p["scale_"..i] = read_u16_le(buf, pos); pos = pos + 2
    p["divider_"..i] = read_u16_le(buf, pos); pos = pos + 2
    p["divmul_"..i] = tonumber(buf[pos]); pos = pos + 1
  end
  return p
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[#payload+1] = tonumber(data.meter_id) or 0
  local lo,hi = pack_u16_le(tonumber(data.scale) or 0); payload[#payload+1]=lo; payload[#payload+1]=hi
  lo,hi = pack_u16_le(tonumber(data.divider) or 0); payload[#payload+1]=lo; payload[#payload+1]=hi
  payload[#payload+1] = tonumber(data.divmul) or 0
  return payload
end

return Api
