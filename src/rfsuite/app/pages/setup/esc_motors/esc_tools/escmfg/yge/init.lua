--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local toolName = "YGE"

local mspHeaderBytes = 2

-- One entry per model, carrying every fact this suite knows about it. The name and the 12 V
-- BEC capability used to live in two hard-coded lists in two files, and adding a model meant
-- remembering both -- which is how 4691 came to be in neither.
--
-- `bec12v` is what raises the BEC Voltage field's ceiling from 8.4 V to 12.0 V. It is a property
-- of the model rather than of the flags word: the flag says what the ESC is set to, this says
-- what it can be set to.
local escModels = {
    [848] = { name = "YGE 35 LVT BEC", bec12v = false },
    [1616] = { name = "YGE 65 LVT BEC", bec12v = false },
    [2128] = { name = "YGE 85 LVT BEC", bec12v = false },
    [2384] = { name = "YGE 95 LVT BEC", bec12v = false },
    [4944] = { name = "YGE 135 LVT BEC", bec12v = false },
    [2304] = { name = "YGE 90 HVT Opto", bec12v = false },
    [4608] = { name = "YGE 120 HVT Opto", bec12v = false },
    [5712] = { name = "YGE 165 HVT", bec12v = true },
    [8272] = { name = "YGE 205 HVT", bec12v = true },
    [8273] = { name = "YGE 205 HVT BEC", bec12v = true },
    [4177] = { name = "YGE Aureus 105", bec12v = false },
    [4179] = { name = "YGE Aureus 105v2", bec12v = true },
    [5025] = { name = "YGE Aureus 135", bec12v = false },
    [5027] = { name = "YGE Aureus 135v2", bec12v = true },
    [5457] = { name = "YGE Saphir 155", bec12v = false },
    [5459] = { name = "YGE Saphir 155v2", bec12v = true },
    [4689] = { name = "YGE Saphir 125", bec12v = false },
    [4691] = { name = "YGE Saphir 125v2", bec12v = true },
    [4928] = { name = "YGE Opto 135", bec12v = false },
    [9552] = { name = "YGE Opto 255", bec12v = false },
    [16464] = { name = "YGE Opto 405", bec12v = false }
}

local escFlags = {spinDirection = 0, f3cAuto = 1, keepMah = 2, bec12v = 3}

local function getEscTypeLabel(values)
    if type(values) ~= "table" then return toolName end
    local idx = ((values[mspHeaderBytes + 24] or 0) * 256) + (values[mspHeaderBytes + 23] or 0)
    local model = escModels[idx]
    return (model and model.name) or ("YGE ESC (" .. idx .. ")")
end

local function getUInt(page, vals)
    if type(page) ~= "table" then return 0 end
    local v = 0
    for idx = 1, #vals do
        local raw_val = page[vals[idx] + mspHeaderBytes] or 0
        raw_val = raw_val * (256 ^ (idx - 1))
        v = v + raw_val
    end
    return v
end

local function getEscModel(buffer) return getEscTypeLabel(buffer) end

local function getEscVersion(buffer)
    if type(buffer) ~= "table" then return "" end
    local sn = getUInt(buffer, {29, 30, 31, 32})
    return sn ~= 0 and tostring(sn) or ""
end

local function getEscFirmware(buffer)
    if type(buffer) ~= "table" then return "" end
    local raw = getUInt(buffer, {25, 26, 27, 28})
    return raw ~= 0 and string.format("%.5f", raw / 100000) or ""
end

return {mspapi = "ESC_PARAMETERS_YGE", toolName = toolName, escSensorProtocolId = 9, powerCycle = false, escModels = escModels, getEscModel = getEscModel, getEscVersion = getEscVersion, getEscFirmware = getEscFirmware}

