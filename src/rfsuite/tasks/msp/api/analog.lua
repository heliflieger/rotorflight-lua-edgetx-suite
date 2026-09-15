-- EdgeTX MSP API: ANALOG (battery and link readings from the flight controller)
--
-- Nine bytes, and the voltage appears twice: byte 1 is the legacy 0.1 V reading kept for older
-- consumers, bytes 8-9 the 0.01 V one that should be used. Values are passed on exactly as the
-- firmware sends them, with the scale of each stated beside it, because the display each caller
-- wants differs and rounding here would take that decision away from it.
--
-- What the readings mean depends on the meter sources the battery configuration names: with the
-- source set to ADC these are the board's own measurements, and only with it set to the ESC do
-- they come from there. The reading alone does not say which.

local Api = {
  command = 110, -- MSP_ANALOG
  simulatorResponse = {
    248,     -- legacy_voltage 24.8 V
    0, 0,    -- mah_drawn       0 mAh
    255, 3,  -- rssi         1023
    50, 0,   -- current       0.50 A
    176, 9   -- voltage      24.80 V
  }
}

local ANALOG_BYTES = 9

local function parseU16(lo, hi)
  return ((tonumber(hi) or 0) << 8) | (tonumber(lo) or 0)
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < ANALOG_BYTES then return nil end

  return {
    legacy_voltage = tonumber(buf[1]) or 0, -- 0.1 V, saturates at 25.5 V
    mah_drawn = parseU16(buf[2], buf[3]),   -- mAh
    rssi = parseU16(buf[4], buf[5]),        -- 0 .. 1023
    current = parseU16(buf[6], buf[7]),     -- 0.01 A
    voltage = parseU16(buf[8], buf[9])      -- 0.01 V
  }
end

return Api
