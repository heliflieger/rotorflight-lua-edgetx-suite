local Api = {
  command = 3,
  simulatorResponse = { 4, 6, 0 }
}

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < 3 then return nil end

  local major = tonumber(buf[1]) or 0
  local minor = tonumber(buf[2]) or 0
  local patch = tonumber(buf[3]) or 0

  local rfMajor = major - 2
  local rfMinor = minor - 3
  local rfVersion
  if rfMajor < 0 or rfMinor < 0 then
    rfVersion = string.format("%d.%d.%d", major, minor, patch)
  else
    rfVersion = string.format("%d.%d.%d", rfMajor, rfMinor, patch)
  end

  return {
    fcVersion = string.format("%d.%d.%d", major, minor, patch),
    rfVersion = rfVersion
  }
end

return Api
