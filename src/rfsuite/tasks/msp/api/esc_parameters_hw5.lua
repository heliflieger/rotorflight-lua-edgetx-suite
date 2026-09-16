-- Ported ESC_PARAMETERS_HW5 -> esc_parameters_hw5.lua
local Api = {
    command = 217,
    writeCommand = 218,
    mspSignature = 0xFD,
    mspHeaderBytes = 2
}

local VALUE_FIELDS = {
    "flight_mode",
    "lipo_cell_count",
    "cutoff_type",
    "cutoff_voltage",
    "bec_voltage",
    "startup_time",
    "response_time",
    "gov_p_gain",
    "gov_i_gain",
    "auto_restart",
    "restart_time",
    "brake_type",
    "brake_force",
    "timing",
    "rotation",
    "active_freewheel",
    "startup_power",
}

local DEFAULT_LAYOUT = {
    flight_mode = 1,
    lipo_cell_count = 2,
    cutoff_type = 3,
    cutoff_voltage = 4,
    bec_voltage = 5,
    startup_time = 6,
    gov_p_gain = 7,
    gov_i_gain = 8,
    auto_restart = 9,
    restart_time = 10,
    brake_type = 11,
    brake_force = 12,
    timing = 13,
    rotation = 14,
    active_freewheel = 15,
    startup_power = 16,
}

local HW1132_LAYOUT = {
    lipo_cell_count = 1,
    cutoff_type = 2,
    cutoff_voltage = 3,
    bec_voltage = 4,
    response_time = 5,
    timing = 6,
    rotation = 7,
    active_freewheel = 8,
    startup_power = 9,
}

local HW1128_LAYOUT = {
    lipo_cell_count = 1,
    cutoff_type = 2,
    cutoff_voltage = 3,
    brake_type = 5,
    brake_force = 6,
    timing = 7,
    rotation = 8,
    active_freewheel = 9,
    startup_power = 10,
}

local OPTO_LAYOUT = {
    flight_mode = 1,
    lipo_cell_count = 2,
    cutoff_type = 3,
    cutoff_voltage = 4,
    startup_time = 5,
    gov_p_gain = 6,
    gov_i_gain = 7,
    auto_restart = 8,
    restart_time = 9,
    brake_type = 10,
    brake_force = 11,
    timing = 12,
    rotation = 13,
    active_freewheel = 14,
    startup_power = 15,
}

local PROFILES = {
    default = { layout = DEFAULT_LAYOUT },
    ["HW1104_V100456NB"] = { layout = DEFAULT_LAYOUT },
    ["HW1106_V100456NB"] = { layout = DEFAULT_LAYOUT },
    ["HW1106_V200456NB"] = { layout = DEFAULT_LAYOUT },
    ["HW1106_V300456NB"] = { layout = DEFAULT_LAYOUT },
    ["HW1121_V100456NB"] = { layout = DEFAULT_LAYOUT },
    ["HW1121_V00456NB"] = { layout = DEFAULT_LAYOUT },
    ["HW1132_V100456NB"] = { layout = HW1132_LAYOUT },
    ["HW198_V1.00456NB"] = { layout = DEFAULT_LAYOUT },
    HW1128 = { layout = HW1128_LAYOUT },
    OPTO = { layout = OPTO_LAYOUT },
}

local function trim(value)
    if not value then return "" end
    local text = string.gsub(tostring(value), "%z.*", "")
    return string.match(text, "^%s*(.-)%s*$") or ""
end

