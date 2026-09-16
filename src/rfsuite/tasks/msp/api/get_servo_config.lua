-- EdgeTX MSP API: GET_SERVO_CONFIG (one servo)
--
-- The request carries the servo index and the reply is a single 16-byte record with the same
-- field order and encoding as one entry of the whole-table MSP_SERVO_CONFIGURATIONS reply. The
-- index is the RAW servoParams index, not the packed one that MSP_SERVO_CONFIGURATIONS and
-- MSP_SET_SERVO_CONFIGURATION use -- the firmware refuses anything from MAX_SUPPORTED_SERVOS
-- upwards, and a request of any other length.

local Api = {
  command = 125, -- MSP_GET_SERVO_CONFIG
  simulatorResponse = { 220,5, 12,254, 244,1, 244,1, 244,1, 77,1, 0,0, 0,0 },
}

local SERVO_CONFIG_BYTES = 16

local function read_u16_le(buf, pos)
  local lo = tonumber(buf[pos]) or 0
  local hi = tonumber(buf[pos + 1]) or 0
  return lo + hi * 256
end

local function read_s16_le(buf, pos)
  local val = read_u16_le(buf, pos)
  if val >= 32768 then val = val - 65536 end
  return val
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < SERVO_CONFIG_BYTES then return nil end

  return {
    servo_config = {
      mid = read_u16_le(buf, 1),
      min = read_s16_le(buf, 3),
      max = read_s16_le(buf, 5),
      rneg = read_u16_le(buf, 7),
      rpos = read_u16_le(buf, 9),
      rate = read_u16_le(buf, 11),
      speed = read_u16_le(buf, 13),
      flags = read_u16_le(buf, 15)
    }
  }
end

return Api
