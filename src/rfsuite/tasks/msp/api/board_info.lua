-- EdgeTX MSP API: BOARD_INFO
--
-- The reply is NOT a fixed-width record, and reading it as one is how this module used to get
-- every string after the first wrong. The firmware writes the four-byte board identifier, the
-- hardware revision, the flight-controller type and the target capabilities, and then FOUR
-- strings, each as a length byte followed by exactly that many characters with no padding at
-- all (msp/msp.c:689-706; the writer is common/streambuf.c:126-129, which stops at the
-- terminator and pads nothing). Advancing by the maximum width of each field therefore lands
-- in the middle of the next one on every real board -- it only appeared to work against a
-- zero-padded simulator reply, which is why the simulator reply below now has the shape a
-- flight controller actually sends.
--
-- The Configurator reads the same reply the same way (src/js/msp/MSPHelper.js:867-907).

-- pg/board.h:28. Skipped rather than returned: nothing on the radio has a use for the
-- signature, and the fields behind it do.
local SIGNATURE_LENGTH = 32

local Api = {
  command = 4, -- MSP_BOARD_INFO
  -- A reply in the shape a board sends it, taken from a Rotorflight Nexus: a unified F7X2
  -- build, so the board identifier is the generic S7X2 and the board is told apart by
  -- board_name and board_design.
  simulatorResponse = {
    83, 55, 88, 50,                                 -- board_identifier "S7X2"
    0, 0,                                           -- hardware_revision
    0,                                              -- fc_type (0 = FC, 2 = FC with MAX7456)
    1,                                              -- target_capabilities (bit 0: has VCP)
    9, 83, 84, 77, 51, 50, 70, 55, 88, 50,          -- target_name "STM32F7X2"
    8, 78, 69, 88, 85, 83, 95, 70, 55,              -- board_name "NEXUS_F7"
    4, 70, 55, 65, 49,                              -- board_design "F7A1"
    4, 82, 68, 77, 83,                              -- manufacturer_id "RDMS"
    -- signature (32 bytes, zero on a board that carries none)
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    4,                                              -- mcu_type_id (F722)
    0,                                              -- configuration_state
    64, 31,                                         -- gyro_sample_rate_hz (8000)
    0, 0, 0, 0,                                     -- configuration_problems
    0,                                              -- spi_device_count
    0                                               -- i2c_device_count
  }
}

-- A board identifier is a fixed-width field and may carry trailing zero bytes; the four
-- length-prefixed strings should not, but a zero inside one would draw as a missing glyph
-- rather than as nothing. Cutting at the first terminator costs nothing and covers both.
local function trimZeroPadding(text)
  local stop = string.find(text, "\0", 1, true)
  if stop == nil then return text end
  return string.sub(text, 1, stop - 1)
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end

  -- One cursor, and every read is bounded. A reply that stops early -- an older firmware, a
  -- frame cut short -- leaves the fields past the cut nil instead of raising, because the two
  -- a caller is usually after (board_name, board_design) arrive well before the end.
  local pos = 1

  local function bytes(count)
    if count <= 0 then return "" end
    if buf[pos + count - 1] == nil then return nil end
    local chars = {}
    for i = 1, count do
      chars[i] = string.char((tonumber(buf[pos + i - 1]) or 0) % 256)
    end
    pos = pos + count
    return table.concat(chars)
  end

  local function u8()
    local value = buf[pos]
    if value == nil then return nil end
    pos = pos + 1
    return tonumber(value) or 0
  end

  local function u16()
    local lo, hi = u8(), u8()
    if lo == nil or hi == nil then return nil end
    return lo + hi * 256
  end

  local function u32()
    local b1, b2, b3, b4 = u8(), u8(), u8(), u8()
    if b1 == nil or b2 == nil or b3 == nil or b4 == nil then return nil end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  end

  -- A length byte and exactly that many characters (msp.c:689-706).
  local function lengthPrefixed()
    local length = u8()
    if length == nil then return nil end
    local text = bytes(length)
    if text == nil then return nil end
    return trimZeroPadding(text)
  end

  local identifier = bytes(4)
  if identifier == nil then return nil end

  local parsed = {
    board_identifier = trimZeroPadding(identifier),
    hardware_revision = u16(),
    fc_type = u8(),
    target_capabilities = u8()
  }
  parsed.target_name = lengthPrefixed()
  parsed.board_name = lengthPrefixed()
  parsed.board_design = lengthPrefixed()
  parsed.manufacturer_id = lengthPrefixed()

  if bytes(SIGNATURE_LENGTH) ~= nil then
    parsed.mcu_type_id = u8()
    parsed.configuration_state = u8()
    parsed.gyro_sample_rate_hz = u16()
    parsed.configuration_problems = u32()
    -- Added in MSP API 1.44 and absent from an older reply, which the bounded reads cover.
    parsed.spi_device_count = u8()
    parsed.i2c_device_count = u8()
  end

  return parsed
end

return Api
