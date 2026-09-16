local M = {}

local function clamp01(v)
  local n = tonumber(v) or 0
  if n < 0 then return 0 end
  if n > 1 then return 1 end
  return n
end

-- The measured width and line height of a string in one font. `lcd.sizeText(text, flags)` is
-- the EdgeTX name and it takes the font flags, so the answer is for the font the label is
-- actually drawn in; it is not gated on a drawing context, so it may be called while the child
-- list is being built. The fallback is deliberately crude and only has to be safe on a build
-- that does not offer the call at all.
local function textSize(text, font, fallbackCharW, fallbackLineH)
  local fn = lcd and lcd.sizeText
  if type(fn) == "function" then
    local ok, tw, th = pcall(fn, tostring(text or ""), font)
    tw, th = tonumber(tw), tonumber(th)
    if ok and tw and th and th > 0 then
      return tw, th
    end
  end

  return #tostring(text or "") * fallbackCharW, fallbackLineH
end

--- The longest prefix of `text` that still counts as `lines` lines, with an ellipsis on it.
--
-- Bisected rather than walked: `count` measures a whole string, and calling it once per
-- character on a long stack trace is the kind of loop this tool has a budget for. The cut is
-- moved back off a UTF-8 continuation byte, so a truncated string cannot end in half a
-- character on a locale that has any.
local ELLIPSIS = "..."

local function truncateToLines(text, lines, count)
  local best = ELLIPSIS
  local lo, hi = 0, #text
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local cut = mid
    while cut > 0 do
      local b = string.byte(text, cut + 1)
      if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
    end
    local candidate = string.sub(text, 1, cut) .. ELLIPSIS
    if count(candidate) <= lines then
      best = candidate
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best
end

