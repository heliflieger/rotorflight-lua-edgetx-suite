-- EdgeTX MSP API: VTX_CONFIG (ported)

local Api = {
  command = 88,
  writeCommand = 89
}

local FIELD_SPEC = {
  {"device_type", "U8"}, {"band", "U8"}, {"channel", "U8"}, {"power", "U8"}, {"pit_mode", "U8"}, {"freq", "U16"}, {"device_ready", "U8"}, {"low_power_disarm", "U8"}
}

local WRITE_FIELD_SPEC = {
  {"freq_or_bandchan", "U16"}, {"power", "U8"}, {"pit_mode", "U8"}, {"low_power_disarm", "U8"}, {"pit_mode_freq", "U16"}, {"band", "U8"}, {"channel", "U8"}, {"freq", "U16"},
  {"vtxtable_bands", "U8"}, {"vtxtable_channels", "U8"}, {"vtxtable_power_levels", "U8"}, {"vtxtable_clear", "U8"}
}

local SIM_RESPONSE = {0,1,1,1,0,108,22,1,0,0,1,5}

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
  local parsed = {}
  local pos = 1
  parsed.device_type = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.band = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.channel = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.power = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.pit_mode = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.freq = read_u16_le(buf, pos); pos = pos + 2
  parsed.device_ready = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.low_power_disarm = tonumber(buf[pos]) or 0; pos = pos + 1
  -- optional extras
  if #buf >= pos + 2 then
    parsed.pit_mode_freq = read_u16_le(buf, pos); pos = pos + 2
  end
  if #buf >= pos + 1 then
    parsed.vtxtable_available = tonumber(buf[pos]) or 0; pos = pos + 1
  end
  if #buf >= pos + 1 then
    parsed.vtxtable_bands = tonumber(buf[pos]) or 0; pos = pos + 1
  end
  if #buf >= pos + 1 then
    parsed.vtxtable_channels = tonumber(buf[pos]) or 0; pos = pos + 1
  end
  if #buf >= pos + 1 then
    parsed.vtxtable_power_levels = tonumber(buf[pos]) or 0; pos = pos + 1
  end
  return parsed
end

function Api.buildWritePayload(data)
  local payload = {}
  local v = tonumber(data.freq_or_bandchan) or 0
  local lo,hi = pack_u16_le(v); payload[#payload+1]=lo; payload[#payload+1]=hi
  payload[#payload+1] = tonumber(data.power) or 0
  payload[#payload+1] = tonumber(data.pit_mode) or 0
  payload[#payload+1] = tonumber(data.low_power_disarm) or 0
  lo,hi = pack_u16_le(tonumber(data.pit_mode_freq) or 0); payload[#payload+1]=lo; payload[#payload+1]=hi
  payload[#payload+1] = tonumber(data.band) or 0
  payload[#payload+1] = tonumber(data.channel) or 0
  lo,hi = pack_u16_le(tonumber(data.freq) or 0); payload[#payload+1]=lo; payload[#payload+1]=hi
  payload[#payload+1] = tonumber(data.vtxtable_bands) or 0
  payload[#payload+1] = tonumber(data.vtxtable_channels) or 0
  payload[#payload+1] = tonumber(data.vtxtable_power_levels) or 0
  payload[#payload+1] = tonumber(data.vtxtable_clear) or 0
  return payload
end

return Api
