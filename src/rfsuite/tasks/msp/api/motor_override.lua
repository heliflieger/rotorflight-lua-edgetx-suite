-- EdgeTX MSP API: motor_override (ported from Ethos)

local Api = {
  command = 194,
  writeCommand = 195,
  simulatorResponse = {0,0, 0,0, 0,0, 0,0}
}

--- The firmware's own limits, so a caller does not have to restate them.
---
--- `MOTOR_OVERRIDE_OFF` is 0 and the range is symmetric around it
--- (`src/main/flight/motors.h`). The unit is per-mille of full throttle, which is why a
--- percentage shown to a pilot is a tenth of the value on the wire.
Api.OVERRIDE_OFF = 0
Api.OVERRIDE_MIN = -1000
Api.OVERRIDE_MAX = 1000

local function u16_from_bytes(lo, hi)
  lo = tonumber(lo) or 0
  hi = tonumber(hi) or 0
  return ((hi & 0xFF) << 8) | (lo & 0xFF)
end

local function s16_from_bytes(lo, hi)
  local v = u16_from_bytes(lo, hi)
  if v >= 0x8000 then
    return v - 0x10000
  end
  return v
end

local function bytes_from_u16(v)
  v = math.floor(tonumber(v) or 0) & 0xFFFF
  return v & 0xFF, (v >> 8) & 0xFF
end

--- MSP_MOTOR_OVERRIDE answers one value per motor, `MAX_SUPPORTED_MOTORS` of them
--- (`src/main/msp/msp.c`, `MSP_MOTOR_OVERRIDE`), and a motor the board does not have answers
--- 0. The values are `int16_t` and a reverse override is negative, so they are read signed:
--- unsigned, -100 comes back as 65436.
function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  if #buf < 8 then return nil end
  local out = {}
  local i = 1
  for idx = 1, 4 do
    out["motor_"..idx] = s16_from_bytes(buf[i], buf[i+1]); i = i + 2
  end
  return out
end

--- MSP_SET_MOTOR_OVERRIDE carries ONE motor: `u8 index, u16 value`
--- (`src/main/msp/msp.c`, `MSP_SET_MOTOR_OVERRIDE`), which is also what the Configurator
--- sends. The write is therefore not the mirror image of the read, and a payload shaped like
--- the read would be taken as motor `value & 0xFF` at whatever the next two bytes say.
---
--- `index` is 0-based. The firmware ignores the write while the craft is armed and drops the
--- override again one second after the last one arrives, so a caller that wants a motor to
--- keep turning has to keep writing.
function Api.buildWritePayload(data)
  data = data or {}
  local index = math.floor(tonumber(data.index) or 0) & 0xFF
  local lo, hi = bytes_from_u16(tonumber(data.value) or Api.OVERRIDE_OFF)
  return { index, lo, hi }
end

return Api
