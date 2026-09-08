local Derived = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if rChunk then
    local ok, res = pcall(rChunk)
    if ok and type(res) == "function" then
      requireModule = res
    end
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Utils = requireModule("widgets/dashboard/objects/common.lua")

local IMAGE_DIR = "/IMAGES/"
local LOGO_FILE = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/gfx/logo.png"

-- What EdgeTX accepts for a model bitmap on a colour radio (radio/src/sdcard.h,
-- BITMAPS_EXT), with the empty one first so the same lookup also resolves a name that
-- already carries its extension -- which is what model.getInfo().bitmap reports.
--
-- One spelling per extension is enough: FatFs compares long file names case-insensitively
-- (radio/src/thirdparty/FatFs/ff.c, cmp_lfn), so ".PNG" on the card matches ".png" here.
local IMAGE_EXTENSIONS = { "", ".png", ".bmp", ".jpg", ".jpeg" }

-- Does a readable file sit at `path`?
--
-- `fstat` is the radio's own stat and returns nothing at all for a path that is not there
-- (radio/src/lua/api_filesystem.cpp, luaFstat), so it answers the question without opening
-- a handle. It answers for directories too, and the empty extension above can put a
-- directory name in front of it, so the AM_DIR bit is taken back out.
local function fileExists(path)
  if type(fstat) ~= "function" then return false end
  local ok, info = pcall(fstat, path)
  if not ok or type(info) ~= "table" then return false end
  local attrib = tonumber(info.attrib) or 0
  if bit32 and type(bit32.btest) == "function" and bit32.btest(attrib, 0x10) then
    return false
  end
  return true
end

--- The first file under /IMAGES/ that `name` resolves to, or nil.
local function findImage(name)
  if type(name) ~= "string" or name == "" then return nil end
  for i = 1, #IMAGE_EXTENSIONS do
    local path = IMAGE_DIR .. name .. IMAGE_EXTENSIONS[i]
    if fileExists(path) then return path end
  end
  return nil
end

-- The last resolution and the inputs it was made from. The lookup walks the card, so it
-- runs when one of those inputs changes and not once per telemetry read; a single memo
-- rather than a table, because only the current craft can be on screen.
local imageKey, imageFile, imageCaption

--- The model image and its caption: which picture belongs to the craft in front of us.
--
-- The craft name comes from the flight controller and the other three from the radio, so
-- the picture follows the model rather than the radio slot it is flown from. A per-cell
-- variant comes first, which is how one airframe flown on two batteries gets two pictures.
local function resolveModelImage(craftName, edgetxName, edgetxBitmap, cells)
  -- A flight controller with no name answers the read with an empty string rather than
  -- with nothing (tasks/msp/api/name.lua, Api.parse), so "" is the case to step over.
  if type(craftName) ~= "string" then craftName = "" end
  if type(edgetxName) ~= "string" then edgetxName = "" end
  if type(edgetxBitmap) ~= "string" then edgetxBitmap = "" end
  cells = math.floor(tonumber(cells) or 0)

  local key = craftName .. "\0" .. edgetxName .. "\0" .. edgetxBitmap .. "\0" .. cells
  if key == imageKey then return imageFile, imageCaption end

  local file = nil
  if craftName ~= "" then
    if cells > 0 then file = findImage(craftName .. "-" .. cells .. "S") end
    if not file then file = findImage(craftName) end
  end
  if not file then file = findImage(edgetxBitmap) end

  local caption = nil
  if craftName ~= "" then
    caption = craftName
  elseif edgetxName ~= "" then
    caption = edgetxName
  end

  imageKey, imageFile, imageCaption = key, file or LOGO_FILE, caption
  return imageFile, imageCaption
end

-- Builds `state.derived`: one resolved value per source the standing tree reads, so the
-- reactive sweep never probes. Probing (sensors, `model.getInfo`) is legal HERE -- this
-- runs in the widget's own pass, inside its pcall, on the telemetry-read cadence -- and
-- illegal in a reactive closure, which runs per frame on the refresh's leftover budget
-- outside any pcall (see GEMINI.md, "Dashboard reactive closures").
function Derived.build(state, sources)
  if type(state) ~= "table" then return end
  if not (Utils and type(Utils.mapTelemetrySource) == "function") then return end

  local snap = {}
  if type(sources) == "table" then
    for i = 1, #sources do
      local source = sources[i]
      if type(source) == "string" and source ~= "" then
        snap[source] = Utils.mapTelemetrySource(source, state)
      end
    end
  end

  -- Read by the image and text objects whether or not any box declares them as a source.
  snap.model_name = Utils.mapTelemetrySource("model_name", state)
  if model and type(model.getInfo) == "function" then
    local info = model.getInfo()
    if info then
      snap.edgetx_model_name = info.name
      snap.edgetx_model_bitmap = info.bitmap
    end
  end

  local craftName = nil
  if _G.rfsuite and type(_G.rfsuite.session) == "table" then
    craftName = _G.rfsuite.session.modelName
  end
  snap.model_image, snap.model_image_caption = resolveModelImage(
    craftName, snap.edgetx_model_name, snap.edgetx_model_bitmap, state.batteryCellCount)

  -- Assigned once, as a fresh table per build: closures hold `state` and read mid-sweep,
  -- so the swap has to be atomic -- a table filled in place would show half a snapshot.
  state.derived = snap
end

return Derived
