local M = {}

local USER_ROOTS = {
  "/SCRIPTS/TOOLS/rfsuite.user",
  "SCRIPTS:/TOOLS/rfsuite.user"
}

-- Reload request file monitored by the dashboard widget via fstat size.
-- Uses a rotating byte counter (1..32 bytes) so changes are reliably detected
-- where fstat is available even without an RTC or when the INI byte-size doesn't change,
-- without ever consuming or deleting the file (which breaks multi-reader and drops armed events).
local RELOAD_REQ_FILE = "reload.req"

M.USER_ROOTS = USER_ROOTS
M.RELOAD_REQ_FILE = RELOAD_REQ_FILE

local function bumpReloadCounter(userRoot)
  M.bumpReloadCounter(userRoot)
end

local function logD(fmt, ...)
  local L = _G.rfsuite and _G.rfsuite.Log
  if L and type(L.emitf) == "function" then
    L.emitf("rfsuite.reload", "debug", fmt, ...)
  end
end

-- How much is asked for per io.read() call. It is a chunk size, not a limit: the reader
-- below keeps going until the file ends.
local READ_CHUNK = 2048

local function trim(s)
  local asString = tostring(s or "")
  asString = string.gsub(asString, "^%s+", "")
  asString = string.gsub(asString, "%s+$", "")
  return asString
end

local function parseValue(v)
  local t = trim(v)
  local lower = string.lower(t)
  if lower == "true" then return true end
  if lower == "false" then return false end
  local n = tonumber(t)
  if n ~= nil then return n end
  return t
end

local function serializeValue(v)
  local vt = type(v)
  if vt == "boolean" then
    return v and "true" or "false"
  end
  if vt == "number" then
    return tostring(v)
  end
  return tostring(v)
end

local function deepCopyTable(src)
  if type(src) ~= "table" then return src end
  local out = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      out[k] = deepCopyTable(v)
    else
      out[k] = v
    end
  end
  return out
end

