-- EdgeTX MSP API: ADJUSTMENT_RANGES
-- Ported to EdgeTX schema (Api table + parse)

local Api = {
  command = 52, -- MSP_ADJUSTMENT_RANGES
  simulatorResponse = {},
}

local ADJUSTMENT_RANGE_BYTES = 14
local ADJUSTMENT_RANGE_MAX = 42

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
  -- The firmware serialises every slot, so a reply that does not carry all of them is a failed
  -- read rather than a shorter table. Returning the records it did carry, or an empty table,
  -- puts the None function in every slot it could not read -- which is indistinguishable from a
  -- flight controller with nothing configured.
  if type(buf) ~= "table" or #buf < ADJUSTMENT_RANGE_MAX * ADJUSTMENT_RANGE_BYTES then
    return nil
  end
  local ranges = {}
  local slotCount = ADJUSTMENT_RANGE_MAX
  for slot = 0, slotCount - 1 do
    local base = slot * ADJUSTMENT_RANGE_BYTES + 1
    local adjFunction = buf[base]
    local enaChannel = buf[base + 1]
    local enaStartStep = parseS8(buf[base + 2])
    local enaEndStep = parseS8(buf[base + 3])
    local adjChannel = buf[base + 4]
    local adjRange1StartStep = parseS8(buf[base + 5])
    local adjRange1EndStep = parseS8(buf[base + 6])
    local adjRange2StartStep = parseS8(buf[base + 7])
    local adjRange2EndStep = parseS8(buf[base + 8])
    local adjMin = parseS16(buf[base + 9], buf[base + 10])
    local adjMax = parseS16(buf[base + 11], buf[base + 12])
    local adjStep = buf[base + 13]
    ranges[#ranges + 1] = {
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
  end
  return { adjustment_ranges = ranges }
end

return Api
