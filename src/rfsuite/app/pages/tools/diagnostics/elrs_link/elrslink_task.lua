-- Ported ELRS link task for EdgeTX
local M = {}

local math_floor = math.floor
local string_find = string.find
local string_gmatch = string.gmatch
local string_lower = string.lower
local tonumber = tonumber
local tostring = tostring
local type = type

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local CRSF_FRAMETYPE_DEVICE_PING = 0x28
local CRSF_FRAMETYPE_DEVICE_INFO = 0x29
local CRSF_FRAMETYPE_PARAMETER_SETTINGS_ENTRY = 0x2B
local CRSF_FRAMETYPE_PARAMETER_READ = 0x2C
local CRSF_FRAMETYPE_PARAMETER_WRITE = 0x2D

local CRSF_ADDRESS_BROADCAST = 0x00
local CRSF_ADDRESS_RADIO_TRANSMITTER = 0xEA
local CRSF_ADDRESS_CRSF_TRANSMITTER = 0xEE
local CRSF_ADDRESS_ELRS_LUA = 0xEF

local ELRS_SERIAL_ID = 0x454C5253
local TYPE_TEXT_SELECTION = 9

local DISCOVERY_TIMEOUT_SECONDS = 4.0
local READ_TIMEOUT_MAX_SECONDS = 8.0
local READ_TIMEOUT_SECONDS = 0.5
local PING_RETRY_SECONDS = 1.0
local WRITE_DELAY_SECONDS = 0.25

local SYNC_MODE_OFF = 0
local SYNC_MODE_ROTORFLIGHT_TO_ELRS = 1
local SYNC_MODE_ELRS_TO_ROTORFLIGHT = 2

local STD_TLM_RATIO_BY_PACKET_RATE = {
    [25] = 8,
    [50] = 16,
    [100] = 32,
    [150] = 32,
    [200] = 64,
    [250] = 64,
    [333] = 128,
    [500] = 128,
    [1000] = 128
}

local taskComplete = false
local configWaitStartedAt = 0
local probeStartedAt = 0
local nextActionAt = 0
local state = "idle"

local deviceId = CRSF_ADDRESS_CRSF_TRANSMITTER
local fieldCount = 0
local currentField = 1
local currentChunk = 0
local expectedChunksRemain = -1
local fieldData = {}
local rateField = nil
local ratioField = nil
local moduleRateLabel = nil
local moduleRatioLabel = nil
local pendingWrites = {}
local pendingWriteCount = 0
local pendingWriteIndex = 1
local manualSyncMode = SYNC_MODE_OFF
local statusText = "Idle"
local statusI18nKey = "status_idle"

local function getSession()
    return _G.rfsuite and _G.rfsuite.session
end

local function logMsg(msg, level)
    local t = "rfsuite.elrs.task"
    local lvl = level or "debug"
    
    local rf = _G.rfsuite
    local logModule = rf and rf.Log
    if not logModule then
        logModule = loadModule("lib/log.lua")
    end

    if logModule and type(logModule.emit) == "function" then
        logModule.emit(t, msg, lvl)
    end
end

local function setStatus(key, text)
    statusI18nKey = key
    statusText = text or "Idle"
end

local function clearFieldData()
    for i = #fieldData, 1, -1 do
        fieldData[i] = nil
    end
end

local function clearPendingWrites()
    for i = pendingWriteCount, 1, -1 do
        pendingWrites[i] = nil
    end
    pendingWriteCount = 0
    pendingWriteIndex = 1
end

