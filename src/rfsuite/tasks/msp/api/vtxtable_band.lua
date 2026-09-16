-- EdgeTX MSP API: VTXTABLE_BAND (ported)

local Api = {
  command = 137,
  writeCommand = 227
}

local FIELD_SPEC = {
  {"band", "U8"}, {"name_length", "U8"}, {"name_1", "U8"}, {"name_2", "U8"}, {"name_3", "U8"}, {"name_4", "U8"}, {"name_5", "U8"}, {"name_6", "U8"}, {"name_7", "U8"}, {"name_8", "U8"},
  {"band_letter", "U8"}, {"is_factory_band", "U8"}, {"channel_count", "U8"},
  {"freq_1", "U16"}, {"freq_2", "U16"}, {"freq_3", "U16"}, {"freq_4", "U16"}, {"freq_5", "U16"}, {"freq_6", "U16"}, {"freq_7", "U16"}, {"freq_8", "U16"}
}

local WRITE_FIELD_SPEC = {
  {"band", "U8"}, {"name_length", "U8"}, {"name_1", "U8"}, {"name_2", "U8"}, {"name_3", "U8"}, {"name_4", "U8"}, {"name_5", "U8"}, {"name_6", "U8"}, {"name_7", "U8"}, {"name_8", "U8"},
  {"band_letter", "U8"}, {"is_factory_band", "U8"}, {"channel_count", "U8"},
  {"freq_1", "U16"}, {"freq_2", "U16"}, {"freq_3", "U16"}, {"freq_4", "U16"}, {"freq_5", "U16"}, {"freq_6", "U16"}, {"freq_7", "U16"}, {"freq_8", "U16"}
}

local SIM_RESPONSE = {
  1, 8, 65,66,67,68,69,70,71,72, 65, 1, 8,
  100,22, 120,22, 140,22, 160,22, 180,22, 200,22, 220,22, 240,22
}

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

Api.fields = FIELD_SPEC
Api.writeFields = WRITE_FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.buildReadPayload(payloadData, _, _, _, band)
  local readBand = tonumber(band) or tonumber(payloadData and payloadData.band) or 1
  return { readBand }
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local parsed = {}
  local pos = 1
  parsed.band = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.name_length = tonumber(buf[pos]) or 0; pos = pos + 1
  for i = 1, 8 do
    parsed["name_"..i] = tonumber(buf[pos]) or 0; pos = pos + 1
  end
  parsed.band_letter = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.is_factory_band = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.channel_count = tonumber(buf[pos]) or 0; pos = pos + 1
  for i = 1, 8 do
    parsed["freq_"..i] = read_u16_le(buf, pos); pos = pos + 2
  end
  return parsed
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[#payload+1] = tonumber(data.band) or 0
  payload[#payload+1] = tonumber(data.name_length) or 0
  for i = 1, 8 do payload[#payload+1] = tonumber(data["name_"..i]) or 0 end
  payload[#payload+1] = tonumber(data.band_letter) or 0
  payload[#payload+1] = tonumber(data.is_factory_band) or 0
  payload[#payload+1] = tonumber(data.channel_count) or 0
  for i = 1, 8 do
    local lo,hi = pack_u16_le(tonumber(data["freq_"..i]) or 0)
    payload[#payload+1] = lo; payload[#payload+1] = hi
  end
  return payload
end

return Api
