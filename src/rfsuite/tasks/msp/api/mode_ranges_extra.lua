-- EdgeTX MSP API: mode_ranges_extra (ported from Ethos)

local Api = {
  command = 238,
  simulatorResponse = (function()
    local response = {20, 1, 0, 0}
    for _ = 1, 19 do
      response[#response + 1] = 0
      response[#response + 1] = 0
      response[#response + 1] = 0
    end
    return response
  end)()
}

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local i = 1
  local parsed = {}
  local extras = {}
  local count = tonumber(buf[i]) or 0; i = i + 1
  for _ = 1, count do
    local modeId = tonumber(buf[i]); i = i + 1
    local modeLogic = tonumber(buf[i]); i = i + 1
    local linkedTo = tonumber(buf[i]); i = i + 1
    if modeId == nil or modeLogic == nil or linkedTo == nil then break end
    extras[#extras + 1] = {id = modeId, modeLogic = modeLogic, linkedTo = linkedTo}
  end
  return { mode_ranges_extra = extras }
end

return Api
