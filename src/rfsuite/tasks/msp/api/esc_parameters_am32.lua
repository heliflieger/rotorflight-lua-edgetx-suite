-- EdgeTX MSP API: ESC_PARAMETERS_AM32
-- Ported with proper scaling/normalization functions

local Api = {
  command = 217, -- MSP_ESC_PARAMETERS_AM32
  writeCommand = 218, -- MSP_SET_ESC_PARAMETERS_AM32
  simulatorResponse = {
    194,64,1,3,1,2,19,50,1,0,10,100,0,100,0,255,255,255,255,0,0,0,0,0,1,26,16,50,12,24,0,1,5,0,128,128,128,50,0,50,0,0,10,10,5,145,102,7,1,0
  },
}

local function clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

local function normalizeTimingAdvance(raw)
  if raw == nil then return 0, "legacy" end
  if raw >= 10 and raw <= 42 then
    return clamp(math.floor((raw - 10) / 8 + 0.5), 0, 3), "new"
  end
  return clamp(math.floor(raw + 0.5), 0, 3), "legacy"
end

local function encodeTimingAdvance(value, encoding, raw)
  local n = clamp(math.floor((value or 0) + 0.5), 0, 3)
  if raw ~= nil and select(1, normalizeTimingAdvance(raw)) == n then
    return raw  -- not edited: the ESC keeps the byte it had
  end
  if encoding == "new" then
    return 10 + (n * 8)
  end
  return n
end

local function normalizeMotorKv(raw)
  if raw == nil then return 0 end
  return (raw * 40) + 20
end

local function encodeMotorKv(kv)
  if kv == nil then return 0 end
  return clamp(math.floor(((kv - 20) / 40) + 0.5), 0, 255)
end

local function normalizeServoLow(raw)
  if raw == nil then return 0 end
  return (raw * 2) + 750
end

local function encodeServoLow(value)
  if value == nil then return 0 end
  return clamp(math.floor(((value - 750) / 2) + 0.5), 0, 255)
end

local function normalizeServoHigh(raw)
  if raw == nil then return 0 end
  return (raw * 2) + 1750
end

local function encodeServoHigh(value)
  if value == nil then return 0 end
  return clamp(math.floor(((value - 1750) / 2) + 0.5), 0, 255)
end

local function normalizeServoNeutral(raw)
  if raw == nil then return 0 end
  return raw + 1374
end

local function encodeServoNeutral(value)
  if value == nil then return 0 end
  return clamp(math.floor((value - 1374) + 0.5), 0, 255)
end

local function normalizeLowVoltageThreshold(raw)
  if raw == nil then return 0 end
  return raw + 250
end

local function encodeLowVoltageThreshold(value)
  if value == nil then return 0 end
  return clamp(math.floor((value - 250) + 0.5), 0, 255)
end

local function normalizeCurrentLimit(raw)
  if raw == nil then return 0 end
  return raw * 2
end

