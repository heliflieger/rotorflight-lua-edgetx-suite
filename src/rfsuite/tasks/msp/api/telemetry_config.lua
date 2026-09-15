local Api = {
  command = 73,
  writeCommand = 74,
  simulatorResponse = {
    0,
    1,
    0, 0, 0, 0,
    0,
    0,
    250, 0,
    8, 0,
    3, 4, 5, 6, 7, 15, 23, 25, 43, 60,
    90, 91, 93, 95, 96, 97, 99,
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0
  }
}

local function copyBuffer(buf)
  local out = {}
  if type(buf) ~= "table" then
    return out
  end
  for i = 1, #buf do
    out[i] = tonumber(buf[i]) or 0
  end
  return out
end

-- The logging core, through the shared instance in _G. When it is absent, silence is
-- right: an ungated fallback would run on every TELEMETRY_CONFIG response at every
-- debug level.
local function coreLog()
  local rf = _G and _G.rfsuite
  local L = rf and rf.Log
  if type(L) == "table" and type(L.emit) == "function" then return L end
  return nil
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < 6 then
    return nil
  end

  local function u8(idx)
    return tonumber(buf[idx]) or 0
  end

  local function u16(idx)
    local lo = tonumber(buf[idx]) or 0
    local hi = tonumber(buf[idx + 1]) or 0
    return lo + hi * 256
  end

  local function u32(idx)
    local b1 = tonumber(buf[idx]) or 0
    local b2 = tonumber(buf[idx + 1]) or 0
    local b3 = tonumber(buf[idx + 2]) or 0
    local b4 = tonumber(buf[idx + 3]) or 0
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  end

  -- The raw buffer, asked for BEFORE it is built: the dump is a table.concat over up to
  -- 64 bytes, and it must cost nothing when the gate is closed.
  local L = coreLog()
  if L and L.wanted("info") then
    local parts = {}
    for i = 1, math.min(#buf, 64) do parts[#parts + 1] = tostring(buf[i]) end
    L.emit("rfsuite.msp.telemetry_config", "buf len=" .. tostring(#buf) .. " first=" .. table.concat(parts, ","), "info")
  end

  local parsed = {
    telemetry_inverted = u8(1),
    halfDuplex = u8(2),
    enableSensors = u32(3),
    buffer = copyBuffer(buf)
  }

  if #buf >= 12 then
    parsed.pinSwap = u8(7)
    parsed.crsf_telemetry_mode = u8(8)
    parsed.crsf_telemetry_link_rate = u16(9)
    parsed.crsf_telemetry_link_ratio = u16(11)

    local slotBase = 13
    for i = 1, 40 do
      local idx = slotBase + i - 1
      local byte = tonumber(buf[idx])
      if byte == nil then
        if L then L.emit("rfsuite.msp.telemetry_config", "slot "..tostring(i).." idx="..tostring(idx).." is nil (break)", "warn") end
        break
      end
      parsed["telem_sensor_slot_" .. tostring(i)] = byte
    end
  end

  -- The parsed slots, behind the same gate and by the same rule: the string is only
  -- built once the gate has passed.
  if L and L.wanted("info") then
    local slotParts = {}
    for i = 1, 40 do
      local v = parsed["telem_sensor_slot_"..tostring(i)]
      slotParts[#slotParts+1] = tostring(v or "nil")
    end
    L.emit("rfsuite.msp.telemetry_config", "parsed slots: "..table.concat(slotParts, ","), "info")
  end

  return parsed
end

function Api.buildWritePayload(updates)
  local payload = copyBuffer(Api.simulatorResponse)

  updates = updates or {}

  if tonumber(updates.telemetry_inverted) ~= nil then
    payload[1] = tonumber(updates.telemetry_inverted) % 256
  end

  if tonumber(updates.halfDuplex) ~= nil then
    payload[2] = tonumber(updates.halfDuplex) % 256
  end

  if tonumber(updates.pinSwap) ~= nil then
    payload[7] = tonumber(updates.pinSwap) % 256
  end

  if tonumber(updates.crsf_telemetry_mode) ~= nil then
    payload[8] = tonumber(updates.crsf_telemetry_mode) % 256
  end

  if tonumber(updates.crsf_telemetry_link_rate) ~= nil then
    local rate = tonumber(updates.crsf_telemetry_link_rate)
    if rate >= 0 and rate <= 65535 then
      local r = math.floor(rate + 0.5)
      payload[9] = r % 256
      payload[10] = math.floor(r / 256)
    end
  end

  if tonumber(updates.crsf_telemetry_link_ratio) ~= nil then
    local ratio = tonumber(updates.crsf_telemetry_link_ratio)
    if ratio >= 0 and ratio <= 65535 then
      local q = math.floor(ratio + 0.5)
      payload[11] = q % 256
      payload[12] = math.floor(q / 256)
    end
  end

  return payload
end

return Api