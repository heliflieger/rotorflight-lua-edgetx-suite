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

local function trim(s)
  local asString = tostring(s or "")
  asString = string.gsub(asString, "^%s+", "")
  asString = string.gsub(asString, "%s+$", "")
  return asString
end

local function loadConfigStore()
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require("lib/config_store.lua")
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/config_store.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- The one place a per-model store's contents are declared. A section's `keys` carry the
-- defaults and are written on every save; an `open` section keeps the keys it is handed,
-- because its key names are built at runtime and no schema can name them. A section declared
-- nowhere here is dropped at the next save, which is how a key outliving the code that read
-- it leaves the file again.
local MODEL_SCHEMA = {
  -- Per-pack figures, keyed by the pack the pilot selected.
  battery = { open = true },
  dashboard = {
    keys = {
      model_override = false,
      model_theme_preflight = "nil",
      model_theme_inflight = "nil",
      model_theme_postflight = "nil",
    },
    -- A theme's own configuration belongs to the machine and is stored here, under keys built
    -- from the theme's path (app/pages/settings/dashboard/lib.lua).
    open = true,
  },
  -- The model's half of the in-flight tuning overlay: what describes THIS machine. Whether it is
  -- set up for the overlay at all, which set of parameters its flight controller offers, how far
  -- one press moves them, and which PID profile the undo restores.
  --
  -- What is true of the transmitter whatever is plugged into it -- the interlock switch, the two
  -- channels and global variables the mixer devotes to the adjustment pair, the pulse length and
  -- the trims -- belongs to the radio and is seeded in lib/preferences.lua, also under
  -- [inflight]. Those keys are never read out of a per-model store, so seeding them here only
  -- wrote them into every model file and showed a reader numbers nothing used.
  --
  -- These five MUST agree with the model half of M.DEFAULTS in
  -- widgets/dashboard/inflight/setup.lua, which is what the overlay actually reads. They are
  -- duplicated rather than shared because this library is loaded by the whole suite and must not
  -- pull in a widget module to reach them; the same note sits on the other side.
  inflight = {
    keys = {
      -- Off until a pilot says this machine is set up for it. The radio carries a switch of its
      -- own and both have to be on before anything drives.
      enabled = false,
      set_mode = "standard",
      step = 5,
      step_headspeed = 50,
      backup_profile = 6,
    },
  },
  -- Per-widget state, keyed by the widget.
  widgets = { open = true },
  -- The machine's own announcement settings, which override the radio-wide ones. Declared where
  -- they are offered, in app/pages/settings/audio/events/, and partly built in a loop, so this
  -- section keeps what it is handed rather than holding a second copy of that list.
  audio_events = { open = true },
  -- Which battery the flight log last booked a flight against.
  flightlog = { open = true },
  -- What the setup assistant has been told about this machine: a resume cursor and one key per
  -- procedure the pilot passed over, the radio-side ones carrying the transmitter model in the
  -- key (app/pages/setup_wizard/store.lua).
  setup_wizard = { open = true },
  -- Where the name a rename replaced was kept before it moved to a store of its own. Read once
  -- at rename time so a rename in effect across an update is not stranded.
  model = { open = true },
}

local ConfigStore = loadConfigStore()
local store = ConfigStore and ConfigStore.new({ name = "model preferences", schema = MODEL_SCHEMA })

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
  return userRoot .. "/" .. safeId .. ".lua"
end

local function dirExists(path)
  -- Either spelling of the radio-wide store counts: a card written by an earlier release still
  -- carries the former one until its first load brings it across.
  if fileExists(path .. "/preferences.lua") or fileExists(path .. "/preferences.ini")
      or fileExists(path .. "/" .. RELOAD_REQ_FILE) then
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
    if fileExists(root .. "/preferences.lua") or fileExists(root .. "/preferences.ini") then
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
  return M.getUserRoot(safeId) .. "/preferences.lua"
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