local function deepMerge(dst, src)
  if type(dst) ~= "table" or type(src) ~= "table" then return end
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      deepMerge(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

local function tablesEqual(a, b)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end

  for k, v in pairs(a) do
    if not tablesEqual(v, b[k]) then
      return false
    end
  end
  for k, v in pairs(b) do
    if not tablesEqual(v, a[k]) then
      return false
    end
  end
  return true
end

local function loadFileAsString(path)
  local f = io.open(path, "r")
  if not f then return nil end

  -- io.read() hands back at most the number of bytes asked for and "" once the file is
  -- exhausted, so a single call stops wherever that count lands. Stopping there is not
  -- merely a short read: saveIni() writes the whole table back, so everything the parser
  -- never saw is dropped from the file by the next save.
  local parts = {}
  while true do
    local chunk = io.read(f, READ_CHUNK)
    if chunk == nil or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  io.close(f)

  local content = table.concat(parts)
  if content == "" then return nil end
  return content
end

local function parseIni(content)
  local result = {}
  local section = nil

  if type(content) ~= "string" or content == "" then
    return result
  end

  for line in string.gmatch(content, "[^\r\n]+") do
    local normalized = trim(line)
    if normalized ~= "" and string.sub(normalized, 1, 1) ~= ";" and string.sub(normalized, 1, 1) ~= "#" then
      local sec = string.match(normalized, "^%[(.-)%]$")
      if sec then
        section = trim(sec)
        if result[section] == nil then
          result[section] = {}
        end
      else
        local k, v = string.match(normalized, "^([^=]+)=(.*)$")
        if k and v and section then
          result[section][trim(k)] = parseValue(v)
        end
      end
    end
  end

  return result
end

local function saveIni(path, data)
  local f, err = io.open(path, "w")
  if not f then return false, err end

  for section, values in pairs(data or {}) do
    if type(values) == "table" then
      io.write(f, "[" .. tostring(section) .. "]\n")
      for k, v in pairs(values) do
        io.write(f, tostring(k) .. "=" .. serializeValue(v) .. "\n")
      end
    end
  end

  io.close(f)
  return true
end

local function defaultModelPreferences()
  return {
    battery = {},
    dashboard = {
      model_override = false,
      model_theme_preflight = "nil",
      model_theme_inflight = "nil",
      model_theme_postflight = "nil"
    },
    widgets = {}
  }
end

local function fileExists(path)
  local f = io.open(path, "r")
  if not f then return false end
  io.close(f)
  return true
end

local function getToolsRoot(userRoot)
  return string.gsub(userRoot or "", "/rfsuite%.user$", "")
end

-- mkdir() is a bare global of the firmware's filesystem library, not a member of os. The
-- previous guard here tested os.mkdir and could never pass -- this Lua has no os table at
-- all -- so no directory was ever created and a store whose parent was missing simply failed
-- to write. The shape follows app/pages/logs/graph.lua, which tests fstat() the same way.
-- mkdir() creates one level at a time, so the tools root goes first.
local function makeDir(path)
  if type(mkdir) ~= "function" then return end
  if type(path) ~= "string" or path == "" then return end
  pcall(mkdir, path)
end

local function ensureDirs(userRoot)
  local toolsRoot = getToolsRoot(userRoot)
  if toolsRoot ~= "" then
    makeDir(toolsRoot)
  end
  makeDir(userRoot)
end

local function buildPathForRoot(userRoot, safeId)
  return userRoot .. "/" .. safeId .. ".ini"
end

local function dirExists(path)
  if fileExists(path .. "/preferences.ini") or fileExists(path .. "/" .. RELOAD_REQ_FILE) then
    return true
  end
  if type(fstat) == "function" then
    local ok, info = pcall(fstat, path)
    if ok and type(info) == "table" then return true end
  end
  return false
end

local memoizedRoots = {}

local function orderedRoots(safeId)
  local cacheKey = safeId or "__default"
  if memoizedRoots[cacheKey] then
    return memoizedRoots[cacheKey]
  end

  local prioritized = {}
  local used = {}

  local function add(root)
    if type(root) ~= "string" or root == "" then return end
    if used[root] then return end
    used[root] = true
    prioritized[#prioritized + 1] = root
  end

  if safeId then
    for i = 1, #USER_ROOTS do
      local root = USER_ROOTS[i]
      if fileExists(buildPathForRoot(root, safeId)) then
        add(root)
      end
    end
  end

  for i = 1, #USER_ROOTS do
    local root = USER_ROOTS[i]
    if fileExists(root .. "/preferences.ini") then
      add(root)
    end
  end

  for i = 1, #USER_ROOTS do
    local root = USER_ROOTS[i]
    if dirExists(root) then
      add(root)
    end
  end

  for i = 1, #USER_ROOTS do
    add(USER_ROOTS[i])
  end

  memoizedRoots[cacheKey] = prioritized
  return prioritized
end

local function normalizeMcuId(mcuId)
  if mcuId == nil then return nil end
  local id = trim(tostring(mcuId))
  if id == "" then return nil end
  -- Keep filename safe even if an unexpected UID format appears.
  id = string.gsub(id, "[^%w_-]", "_")
  if id == "" then return nil end
  return id
end

local RELOAD_REQ_PATHS = {}
for i = 1, #USER_ROOTS do
  RELOAD_REQ_PATHS[i] = USER_ROOTS[i] .. "/" .. RELOAD_REQ_FILE
end

function M.reloadRequestPaths()
  return RELOAD_REQ_PATHS
end

function M.getUserRoots()
  local roots = {}
  for i = 1, #USER_ROOTS do
    roots[i] = USER_ROOTS[i]
  end
  return roots
end

function M.getUserRoot(safeId)
  local safe = normalizeMcuId(safeId)
  local roots = orderedRoots(safe)
  return roots[1] or USER_ROOTS[1]
end

function M.preferencesPath(safeId)
  return M.getUserRoot(safeId) .. "/preferences.ini"
end

function M.reloadRequestPath(userRootOrSafeId)
  local root
  if type(userRootOrSafeId) == "string" and userRootOrSafeId ~= "" then
    if string.find(userRootOrSafeId, "/") then
      root = userRootOrSafeId
    else
      root = M.getUserRoot(userRootOrSafeId)
    end
  else
    root = M.getUserRoot()
  end
  return root .. "/" .. RELOAD_REQ_FILE
end

function M.bumpReloadCounter(userRoot)
  local targetPath = M.reloadRequestPath(userRoot)
  local prevN = 0
  local n = 1
  if type(fstat) == "function" then
    local ok, info = pcall(fstat, targetPath)
    if ok and type(info) == "table" then
      prevN = (info.size or 0)
      n = (prevN % 32) + 1
    end
  end
  local f = io.open(targetPath, "w")
  if f then
    io.write(f, string.rep("x", n))
    io.close(f)
    logD("bumpReloadCounter: wrote %d bytes (was %d) to %s", n, prevN, targetPath)
  else
    logD("bumpReloadCounter: FAILED to open %s for write", targetPath)
  end
end

local function ensureFileExists(path)
  local f = io.open(path, "r")
  if f then
    io.close(f)
    return true
  end

  local newFile, err = io.open(path, "w")
  if not newFile then return false, err end
  io.close(newFile)
  return true
end

function M.clearCache()
  memoizedRoots = {}
end

function M.buildPath(mcuId)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return nil end

  local roots = orderedRoots(safeId)
  if #roots == 0 then return nil end
  return buildPathForRoot(roots[1], safeId)
end

function M.loadByMcuId(mcuId, force)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return nil, nil end

  local defaults = defaultModelPreferences()
  local roots = orderedRoots(safeId)

  for i = 1, #roots do
    local userRoot = roots[i]
    local path = buildPathForRoot(userRoot, safeId)

    ensureDirs(userRoot)

    -- Ensure first-time setups always have a physical file on disk.
    local okTouch = ensureFileExists(path)
    if okTouch then
      local onDisk = parseIni(loadFileAsString(path))
      local merged = deepCopyTable(onDisk)
      deepMerge(merged, defaults)

      if not tablesEqual(onDisk, merged) then
        local ok = saveIni(path, merged)
        if not ok then
          -- Save errors are non-fatal; caller still gets usable defaults+loaded values.
        end
      end

      local d = merged.dashboard or {}
      logD("loadByMcuId: loaded from disk %s (force=%s, override=%s, preflight=%s)", path, tostring(force), tostring(d.model_override), tostring(d.model_theme_preflight))
      return merged, path
    end
  end

  -- Could not create/load file on any root; still return defaults in-memory.
  local fallback = deepCopyTable(defaults)
  logD("loadByMcuId: fallback defaults for mcuId=%s", safeId)
  return fallback, nil
end

function M.saveByMcuId(mcuId, prefs)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return false, "missing_mcu_id" end

  local roots = orderedRoots(safeId)
  local data = deepCopyTable(prefs or {})
  deepMerge(data, defaultModelPreferences())
  local lastErr = "io"

  for i = 1, #roots do
    local userRoot = roots[i]
    local path = buildPathForRoot(userRoot, safeId)
    ensureDirs(userRoot)

    local okTouch, touchErr = ensureFileExists(path)
    if okTouch then
      local okSave, saveErr = saveIni(path, data)
      if okSave then
        memoizedRoots = {}
        -- Signal the dashboard widget that model preferences have changed via
        -- rotating sequence length in reload.req. Multi-reader safe, armed-safe,
        -- and independent of RTC timestamp or INI file size equality.
        bumpReloadCounter(userRoot)
        local d = data.dashboard or {}
        logD("saveByMcuId: saved to %s (override=%s, preflight=%s)", path, tostring(d.model_override), tostring(d.model_theme_preflight))
        return true
      end
      lastErr = saveErr or "io"
      logD("saveByMcuId: saveIni failed for %s: %s", path, tostring(saveErr))
    else
      lastErr = touchErr or "io"
      logD("saveByMcuId: ensureFileExists failed for %s: %s", path, tostring(touchErr))
    end
  end

  memoizedRoots = {}
  return false, lastErr
end

return M
