local M = {}

M.MAJOR = 0
M.MINOR = 2
M.PATCH = 1

M.VERSION = M.MAJOR .. "." .. M.MINOR .. "." .. M.PATCH

-- Keep supported protocol targets centralized with app versioning.
-- The first entry is the oldest MSP API version the suite connects to: 12.09 is Rotorflight 4.6.
-- A board answering an older version (12.08 is Rotorflight 4.5) is refused on connect.
M.SUPPORTED_MSP_API_VERSIONS = {
  "12.09",
  "12.10",
}

function M.getVersionString()
  return "v" .. M.VERSION
end

function M.getSupportedMspApiVersions()
  return M.SUPPORTED_MSP_API_VERSIONS
end

function M.getLatestSupportedMspApiVersion()
  local versions = M.SUPPORTED_MSP_API_VERSIONS
  if type(versions) ~= "table" or #versions == 0 then
    return "-"
  end
  return versions[#versions]
end

function M.getSupportedMspApiVersionsString()
  local versions = M.SUPPORTED_MSP_API_VERSIONS
  if type(versions) ~= "table" or #versions == 0 then
    return "-"
  end

  local out = tostring(versions[1])
  for i = 2, #versions do
    out = out .. "," .. tostring(versions[i])
  end
  return out
end

-- Backward-compatible aliases (legacy callers).
function M.getSupportedEdgeTxVersions()
  return M.getSupportedMspApiVersions()
end

function M.getLatestSupportedEdgeTxVersion()
  return M.getLatestSupportedMspApiVersion()
end

function M.getSupportedEdgeTxVersionsString()
  return M.getSupportedMspApiVersionsString()
end

return M
