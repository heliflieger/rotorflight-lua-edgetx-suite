-- Where the radio's own model name is kept while a craft's name stands in its place.
--
-- The rename `tasks/events/onconnect/tasks/model_name_sync.lua` performs is temporary, and the
-- restore is the whole of what makes it temporary. The record it restores from therefore has to
-- outlive everything that could be running when the link goes -- the tool, the widgets, and the
-- radio itself. Two properties follow from that, and neither is decoration.
--
-- It is readable WITH NO LINK. A per-board file is not: it is addressed by the flight
-- controller's MCU id, and with nothing powered there is no id to address it by. That is exactly
-- the case a backstop exists for -- the radio switched off while still connected, where no
-- disconnect ever runs and the model comes back up wearing the craft's name.
--
-- It is keyed by the RADIO MODEL. A single slot for the whole transmitter puts one model's old
-- name onto whichever model happens to be selected when the restore finally runs, which turns a
-- missing restore into a wrong one.
--
-- The file is this module's own rather than a section of the radio-wide store. That file is rewritten
-- whole on every save and is watched for changes by the widget; a record written twice per flight
-- has no business triggering either. It is the same Lua data through the same store, though, so
-- there is one reader of one format on the card and not two.

if type(_G) == "table" and type(_G.__rfsuite_model_name_store) == "table" then
  return _G.__rfsuite_model_name_store
end

local M = {}

local USER_ROOTS = {
  "/SCRIPTS/TOOLS/rfsuite.user",
  "SCRIPTS:/TOOLS/rfsuite.user"
}

local FILE_NAME = "model_name_restore.lua"

-- The file as an earlier release wrote it, beside the current one. The migration below reads it
-- once and sets it aside; `previous_name` was the single key each of its sections carried.
local LEGACY_FILE_NAME = "model_name_restore.ini"
local LEGACY_KEY = "previous_name"

-- The one section this store has, and it is open: its keys are model file names, which the radio
-- makes and no schema can name. The store writes a key that is not a Lua name in brackets and
-- quotes it, which is what lets `Kraken 580.yml` be a key at all.
local SECTION = "models"

local SCHEMA = {
  models = { open = true },
}

-- How often the current model is asked for while a record exists that does not belong to it.
-- `model.getInfo()` builds a table on every call, and this runs on the disconnected tick.
local LOOKUP_INTERVAL_SECONDS = 1.0

--: model filename -> the name that model had before the rename. `nil` until the file has been
--: read, which happens once per Lua state; the tool and the widgets each hold their own copy and
--: the file is what they share.
local entries = nil
local anyEntries = false
local resolvedPath = nil
local nextLookupAt = 0

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

-- Built once, here: this module is read once per Lua state and the store is what every later
-- load and save goes through.
local ConfigStore = loadConfigStore()
local store = ConfigStore and ConfigStore.new({ name = "model names", schema = SCHEMA })

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
  return 0
end

local function fileExists(path)
  local f = io.open(path, "r")
  if not f then return false end
  io.close(f)
  return true
end

-- The same root order the per-board store uses: whichever spelling of the user directory already
-- holds the suite's settings is the one this file belongs beside. Falling back to the first entry
-- rather than to nothing means a fresh install still has a path to write to.
local function resolvePath()
  if resolvedPath then return resolvedPath end
  for i = 1, #USER_ROOTS do
    -- Either name counts: a card written by an earlier release carries the former one until its
    -- first load brings it across, and that load has to find it where it lies.
    if fileExists(USER_ROOTS[i] .. "/" .. FILE_NAME)
        or fileExists(USER_ROOTS[i] .. "/" .. LEGACY_FILE_NAME) then
      resolvedPath = USER_ROOTS[i] .. "/" .. FILE_NAME
      return resolvedPath
    end
  end
  for i = 1, #USER_ROOTS do
    -- Either spelling of the radio-wide store counts: a card written by an earlier release
    -- still carries the former one until its first load brings it across.
    if fileExists(USER_ROOTS[i] .. "/preferences.lua") or fileExists(USER_ROOTS[i] .. "/preferences.ini") then
      resolvedPath = USER_ROOTS[i] .. "/" .. FILE_NAME
      return resolvedPath
    end
  end
  resolvedPath = USER_ROOTS[1] .. "/" .. FILE_NAME
  return resolvedPath
end

-- The former file kept one section per model file name, each holding a single `previous_name`;
-- the store keeps one key per model file name.
local function fromLegacyIni(parsed)
  local models = {}
  for modelFile, section in pairs(parsed) do
    local name = type(section) == "table" and section[LEGACY_KEY] or nil
    if type(name) == "string" and name ~= "" then
      models[modelFile] = name
    end
  end
  return { [SECTION] = models }
end

