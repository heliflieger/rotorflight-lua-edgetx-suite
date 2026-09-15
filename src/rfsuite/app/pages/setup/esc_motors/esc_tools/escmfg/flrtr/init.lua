--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local MSP_API = "ESC_PARAMETERS_FLYROTOR"
local toolName = "Flyrotor"

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

local function getPageValue(page, index)
    if type(page) ~= "table" then return nil end
    return page[index]
end

local function getEscModel(self)
    if type(self) ~= "table" then return toolName end
    local hw = "1." .. (getPageValue(self, 20) or 0) .. '/' .. (getPageValue(self, 14) or 0) .. "." .. (getPageValue(self, 15) or 0) .. "." .. (getPageValue(self, 16) or 0)
    local result = (getPageValue(self, 4) or 0) * 256 + (getPageValue(self, 5) or 0)

    return "FLYROTOR " .. tostring(result) .. "A " .. hw
end

local function getEscVersion(self)
    if type(self) ~= "table" then return "" end
    local sn = string.format("%08X", getUInt(self, {9, 8, 7, 6})) .. string.format("%08X", getUInt(self, {13, 12, 11, 10}))

    return sn
end

local function getEscFirmware(self)
    if type(self) ~= "table" then return "" end
    local version = (getPageValue(self, 17) or 0) .. "." .. (getPageValue(self, 18) or 0) .. "." .. (getPageValue(self, 19) or 0)

    return version
end

return {mspapi = MSP_API, toolName = toolName, escSensorProtocolId = 10, powerCycle = false, getEscModel = getEscModel, getEscVersion = getEscVersion, getEscFirmware = getEscFirmware}
