-- EdgeTX MSP API: SENSOR_CONFIG (ported)

local Api = {
  command = 96,
  writeCommand = 97
}

local FIELD_SPEC = {
  {"acc_hardware", "U8"},
  {"baro_hardware", "U8"},
  {"mag_hardware", "U8"},
  {"gyro_to_use", "U8"},
  {"gyro_high_fsr", "U8"},
  {"gyroMovementCalibrationThreshold", "U8"},
  {"gyroCalibrationDuration", "U16"},
  {"gyro_offset_yaw", "U16"},
  {"checkOverflow", "U8"}
}

local SIM_RESPONSE = {0,0,0,0,0,48,244,1,0,0,1}

Api.fields = FIELD_SPEC
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
  p.acc_hardware = tonumber(buf[pos]) or 0; pos = pos + 1
  p.baro_hardware = tonumber(buf[pos]) or 0; pos = pos + 1
  p.mag_hardware = tonumber(buf[pos]) or 0; pos = pos + 1
  p.gyro_to_use = tonumber(buf[pos]) or 0; pos = pos + 1
  p.gyro_high_fsr = tonumber(buf[pos]) or 0; pos = pos + 1
  p.gyroMovementCalibrationThreshold = tonumber(buf[pos]) or 0; pos = pos + 1
  p.gyroCalibrationDuration = read_u16_le(buf, pos); pos = pos + 2
  p.gyro_offset_yaw = read_u16_le(buf, pos); pos = pos + 2
  p.checkOverflow = tonumber(buf[pos]) or 0; pos = pos + 1
  return p
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[#payload+1] = tonumber(data.acc_hardware) or 0
  payload[#payload+1] = tonumber(data.baro_hardware) or 0
  payload[#payload+1] = tonumber(data.mag_hardware) or 0
  payload[#payload+1] = tonumber(data.gyro_to_use) or 0
  payload[#payload+1] = tonumber(data.gyro_high_fsr) or 0
  payload[#payload+1] = tonumber(data.gyroMovementCalibrationThreshold) or 0
  local lo, hi = pack_u16_le(tonumber(data.gyroCalibrationDuration) or 0)
  payload[#payload+1] = lo; payload[#payload+1] = hi
  lo, hi = pack_u16_le(tonumber(data.gyro_offset_yaw) or 0)
  payload[#payload+1] = lo; payload[#payload+1] = hi
  payload[#payload+1] = tonumber(data.checkOverflow) or 0
  return payload
end

return Api
