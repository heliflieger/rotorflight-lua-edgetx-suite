-- EdgeTX MSP API: STATUS (ported)

local Api = {
  command = 101
}

local FIELD_SPEC = {
  {"task_delta_time_pid", "U16"},
  {"task_delta_time_gyro", "U16"},
  {"sensor_status", "U16"},
  {"flight_mode_flags", "U32"},
  {"profile_number", "U8"},
  {"max_real_time_load", "U16"},
  {"average_cpu_load", "U16"},
  {"extra_flight_mode_flags_count", "U8"},
  {"arming_disable_flags_count", "U8"},
  {"arming_disable_flags", "U32"},
  {"reboot_required", "U8"},
  {"configuration_state", "U8"},
  {"current_pid_profile_index", "U8"},
  {"pid_profile_count", "U8"},
  {"current_control_rate_profile_index", "U8"},
  {"control_rate_profile_count", "U8"},
  {"motor_count", "U8"},
  {"servo_count", "U8"},
  {"gyro_detection_flags", "U8"}
}

local SIM_RESPONSE = {252,1, 127,0, 35,0, 0,0,0,0, 0, 122,1, 182,0, 0, 0, 0,0,0,0,0, 2, 0, 5, 6, 1, 4, 1, 4, 1}

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

local function read_u16_le(buf, pos)
  local lo = tonumber(buf[pos]) or 0
  local hi = tonumber(buf[pos+1]) or 0
  return lo + hi * 256
end

local function read_u32_le(buf, pos)
  local b1 = tonumber(buf[pos]) or 0
  local b2 = tonumber(buf[pos+1]) or 0
  local b3 = tonumber(buf[pos+2]) or 0
  local b4 = tonumber(buf[pos+3]) or 0
  return b1 + b2*256 + b3*65536 + b4*16777216
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local parsed = {}
  local pos = 1
  parsed.task_delta_time_pid = read_u16_le(buf, pos); pos = pos + 2
  parsed.task_delta_time_gyro = read_u16_le(buf, pos); pos = pos + 2
  parsed.sensor_status = read_u16_le(buf, pos); pos = pos + 2
  parsed.flight_mode_flags = read_u32_le(buf, pos); pos = pos + 4
  parsed.profile_number = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.max_real_time_load = read_u16_le(buf, pos); pos = pos + 2
  parsed.average_cpu_load = read_u16_le(buf, pos); pos = pos + 2
  parsed.extra_flight_mode_flags_count = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.arming_disable_flags_count = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.arming_disable_flags = read_u32_le(buf, pos); pos = pos + 4
  parsed.reboot_required = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.configuration_state = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.current_pid_profile_index = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.pid_profile_count = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.current_control_rate_profile_index = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.control_rate_profile_count = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.motor_count = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.servo_count = tonumber(buf[pos]) or 0; pos = pos + 1
  parsed.gyro_detection_flags = tonumber(buf[pos]) or 0; pos = pos + 1
  return parsed
end

return Api
