local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = nil
local t = nil

local state = {
  lastSeq = -1,
  requestRebuild = nil,
  i18n = nil
}

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not t then t = Common and Common.pageT("diagnostics_session_logs") or nil end
end

local function pageText(i18n, key, fallback)
  local obj = i18n or state.i18n
  if t then return t(obj, key, fallback) end
  return fallback
end

local function getLogColor(level)
  local l = string.lower(tostring(level or "debug"))
  if l == "error" then return COLOR_THEME_WARNING end
  if l == "warn"  then return COLOR_THEME_PRIMARY2 end
  if l == "info"  then return COLOR_THEME_PRIMARY1 end
  -- debug / trace: use a mid-contrast colour that remains legible on both
  -- light and dark themes (avoids the invisible-white problem of GREY_DEFAULT).
  return COLOR_THEME_DISABLED
end

-- ---------------------------------------------------------------------------
-- Text-measurement helpers (mirrors the implementation in logs/page.lua)
-- ---------------------------------------------------------------------------

-- Returns the pixel width (and height) of `text` rendered in `font`.
-- Falls back to a character-count estimate when lcd.sizeText is unavailable.
local function textSize(text, font)
  local fn = lcd and lcd.sizeText
  if type(fn) == "function" then
    local ok, tw, th = pcall(fn, tostring(text or ""), font)
    tw, th = tonumber(tw), tonumber(th)
    if ok and tw and th and th > 0 then
      return tw, th
    end
  end
  return #tostring(text or "") * 7, 16
end

local ELLIPSIS = "..."

-- Per-font cache for the ellipsis pixel width.
local ellipsisW = {}
local function ellipsisWidth(font)
  local key = font or 0
  local w = ellipsisW[key]
  if not w then
    w = textSize(ELLIPSIS, font)
    ellipsisW[key] = w
  end
  return w
end

-- Largest byte offset <= n that lands on a UTF-8 character boundary.
local function charBoundary(text, n)
  while n > 0 do
    local b = string.byte(text, n + 1)
    if not b or b < 0x80 or b >= 0xC0 then return n end
    n = n - 1
  end
  return 0
end

-- Longest prefix of `text` (in bytes) that fits `maxW` px at `font`.
-- Binary-searches for the cut point; O(log N) font measurements per line.
local function fittingPrefix(text, font, maxW, minN)
  local best = minN
  local lo, hi = minN, #text - 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local n = charBoundary(text, mid)
    if textSize(string.sub(text, 1, n), font) <= maxW then
      if n > best then best = n end
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best
end

-- Truncate `text` so that text + "..." fits within `maxW` px at `font`.
-- Texts that already fit are returned unchanged.
local function fitToWidth(text, font, maxW)
  text = tostring(text or "")
  if maxW <= 0 or textSize(text, font) <= maxW then
    return text
  end
  local room = maxW - ellipsisWidth(font)
  if room <= 0 then return ELLIPSIS end
  local cut = string.sub(text, 1, fittingPrefix(text, font, room, 0))
  return (string.gsub(cut, "[%.%s]+$", "")) .. ELLIPSIS
end

-- ---------------------------------------------------------------------------

function M.getModuleTitle()
  return "Session Logs"
end

function M.getHeaderActions()
  return { reload = true, save = false, help = false }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  local rf = _G.rfsuite
  if rf then
    rf.log_history = {}
    rf.log_history_seq = (rf.log_history_seq or 0) + 1
    state.lastSeq = -1
  end
  return true
end

function M.build(ctx)
  ensureDeps()
  local rf = _G.rfsuite
  state.requestRebuild = ctx.requestRebuild
  state.i18n = ctx.i18n

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h

  -- Always sync sequence counter to prevent rebuild loop in empty state
  state.lastSeq = rf and rf.log_history_seq or 0

  local history = rf and rf.log_history
  if not history or #history == 0 then
    children[#children + 1] = {
      type  = "label",
      x = x + 10, y = y + 20, w = w - 20,
      text  = pageText(ctx.i18n, "no_logs", "No logs available"),
      color = COLOR_THEME_DISABLED, align = CENTER
    }
    return
  end

  local font     = SMLSIZE
  local _, lineH = textSize("Ag", font)
  local rowH     = math.max(14, lineH)
  local maxW     = w - 10
  local cursorY  = y + 5
  local maxVisible = math.floor((h - 10) / rowH)

  local startIdx = 1
  if #history > maxVisible then
    startIdx = #history - maxVisible + 1
  end

  for i = startIdx, #history do
    local entry = history[i]
    local color = getLogColor(entry.level)

    local timeStr = ""
    if entry.time and entry.time > 0 then
      timeStr = string.format("[%0.1f] ", entry.time / 100)
    end

    local lineText = timeStr .. "[" .. tostring(entry.tag) .. "] " .. tostring(entry.msg)

    -- Truncate to available width so the label never wraps onto a second
    -- row and pushes the next entry down by more than rowH pixels (issue #91).
    lineText = fitToWidth(lineText, font, maxW)

    children[#children + 1] = {
      type  = "label",
      x     = x + 5,
      y     = cursorY,
      w     = maxW,
      text  = lineText,
      color = color,
      font  = font
    }
    cursorY = cursorY + rowH
  end
end

function M.wakeup()
  local rf = _G.rfsuite
  if rf and (rf.log_history_seq or 0) ~= state.lastSeq then
    if type(state.requestRebuild) == "function" then
      state.requestRebuild()
    end
  end
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.requestRebuild = nil
  state.lastSeq = -1
  state.i18n = nil
  Common = nil
  t = nil
end

return M
