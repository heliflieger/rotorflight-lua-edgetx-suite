-- EdgeTX MSP API: SENSOR_ALIGNMENT (ported)

local Api = {
  command = 126,
  writeCommand = 220
}

local FIELD_SPEC = {
  {"gyro_1_alignment", "U8"},
  {"gyro_2_alignment", "U8"},
  {"mag_alignment", "U8"}
}

local SIM_RESPONSE = {0,0,0}

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local parsed = {}
  parsed.gyro_1_alignment = tonumber(buf[1]) or 0
  parsed.gyro_2_alignment = tonumber(buf[2]) or 0
  parsed.mag_alignment = tonumber(buf[3]) or 0
  return parsed
end

function Api.buildWritePayload(data)
  return {
    tonumber(data and data.gyro_1_alignment) or 0,
    tonumber(data and data.gyro_2_alignment) or 0,
    tonumber(data and data.mag_alignment) or 0
  }
end

return Api
