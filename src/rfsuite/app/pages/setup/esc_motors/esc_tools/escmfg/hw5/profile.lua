--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local rfsuite = _G.rfsuite

local helper = {}

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

local TABLES = {
    rotation = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_cw)@", "@i18n(api.ESC_PARAMETERS_HW5.tbl_ccw)@"},
    rotation_hw1128 = {"Forward", "@i18n(api.ESC_PARAMETERS_HW5.tbl_reverse)@", "4D", "4D Reverse"},
    lipo_3_to_14 = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_autocalculate)@", "3S", "4S", "5S", "6S", "7S", "8S", "9S", "10S", "11S", "12S", "13S", "14S"},
    lipo_3_to_8 = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_autocalculate)@", "3S", "4S", "5S", "6S", "7S", "8S"},
    lipo_even_6_to_14 = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_autocalculate)@", "6S", "8S", "10S", "12S", "14S"},
    lipo_2_to_4 = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_autocalculate)@", "2S", "3S", "4S"},
    cutoff_28_to_38 = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_disabled)@", "2.8V", "2.9V", "3.0V", "3.1V", "3.2V", "3.3V", "3.4V", "3.5V", "3.6V", "3.7V", "3.8V"},
    cutoff_25_to_38 = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_disabled)@", "2.5V", "2.6V", "2.7V", "2.8V", "2.9V", "3.0V", "3.1V", "3.2V", "3.3V", "3.4V", "3.5V", "3.6V", "3.7V", "3.8V"},
    bec_50_to_84 = {"5.0V", "5.1V", "5.2V", "5.3V", "5.4V", "5.5V", "5.6V", "5.7V", "5.8V", "5.9V", "6.0V", "6.1V", "6.2V", "6.3V", "6.4V", "6.5V", "6.6V", "6.7V", "6.8V", "6.9V", "7.0V", "7.1V", "7.2V", "7.3V", "7.4V", "7.5V", "7.6V", "7.7V", "7.8V", "7.9V", "8.0V", "8.1V", "8.2V", "8.3V", "8.4V"},
    bec_54_to_84 = {"5.4V", "5.5V", "5.6V", "5.7V", "5.8V", "5.9V", "6.0V", "6.1V", "6.2V", "6.3V", "6.4V", "6.5V", "6.6V", "6.7V", "6.8V", "6.9V", "7.0V", "7.1V", "7.2V", "7.3V", "7.4V", "7.5V", "7.6V", "7.7V", "7.8V", "7.9V", "8.0V", "8.1V", "8.2V", "8.3V", "8.4V"},
    bec_60_74_84 = {"6.0V", "7.4V", "8.4V"},
    bec_50_to_120 = {"5.0V", "5.1V", "5.2V", "5.3V", "5.4V", "5.5V", "5.6V", "5.7V", "5.8V", "5.9V", "6.0V", "6.1V", "6.2V", "6.3V", "6.4V", "6.5V", "6.6V", "6.7V", "6.8V", "6.9V", "7.0V", "7.1V", "7.2V", "7.3V", "7.4V", "7.5V", "7.6V", "7.7V", "7.8V", "7.9V", "8.0V", "8.1V", "8.2V", "8.3V", "8.4V", "8.5V", "8.6V", "8.7V", "8.8V", "8.9V", "9.0V", "9.1V", "9.2V", "9.3V", "9.4V", "9.5V", "9.6V", "9.7V", "9.8V", "9.9V", "10.0V", "10.1V", "10.2V", "10.3V", "10.4V", "10.5V", "10.6V", "10.7V", "10.8V", "10.9V", "11.0V", "11.1V", "11.2V", "11.3V", "11.4V", "11.5V", "11.6V", "11.7V", "11.8V", "11.9V", "12.0V"},
    brake_full = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_disabled)@", "@i18n(api.ESC_PARAMETERS_HW5.tbl_normal)@", "@i18n(api.ESC_PARAMETERS_HW5.tbl_proportional)@", "@i18n(api.ESC_PARAMETERS_HW5.tbl_reverse)@"},
    brake_no_prop = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_disabled)@", "@i18n(api.ESC_PARAMETERS_HW5.tbl_normal)@", "@i18n(api.ESC_PARAMETERS_HW5.tbl_reverse)@"},
    brake_basic = {"@i18n(api.ESC_PARAMETERS_HW5.tbl_disabled)@", "@i18n(api.ESC_PARAMETERS_HW5.tbl_normal)@"},
    response_time = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10"}
}

local PROFILES = {
    default = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_3_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_50_to_84,
            brake_type = TABLES.brake_full
        }
    },
    ["HW1104_V100456NB"] = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_even_6_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_50_to_120,
            brake_type = TABLES.brake_basic
        }
    },
    ["HW1106_V100456NB"] = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_3_to_8,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_54_to_84,
            brake_type = TABLES.brake_full
        }
    },
    ["HW1106_V200456NB"] = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_3_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_50_to_120,
            brake_type = TABLES.brake_no_prop
        }
    },
    ["HW1106_V300456NB"] = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_3_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_50_to_120,
            brake_type = TABLES.brake_no_prop
        }
    },
    ["HW1121_V100456NB"] = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_3_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_50_to_120,
            brake_type = TABLES.brake_no_prop
        }
    },
    ["HW1121_V00456NB"] = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_3_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_50_to_120,
            brake_type = TABLES.brake_no_prop
        }
    },
    ["HW1132_V100456NB"] = {
        layout = HW1132_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_2_to_4,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_60_74_84,
            response_time = TABLES.response_time,
            brake_type = TABLES.brake_no_prop
        }
    },
    ["HW198_V1.00456NB"] = {
        layout = DEFAULT_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_even_6_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            bec_voltage = TABLES.bec_50_to_120,
            brake_type = TABLES.brake_basic
        }
    },
    HW1128 = {
        layout = HW1128_LAYOUT,
        tables = {
            rotation = TABLES.rotation_hw1128,
            lipo_cell_count = TABLES.lipo_2_to_4,
            cutoff_voltage = TABLES.cutoff_25_to_38,
            brake_type = TABLES.brake_no_prop
        }
    },
    OPTO = {
        layout = OPTO_LAYOUT,
        tables = {
            rotation = TABLES.rotation,
            lipo_cell_count = TABLES.lipo_even_6_to_14,
            cutoff_voltage = TABLES.cutoff_28_to_38,
            brake_type = TABLES.brake_basic
        }
    }
}

local function trim(text)
    if type(text) ~= "string" then return "" end
    local s = string.gsub(text, "%z.*", "")
    return string.match(s, "^%s*(.-)%s*$") or ""
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

function helper.getProfile()
    local escDetails = rfsuite and rfsuite.session and rfsuite.session.escDetails or {}
    local hardware = escDetails.version or ""
    local esc = escDetails.model or ""
    local firmware = escDetails.firmware or ""

    return selectProfile(hardware, esc, firmware)
end

function helper.isFieldAllowed(apikey)
    local profile = helper.getProfile()
    if not profile or not profile.layout then return true end
    if apikey == "volt_cutoff_type" then apikey = "cutoff_type" end
    return profile.layout[apikey] ~= nil
end

helper.TABLES = TABLES
helper.PROFILES = PROFILES

return helper