local function encodeCurrentLimit(value)
  if value == nil then return 0 end
  return clamp(math.floor((value / 2) + 0.5), 0, 255)
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < 50 then return nil end
  local timingAdvance, timingAdvanceEncoding = normalizeTimingAdvance(buf[26])
  return {
    esc_signature = buf[1] or 0,
    esc_command = buf[2] or 0,
    reserved_0 = buf[3] or 0,
    eeprom_version = buf[4] or 0,
    reserved_1 = buf[5] or 0,
    version_major = buf[6] or 0,
    version_minor = buf[7] or 0,
    max_ramp = buf[8] or 0,
    minimum_duty_cycle = buf[9] or 0,
    disable_stick_calibration = buf[10] or 0,
    absolute_voltage_cutoff = buf[11] or 0,
    current_p = buf[12] or 0,
    current_i = buf[13] or 0,
    current_d = buf[14] or 0,
    active_brake_power = buf[15] or 0,
    reserved_eeprom_3_0 = buf[16] or 0,
    reserved_eeprom_3_1 = buf[17] or 0,
    reserved_eeprom_3_2 = buf[18] or 0,
    reserved_eeprom_3_3 = buf[19] or 0,
    motor_direction = buf[20] or 0,
    bidirectional_mode = buf[21] or 0,
    sinusoidal_startup = buf[22] or 0,
    complementary_pwm = buf[23] or 0,
    variable_pwm_frequency = buf[24] or 0,
    stuck_rotor_protection = buf[25] or 0,
    timing_advance = timingAdvance,
    timing_advance_encoding = timingAdvanceEncoding,
    timing_advance_raw = buf[26],
    pwm_frequency = buf[27] or 0,
    startup_power = buf[28] or 0,
    motor_kv = normalizeMotorKv(buf[29]),
    motor_poles = buf[30] or 0,
    brake_on_stop = buf[31] or 0,
    stall_protection = buf[32] or 0,
    beep_volume = buf[33] or 0,
    interval_telemetry = buf[34] or 0,
    servo_low_threshold = normalizeServoLow(buf[35]),
    servo_high_threshold = normalizeServoHigh(buf[36]),
    servo_neutral = normalizeServoNeutral(buf[37]),
    servo_dead_band = buf[38] or 0,
    low_voltage_cutoff = buf[39] or 0,
    low_voltage_threshold = normalizeLowVoltageThreshold(buf[40]),
    rc_car_reversing = buf[41] or 0,
    use_hall_sensors = buf[42] or 0,
    sine_mode_range = buf[43] or 0,
    brake_strength = buf[44] or 0,
    running_brake_level = buf[45] or 0,
    temperature_limit = buf[46] or 0,
    current_limit = normalizeCurrentLimit(buf[47]),
    sine_mode_power = buf[48] or 0,
    esc_protocol = buf[49] or 0,
    auto_advance = buf[50] or 0
  }
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[1] = tonumber(data.esc_signature) or 0
  payload[2] = tonumber(data.esc_command) or 0
  payload[3] = tonumber(data.reserved_0) or 0
  payload[4] = tonumber(data.eeprom_version) or 0
  payload[5] = tonumber(data.reserved_1) or 0
  payload[6] = tonumber(data.version_major) or 0
  payload[7] = tonumber(data.version_minor) or 0
  payload[8] = tonumber(data.max_ramp) or 0
  payload[9] = tonumber(data.minimum_duty_cycle) or 0
  payload[10] = tonumber(data.disable_stick_calibration) or 0
  payload[11] = tonumber(data.absolute_voltage_cutoff) or 0
  payload[12] = tonumber(data.current_p) or 0
  payload[13] = tonumber(data.current_i) or 0
  payload[14] = tonumber(data.current_d) or 0
  payload[15] = tonumber(data.active_brake_power) or 0
  payload[16] = tonumber(data.reserved_eeprom_3_0) or 0
  payload[17] = tonumber(data.reserved_eeprom_3_1) or 0
  payload[18] = tonumber(data.reserved_eeprom_3_2) or 0
  payload[19] = tonumber(data.reserved_eeprom_3_3) or 0
  payload[20] = tonumber(data.motor_direction) or 0
  payload[21] = tonumber(data.bidirectional_mode) or 0
  payload[22] = tonumber(data.sinusoidal_startup) or 0
  payload[23] = tonumber(data.complementary_pwm) or 0
  payload[24] = tonumber(data.variable_pwm_frequency) or 0
  payload[25] = tonumber(data.stuck_rotor_protection) or 0
  payload[26] = encodeTimingAdvance(data.timing_advance, data.timing_advance_encoding, data.timing_advance_raw)
  payload[27] = tonumber(data.pwm_frequency) or 0
  payload[28] = tonumber(data.startup_power) or 0
  payload[29] = encodeMotorKv(data.motor_kv)
  payload[30] = tonumber(data.motor_poles) or 0
  payload[31] = tonumber(data.brake_on_stop) or 0
  payload[32] = tonumber(data.stall_protection) or 0
  payload[33] = tonumber(data.beep_volume) or 0
  payload[34] = tonumber(data.interval_telemetry) or 0
  payload[35] = encodeServoLow(data.servo_low_threshold)
  payload[36] = encodeServoHigh(data.servo_high_threshold)
  payload[37] = encodeServoNeutral(data.servo_neutral)
  payload[38] = tonumber(data.servo_dead_band) or 0
  payload[39] = tonumber(data.low_voltage_cutoff) or 0
  payload[40] = encodeLowVoltageThreshold(data.low_voltage_threshold)
  payload[41] = tonumber(data.rc_car_reversing) or 0
  payload[42] = tonumber(data.use_hall_sensors) or 0
  payload[43] = tonumber(data.sine_mode_range) or 0
  payload[44] = tonumber(data.brake_strength) or 0
  payload[45] = tonumber(data.running_brake_level) or 0
  payload[46] = tonumber(data.temperature_limit) or 0
  payload[47] = encodeCurrentLimit(data.current_limit)
  payload[48] = tonumber(data.sine_mode_power) or 0
  payload[49] = tonumber(data.esc_protocol) or 0
  payload[50] = tonumber(data.auto_advance) or 0
  return payload
end

return Api