function M.append(children, opts)
  if type(children) ~= "table" or type(opts) ~= "table" then return end

  local x = tonumber(opts.x) or 0
  local y = tonumber(opts.y) or 0
  local w = tonumber(opts.w) or 0
  local h = tonumber(opts.h) or 0
  if w <= 0 or h <= 0 then return end

  local title = tostring(opts.title or "Loading")
  local message = tostring(opts.message or "")
  local progress = clamp01(opts.progress)

  local action = type(opts.action) == "table" and opts.action or nil

  -- A box that reports no progress. A notice waiting to be acknowledged has none to
  -- report, and a bar sitting at zero or at full under it says something untrue; without
  -- one the box is the same shape, one row shorter.
  local showBar = opts.bar ~= false

  local boxW = math.min(420, math.max(220, w - 40))
  local innerW = boxW - 28

  -- The title is drawn in MIDSIZE into `innerW` and wraps when it does not fit, while
  -- everything under it sat at a fixed offset from the top of the box -- so a title of two
  -- lines was drawn ON the message. Each extra line now moves the message, the bar and the
  -- button down by one line height and makes the box that much taller. A one-line title, which
  -- is what every caller in the tree passes, leaves `extra` at 0 and reproduces the geometry
  -- this file had before, arithmetic for arithmetic.
  local titleW, titleLineH = textSize(title, MIDSIZE, 12, 24)
  local titleLines = 1
  if innerW > 0 and titleW > innerW then
    titleLines = math.ceil(titleW / innerW)
  end
  local extra = (titleLines - 1) * titleLineH

  -- And the FIRST title line needs its own line height too. The message started a fixed 32 px
  -- below the top of the title, and 32 px is less than the MIDSIZE line height on the large
  -- font set: radio/src/fonts/CMakeLists.txt compiles fonts/lvgl/lrg for an 800 px target and
  -- its lv_font_en_L.c is generated at 33 ppem with .line_height = 42 (.base_line = 9), so the
  -- title's line box ran 10 px into the message's there -- and the default title has a
  -- descender to put in that overlap. `titleLineH` above is already the number to use: it is
  -- lv_font_get_line_height() of that font. The 32 px stays as the lower bound, so the font
  -- sets whose MIDSIZE already fits keep the spacing this box was drawn with -- lvgl/std
  -- declares 29 and lvgl/sml declares 23 -- and only the large set moves.
  local titleStep = math.max(32, titleLineH)
  local titleShift = titleStep - 32

  -- The message is given a fixed 68 px between its own top and whatever comes next -- one
  -- SMLSIZE line plus the gap this box is drawn with -- and one line is not what every
  -- caller passes. app/pages/logs/page.lua passes the message from i18n/en.lua that carries
  -- an explicit newline and a second sentence wider than the box, so the label is broken
  -- into three lines on the large font set and the last one reached into the progress bar;
  -- the ESC pages' safety warning is two lines on every set but the standard one. The label
  -- has a width and no height, so LVGL sizes it to its own text with LV_LABEL_LONG_WRAP,
  -- which breaks on a newline and on the width -- count both, the same way the title is
  -- counted above, and grow the box by the amount those lines do not fit in. Most of the
  -- multi-line cases still fit, and those do not move.
  local _, messageLineH = textSize("", SMLSIZE, 6, 14)
  -- `string.gmatch(s, ...)`, not `s:gmatch(...)`. Indexing a string needs the string
  -- metatable, and this tree does not rely on it having one: every other split here goes
  -- through the library form.
  --
  -- The words are walked rather than the width divided. A division answers "how many line
  -- widths of text is this", and LV_LABEL_LONG_WRAP breaks at word boundaries -- so every line
  -- that breaks early at a long word leaves slack the division does not see, and the count comes
  -- out LOW. It was low enough on a runtime error string to put the button on top of the text.
  -- A word wider than the line is broken inside the word, which the inner loop follows.
  local spaceW = textSize(" ", SMLSIZE, 6, 14)
  local function countMessageLines(text)
    local n = 0
    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
      n = n + 1
      local used = 0
      for word in string.gmatch(line, "%S+") do
        local wordW = textSize(word, SMLSIZE, 6, 14)
        local add = used > 0 and spaceW + wordW or wordW
        if used > 0 and used + add > innerW then
          n = n + 1
          used = wordW
        else
          used = used + add
        end
        while innerW > 0 and used > innerW do
          n = n + 1
          used = used - innerW
        end
      end
    end
    return n
  end
  local messageLines = countMessageLines(message)
  -- The room the layout gives the message: from its own top to the top of the bar, which is
  -- where the button goes when there is no bar. Written as the difference of the two offsets
  -- this file already uses rather than as a number, so it stays correct if either moves.
  local messageTop = 10 + titleStep + extra
  local messageRoom = (110 + extra + titleShift) - messageTop
  local barBlock = showBar and 0 or -32
  local baseBoxH = (action and 208 or 154) + extra + barBlock + titleShift

  -- A message has no length of its own to rely on: a runtime error string is whatever was
  -- raised. The box grows by every line that does not fit in `messageRoom`, so past a certain
  -- length it grows off the bottom of the screen and takes the acknowledging button with it --
  -- and a modal whose only button is off-screen cannot be dismissed at all. Cap what is DRAWN
  -- instead. Nothing is lost by it: whoever raises one of these has already written the full
  -- text to the card log, so the short form here is a summary rather than the only copy.
  local maxLines = (h >= 400) and 6 or 3
  -- And never more lines than the box can grow by while still fitting on the screen, whatever
  -- the cap above says: the geometry is the hard constraint, the cap is the readable one.
  local roomForLines = math.floor((messageRoom + math.max(0, h - 16 - baseBoxH)) / messageLineH)
  if maxLines > roomForLines then maxLines = roomForLines end
  if maxLines < 1 then maxLines = 1 end

  if messageLines > maxLines then
    message = truncateToLines(message, maxLines, countMessageLines)
    messageLines = countMessageLines(message)
  end

  local messageShift = math.max(0, messageLines * messageLineH - messageRoom)
  local boxH = baseBoxH + messageShift
  local boxX = x + math.floor((w - boxW) / 2)
  local boxY = y + math.floor((h - boxH) / 2) - 64
  if boxY < y + 8 then
    boxY = y + 8
  end

  local barX = boxX + 16
  local barY = boxY + 110 + extra + titleShift + messageShift
  local barW = boxW - 32
  local barH = 16
  local fillW = math.floor((barW - 4) * progress + 0.5)

  children[#children + 1] = {
    type = "rectangle",
    x = boxX,
    y = boxY,
    w = boxW,
    h = boxH,
    color = COLOR_THEME_PRIMARY2,
    filled = true
  }

  children[#children + 1] = {
    type = "label",
    x = boxX + 14,
    y = boxY + 10,
    w = innerW,
    text = title,
    color = COLOR_THEME_PRIMARY1,
    font = MIDSIZE
  }

  children[#children + 1] = {
    type = "label",
    x = boxX + 14,
    y = boxY + messageTop,
    w = innerW,
    text = message,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  -- The track, and it needs a colour of its own. GREY_DEFAULT is exported to Lua only when
  -- LCD_DEPTH > 1 and COLORLCD is NOT defined (radio/src/lua/api_general.cpp), so on every
  -- radio this overlay can run on it is nil -- and a rectangle with no colour is drawn in
  -- COLOR_THEME_SECONDARY1, which is what the filled part uses. Track and fill were therefore
  -- the same colour, and the bar read as full from the first frame to the last.
  if showBar then
    children[#children + 1] = {
      type = "rectangle",
      x = barX,
      y = barY,
      w = barW,
      h = barH,
      color = COLOR_THEME_SECONDARY2,
      filled = true
    }

    if fillW > 0 then
      children[#children + 1] = {
        type = "rectangle",
        x = barX + 2,
        y = barY + 2,
        w = fillW,
        h = barH - 4,
        color = COLOR_THEME_SECONDARY1,
        filled = true
      }
    end
  end

  -- An optional way out of the notice. A loading box normally has none, because there is
  -- nothing to decide while something is being read; a caller that CAN be left early -- a save
  -- whose settings are already stored, waiting on a flight controller that may never come back
  -- -- passes one, and it is drawn here so the box geometry stays in one place.
  if action then
    local btnW = math.min(180, boxW - 32)
    children[#children + 1] = {
      type = "button",
      x = boxX + math.floor((boxW - btnW) / 2),
      y = showBar and (barY + barH + 14) or barY,
      w = btnW,
      h = 32,
      text = tostring(action.text or "OK"),
      press = type(action.press) == "function" and action.press or function() end
    }
  end
end

-- A notice the pilot has to acknowledge: the same box, without a progress bar it has no
-- progress to put in, and with exactly one button. This exists so that nothing in the
-- tool has to reach for lvgl.message, which is a native modal outside the tool's own
-- run loop -- while one stands, run() is not reached, and which key or touch closes it
-- depends on whether anything focusable was created after it in the same build.
function M.appendNotice(children, opts)
  if type(opts) ~= "table" then return end

  local press = type(opts.press) == "function" and opts.press or function() end
  M.append(children, {
    x = opts.x,
    y = opts.y,
    w = opts.w,
    h = opts.h,
    title = opts.title,
    message = opts.message,
    bar = false,
    action = { text = opts.buttonText or "OK", press = press }
  })
end

return M
