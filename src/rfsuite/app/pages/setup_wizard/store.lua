-- The only three things the setup assistant stores, and the reason each one has to be stored
-- rather than derived.
--
-- Everything else is read back from the flight controller on every entry. A stored progress flag
-- survives a configuration restore, a firmware flash and a board swap, and it lies in the
-- dangerous direction -- by claiming a setup step happened.
--
--   the resume cursor          a convenience. A wrong one is corrected by the next derivation.
--   "deliberately skipped"     a claim that a step was NOT done. Nothing on the board can say it.
--   pilot assertions           facts about the machine that are not in any register.
--
-- The file is the flight controller's own, keyed by its MCU id -- `lib/model_preferences.lua` is
-- named for a model and is a BOARD store. That is the right key for two of the three, and the
-- wrong one for the radio side: the same board moved into another transmitter model is the same
-- machine for everything on the board and a different one for everything in the model. So a
-- radio-side entry carries the model in its key and a board-side entry does not.

local M = {}

local SECTION = "setup_wizard"

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function session()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

-- The transmitter model's own name, reduced to what an INI key may carry. The FILE name is used
-- rather than the label, because the label is what the suite renames after the craft while a link
-- is up -- a key built from it would move under the assistant mid-run.
local function modelKey()
  local model = _G and _G.model
  if type(model) ~= "table" or type(model.getInfo) ~= "function" then return nil end
  local ok, info = pcall(model.getInfo)
  if not ok or type(info) ~= "table" then return nil end
  local name = info.filename or info.name
  if type(name) ~= "string" or name == "" then return nil end
  return (string.gsub(name, "[^%w_%-]", "_"))
end

M.modelKey = modelKey

local function bag(create)
  local s = session()
  if type(s) ~= "table" then return nil end
  local prefs = s.modelPreferences
  if type(prefs) ~= "table" then
    if not create then return nil end
    prefs = {}
    s.modelPreferences = prefs
  end
  local own = prefs[SECTION]
  if type(own) ~= "table" then
    if not create then return nil end
    own = {}
    prefs[SECTION] = own
  end
  return own
end

-- Writing this file IS the event -- nothing signals it, and the readers pick it up by reading.
-- The write is deferred to `M.flush` so that a screen changing three flags costs one file write.
local dirty = false

function M.flush()
  if not dirty then return true end
  local s = session()
  local mcuId = s and s.mcu_id
  if mcuId == nil then return false, "no_mcu_id" end
  local prefs = s and s.modelPreferences
  if type(prefs) ~= "table" then return false, "no_prefs" end
  local mod = loadModule("lib/model_preferences.lua")
  if type(mod) ~= "table" or type(mod.saveByMcuId) ~= "function" then return false, "unavailable" end
  -- `saveByMcuId` reports an unwritable card by RETURNING false rather than by raising, so a
  -- successful `pcall` says nothing about the write. Both halves have to be read, and `dirty`
  -- has to stay set when either fails: it is the only thing that makes the next flush retry.
  local ok, saved, err = pcall(mod.saveByMcuId, mcuId, prefs)
  if ok and saved then
    dirty = false
    return true
  end
  return false, (not ok and tostring(saved)) or err or "save_failed"
end

local function keyFor(id, perModel)
  if not perModel then return "skip." .. tostring(id) end
  local model = modelKey()
  if model == nil then return nil end
  return "skip." .. model .. "." .. tostring(id)
end

-- A procedure the pilot deliberately passed over. The wording matters where this is rendered:
-- the pilot is asserting something about their own machine, not dismissing a dialog.
function M.isSkipped(id, perModel)
  local key = keyFor(id, perModel)
  local own = key and bag(false)
  if not own then return false end
  return own[key] == true
end

function M.setSkipped(id, perModel, value)
  local key = keyFor(id, perModel)
  if key == nil then return false end
  local own = bag(true)
  if not own then return false end
  if value then own[key] = true else own[key] = nil end
  dirty = true
  return true
end

-- Where the path stood when the assistant was last left. An optimisation and a courtesy, never
-- the authority: the runner re-derives every procedure on entry and the cursor only decides where
-- the pilot is OFFERED to continue.
function M.resume()
  local own = bag(false)
  local value = own and own["resume"]
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

function M.setResume(id)
  local own = bag(true)
  if not own then return false end
  local value = nil
  if type(id) == "string" and id ~= "" then value = id end
  -- Only a CHANGE is worth a file write. The cursor is set on entering every procedure,
  -- and a card write per screen is real cost on a radio for a value that did not move.
  if own["resume"] == value then return true end
  own["resume"] = value
  dirty = true
  return true
end

-- The marker that says this board has been through the assistant before. It cannot be the store's
-- own existence: `loadByMcuId` creates the file on the first connect and writes the merged
-- defaults back, so from that moment the store exists and is non-empty for every board. The
-- assistant has to write its own.
function M.seen()
  local own = bag(false)
  return own ~= nil and own["seen"] == true
end

function M.setSeen()
  local own = bag(true)
  if not own then return false end
  if own["seen"] ~= true then
    own["seen"] = true
    dirty = true
  end
  return true
end

return M
