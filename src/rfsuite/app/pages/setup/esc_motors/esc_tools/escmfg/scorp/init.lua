--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local toolName = "Scorpion"

local function getUInt(page, vals)
    if type(page) ~= "table" then return 0 end
    local v = 0
    for idx = 1, #vals do
        local raw_val = page[vals[idx]] or 0
        raw_val = raw_val << ((idx - 1) * 8)
        v = v | raw_val
    end
    return v
end

local function getEscModel(buffer)
    if type(buffer) ~= "table" then return toolName end
    local tt = {}
    for i = 1, 32 do
        local v = buffer[i + 2]
        if v == nil or v == 0 then break end
        table.insert(tt, string.char(v))
    end
    local s = table.concat(tt)
    local trimmed = string.match(s, "^%s*(.-)%s*$")
    return (trimmed ~= nil and trimmed ~= "") and trimmed or toolName
end

local function getEscVersion(buffer)
    if type(buffer) ~= "table" then return "" end
    local sn = getUInt(buffer, {57, 58, 59, 60})
    return sn ~= 0 and tostring(sn) or ""
end

local function getEscFirmware(buffer)
    if type(buffer) ~= "table" then return "" end
    local fw = getUInt(buffer, {61, 62})
    return fw ~= 0 and ("v" .. tostring(fw)) or ""
end

return {mspapi = "ESC_PARAMETERS_SCORPION", toolName = toolName, escSensorProtocolId = 4, powerCycle = true, getEscModel = getEscModel, getEscVersion = getEscVersion, getEscFirmware = getEscFirmware}

