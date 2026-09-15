-- EdgeTX MSP API: RX_MAP (ported)

local Api = {
  command = 64,
  writeCommand = 65
}

local FIELD_SPEC = {
  {"aileron", "U8"}, {"elevator", "U8"}, {"rudder", "U8"}, {"collective", "U8"},
  {"throttle", "U8"}, {"aux1", "U8"}, {"aux2", "U8"}, {"aux3", "U8"}
}

local SIM_RESPONSE = {0,1,2,3,4,5,6,7}

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local parsed = {}
  for i = 1, 8 do
    parsed[FIELD_SPEC[i][1]] = tonumber(buf[i]) or 0
  end
  return parsed
end

function Api.buildWritePayload(data)
  local payload = {}
  for i = 1, 8 do
    local name = FIELD_SPEC[i][1]
    payload[#payload+1] = tonumber(data and data[name]) or 0
  end
  return payload
end

return Api
