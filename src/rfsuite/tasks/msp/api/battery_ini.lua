-- EdgeTX API: BATTERY_INI (minimal port)

local Api = {}

local FIELD_SPEC = {
    {"smartfuel_model_type", "U8", 0, 2, 0},
    {"smartfuel_source", "U8", 0, 2, 0},
    {"stabilize_delay", "U16", 0, 10000, 1500, "s", 1, 1000, 1},
    {"stable_window", "U16", 0, 100, 15, "V", 2, 100, 1},
    {"voltage_fall_limit", "U16", 0, 100, 5, "V/s", 2, 100, 1},
    {"fuel_drop_rate", "U16", 0, 500, 10, "%/s", 1, 10, 1},
    {"fuel_rise_rate", "U16", 0, 500, 2, "%/s", 1, 10, 1},
    {"sag_multiplier_percent", "U16", 0, 200, 70, "x", 2, 100, 1},
    {"alert_type", "U8", 0, 2, 0},
    {"becalertvalue", "U8", 30, 140, 6.5, "V", 1, 10, 1},
    {"rxalertvalue", "U8", 30, 140, 7.5, "V", 1, 10, 1},
    {"flighttime", "U8", 0, 3600, 300, "s", nil, nil, 1}
}

Api.fields = FIELD_SPEC

local function defaults()
  local t = {}
  for _, entry in ipairs(FIELD_SPEC) do
    local name = entry[1]
    local def = entry[5]
    if name == "becalertvalue" or name == "rxalertvalue" then
      if def ~= nil then t[name] = def * 10 else t[name] = 0 end
    else
      t[name] = def or 0
    end
  end
  return t
end

function Api.parse(buf)
  -- This API is INI-backed in Ethos; port provides defaults for simulator/UI.
  if type(buf) == "table" then
    -- attempt to interpret sequential byte buffer if provided
    local parsed = {}
    local pos = 1
    for _, entry in ipairs(FIELD_SPEC) do
      local name, typ = entry[1], entry[2]
      if typ == "U8" then
        parsed[name] = tonumber(buf[pos]) or 0
        pos = pos + 1
      elseif typ == "U16" then
        local lo = tonumber(buf[pos]) or 0
        local hi = tonumber(buf[pos+1]) or 0
        parsed[name] = lo + hi * 256
        pos = pos + 2
      else
        parsed[name] = tonumber(buf[pos]) or 0
        pos = pos + 1
      end
      if name == "becalertvalue" or name == "rxalertvalue" then
        if parsed[name] then parsed[name] = parsed[name] end
      end
    end
    return parsed
  end

  return defaults()
end

function Api.buildWritePayload(payloadData)
  -- INI-backed write in Ethos; here we return an empty payload placeholder.
  return {}
end

return Api
