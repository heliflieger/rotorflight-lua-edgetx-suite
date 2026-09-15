-- Ported ESC_PARAMETERS_FLYROTOR -> esc_parameters_flyrotor.lua
local Api = {
    command = 217,
    writeCommand = 218,
    mspSignature = 0x73,
    mspHeaderBytes = 2
}

local FIELD_SPEC = {
    {"esc_signature", "U8"},
    {"esc_command", "U8"},
    {"esc_type", "U8"},
    {"esc_model", "U16", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "big"},
    {"esc_sn", "U64"},
    {"esc_iap", "U24"},
    {"esc_fw", "U24"},
    {"esc_hardware", "U8"},
    {"throttle_min", "U16", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "big"},
    {"throttle_max", "U16", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "big"},
    {"esc_mode", "U8"},
    {"cell_count", "U8", 4, 14, 6},
    {"low_voltage_protection", "U8", 28, 38, 30},
    {"temperature_protection", "U8", 50, 135, 125},
    {"bec_voltage", "U8"},
    {"electrical_angle", "U8"},
    {"motor_direction", "U8"},
    {"starting_torque", "U8", 1, 15, 3},
    {"response_speed", "U8", 1, 15, 5},
    {"buzzer_volume", "U8", 1, 5, 2},
    {"current_gain", "S8"},
    {"fan_control", "U8"},
    {"soft_start", "U8"},
    {"auto_restart_time", "U8"},
    {"restart_acc", "U8"},
    {"gov_p", "U8"},
    {"gov_i", "U8"}
}

local SIM_RESPONSE = {
    115, -- esc_signature
    0, -- esc_command
    0, -- esc_type
    1, 24, -- esc_model (big)
    231, 79, 190, 216, 78, 29, 169, 244, -- esc_sn (U64, little-order)
    1, 0, 0, -- esc_iap (U24)
    1, 0, 1, -- esc_fw (U24)
    0, -- esc_hardware
    4, 76, -- throttle_min (big)
    7, 148, -- throttle_max (big)
    0, -- esc_mode
    6, -- cell_count
    30, -- low_voltage_protection
    125, -- temperature_protection
    1, -- bec_voltage
    0, -- electrical_angle
    0, -- motor_direction
    3, -- starting_torque
    5, -- response_speed
    1, -- buzzer_volume
    20, -- current_gain
    0, -- fan_control
    15, -- soft_start
    15, -- auto_restart_time
    15, -- restart_acc
    45, -- gov_p
    35  -- gov_i
}

local TYPE_LEN = {
    U8 = 1, S8 = 1, U16 = 2, S16 = 2, U24 = 3, U32 = 4, U64 = 8, U120 = 15, U128 = 16
}

-- pairs, not ipairs. The flag is the FOURTEENTH element of a field table whose elements 3 to
-- 13 are nil, and ipairs stops at the first hole -- so with ipairs this returned false for
-- every field, including the three that carry the flag.
local function has_big_flag(field)
    for _, v in pairs(field) do if v == "big" then return true end end
    return false
end

local function read_unsigned(buf, pos, len, big)
    local v = 0
    if big then
        for i = 0, len - 1 do v = v * 256 + (tonumber(buf[pos + i]) or 0) end
    else
        local mul = 1
        for i = 0, len - 1 do v = v + (tonumber(buf[pos + i]) or 0) * mul; mul = mul * 256 end
    end
    return v
end

local function read_signed(buf, pos, len, big)
    local v = read_unsigned(buf, pos, len, big)
    local max = 2 ^ (len * 8)
    local half = 2 ^ (len * 8 - 1)
    if v >= half then v = v - max end
    return v
end

local function bytes_to_string(buf, pos, len)
    local chars = {}
    for i = 0, len - 1 do chars[#chars+1] = string.char(tonumber(buf[pos + i]) or 0) end
    local s = table.concat(chars)
    s = string.gsub(s, "%z+$", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function pack_unsigned(v, len, big)
    v = tonumber(v) or 0
    local out = {}
    if big then
        for i = len - 1, 0, -1 do out[#out+1] = math.floor(v / (256 ^ i)) % 256 end
    else
        for i = 0, len - 1 do out[#out+1] = math.floor(v / (256 ^ i)) % 256 end
    end
    return out
end

-- EdgeTX builds Lua with LUA_32BITS, so a 64-bit value has no exact representation: reading
-- one into a number and writing it back does not round-trip. The only 64-bit field here is
-- an identifier that nothing displays or edits, so it is carried as the bytes it arrived as
-- and written back untouched.
local function raw_bytes(buf, pos, len)
    local out = {}
    for i = 0, len - 1 do out[#out+1] = (tonumber(buf[pos + i]) or 0) & 0xFF end
    return out
end

local function pack_string(s, len)
    s = s or ""
    local out = {}
    for i = 1, len do out[#out+1] = string.byte(s, i) or 0 end
    return out
end

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
    if type(buf) ~= "table" then return nil end
    local pos = 1
    local out = {}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]
        local len = TYPE_LEN[typ] or 1
        local big = has_big_flag(f)
        if typ == "U64" then
            out[name] = raw_bytes(buf, pos, len)
            pos = pos + len
        elseif typ == "U120" or typ == "U128" then
            out[name] = bytes_to_string(buf, pos, len)
            pos = pos + len
        elseif typ == "S8" then
            out[name] = read_signed(buf, pos, len, big); pos = pos + len
        elseif string.sub(typ, 1, 1) == "S" then
            out[name] = read_signed(buf, pos, len, big); pos = pos + len
        else
            out[name] = read_unsigned(buf, pos, len, big); pos = pos + len
        end
    end
    return out
end

function Api.buildWritePayload(data)
    data = data or {}
    local payload = {}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]
        local len = TYPE_LEN[typ] or 1
        local big = has_big_flag(f)
        local v = data[name]
        if typ == "U64" then
            local bytes = v
            if type(bytes) ~= "table" or #bytes ~= len then bytes = pack_unsigned(0, len, big) end
            for i = 1, len do payload[#payload+1] = bytes[i] or 0 end
        elseif typ == "U120" or typ == "U128" then
            local bytes = pack_string(v, len)
            for _, b in ipairs(bytes) do payload[#payload+1] = b end
        else
            local bytes = pack_unsigned(v or 0, len, big)
            for _, b in ipairs(bytes) do payload[#payload+1] = b end
        end
    end
    return payload
end

return Api
