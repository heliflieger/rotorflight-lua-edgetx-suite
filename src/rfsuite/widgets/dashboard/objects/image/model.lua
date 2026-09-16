local Render = {}

-- Where the image and its caption come from is decided in the widget pass, not here:
-- resolving them walks the card and reads the craft name the flight controller reported,
-- and neither is allowed in an object (see GEMINI.md, "Dashboard reactive closures", and
-- the .luacheckrc override that enforces it). This file only places what the snapshot holds.
local LOGO_FILE = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/gfx/logo.png"

--- The derived snapshot, or nil before the first one has been built.
--
-- Read at call time rather than captured: `state.derived` is replaced by a fresh table on
-- every build, so a reference taken when the scene was built would freeze on the snapshot
-- of that moment.
local function snapshot(state)
  return (type(state) == "table" and state.derived) or nil
end

function Render.render(nodes, rect, box, state, themeCommon, utils)
  -- We need space for the text at the bottom
  local textH = 22
  local drawH = math.max(18, rect.h - 8 - textH)
  local drawW = math.max(18, rect.w - 8)

  nodes[#nodes + 1] = {
    type = "image",
    x = rect.x + 4,
    y = rect.y + 4,
    -- The whole draw area, and no aspect arithmetic: EdgeTX fits the picture inside these
    -- bounds itself and keeps its proportions, scaling by min(zw, zh) and centring the
    -- result (radio/src/gui/colorlcd/libui/static.cpp, StaticImage::setZoom and setSource).
    -- Guessing an aspect here could therefore only hand the firmware a smaller box than the
    -- one the theme reserved -- in a wide box, most of the width.
    w = drawW,
    h = drawH,
    -- A getter rather than a string, because the picture can change after the scene was
    -- built: the craft name arrives from the flight controller on its own schedule, and the
    -- render key that tears a scene down does not carry it (engine.lua, Engine.renderKey).
    -- EdgeTX calls this per frame but re-reads the file only when the string differs from
    -- the one it is showing (LvglWidgetImage::callRefs).
    file = function()
      local snap = snapshot(state)
      return (snap and snap.model_image) or LOGO_FILE
    end
  }

  if utils and type(utils.pushLabel) == "function" then
    utils.pushLabel(
      nodes,
      rect.x + 4,
      rect.y + rect.h - textH,
      rect.w - 8,
      function()
        local snap = snapshot(state)
        return (snap and snap.model_image_caption) or "Rotorflight"
      end,
      box.titlecolor or COLOR_THEME_DISABLED,
      CENTER,
      SMLSIZE
    )
  end
end

return Render
