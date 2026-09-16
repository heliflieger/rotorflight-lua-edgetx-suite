-- MSP_BUILD_INFO. The reply is FOUR fields with no separator and no terminator between them:
-- the build date (11 bytes), the build time (8), the short git revision (7), then one length
-- byte and the firmware version string of that length. Reading it as one NUL-terminated string
-- runs all four together and puts the length byte -- a control character -- into the middle of
-- what reaches the screen.
local Api = {
  command = 5,
  -- Shaped like the wire rather than like a sentence: 11 + 8 + 7 bytes, then the length byte
  -- and the version. The old fixture was the human string "Dec 12 2024 13:20:32", which the
  -- firmware never sends -- which is why the defect above was invisible in the simulator.
  simulatorResponse = {
    68, 101, 99, 32, 49, 50, 32, 50, 48, 50, 52,          -- "Dec 12 2024"
    49, 51, 58, 50, 48, 58, 51, 50,                       -- "13:20:32"
    110, 111, 114, 101, 118, 105, 115,                    -- "norevis"
    5, 52, 46, 54, 46, 48                                 -- 5, "4.6.0"
  }
}

local DATE_LEN = 11
local TIME_LEN = 8
local REV_LEN = 7

local function slice(buf, from, len)
  local out = {}
  for i = from, from + len - 1 do
    local byte = buf[i]
    if type(byte) ~= "number" or byte == 0 then break end
    out[#out + 1] = string.char(byte)
  end
  return table.concat(out)
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf == 0 then return nil end

  local date = slice(buf, 1, DATE_LEN)
  local time = slice(buf, 1 + DATE_LEN, TIME_LEN)
  local revision = slice(buf, 1 + DATE_LEN + TIME_LEN, REV_LEN)

  -- The version is optional: older firmware stops after the revision.
  local version = nil
  local lenAt = 1 + DATE_LEN + TIME_LEN + REV_LEN
  local versionLen = buf[lenAt]
  if type(versionLen) == "number" and versionLen > 0 and #buf >= lenAt + versionLen then
    version = slice(buf, lenAt + 1, versionLen)
    if version == "" then version = nil end
  end

  local parts = {}
  if date ~= "" then parts[#parts + 1] = date end
  if time ~= "" then parts[#parts + 1] = time end
  if revision ~= "" then parts[#parts + 1] = revision end

  return {
    buildInfo = table.concat(parts, " "),
    buildDate = date ~= "" and date or nil,
    buildTime = time ~= "" and time or nil,
    gitRevision = revision ~= "" and revision or nil,
    fcVersion = version
  }
end

return Api
