-- EdgeTX MSP API: SMARTFUEL_CONFIG (ported from Ethos)
--[[
  Copyright (C) 2026 Rotorflight Project
  GPLv3 - https://www.gnu.org/licenses/gpl-3.0.en.html
]]

local Api = {
  command = 0x4000,
  writeCommand = 0x4001
}

local modeTable = {
    "OFF (LOCAL)",
    "VOLTAGE",
    "CURRENT",
    "COMBINED"
}

local FIELD_SPEC = {
    {"smartfuel_mode", "U8", 0, 3, 0, nil, nil, nil, nil, nil, modeTable},
    {"voltage_drop_rate", "U8", 0, 250, 10, "mV/s"},
    {"charge_drop_rate", "U8", 0, 250, 50, "%/s", 2, 100, 1},
    {"sag_gain", "U8", 0, 100, 40, "%"}
}

local SIM_RESPONSE = {0, 10, 50, 40}

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
  if type(buf) == "table" then
    local parsed = {}
    parsed.smartfuel_mode = tonumber(buf[1]) or 0
    parsed.voltage_drop_rate = tonumber(buf[2]) or 0
    parsed.charge_drop_rate = tonumber(buf[3]) or 0
    parsed.sag_gain = tonumber(buf[4]) or 0
    return parsed
  end
  local def = {}
  for _, e in ipairs(FIELD_SPEC) do def[e[1]] = e[5] or 0 end
  return def
end

function Api.buildWritePayload(data)
  local payload = {}
  payload[1] = tonumber(data.smartfuel_mode) or 0
  payload[2] = tonumber(data.voltage_drop_rate) or 0
  payload[3] = tonumber(data.charge_drop_rate) or 0
  payload[4] = tonumber(data.sag_gain) or 0
  return payload
end

return Api
