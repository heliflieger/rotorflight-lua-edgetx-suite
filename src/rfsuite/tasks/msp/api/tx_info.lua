-- EdgeTX MSP API: TX_INFO (ported)

local Api = {
  command = 187,
  writeCommand = 186
}

local FIELD_SPEC = {
  {"rssi_source", "U8"},
  {"rtc_datetime_set", "U8"}
}

local WRITE_FIELD_SPEC = {
  {"rssi", "U8"}
}

local SIM_RESPONSE = {0,0}

Api.fields = FIELD_SPEC
Api.writeFields = WRITE_FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  return { rssi_source = tonumber(buf[1]) or 0, rtc_datetime_set = tonumber(buf[2]) or 0 }
end

function Api.buildWritePayload(data)
  return { tonumber(data and data.rssi) or 0 }
end

return Api