--- Reads the store for one board. Answers the table and the path it came from; the table is
--- usable whatever the card did, and its identity is fresh on every call so that a caller may
--- treat it as a generation marker.
---
--- A connected board is left with a file carrying every declared key, so a release that adds
--- one does not leave every model file behind: the store is written back where the file was
--- absent or predates a key. That write happens in the Lua state that may migrate and nowhere
--- else: the connect tasks run in the widgets as well, and a widget call is cut off at a fixed
--- instruction count, which a write is as likely to land in the middle of as a parse. A widget
--- therefore answers with what the card holds and leaves settling the file to the next tool
--- session -- which changes no value, because the declared defaults fill the gaps either way.
function M.loadByMcuId(mcuId, force)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return nil, nil end
  if not store then return nil, nil end

  local roots = orderedRoots(safeId)

  for i = 1, #roots do
    local userRoot = roots[i]
    local path = buildPathForRoot(userRoot, safeId)

    ensureDirs(userRoot)

    -- A card written by an earlier release carries the former format. Bringing it across is a
    -- one-off, and after it the probe costs one failed open. It does nothing in a state that is
    -- not allowed to migrate; the load below then reads the former file into memory instead.
    store:migrate(path, ConfigStore.legacyPath(path))

    local prefs, info = store:load(path)
    local settled = info.found
    if ConfigStore.migrationAllowed() and (not info.found or not info.complete) then
      local ok, err = store:save(path, prefs)
      if ok then
        settled = true
      else
        logD("loadByMcuId: could not write %s: %s", path, tostring(err))
      end
    end

    -- A root that has neither a file to read nor room to write one is not this board's root,
    -- whatever the ordering said. The next one is tried before the defaults are given up to.
    -- In a state that may not write, only the first half of that test can be made, so a board
    -- whose file does not exist yet is answered from the declared defaults with no path -- the
    -- same answer this gives today when no root can be written to.
    if settled then
      local d = prefs.dashboard or {}
      -- The name logged is the file that was actually read: on a card that has not been brought
      -- across yet that is the former one beside the store, and a reader of this line that
      -- opens the store's name would find nothing there.
      local readFrom = info.legacy and ConfigStore.legacyPath(path) or path
      logD("loadByMcuId: loaded from disk %s (force=%s, override=%s, preflight=%s)",
        readFrom, tostring(force), tostring(d.model_override), tostring(d.model_theme_preflight))
      return prefs, path
    end
  end

  -- No root at all to read or write; the declared defaults are still the right answer.
  local fallback = store:defaults()
  logD("loadByMcuId: fallback defaults for mcuId=%s", safeId)
  return fallback, nil
end

--- Writes the store for one board and tells the widgets that it changed. What is written is
--- the schema above, so a key nothing declares any more leaves the file here.
function M.saveByMcuId(mcuId, prefs)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return false, "missing_mcu_id" end
  if not store then return false, "unavailable" end

  local roots = orderedRoots(safeId)
  local lastErr = "io"

  for i = 1, #roots do
    local userRoot = roots[i]
    local path = buildPathForRoot(userRoot, safeId)
    ensureDirs(userRoot)

    local okSave, saveErr = store:save(path, prefs)
    if okSave then
      memoizedRoots = {}
      -- Signal the dashboard widget that model preferences have changed via
      -- rotating sequence length in reload.req. Multi-reader safe, armed-safe,
      -- and independent of RTC timestamp or file size equality.
      bumpReloadCounter(userRoot)
      local d = (type(prefs) == "table" and prefs.dashboard) or {}
      logD("saveByMcuId: saved to %s (override=%s, preflight=%s)",
        path, tostring(d.model_override), tostring(d.model_theme_preflight))
      return true
    end
    lastErr = saveErr or "io"
    logD("saveByMcuId: could not write %s: %s", path, tostring(saveErr))
  end

  memoizedRoots = {}
  return false, lastErr
end

return M
