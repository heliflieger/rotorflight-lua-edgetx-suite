local Splash = {}

local LOGO_FILE = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/gfx/logo.png"

function Splash.build(zone, statusLine, title)
  local w = (zone and zone.w) or LCD_W or 320
  local h = (zone and zone.h) or LCD_H or 172
  local logoW = math.max(112, math.min(math.floor(w * 0.80), 240))
  local logoH = math.max(36, math.min(math.floor(h * 0.32), 68))
  local logoX = math.floor((w - logoW) * 0.5)
  local logoY = math.max(6, math.floor(h * 0.10))
  local titleY = math.max(math.floor(h * 0.44), logoY + logoH + 8)
  local lineY = titleY + 46

  return {
    {
      type = "rectangle",
      x = 0,
      y = 0,
      w = w,
      h = h,
      color = COLOR_THEME_PRIMARY3,
      filled = true
    },
    {
      type = "image",
      x = logoX,
      y = logoY,
      w = logoW,
      h = logoH,
      file = LOGO_FILE
    },
    {
      type = "label",
      x = 0,
      y = titleY,
      w = w,
      text = tostring(title or "Connecting FBL..."),
      align = CENTER,
      color = COLOR_THEME_PRIMARY2,
      font = MIDSIZE
    },
    {
      type = "label",
      x = 0,
      y = lineY,
      w = w,
      text = tostring(statusLine or "Please wait for telemetry"),
      align = CENTER,
      color = COLOR_THEME_PRIMARY2,
      font = SMLSIZE
    }
  }
end

return Splash
