--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local toolName = "Hobbywing V5"
local mspHeaderBytes = 2

local function getText(buffer, st, en)
    if type(buffer) ~= "table" then return "" end
    local tt = {}
    for i = st, en do
        local v = buffer[i]
        if v == nil or v == 0 then break end
        table.insert(tt, string.char(v))
    end
    local s = table.concat(tt)
    return string.match(s, "^%s*(.-)%s*$") or ""
end

local function getEscModel(buffer)
    local t2 = getText(buffer, 35, 50)
    local t1 = getText(buffer, 51, 65)
    local combined = string.match((t2 .. " " .. t1), "^%s*(.-)%s*$")
    return (combined ~= nil and combined ~= "") and combined or toolName
end

local function getEscVersion(buffer) return getText(buffer, 19, 34) end

local function getEscFirmware(buffer) return getText(buffer, 3, 18) end

return {mspapi = "ESC_PARAMETERS_HW5", toolName = toolName, escSensorProtocolId = 3, powerCycle = false, getEscModel = getEscModel, getEscVersion = getEscVersion, getEscFirmware = getEscFirmware, mspHeaderBytes = mspHeaderBytes}