local function fieldGetStrOrOpts(data, offset, isOpts)
  local r = isOpts and {} or nil
  local opt = ""
  local vcnt = 0
  repeat
    local b = data[offset]
    if b == nil then break end
    offset = offset + 1

    if isOpts then
      if b == 59 or b == 0 then -- ';' or '\0'
        r[#r+1] = opt
        if opt ~= "" then
          vcnt = vcnt + 1
        end
        opt = ""
      else
        opt = opt .. string.char(b)
      end
    else
      if b ~= 0 then
        opt = opt .. string.char(b)
      end
    end
  until b == 0

  return (r or opt), offset, vcnt
end

local function optionLooksLikeRatio(text)
    if type(text) ~= "string" or text == "" then return false end
    local lowerText = string_lower(text)
    if string_find(lowerText, "std", 1, true) then return true end
    if string_find(lowerText, "race", 1, true) then return true end
    if string_find(lowerText, "1:", 1, true) or string_find(lowerText, "1/", 1, true) then return true end
    if string.match(lowerText, "^:%d+") then return true end
    return false
end

local function optionLooksLikeRate(text)
    if type(text) ~= "string" or text == "" then return false end
    local lowerText = string_lower(text)
    if string_find(lowerText, "ghz", 1, true) then return false end
    if string_find(lowerText, "mhz", 1, true) then return false end
    if string_find(lowerText, "hz", 1, true) then return true end
    if string.match(lowerText, "^%s*[dfk]%d+") then return true end
    return false
end

local function classifyChoiceField(lowerName, options)
    if string_find(lowerName, "packet rate", 1, true)
        or string_find(lowerName, "pkt rate", 1, true)
        or string_find(lowerName, "pkt. rate", 1, true)
        or string_find(lowerName, "pkt.rate", 1, true)
        or string_find(lowerName, "air rate", 1, true)
        or string_find(lowerName, "rf rate", 1, true)
        or lowerName == "packet rate"
        or lowerName == "pkt rate"
        or lowerName == "rate" then
        return "rate"
    end

    if string_find(lowerName, "telem ratio", 1, true)
        or string_find(lowerName, "telemetry ratio", 1, true)
        or string_find(lowerName, "tlm ratio", 1, true)
        or string_find(lowerName, "tlm. ratio", 1, true)
        or lowerName == "telem ratio"
        or lowerName == "tlm ratio"
        or lowerName == "ratio" then
        return "ratio"
    end

    if string_find(lowerName, "power", 1, true)
        or string_find(lowerName, "switch", 1, true)
        or string_find(lowerName, "model", 1, true)
        or string_find(lowerName, "vtx", 1, true)
        or string_find(lowerName, "wifi", 1, true)
        or string_find(lowerName, "ble", 1, true)
        or string_find(lowerName, "band", 1, true)
        or string_find(lowerName, "domain", 1, true)
        or string_find(lowerName, "bind", 1, true) then
        return nil
    end

    local hasRateOptions = false
    local hasRatioOptions = false
    for i = 1, #options do
        if optionLooksLikeRate(options[i]) then hasRateOptions = true end
        if optionLooksLikeRatio(options[i]) then hasRatioOptions = true end
    end

    if hasRateOptions and not hasRatioOptions then return "rate" end
    if hasRatioOptions and not hasRateOptions then return "ratio" end

    return nil
end

local function parseRateFromLabel(label)
    if type(label) ~= "string" or label == "" then return nil end
    local lower = string_lower(label)
    
    if string_find(lower, "2.4g", 1, true) and not string_find(lower, "hz", 1, true) then return nil end
    if string_find(lower, "ghz", 1, true) then return nil end
    if string_find(lower, "mhz", 1, true) and not string_find(lower, "hz", 1, true) then return nil end
    
    local rateStr = string.match(lower, "(%d+)%s*hz")
    if rateStr then
        local rateNum = tonumber(rateStr)
        if rateNum and rateNum >= 25 and rateNum <= 1000 then
            return rateNum
        end
    end
    
    local _, modeDigits = string.match(lower, "^%s*([dfk])(%d+)")
    if modeDigits then
        local modeNum = tonumber(modeDigits)
        if modeNum and modeNum >= 25 and modeNum <= 1000 then
            return modeNum
        end
    end
    
    local KNOWN_RATES = { 1000, 500, 333, 250, 200, 150, 100, 50, 25 }
    for _, rate in ipairs(KNOWN_RATES) do
        if string_find(lower, "%f[%d]" .. tostring(rate) .. "%f[%D]") then
            return rate
        end
    end
    
    return nil
end

local function parseRatioLabel(label)
    if type(label) ~= "string" or label == "" then return nil, "unknown" end
    local lowerLabel = string_lower(label)
    if string_find(lowerLabel, "std", 1, true) then return nil, "std" end
    if string_find(lowerLabel, "race", 1, true) then return nil, "race" end
    if string_find(lowerLabel, "off", 1, true) then return nil, "off" end
    
    local ratio = string.match(lowerLabel, "1%s*[:/]%s*(%d+)")
    if ratio then return tonumber(ratio), "explicit" end
    
    local colonRatio = string.match(lowerLabel, "[:/]%s*(%d+)")
    if colonRatio then return tonumber(colonRatio), "explicit" end
    
    local num = tonumber(string.match(lowerLabel, "(%d+)"))
    if num and (num == 2 or num == 4 or num == 8 or num == 16 or num == 32 or num == 64 or num == 128) then
        return num, "explicit"
    end
    
    return nil, "unknown"
end

local function parseTelemetryField()
    if #fieldData < 3 then return end

    local fieldTypeByte = fieldData[2] or 0
    local fieldType = fieldTypeByte % 128
    local hidden = fieldTypeByte >= 128
    if hidden or fieldType ~= TYPE_TEXT_SELECTION then return end

    local name, offset = fieldGetStrOrOpts(fieldData, 3, false)
    local options, valOffset = fieldGetStrOrOpts(fieldData, offset, true)
    local selectedIndex = fieldData[valOffset] or 0
    local selectedLabel = options and options[selectedIndex + 1] or nil

    if not selectedLabel and options and #options > 0 then
        selectedLabel = options[1]
    end

    local lowerName = string_lower(name or "")
    local fieldKind = classifyChoiceField(lowerName, options or {})

    logMsg("parseTelemetryField: fieldId=" .. tostring(currentField) .. " name='" .. tostring(name) .. "' kind=" .. tostring(fieldKind) .. " selectedIndex=" .. tostring(selectedIndex) .. " selectedLabel='" .. tostring(selectedLabel) .. "'")

    if selectedLabel == nil or fieldKind == nil then return end

    if fieldKind == "rate" then
        local rateNum = parseRateFromLabel(selectedLabel)
        if rateNum then
            rateField = { id = currentField, name = name, options = options, selectedIndex = selectedIndex, selectedLabel = selectedLabel, rate = rateNum }
            moduleRateLabel = selectedLabel
            logMsg("parseTelemetryField: rateField matched - rate=" .. tostring(rateNum) .. " label='" .. tostring(selectedLabel) .. "'")
        else
            logMsg("parseTelemetryField: fieldKind rate rejected parseRateFromLabel for label='" .. tostring(selectedLabel) .. "'", "warn")
        end
    elseif fieldKind == "ratio" then
        ratioField = { id = currentField, name = name, options = options, selectedIndex = selectedIndex, selectedLabel = selectedLabel }
        moduleRatioLabel = selectedLabel
        logMsg("parseTelemetryField: ratioField matched - label='" .. tostring(selectedLabel) .. "'")
    end
end

local function resolveEffectiveRatio(packetRate, ratioKind, explicitRatio)
    if ratioKind == "explicit" then return explicitRatio end
    if ratioKind == "std" or ratioKind == "race" then
        return STD_TLM_RATIO_BY_PACKET_RATE[packetRate]
    end
    return nil
end

local function findRateTarget(field, targetRate)
    if type(field) ~= "table" or type(field.options) ~= "table" then return nil, nil end
    
    local bestIdx = nil
    local bestLabel = nil
    local bestScore = -1

    for i = 1, #field.options do
        local label = field.options[i]
        if parseRateFromLabel(label) == targetRate then
            local score = 0
            local lowerLabel = string_lower(label)
            
            local prefix = string.match(lowerLabel, "^%s*([a-z]+)%d")
            if not prefix or prefix == "" then
                score = 10 -- Standard rate (no letter prefix)
            else
                score = 1
            end
            
            if string_find(lowerLabel, "hz", 1, true) then
                score = score + 2
            end

            if score > bestScore then
                bestScore = score
                bestIdx = i - 1
                bestLabel = label
            end
        end
    end
    
    if bestLabel then
        logMsg("findRateTarget: mapped " .. tostring(targetRate) .. "Hz to module option '" .. tostring(bestLabel) .. "' (idx=" .. tostring(bestIdx) .. ", score=" .. tostring(bestScore) .. ")")
    end
    
    return bestIdx, bestLabel
end

local function findRatioTarget(field, targetRatio)
    if type(field) ~= "table" or type(field.options) ~= "table" then return nil, nil end
    for i = 1, #field.options do
        local explicitRatio, ratioKind = parseRatioLabel(field.options[i])
        if ratioKind == "explicit" and explicitRatio == targetRatio then
            return i - 1, field.options[i]
        end
    end
    return nil, nil
end

local function completeTask()
    state = "done"
    taskComplete = true
end

local function syncRotorflightToElrs(fcConfig)
    clearPendingWrites()
    local ratioIdx, ratioLbl = findRatioTarget(ratioField, fcConfig.linkRatio)
    local rateIdx, rateLbl = findRateTarget(rateField, fcConfig.linkRate)

    if ratioField and ratioIdx ~= nil and ratioField.selectedIndex ~= ratioIdx then
        pendingWriteCount = pendingWriteCount + 1
        pendingWrites[pendingWriteCount] = { fieldKind = "ratio", fieldId = ratioField.id, fieldName = ratioField.name, value = ratioIdx, label = ratioLbl }
    end
    if rateField and rateIdx ~= nil and rateField.selectedIndex ~= rateIdx then
        pendingWriteCount = pendingWriteCount + 1
        pendingWrites[pendingWriteCount] = { fieldKind = "rate", fieldId = rateField.id, fieldName = rateField.name, value = rateIdx, label = rateLbl }
    end

    if pendingWriteCount > 0 then
        setStatus("status_writing_elrs", "Writing ELRS...")
        state = "write"
        nextActionAt = 0
    else
        setStatus("status_elrs_probe_complete", "Probe complete")
        completeTask()
    end
end

local function syncElrsToRotorflight(fcConfig, moduleRate, moduleRatioLabel, ratioKind, effectiveRatio)
    local session = getSession()
    if not effectiveRatio or not moduleRate or not session or not session.telemetryConfigBuffer then
        logMsg("syncElrsToRotorflight: missing parameters - rate=" .. tostring(moduleRate) .. " ratio=" .. tostring(effectiveRatio), "warn")
        setStatus("status_rotorflight_write_failed", "Write failed")
        completeTask()
        return
    end

    if fcConfig and fcConfig.linkRate == moduleRate and fcConfig.linkRatio == effectiveRatio and fcConfig.mode == 1 then
        setStatus("status_rf_matches_elrs", "RF matches ELRS")
        completeTask()
        return
    end

    local writeBuffer = {}
    for i=1, #session.telemetryConfigBuffer do writeBuffer[i] = session.telemetryConfigBuffer[i] end
    
    -- Set mode to CUSTOM (1), rate (U16 LE at offset 9) and ratio (U16 LE at offset 11)
    writeBuffer[8] = 1
    writeBuffer[9] = moduleRate % 256
    writeBuffer[10] = math_floor(moduleRate / 256)
    writeBuffer[11] = effectiveRatio % 256
    writeBuffer[12] = math_floor(effectiveRatio / 256)

    logMsg("syncElrsToRotorflight: writing to RF mode=1 rate=" .. tostring(moduleRate) .. " ratio=" .. tostring(effectiveRatio))
    setStatus("status_writing_rotorflight", "Writing RF...")
    
    local msp = loadModule("tasks/msp/runtime.lua")
    local mspState = msp and type(msp.getState) == "function" and msp.getState()
    if not mspState or not mspState.queue then
        setStatus("status_rotorflight_write_failed", "Write failed")
        completeTask()
        return
    end

    local api = loadModule("tasks/msp/api/telemetry_config.lua")
    mspState.queue:add({
        command = api.writeCommand,
        payload = writeBuffer,
        isWrite = true,
        processReply = function()
            setStatus("status_saving_rotorflight", "Saving RF...")
            local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
            mspState.queue:add({
                command = eepromApi.writeCommand,
                payload = {},
                isWrite = true,
                processReply = function()
                    if session then
                        session.crsfTelemetryConfig = session.crsfTelemetryConfig or {}
                        session.crsfTelemetryConfig.mode = 1
                        session.crsfTelemetryConfig.linkRate = moduleRate
                        session.crsfTelemetryConfig.linkRatio = effectiveRatio
                        session.telemetryConfigBuffer = writeBuffer
                    end
                    logMsg("syncElrsToRotorflight: successfully saved to RF")
                    setStatus("status_rotorflight_updated", "RF updated")
                    completeTask()
                end,
                errorHandler = function()
                    logMsg("syncElrsToRotorflight: eeprom save failed", "warn")
                    setStatus("status_rotorflight_save_failed", "Save failed")
                    completeTask()
                end
            })
        end,
        errorHandler = function()
            logMsg("syncElrsToRotorflight: MSP write failed", "warn")
            setStatus("status_rotorflight_write_failed", "Write failed")
            completeTask()
        end
    })
end

local function finalize()
    local session = getSession()
    local fcConfig = session and session.crsfTelemetryConfig
    
    local moduleRate = parseRateFromLabel(moduleRateLabel)
    local explicitRatio, ratioKind = parseRatioLabel(moduleRatioLabel)
    local effectiveRatio = resolveEffectiveRatio(moduleRate, ratioKind, explicitRatio)

    logMsg("finalize: moduleRateLabel='" .. tostring(moduleRateLabel) .. "' moduleRate=" .. tostring(moduleRate) .. " ratioLabel='" .. tostring(moduleRatioLabel) .. "' effectiveRatio=" .. tostring(effectiveRatio))

    if session then
        session.elrsLinkConfig = {
            packetRateLabel = moduleRateLabel,
            packetRate = moduleRate,
            telemetryRatioLabel = moduleRatioLabel,
            telemetryRatio = effectiveRatio,
            telemetryRatioEffective = effectiveRatio,
            telemetryRatioKind = ratioKind
        }
    end

    if manualSyncMode == SYNC_MODE_OFF then
        setStatus("status_probe_complete", "Probe complete")
        completeTask()
    elseif manualSyncMode == SYNC_MODE_ELRS_TO_ROTORFLIGHT then
        syncElrsToRotorflight(fcConfig, moduleRate, moduleRatioLabel, ratioKind, effectiveRatio)
    else
        syncRotorflightToElrs(fcConfig)
    end
end

function M.reset()
    taskComplete = false
    configWaitStartedAt = 0
    probeStartedAt = 0
    nextActionAt = 0
    state = "idle"
    deviceId = CRSF_ADDRESS_CRSF_TRANSMITTER
    fieldCount = 0
    currentField = 1
    currentChunk = 0
    expectedChunksRemain = -1
    rateField = nil
    ratioField = nil
    moduleRateLabel = nil
    moduleRatioLabel = nil
    clearFieldData()
    clearPendingWrites()
    setStatus("status_idle", "Idle")
end

local function handleDeviceInfo(data)
    -- data[1] = Dest (0xEA)
    -- data[2] = Source Address
    local srcAddr = data[2] or 0x00
    
    -- If we are already reading or writing a specific device, ignore others
    if state ~= "ping" then return end

    local newName, offset = fieldGetStrOrOpts(data, 3, false)
    local serial = 0
    for i = 0, 3 do
        serial = serial * 256 + (data[offset + i] or 0)
    end
    
    local lowerName = string_lower(newName or "")
    local isElrs = (serial == ELRS_SERIAL_ID) or (srcAddr == CRSF_ADDRESS_CRSF_TRANSMITTER) or string_find(lowerName, "elrs", 1, true) or string_find(lowerName, "expresslrs", 1, true)
    
    if not isElrs then 
        logMsg("handleDeviceInfo: ignoring non-ELRS device '" .. tostring(newName) .. "' at " .. string.format("0x%02X", srcAddr) .. " serial=" .. string.format("0x%08X", serial))
        return 
    end

    deviceId = srcAddr
    fieldCount = data[offset + 12] or 0
    logMsg("handleDeviceInfo: found ELRS module '" .. tostring(newName) .. "' at " .. string.format("0x%02X", deviceId) .. " with " .. tostring(fieldCount) .. " fields")
    
    currentField = 1
    currentChunk = 0
    expectedChunksRemain = -1
    clearFieldData()
    state = "read"
    nextActionAt = 0
    setStatus("status_reading_module", "Reading module...")
    if fieldCount <= 0 then finalize() end
end

local function handleParameterEntry(data)
    if state ~= "read" then return end
    
    local src = data[2] or 0
    local fld = data[3] or 0
    if src ~= deviceId or fld ~= currentField then 
        logMsg("handleParameterEntry: mismatch src=" .. string.format("0x%02X", src) .. " (expected " .. string.format("0x%02X", deviceId) .. ") fld=" .. tostring(fld) .. " (expected " .. tostring(currentField) .. ")")
        return 
    end

    logMsg("handleParameterEntry: received field=" .. tostring(fld) .. " chunk=" .. tostring(data[4] or 0))

    local chunksRemain = data[4] or 0
    expectedChunksRemain = chunksRemain - 1
    for i = 5, #data do fieldData[#fieldData + 1] = data[i] end

    if chunksRemain > 0 then
        currentChunk = currentChunk + 1
        nextActionAt = 0
        return
    end

    parseTelemetryField()
    currentField = currentField + 1
    currentChunk = 0
    expectedChunksRemain = -1
    clearFieldData()
    nextActionAt = 0

    if (moduleRateLabel and moduleRatioLabel) or currentField > fieldCount then
        logMsg("handleParameterEntry: discovery complete")
        finalize()
    end
end

local function isSimulation()
  if type(getVersion) == "function" then
    local ok, _, fw = pcall(getVersion)
    if ok and type(fw) == "string" then
      local fwl = string_lower(fw)
      if string_find(fwl, "simu", 1, true) ~= nil then return true end
    end
  end
  return false
end

local CrsfManager = nil

function M.wakeup()
    if taskComplete then return end
    local now = nowSeconds()
    local session = getSession()

    if not session or session.isConnected ~= true or session.telemetryType ~= "crsf" then
        if not isSimulation() then
            setStatus("status_requires_active_link", "Requires active link")
            taskComplete = true
            return
        end
    end

    if not session.crsfTelemetryConfig then
        if configWaitStartedAt == 0 then
            configWaitStartedAt = now
            setStatus("status_waiting_rotorflight_config", "Waiting for RF config")
        elseif (now - configWaitStartedAt) >= DISCOVERY_TIMEOUT_SECONDS then
            logMsg("Skipping ELRS link probe: CRSF telemetry config not ready", "warn")
            setStatus("status_rotorflight_config_not_ready", "RF config not ready")
            taskComplete = true
        end
        return
    end

    if state == "idle" then
        configWaitStartedAt = 0
        probeStartedAt = now
        state = "ping"
        nextActionAt = 0
        logMsg("Starting ELRS link probe (pinging 0x00 from 0xEA)")
        setStatus("status_pinging_module", "Pinging module...")
    end

    if not CrsfManager then
      CrsfManager = loadModule("lib/crsf.lua")
    end

    -- Simulator logic: inject dummy frames
    if isSimulation() then
        if state == "ping" and now >= nextActionAt then
            local dummyInfo = {
                CRSF_ADDRESS_RADIO_TRANSMITTER, CRSF_ADDRESS_CRSF_TRANSMITTER,
                string.byte('E'), string.byte('L'), string.byte('R'), string.byte('S'), 0x00,
                0x45, 0x4C, 0x52, 0x53, -- Serial ID
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x02 -- fieldCount
            }
            handleDeviceInfo(dummyInfo)
        elseif state == "read" and now >= nextActionAt then
            if currentField == 1 then
                local dummyRate = {
                    CRSF_ADDRESS_RADIO_TRANSMITTER, deviceId, currentField, 0x00,
                    0x00, -- parent
                    TYPE_TEXT_SELECTION,
                    string.byte('P'), string.byte('a'), string.byte('c'), string.byte('k'), string.byte('e'), string.byte('t'), string.byte(' '), string.byte('R'), string.byte('a'), string.byte('t'), string.byte('e'), 0x00,
                    string.byte('5'), string.byte('0'), string.byte('0'), string.byte('H'), string.byte('z'), 0x00,
                    0x00 -- selectedIndex
                }
                handleParameterEntry(dummyRate)
            elseif currentField == 2 then
                local dummyRatio = {
                    CRSF_ADDRESS_RADIO_TRANSMITTER, deviceId, currentField, 0x00,
                    0x00, -- parent
                    TYPE_TEXT_SELECTION,
                    string.byte('T'), string.byte('e'), string.byte('l'), string.byte('e'), string.byte('m'), string.byte(' '), string.byte('R'), string.byte('a'), string.byte('t'), string.byte('i'), string.byte('o'), 0x00,
                    string.byte('1'), string.byte(':'), string.byte('4'), 0x00,
                    0x00 -- selectedIndex
                }
                handleParameterEntry(dummyRatio)
            end
        end
    end

    -- Process frames via CrsfManager
    if CrsfManager then
        while true do
            local data = CrsfManager.popFrame(CRSF_FRAMETYPE_DEVICE_INFO)
            if data then handleDeviceInfo(data) else break end
        end
        while true do
            local data = CrsfManager.popFrame(CRSF_FRAMETYPE_PARAMETER_SETTINGS_ENTRY)
            if data then handleParameterEntry(data) else break end
        end
    end

    if taskComplete then return end

    if state == "ping" and (now - probeStartedAt) >= DISCOVERY_TIMEOUT_SECONDS then
        logMsg("ELRS probe failed: discovery timeout (no device info response)", "warn")
        setStatus("status_no_module", "No module found")
        taskComplete = true
        return
    end

    if state == "read" and (now - probeStartedAt) >= READ_TIMEOUT_MAX_SECONDS then
        logMsg("ELRS probe failed: read timeout", "warn")
        setStatus("status_read_timeout", "Read timeout")
        finalize()
        return
    end

    if now < nextActionAt then return end

    if state == "ping" then
        if type(crossfireTelemetryPush) == "function" then
            logMsg("pinging 0x00 from 0xEA")
            crossfireTelemetryPush(CRSF_FRAMETYPE_DEVICE_PING, {CRSF_ADDRESS_BROADCAST, CRSF_ADDRESS_RADIO_TRANSMITTER})
        end
        nextActionAt = now + PING_RETRY_SECONDS
    elseif state == "read" then
        if type(crossfireTelemetryPush) == "function" then
            -- Note: Using 0xEF as source (handsetId) for parameter reads
            logMsg("requesting field " .. tostring(currentField) .. " from " .. string.format("0x%02X", deviceId))
            crossfireTelemetryPush(CRSF_FRAMETYPE_PARAMETER_READ, {deviceId, CRSF_ADDRESS_ELRS_LUA, currentField, currentChunk})
        end
        nextActionAt = now + READ_TIMEOUT_SECONDS
    elseif state == "write" then
        local action = pendingWrites[pendingWriteIndex]
        if not action then completeTask(); return end
        if type(crossfireTelemetryPush) == "function" then
            -- Note: Using 0xEF as source (handsetId) for parameter writes
            logMsg("writing field " .. tostring(action.fieldId) .. " to " .. string.format("0x%02X", deviceId))
            crossfireTelemetryPush(CRSF_FRAMETYPE_PARAMETER_WRITE, {deviceId, CRSF_ADDRESS_ELRS_LUA, action.fieldId, action.value})
        end
        setStatus("status_writing_prefix", "Writing " .. tostring(action.fieldName))
        pendingWriteIndex = pendingWriteIndex + 1
        if pendingWriteIndex > pendingWriteCount then
            setStatus("status_elrs_updated", "ELRS updated")
            completeTask()
        else
            nextActionAt = now + WRITE_DELAY_SECONDS
        end
    end
end

function M.start(mode)
    manualSyncMode = mode or SYNC_MODE_OFF
    M.reset()
    taskComplete = false
    return true
end

-- What the walk found, so a caller can offer the CHOICE rather than only the two syncs.
--
-- Both sync modes answer the question "which side wins"; neither lets the pilot say what the link
-- should actually run at, and the option list needed for that is already here -- it was read off
-- the module and then used only to compare. Returned as-is rather than copied: the caller reads
-- it, and the walk owns it.
function M.getRateField() return rateField end
function M.getRatioField() return ratioField end

-- Write ONE option of one field, without the comparison the sync modes make.
--
-- The same queue and the same state the sync modes use, so the write is paced, reported and
-- completed identically -- the difference is only that the value comes from the pilot instead of
-- from the other side of the link. `index` is the module's own zero-based option index, which is
-- what the parameter frame carries.
function M.selectOption(kind, index)
    local field = (kind == "rate") and rateField or ratioField
    if type(field) ~= "table" or type(index) ~= "number" then return false end

    local label = field.options and field.options[index + 1] or nil
    clearPendingWrites()
    pendingWriteCount = 1
    pendingWrites[1] = { fieldKind = kind, fieldId = field.id, fieldName = field.name,
                         value = index, label = label }

    manualSyncMode = SYNC_MODE_OFF
    taskComplete = false
    state = "write"
    nextActionAt = 0
    setStatus("status_writing_elrs", "Writing ELRS...")
    return true
end

function M.getStatus() return statusI18nKey, statusText end
function M.isRunning() return not taskComplete end
function M.getMode() return manualSyncMode end

M.MODE_PROBE = SYNC_MODE_OFF
M.MODE_ROTORFLIGHT_TO_ELRS = SYNC_MODE_ROTORFLIGHT_TO_ELRS
M.MODE_ELRS_TO_ROTORFLIGHT = SYNC_MODE_ELRS_TO_ROTORFLIGHT

M.reset()
return M
