-- EdgeTX MSP API: GET_ADJUSTMENT_RANGE (one slot)
--
-- The request carries the slot index; the reply is a single 14-byte record with the same field
-- order and encoding as the whole-table MSP_ADJUSTMENT_RANGES reply. The firmware answers a
-- request of any other length, or an index it does not have, with an MSP error.

local Api = {
  command = 156, -- MSP_GET_ADJUSTMENT_RANGE
  simulatorResponse = { 1, 255, 0, 0, 1, 236, 246, 10, 20, 1, 0, 6, 0, 0 },
}

local ADJUSTMENT_RANGE_BYTES = 14

-- Helper to parse signed 8-bit
local function parseS8(b)
  b = tonumber(b) or 0
  if b >= 0x80 then b = b - 0x100 end
  return b
end

-- Helper to parse signed 16-bit from two bytes (little endian)
local function parseS16(lo, hi)
  local v = (tonumber(hi) or 0) << 8 | (tonumber(lo) or 0)
  if v >= 0x8000 then v = v - 0x10000 end
  return v
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < ADJUSTMENT_RANGE_BYTES then return nil end

  local adjFunction = buf[1]
  local enaChannel = buf[2]
  local enaStartStep = parseS8(buf[3])
  local enaEndStep = parseS8(buf[4])
  local adjChannel = buf[5]
  local adjRange1StartStep = parseS8(buf[6])
  local adjRange1EndStep = parseS8(buf[7])
  local adjRange2StartStep = parseS8(buf[8])
  local adjRange2EndStep = parseS8(buf[9])
  local adjMin = parseS16(buf[10], buf[11])
  local adjMax = parseS16(buf[12], buf[13])
  local adjStep = buf[14]

  return {
    adjustment_range = {
      adjFunction = adjFunction,
      enaChannel = enaChannel,
      enaRange = {
        start = 1500 + (enaStartStep * 5),
        ["end"] = 1500 + (enaEndStep * 5)
      },
      adjChannel = adjChannel,
      adjRange1 = {
        start = 1500 + (adjRange1StartStep * 5),
        ["end"] = 1500 + (adjRange1EndStep * 5)
      },
      adjRange2 = {
        start = 1500 + (adjRange2StartStep * 5),
        ["end"] = 1500 + (adjRange2EndStep * 5)
      },
      adjMin = adjMin,
      adjMax = adjMax,
      adjStep = adjStep
    }
  }
end

return Api