-- The mapping above describes the former file whether it is being brought across or only read,
-- so both calls take the same record.
--
-- `raw`: these values are names the pilot chose, not settings. The reader coerces a value that
-- reads as a number by default, which is right for a file of thresholds and switches and wrong
-- here -- a model called `007` would come back as 7 and one called `1.50` as 1.5, and no later
-- conversion can put the leading zero or the trailing digit back.
local LEGACY_OPTS = { fromIni = fromLegacyIni, raw = true }

local function ensureLoaded()
  if entries ~= nil then return end

  entries = {}
  anyEntries = false
  if not store then return end

  local path = resolvePath()
  -- A card written by an earlier release carries the former format. Bringing it across is a
  -- one-off, and after it this costs one failed open. Only a Lua state that is yielded rather
  -- than cut off at an instruction count does it; in a widget this does nothing and the load
  -- below reads the former file into memory instead, which answers the same records.
  store:migrate(path, ConfigStore.legacyPath(path), LEGACY_OPTS)

  local loaded = store:load(path, LEGACY_OPTS)
  local models = loaded[SECTION]
  if type(models) ~= "table" then return end

  -- A record whose value is not a name is no record. An open section keeps whatever it is
  -- handed, so only a hand edit can put anything else in there, and it is dropped rather than
  -- written onto a model.
  for modelFile, name in pairs(models) do
    if type(name) == "string" and name ~= "" then
      entries[modelFile] = name
      anyEntries = true
    end
  end
end

local function save()
  if not store then return false end
  -- The store answers `true`, or `false` and a reason. Only the first is this module's answer:
  -- its callers test it as a boolean.
  local ok = store:save(resolvePath(), { [SECTION] = entries or {} })
  return ok == true
end

local function currentModelFile()
  if type(model) ~= "table" or type(model.getInfo) ~= "function" then return nil end
  local ok, info = pcall(model.getInfo)
  if not ok or type(info) ~= "table" then return nil end
  local fileName = info.filename
  if type(fileName) ~= "string" or fileName == "" then return nil end
  return fileName, info
end

--- Drop what was read from the card, so the next call reads it again.
--
-- Each Lua state holds its own copy and the file is all they share, so a state's answer is only
-- as good as the moment it last read it. Cheap: it costs one file read on the next call, and the
-- caller decides when that is worth paying.
function M.invalidate()
  entries = nil
  anyEntries = false
  nextLookupAt = 0
end

--- Is there anything at all to put back, for any model?
--
-- The cheap half of the disconnected tick: after the first call, false costs one boolean. That is
-- what keeps this out of the way in the case that is almost always the true one -- nothing
-- renamed, nothing to do.
function M.hasAny()
  ensureLoaded()
  return anyEntries
end

--- The name recorded for the model that is selected now, or nil.
function M.pending()
  ensureLoaded()
  if not anyEntries then return nil end
  local modelFile = currentModelFile()
  if not modelFile then return nil end
  return entries[modelFile]
end

--- Record what this model was called before the craft name was written over it.
function M.remember(name)
  if type(name) ~= "string" or name == "" then return false end
  ensureLoaded()
  local modelFile = currentModelFile()
  if not modelFile then return false end
  if entries[modelFile] == name then return true end
  entries[modelFile] = name
  anyEntries = true
  return save()
end

--- Drop this model's record without touching the model itself.
function M.forget()
  ensureLoaded()
  if not anyEntries then return true end
  local modelFile = currentModelFile()
  if not modelFile or entries[modelFile] == nil then return true end
  entries[modelFile] = nil
  anyEntries = next(entries) ~= nil
  return save()
end

--- Put the recorded name back on the model that is selected now, and clear the record.
--
-- Returns the name that was restored, or nil where there was nothing to do. The caller decides
-- WHEN this may happen: it writes to the pilot's model, so it belongs on a tick that has already
-- established there is no craft on the other end.
function M.restore()
  ensureLoaded()
  if not anyEntries then return nil end

  local t = nowSeconds()
  if t < nextLookupAt then return nil end
  nextLookupAt = t + LOOKUP_INTERVAL_SECONDS

  local modelFile, info = currentModelFile()
  if not modelFile then return nil end

  local name = entries[modelFile]
  if name == nil then return nil end

  -- The record is dropped only once the name is actually back on the model. Dropping it first
  -- would turn a single failed write into a name the pilot never gets back at all; leaving it
  -- costs one retry on a later tick, which is what the interval above bounds.
  if info.name ~= name then
    if type(model.setInfo) ~= "function" then return nil end
    info.name = name
    if pcall(model.setInfo, info) ~= true then return nil end
  end

  entries[modelFile] = nil
  anyEntries = next(entries) ~= nil
  save()
  return name
end

if type(_G) == "table" then
  _G.__rfsuite_model_name_store = M
end

return M