local function startsWith(value, prefix)
    return string.sub(value or "", 1, #prefix) == prefix
end

local function selectProfile(hardwareVersion, escType, firmwareVersion)
    local hardware = trim(hardwareVersion)
    local esc = string.upper(trim(escType))
    local firmware = string.upper(trim(firmwareVersion))

    if string.find(esc, "OPTO", 1, true) or string.find(firmware, "OPTO", 1, true) then
        return PROFILES.OPTO
    end

    if PROFILES[hardware] then
        return PROFILES[hardware]
    end

    local hwUpper = string.upper(hardware)
    if startsWith(hwUpper, "HW1132_") or startsWith(hwUpper, "HW1132") then
        return PROFILES["HW1132_V100456NB"]
    elseif startsWith(hwUpper, "HW1128_") or startsWith(hwUpper, "HW1128") then
        return PROFILES.HW1128
    elseif startsWith(hwUpper, "HW1121_") or startsWith(hwUpper, "HW1121") then
        return PROFILES["HW1121_V100456NB"]
    end

    return PROFILES.default
end

local function bytes_to_string(buf, pos, len)
    local chars = {}
    for i = 0, len - 1 do
        local b = tonumber(buf[pos + i]) or 0
        if b ~= 0 then
            chars[#chars + 1] = string.char(b)
        end
    end
    local s = table.concat(chars)
    s = string.gsub(s, "%z+$", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function pack_string(s, len)
    s = s or ""
    local out = {}
    for i = 1, len do
        out[#out + 1] = string.byte(s, i) or 0
    end
    return out
end

-- The device-info block has to go back BYTE-IDENTICAL, and the string round trip cannot do
-- that: bytes_to_string drops every 0x00 and trims trailing whitespace, pack_string pads with
-- 0x00. A space-padded field therefore comes back NUL-padded, and an embedded 0x00 shifts the
-- whole field left. So the bytes are kept as they arrived and written back unchanged.
local function raw_bytes(buf, pos, len)
    local out = {}
    for i = 0, len - 1 do
        out[#out + 1] = (tonumber(buf[pos + i]) or 0) & 0xFF
    end
    return out
end

-- The bytes as they were read where the block was read, and the encoded string otherwise.
local function string_bytes(data, name, len)
    local raw = data.raw_strings and data.raw_strings[name]
    if type(raw) == "table" and #raw == len then
        return raw
    end
    return pack_string(data[name] or "", len)
end

Api.selectProfile = selectProfile
Api.VALUE_FIELDS = VALUE_FIELDS
Api.DEFAULT_LAYOUT = DEFAULT_LAYOUT
Api.HW1132_LAYOUT = HW1132_LAYOUT
Api.HW1128_LAYOUT = HW1128_LAYOUT
Api.OPTO_LAYOUT = OPTO_LAYOUT
Api.PROFILES = PROFILES

Api.simulatorResponse = {
    253, -- esc_signature
    0,   -- command
    32, 32, 32, 80, 76, 45, 48, 52, 46, 49, 46, 48, 50, 32, 32, 32, -- firmware_version (16 bytes)
    72, 87, 49, 49, 48, 54, 95, 86, 49, 48, 48, 52, 53, 54, 78, 66, -- hardware_version (16 bytes)
    80, 108, 97, 116, 105, 110, 117, 109, 95, 86, 53, 32, 32, 32, 32, 32, -- esc_type2 (16 bytes)
    80, 108, 97, 116, 105, 110, 117, 109, 32, 86, 53, 32, 32, 32, 32,     -- esc_type (15 bytes)
    0,  -- item 1: flight_mode
    0,  -- item 2: lipo_cell_count
    0,  -- item 3: cutoff_type
    3,  -- item 4: cutoff_voltage
    0,  -- item 5: bec_voltage
    11, -- item 6: startup_time (raw 11 -> 15s)
    6,  -- item 7: gov_p_gain
    5,  -- item 8: gov_i_gain
    25, -- item 9: auto_restart
    1,  -- item 10: restart_time
    0,  -- item 11: brake_type
    0,  -- item 12: brake_force
    24, -- item 13: timing
    0,  -- item 14: rotation
    0,  -- item 15: active_freewheel (0 = Enabled)
    2   -- item 16: startup_power
}

function Api.parse(buf)
    if type(buf) ~= "table" or #buf < 2 then return nil end
    local signature = tonumber(buf[1]) or 0
    if signature ~= 253 then
        return nil
    end

    local out = {
        esc_signature = signature,
        command = tonumber(buf[2]) or 0,
        firmware_version = bytes_to_string(buf, 3, 16),
        hardware_version = bytes_to_string(buf, 19, 16),
        esc_type2 = bytes_to_string(buf, 35, 16),
        esc_type = bytes_to_string(buf, 51, 15),
        raw_strings = {
            firmware_version = raw_bytes(buf, 3, 16),
            hardware_version = raw_bytes(buf, 19, 16),
            esc_type2        = raw_bytes(buf, 35, 16),
            esc_type         = raw_bytes(buf, 51, 15),
        },
    }
    out.model_name = trim((out.esc_type2 or "") .. " " .. (out.esc_type or ""))

    local itemBytes = {}
    for i = 1, 16 do
        itemBytes[i] = tonumber(buf[65 + i]) or 0
    end
    out._itemBytes = itemBytes

    local profile = selectProfile(out.hardware_version, (out.esc_type2 or "") .. (out.esc_type or ""), out.firmware_version)
    out._profile = profile
    out._layout = profile.layout
    out._supported = {}
    for _, fieldName in ipairs(VALUE_FIELDS) do
        out._supported[fieldName] = (profile.layout[fieldName] ~= nil)
    end

    for _, fieldName in ipairs(VALUE_FIELDS) do
        local idx = profile.layout[fieldName]
        if idx and itemBytes[idx] ~= nil then
            local rawVal = itemBytes[idx]
            if fieldName == "startup_time" then
                out[fieldName] = rawVal + 4
            else
                out[fieldName] = rawVal
            end
        end
    end

    out.volt_cutoff_type = out.cutoff_type

    return out
end

function Api.buildWritePayload(data)
    data = data or {}
    local hwVer = data.hardware_version or ""
    local escTypeCombined = (data.esc_type2 or "") .. (data.esc_type or "")
    local fwVer = data.firmware_version or ""
    local profile = data._profile or selectProfile(hwVer, escTypeCombined, fwVer)

    local itemBytes = {}
    for i = 1, 16 do
        itemBytes[i] = (data._itemBytes and data._itemBytes[i]) or 0
    end

    for _, fieldName in ipairs(VALUE_FIELDS) do
        local idx = profile.layout[fieldName]
        local val = data[fieldName]
        if fieldName == "cutoff_type" and val == nil then
            val = data.volt_cutoff_type
        end
        if idx and val ~= nil then
            local rawVal = val
            if fieldName == "startup_time" then
                rawVal = math.max(0, math.min(21, (tonumber(val) or 4) - 4))
            end
            itemBytes[idx] = (tonumber(rawVal) or 0) & 0xFF
        end
    end

    local payload = {}
    payload[1] = (tonumber(data.esc_signature) or 253) & 0xFF
    payload[2] = (tonumber(data.command) or 0) & 0xFF

    local fwBytes = string_bytes(data, "firmware_version", 16)
    for _, b in ipairs(fwBytes) do payload[#payload + 1] = b end

    local hwBytes = string_bytes(data, "hardware_version", 16)
    for _, b in ipairs(hwBytes) do payload[#payload + 1] = b end

    local t2Bytes = string_bytes(data, "esc_type2", 16)
    for _, b in ipairs(t2Bytes) do payload[#payload + 1] = b end

    local t1Bytes = string_bytes(data, "esc_type", 15)
    for _, b in ipairs(t1Bytes) do payload[#payload + 1] = b end

    for i = 1, 16 do
        payload[#payload + 1] = itemBytes[i] or 0
    end

    return payload
end

return Api
