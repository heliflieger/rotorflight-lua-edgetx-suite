-- EdgeTX API: FLIGHT_STATS_INI (minimal port)

local Api = {}

local FIELD_SPEC = {
  {"flightcount", "U32", 0, 1000000000, 0},
  {"lastflighttime", "U32", 0, 1000000000, 0, "s"},
  {"totalflighttime", "U32", 0, 1000000000, 0, "s"}
}

Api.fields = FIELD_SPEC

local function defaults()
  local t = {}
  for _, e in ipairs(FIELD_SPEC) do t[e[1]] = e[5] or 0 end
  return t
end

function Api.parse(buf)
  -- INI backed in Ethos; here provide defaults or parse simple byte buffer if given
  if type(buf) == "table" then
    local parsed = {}
    local pos = 1
    local function read_u32()
      local b1 = tonumber(buf[pos]) or 0
      local b2 = tonumber(buf[pos+1]) or 0
      local b3 = tonumber(buf[pos+2]) or 0
      local b4 = tonumber(buf[pos+3]) or 0
      pos = pos + 4
      return b1 + b2*256 + b3*65536 + b4*16777216
    end
    parsed.flightcount = read_u32()
    parsed.lastflighttime = read_u32()
    parsed.totalflighttime = read_u32()
    return parsed
  end
  return defaults()
end

function Api.buildWritePayload(payloadData)
  -- INI backed write in Ethos; provide placeholder empty payload
  return {}
end

return Api
