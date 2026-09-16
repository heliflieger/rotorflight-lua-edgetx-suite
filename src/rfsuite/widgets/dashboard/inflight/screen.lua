-- The three renderings of the in-flight tuning overlay: the widget zone, fullscreen, and the
-- ground surface between flights.
--
-- All three append node tables to `children`, the idiom widgets/dashboard/fullscreen_menu.lua
-- uses, so the runtime builds them exactly the way it builds the quick settings menu.
--
-- The layout is the concept drawing's, and it is laid out in FRACTIONS of the widget's own zone
-- rather than in constants: the reference is 480 x 272, the pilot's radio is 480 x 320 and the
-- large radios are 800 x 480, and a surface a pilot reads at arm's length in sunlight cannot have
-- a row list that runs off the bottom of one of them. Only the fonts step, because the firmware
-- offers a ladder of five and not a size.
--
-- The zone screen carries NO buttons. Whether an LVGL button in a non-fullscreen widget zone ever
-- receives a press is not something this file knows, and a control that may or may not answer is
-- worse on a tuning screen than no control at all: there the pilot's trims are the input and the
-- screen is the read-out.
--
-- What is reactive here is what the FLIGHT CONTROLLER moves -- the value, the value it stepped
-- from, the six row values, the active row's colour and the lines that expire on the clock -- and
-- every one of them reads the precomputed snapshot on `widget.state.inflight` and nothing else.
-- Everything else is laid down at build time and replaced when the render key moves. The division
-- is not a style: the board answers a step while the radio is still holding the pulse that asked
-- for it, and a rebuild in that window costs the pilot a second step he did not ask for. That is the rule from
-- GEMINI.md: a closure handed to lvgl.build runs per frame, on whatever instruction budget
-- refresh() left over, outside the widget's own pcall.

local M = {}

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

local Functions = requireModule("widgets/dashboard/inflight/functions.lua")
local Drive = requireModule("widgets/dashboard/inflight/drive.lua")

-- A dependency that did not load must not leave a WORKING-LOOKING module behind.
--
-- lib/require.lua caches whatever a chunk RETURNS. Its own load of a dependency goes through
-- pcall, and a pcall catches the firmware's instruction-limit error like any other -- so a widget
-- pass that runs out of budget while one of the files above is being read leaves the require
-- answering nil, this chunk running on to its end with a nil upvalue, and the broken table cached
-- for the rest of the session. Every call into it then raises
--   ?:0: attempt to index a nil value (upvalue '?')
-- on every pass, for ever, and the widget's refresh is abandoned each time. That is what the
-- pilot's card log recorded 913 times after a start with no flight controller: the overlay's
-- modules were first loaded on the pass the connect chain and the theme reload were already
-- filling, and the load that lost the race was cached.
--
-- Raising here instead means the pcall in lib/require.lua fails, NOTHING is cached, and the next
-- pass loads the file again on a budget that may well be quieter. A missing file behaves the same
-- way and is answered by the caller, which keeps its own retry.
if type(Functions) ~= "table" or type(Drive) ~= "table" then
  error("inflight/screen.lua: a dependency did not load", 0)
end

-- The ground half, loaded only when the ground surface is actually built. It pulls in the MSP
-- runtime and the api modules behind it, and the zone screen -- the one that is built while the
-- pilot is flying -- has no use for any of that.
local PrimeModule = nil
local function prime()
  if PrimeModule == nil then
    PrimeModule = requireModule("widgets/dashboard/inflight/prime.lua") or false
  end
  if PrimeModule == false then return nil end
  return PrimeModule
end


local UNKNOWN_VALUE = "--"

local function translator(widget)
  return (widget.i18n and type(widget.i18n.t) == "function") and widget.i18n.t
    or function(key, fallback) return fallback or key end
end

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

--- The surface's palette.
--
-- The theme's own constants where the quick settings menu uses them, and named colours where the
-- drawing asks for one the theme does not carry. `lcd.RGB` is the firmware's own mixer and this
-- file is not the first to reach for it: widgets/dashboard/fullscreen_menu.lua builds its
-- background with it, and widgets/dashboard/objects/common.lua wraps it for the gauges.
--
-- The accent is AMBER and deliberately not the theme's, which is the one deviation from "use what
-- the theme gives you". The tuning surface is a MODE: the flight controller is being driven from
-- the radio, the value the pilot is looking at is being written to the board, and the one thing
-- that must never happen is a pilot mistaking it for the dashboard. A theme whose accent is the
-- dashboard's accent cannot say that. Every colour falls back to a named constant on a build
-- without lcd.RGB, so a radio that lacks it gets a plainer screen rather than an error.
local function rgb(r, g, b, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local ok, col = pcall(lcd.RGB, r, g, b)
    if ok and col ~= nil then return col end
  end
  return fallback
end

local function palette()
  local p = {}
  p.bg = rgb(10, 12, 16, COLOR_THEME_PRIMARY3 or BLACK)
  p.header = rgb(28, 32, 40, COLOR_THEME_PRIMARY1 or BLACK)
  p.text = WHITE
  p.dim = rgb(140, 140, 140, COLOR_THEME_DISABLED or WHITE)
  p.accent = rgb(255, 180, 40, COLOR_THEME_SECONDARY1 or YELLOW)
  p.ok = rgb(90, 200, 120, GREEN or WHITE)
  p.warn = COLOR_THEME_WARNING or p.accent
  p.button = rgb(40, 44, 54, COLOR_THEME_PRIMARY1 or BLACK)
  -- The armed row's fill: dark, with just enough of the accent in it that the outline reads as
  -- belonging to the row rather than floating over it.
  p.rowFill = rgb(45, 45, 30, COLOR_THEME_PRIMARY1 or BLACK)
  return p
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

-- The firmware's font ladder, with the heights the layout has to reserve for them.
--
-- There is no way to ask the firmware how tall a font is from a widget, so these are read off a
-- rendered frame -- the title in the header, the parameter name and the value, measured on the
-- simulator at 800 x 480 -- and every vertical stack below is built from them. They are the box
-- the glyphs occupy and not the cap height: a stack built from the cap height puts the next line
-- across the descenders of the one above, which is what the caption did to the parameter name.
local FONT_H = { [SMLSIZE or -1] = 14, [MIDSIZE or -2] = 30, [DBLSIZE or -3] = 40, [XXLSIZE or -4] = 66 }

local function fontHeight(font)
  return FONT_H[font] or 12
end

-- How wide one character of each font is, on average. The firmware will not say, and a label
-- whose text is wider than its box does not clip it -- it WRAPS, onto the row below and off the
-- bottom of the screen. So text that cannot fit is cut here instead.
--
-- MEASURED on a rendered frame, per font, and not derived from the height by one ratio: the
-- small font runs about 8.5 pixels against a box 14 tall and the middle one about 15 against a
-- box of 30, so one ratio over-estimates the larger fonts by a third and cuts titles that fit.
--
-- Each figure is the WIDEST average a string of that font was measured at, not the mean one --
-- `Yaw CCW Stop` runs 10.1 pixels a character where a lowercase sentence runs 8. A budget set at
-- the mean cuts most strings correctly and lets the capital-heavy ones wrap, which is the failure
-- it exists to prevent; set at the maximum it cuts a few strings a character early, which is not
-- a failure at all.
local FONT_W = { [SMLSIZE or -1] = 11, [MIDSIZE or -2] = 16, [DBLSIZE or -3] = 21, [XXLSIZE or -4] = 34 }

local function charWidth(font)
  return FONT_W[font] or 9
end

--- The layout, in fractions of the zone the widget was given.
--
-- Every number here is the concept drawing's own, divided by 480 or by 272: the drawing is the
-- specification and this is it, expressed so that the same surface lands on a 480 x 320 radio and
-- on an 800 x 480 one. What does NOT scale is the font ladder, so the two size classes below pick
-- the nearest rung and the vertical stacks are built from the chosen font's height rather than
-- from a constant -- which is the defect the first cut had, a caption laid out for one font and
-- drawn in another, printed over the parameter name.
local function metrics(w, h, fullscreen)
  local m = {}
  m.large = h > 350

  if m.large then
    m.font = MIDSIZE
    m.nameFont = DBLSIZE
  else
    m.font = SMLSIZE
    m.nameFont = MIDSIZE
  end
  m.small = SMLSIZE
  m.valueFont = XXLSIZE
  m.fontH = fontHeight(m.font)
  m.smallH = fontHeight(m.small)
  m.nameH = fontHeight(m.nameFont)
  m.valueH = fontHeight(m.valueFont)
  m.lineH = m.smallH + 2
  -- The label objects carry leading above the glyphs; their own menu nudges its text up by the
  -- same amounts and this surface has to sit on the same baselines.
  m.textOff = m.large and -6 or -2

  m.pad = math.max(3, math.floor(w * 0.021 + 0.5))
  m.headerH = math.max(16, math.floor(h * 0.125 + 0.5))
  m.chipY = m.headerH + math.max(2, math.floor(h * 0.029 + 0.5))
  m.chipH = math.max(14, math.floor(h * 0.096 + 0.5))
  m.chipGap = math.max(2, math.floor(w * 0.0125 + 0.5))
  m.chipW = math.max(12, math.floor(w * 0.075 + 0.5))
  m.chipEnd = m.pad + Functions.BANK_COUNT * (m.chipW + m.chipGap)
  -- To the right edge and not to the row column: the caption sits ABOVE the row list, so its
  -- width is bounded by the screen. Bounded at the column, the longer of the two things that
  -- can stand here wrapped into three lines and ran into the row caption below it.
  m.chipCaptionW = w - m.chipEnd - m.pad

  m.bodyY = math.max(m.chipY + m.chipH + 4, math.floor(h * 0.279 + 0.5))
  m.rowX = math.floor(w * 0.58 + 0.5)
  m.rowH = math.max(10, math.floor(h * 0.081 + 0.5))
  -- The four columns inside a row are fractions of the ROW's own width and not of the screen's.
  -- Taken from the screen they grow faster than the row does -- at 800 pixels the name was left
  -- 40 of the row's 283 -- and a label narrower than its text does not clip, it WRAPS: the row
  -- list drew each name three lines deep, over its neighbours and off the bottom of the screen.
  m.rowW = w - m.rowX - m.pad
  m.rowNumX = m.rowX + math.max(2, math.floor(m.rowW * 0.035 + 0.5))
  m.rowTrimX = m.rowX + math.floor(m.rowW * 0.10 + 0.5)
  m.rowNameX = m.rowX + math.floor(m.rowW * 0.30 + 0.5)
  m.rowTrimW = m.rowNameX - m.rowTrimX - 2
  -- Four digits, because a head speed is four and a value cut to three would read as a plausible
  -- number that is not the one on the board.
  m.rowValueW = math.max(math.floor(m.rowW * 0.22 + 0.5), 4 * charWidth(m.small) + 4)
  m.rowNameW = (m.rowX + m.rowW) - m.rowValueW - m.rowNameX - 6

  m.leftX = math.floor(w * 0.025 + 0.5)
  m.leftW = m.rowX - m.leftX - m.pad
  -- Far enough right that four digits of the big value fit to its left. A fraction alone put the
  -- primed and spoken lines on top of the third digit at 480 pixels, and the value -- being a
  -- label like any other -- wrapped its last digit onto a line of its own.
  m.sideX = m.leftX + math.max(math.floor(w * 0.204 + 0.5), 4 * charWidth(m.valueFont) + 6)
  m.valueW = m.sideX - m.leftX - 4

  m.nameY = m.bodyY + 2
  -- The caption under the name -- "row 2 - bank P - trim Ele" -- is gone on the pilot's word after
  -- the third radio round: he reads the row and the bank off the highlighted row and the lit chip
  -- and never looked at the sentence. Its line goes to the value, which is the thing he does look
  -- at. The slot itself stays, as the ZONE screen's home for the profile banner, and carries
  -- nothing at all the rest of the time.
  m.captionY = m.nameY + m.nameH + 2
  m.valueY = m.captionY + math.floor(m.smallH / 2)
  m.sideY = m.valueY + math.floor(m.valueH / 2) - m.smallH

  -- The ground surface's four status lines. They used to be the smallest font the radio has at a
  -- pitch of that font plus two, which on an 800-pixel screen is four cramped lines under a header
  -- twice their height. They take the row list's own scaling instead -- the same fraction of the
  -- zone height m.rowH is -- with a floor at the larger font's box, so the pitch does not move
  -- when the block picks its font. That matters beyond looks: the ground actions are placed under
  -- this block rather than at a fixed line, so a pitch that varied would move the buttons.
  m.statusLineH = math.max(m.fontH + 2, m.rowH)

  m.actionH = fullscreen and math.max(18, math.floor(h * 0.206 + 0.5)) or 0
  m.actionY = fullscreen and (h - m.actionH - math.max(3, math.floor(h * 0.029 + 0.5))) or h
  m.buttonW = math.floor(w * 0.271 + 0.5)
  -- The hints start clear of the two step buttons, not at the row column: the buttons are wider
  -- than the space to the left of that column and the first letter of every hint was drawn
  -- underneath the plus.
  m.hintX = math.max(m.rowX, m.pad * 3 + m.buttonW * 2)
  m.hintW = w - m.hintX - m.pad
  -- The glyph inside the step button, at the largest rung the button is tall enough to hold.
  m.glyphFont = (m.actionH >= 80) and XXLSIZE or DBLSIZE
  m.glyphH = fontHeight(m.glyphFont)
  m.hintY = m.actionY + math.max(2, math.floor(h * 0.022 + 0.5))
  return m
end

-- How wide the frame around an interactive chip, row or step button is -- and, because the
-- object that carries the press is inset by it, how much smaller that object is than the frame.
local OUTLINE_W = 2

local function appendLabel(children, x, y, w, text, color, font, align)
  children[#children + 1] = {
    type = "label", x = x, y = y, w = w, text = text, color = color, align = align, font = font
  }
end

--- A label whose glyphs sit centred in a box `boxH` tall.
local function appendCentredLabel(children, x, y, w, boxH, text, color, font, align, m)
  appendLabel(children, x, y + math.floor((boxH - fontHeight(font)) / 2) + m.textOff,
    w, text, color, font, align)
end


--- `text`, cut to what fits in `width` at `font`. Cut without an ellipsis: three dots cost three
-- of the characters that were the reason to cut, and on a parameter name the front is what
-- identifies it.
local function textFits(text, width, font)
  if type(text) ~= "string" then return true end
  return (#text * charWidth(font)) <= width
end

local function fitText(text, width, font)
  if type(text) ~= "string" then return text end
  local budget = math.floor(width / charWidth(font))
  if budget < 1 then budget = 1 end
  if #text <= budget then return text end
  return string.sub(text, 1, budget)
end

--- `long` where it fits, `short` where it does not, cut only if neither does.
--
-- A caption or a hint carries more on a wide screen than on a narrow one, and the alternative --
-- one wording cut in the middle -- loses the end of the sentence on every radio rather than on
-- the small one. The pair is two i18n keys and the choice is made per screen.
local function pickText(long, short, width, font)
  if textFits(long, width, font) then return long end
  return fitText(short, width, font)
end

local function formatValue(value)
  if value == nil then return UNKNOWN_VALUE end
  return tostring(math.floor(value + 0.5))
end

-- ---------------------------------------------------------------------------
-- The setup check, as one line
-- ---------------------------------------------------------------------------

--- The verdict, walked ONCE and then kept on the drive.
--
-- Two things this is deliberately not. It is not on a timer: with a two-second one it walked the
-- model's mixer lines, its variable details and its flight mode's trim modes over and over for as
-- long as the surface was up -- and in the air that is every couple of seconds, for a verdict
-- about a model that cannot change while the pilot is flying it. And it is not run while the
-- overlay is LIVE at all: the ground surface is the only place the verdict is shown, and it walks
-- nothing while the overlay is up, because the one place that budget must not be spent is the
-- pass that is driving the flight controller.
--
-- The walk is repeated when the settings move, which is the only thing that can change the answer
-- without the pilot leaving this screen; widgets/dashboard/inflight/drive.lua's own settings
-- comparison drops the cache when it re-settles a drive.
--
-- What holds the walk off is the PHASE and not the interlock, and the difference is the whole of
-- the verdict on a great many screens. `live` says the interlock is closed; the phase says the
-- craft is in the air, since it only reaches `live` on the arm reading. A pilot who closes the
-- interlock on the ground -- to look at the surface before he flies, which is what it is for --
-- had a drive whose `live` was already true, so the walk never ran and the one line that exists
-- to tell him whether his model is wired up read "Setup not checked" for the whole session. The
-- reason the walk is held off at all is the pass that is driving the flight controller, and that
-- pass is the airborne one.
function M.checkVerdict(widget)
  local drive = widget and widget._inflight
  if drive == nil then return nil end
  -- One cache, and the drive owns it: the same verdict decides whether the interlock may close at
  -- all, so a walk of this screen's own would be a second answer to a question with one.
  return Drive.verdict(drive)
end

--- The verdict in one sentence. Faults are grouped by what the pilot has to go and fix rather
-- than listed one by one: the model has one mixer page, one global variable page and one trim
-- setting, and naming those three is what makes the message actionable on a flight line.
function M.describeCheck(result, t)
  if result == nil then
    return t("widgets.dashboard.inflight_check_unchecked", "Setup not checked")
  end
  if result == "ok" then
    return t("widgets.dashboard.inflight_check_ok", "Setup OK")
  end
  if type(result) ~= "table" then return "" end

  local unset, mix, gvar, trim, claim = false, false, false, false, false
  local same, twice = false, false
  for i = 1, #result do
    local code = result[i]
    -- The two "one thing doing both jobs" faults are matched FIRST and by name. `same_gvar` reads
    -- as neither a gvar_ fault nor a mixer one, and left to the tests below it would have fallen
    -- through to "not set" -- which is the opposite of what it is.
    if code == "same_gvar" or code == "same_channel" then
      same = true
    elseif code == "trim_claimed_twice" then
      twice = true
    elseif string.find(code, "mix", 1, true) then
      mix = true
    elseif string.find(code, "gvar_", 1, true) then
      gvar = true
    elseif string.find(code, "trim_mode", 1, true) then
      trim = true
    elseif code == "no_nav_trim" then
      claim = true
    else
      unset = true
    end
  end

  local parts = {}
  if unset then parts[#parts + 1] = t("widgets.dashboard.inflight_check_unset", "Switch or variables not set") end
  if same then parts[#parts + 1] = t("widgets.dashboard.inflight_check_same", "Bank and value share a variable or a channel") end
  if mix then parts[#parts + 1] = t("widgets.dashboard.inflight_check_mix", "Mixer line missing or wrong") end
  if gvar then parts[#parts + 1] = t("widgets.dashboard.inflight_check_gvar", "Variable range or precision") end
  if trim then parts[#parts + 1] = t("widgets.dashboard.inflight_check_trim", "Trim still active here") end
  if claim then parts[#parts + 1] = t("widgets.dashboard.inflight_check_claim", "Walk and adjust need two trims") end
  if twice then parts[#parts + 1] = t("widgets.dashboard.inflight_check_twice", "One trim is claimed twice") end
  return table.concat(parts, " / ")
end

-- ---------------------------------------------------------------------------
-- The pieces the three surfaces share
-- ---------------------------------------------------------------------------

--- The header bar: what this surface is, which profile it is tuning, and whether it is live.
--
-- The set the rows come from is named HERE rather than left to the ground surface, because a
-- standard set and a set read off the board name the same six banks differently and the chips
-- immediately below carry the difference.
local function appendHeader(children, widget, m, w, t, p, closeW)
  local snapshot = widget.state.inflight or {}
  children[#children + 1] = {
    type = "rectangle", x = 0, y = 0, w = w, h = m.headerH, color = p.header, filled = true
  }

  -- The headline is the PROFILE, and that is the pilot's own ruling after the third radio round.
  -- The firmware's adjustments act on whichever PID profile is active, he chooses that with a
  -- switch of his own, and everything else on this surface is true of that one profile and of no
  -- other -- so it is the one thing on the screen that must not need looking for. It used to be
  -- dim text beside a title that said "TUNING - set: standard"; the set moved to the ground
  -- surface, which is where it can be acted on, and the profile took the room.
  local titleText = t("widgets.dashboard.inflight_title", "TUNING") .. " "
    .. t("widgets.dashboard.inflight_profile", "profile") .. " "
    .. (snapshot.profile and formatValue(snapshot.profile) or UNKNOWN_VALUE)
  local titleFont = m.large and m.font or m.small
  titleText = fitText(titleText, math.floor(w * 0.60), titleFont)
  local titleW = #titleText * charWidth(titleFont)
  appendCentredLabel(children, m.pad, 0, titleW, m.headerH, titleText, p.text, titleFont, LEFT, m)

  local profile = ""
  local backupText = nil
  if snapshot.backup ~= nil and snapshot.backup.profile ~= nil then
    backupText = t("widgets.dashboard.inflight_hdr_backup", "backup")
      .. " " .. tostring(snapshot.backup.profile)
  end

  -- Which of the three phases this is, in one word. The switch is one, so the word is what says
  -- which surface the pilot is looking at.
  local liveText, liveColor
  if snapshot.phase == "live" then
    liveText, liveColor = t("widgets.dashboard.inflight_live", "LIVE"), p.ok
  elseif snapshot.phase == "post" then
    liveText, liveColor = t("widgets.dashboard.inflight_after", "AFTER"), p.accent
  else
    liveText, liveColor = t("widgets.dashboard.inflight_ground", "GROUND"), p.dim
  end
  -- Wide enough for the LONGER of the two words in the SMALL font, which is what it is drawn in:
  -- in the middle font `GROUND` needs a hundred pixels and wrapped into `GRO` over `UND`, and the
  -- room to widen the box is room the profile beside it needs.
  local liveW = math.max(math.floor(w * 0.09), 6 * charWidth(m.small) + 6)
  local liveX = w - closeW - m.pad - liveW
  local dotR = math.max(3, math.floor(m.headerH * 0.12))
  children[#children + 1] = {
    type = "circle", x = liveX - m.pad - dotR, y = math.floor(m.headerH / 2),
    radius = dotR, color = liveColor, filled = true
  }
  appendCentredLabel(children, liveX, 0, liveW, m.headerH, liveText, liveColor, m.small, LEFT, m)

  -- The backup is dropped WHOLE rather than cut in half where the header is too narrow for it.
  -- On the shortest radio the box between the title and the phase word is a hundred pixels, and a
  -- label that does not fit wraps -- inside a header bar, onto a line that is not there.
  local profileX = m.pad * 2 + titleW
  local profileW = liveX - m.pad - dotR * 2 - m.pad - profileX
  if backupText ~= nil and profileW > 0 and textFits(backupText, profileW, m.small) then
    profile = backupText
  end
  if profile ~= "" then
    appendCentredLabel(children, profileX, 0, profileW, m.headerH,
      fitText(profile, profileW, m.small), p.dim, m.small, RIGHT, m)
  end
end

--- The six bank chips, and one caption beside them.
--
-- Labelled with the standard set's own letters -- P, I, D, F, O, B -- when that is the set, and
-- with 1..6 when the set came off the board, where a letter would stand for nothing. `press` is
-- nil on the zone and ground surfaces, which is what makes them read-outs there.
--- The profile the board is now flying, while a change of it is fresh.
--
-- The firmware's adjustments act on the ACTIVE PID profile and the pilot chooses that with his own
-- switch, so a profile change moves what the overlay is tuning without the overlay being told. The
-- values it was showing describe a profile nobody is flying any more; they go to dashes, and a
-- dash on its own does not say why.
--
-- Answers nil when no banner is standing, so a caller can fall back to whatever it normally draws.
-- Read through the clock rather than through a flag somebody has to clear: the stamp is on the
-- published snapshot, so the banner goes away by itself with no pass rebuilding anything for it.
--
-- Two wordings, the way every other line on this surface has two: on a 480-pixel screen the slot
-- beside the bank chips is about 230 pixels, and a label narrower than its text WRAPS rather than
-- clipping. A banner cut off after "active -" says less than a short one that fits.
local function profileBanner(snapshot, t, width, font)
  local until_ = tonumber(snapshot.profileBannerUntil)
  if until_ == nil then return nil end
  -- Reached through the name rather than called outright: this runs in the firmware's reactive
  -- sweep, OUTSIDE the pcall the widget entry point wraps refresh in, so a build without the call
  -- would take the whole frame down with nothing able to report it.
  local clock = getTime
  if type(clock) ~= "function" then return nil end
  if clock() >= until_ then return nil end
  local number = tostring(snapshot.profile or "?")
  return pickText(
    t("widgets.dashboard.inflight_profile_banner", "PID profile") .. " " .. number .. " "
      .. t("widgets.dashboard.inflight_profile_banner_tail", "active - values unknown"),
    t("widgets.dashboard.inflight_profile_banner_short", "PID") .. " " .. number .. " "
      .. t("widgets.dashboard.inflight_profile_banner_tail_short", "- values ?"),
    width, font)
end

local function appendChips(children, widget, m, t, p, interactive)
  local snapshot = widget.state.inflight or {}
  local drive = widget._inflight
  local standard = (snapshot.setSource == "standard")

  -- The outline goes DOWN FIRST and the object that carries the press sits INSIDE it. An LVGL
  -- object drawn after a button and overlapping it takes the touch: measured on the simulator
  -- against the real firmware, an outline laid over the step button swallowed every press while
  -- the one chip that had no outline -- the selected one -- still fired. So the frame is a
  -- rectangle behind, and the button is inset by its width.
  local inset = interactive and OUTLINE_W or 0
  for bank = 1, Functions.BANK_COUNT do
    local x = m.pad + (bank - 1) * (m.chipW + m.chipGap)
    local isActive = (snapshot.bank == bank)
    if not isActive then
      children[#children + 1] = {
        type = "rectangle", x = x, y = m.chipY, w = m.chipW, h = m.chipH,
        color = p.dim, filled = false
      }
    end
    local node = {
      type = interactive and "button" or "rectangle",
      x = x + inset, y = m.chipY + inset,
      w = m.chipW - inset * 2, h = m.chipH - inset * 2,
      color = isActive and p.accent or p.button
    }
    -- `filled` belongs to the BORDERED objects -- rectangle, circle, arc
    -- (lua_lvgl_widget.cpp, LvglWidgetBorderedObject::parseParam). A button is built from
    -- LvglWidgetObject and rejects it with `Invalid property 'filled'`, which is raised out of
    -- the build and swallowed by the entry point's pcall: measured on a radio, the live surface
    -- drew its header and nothing below it, and the trace said nothing at all.
    if not interactive then node.filled = true end
    if interactive and drive then
      node.press = function()
        drive:setBank(bank)
        -- Asked for rather than taken. Dropping the render key here would rebuild in the next
        -- pass whatever else is going on, and a rebuild deletes the step button a finger may be
        -- resting on; the widget's own key gate decides when -- and whether -- to act on this.
        widget._tuningKeyDirty = true
      end
    end
    children[#children + 1] = node
    -- The chip that is not selected reads as an outline rather than a filled box, which is what
    -- lets six of them sit in a strip without the eye having to pick the odd one out.
    local label = standard and (Functions.STANDARD_BANK_LABELS[bank] or tostring(bank))
      or tostring(bank)
    appendCentredLabel(children, x, m.chipY, m.chipW, m.chipH, label,
      isActive and p.bg or p.dim, m.font, CENTER, m)
  end

  -- The caption beside the strip, and where the enable channel is not resting in any band the
  -- WARNING takes its place. Said in words rather than left to the chips: a bank the flight
  -- controller is not listening on is not one the highlight can describe -- and it is the same
  -- slot rather than a line of its own, which is where it used to be drawn over the parameter
  -- name on the shortest radio.
  -- The slot beside the chips carries three things, and this is their order of precedence: the
  -- profile banner while it stands, then the warning that no bank is armed, then the caption. It
  -- is a CLOSURE because the banner has a clock and nothing else on this surface does -- the
  -- alternative is a rebuild to put it up and a second one to take it down, which is exactly the
  -- rebuild-per-event this round removed everywhere else.
  local state = widget.state
  local captionText, captionColor
  if snapshot.live == true and snapshot.bankShown == nil then
    captionText = pickText(
      t("widgets.dashboard.inflight_bank_unknown", "Enable channel between banks"),
      t("widgets.dashboard.inflight_bank_unknown_short", "no bank armed"),
      m.chipCaptionW, m.small)
    captionColor = p.warn
  else
    captionText = pickText(
      t("widgets.dashboard.inflight_chip_caption", "bank = enable band"),
      t("widgets.dashboard.inflight_chip_caption_short", "bank = band"),
      m.chipCaptionW, m.small)
    captionColor = p.dim
  end
  local captionW, captionFont = m.chipCaptionW, m.small
  local bannerColor = p.warn
  children[#children + 1] = {
    type = "label",
    x = m.chipEnd, y = m.chipY + math.floor((m.chipH - fontHeight(captionFont)) / 2) + m.textOff,
    w = captionW, align = LEFT, font = captionFont,
    text = function()
      local snap = state.inflight
      if type(snap) ~= "table" then return captionText end
      local banner = profileBanner(snap, t, captionW, captionFont)
      if banner ~= nil then return fitText(banner, captionW, captionFont) end
      return captionText
    end,
    color = function()
      local snap = state.inflight
      if type(snap) == "table" and profileBanner(snap, t, captionW, captionFont) ~= nil then
        return bannerColor
      end
      return captionColor
    end
  }
end

--- The parameter the pilot is on: its name, where it sits, and its value in the accent, large.
--
-- The value is the one reactive closure on the left of this screen. It reads the published
-- snapshot and formats one string per change, which is exactly what the reactive-closure rule
-- allows -- and it is the reason the number can follow the board without a rebuild.
local function appendActive(children, widget, m, t, p)
  local snapshot = widget.state.inflight or {}
  local state = widget.state
  -- Read out of the metrics HERE and not inside the closure: a reactive closure runs per frame on
  -- whatever budget the refresh left over, and a table walk per frame is the cost this rule
  -- exists to prevent.
  local valueW, valueFont = m.valueW, m.valueFont
  local name = snapshot.activeName or t("widgets.dashboard.inflight_unassigned", "Unassigned")
  appendLabel(children, m.leftX, m.nameY, m.leftW, name, p.text, m.nameFont, LEFT)

  -- The line under the name is EMPTY unless a profile banner stands in it.
  --
  -- It used to carry "row 2 - bank P - trim Ele" and the pilot's ruling after the third radio
  -- round is that it goes: the row is highlighted in the list beside it, the bank is the lit chip
  -- above it, and the trim is named under the step buttons -- so the sentence spelled out three
  -- things the screen was already saying and took a line off the one number he was reading. The
  -- SLOT stays, because the zone screen has no chip caption and the banner has to land somewhere.
  local captionW, captionFont = m.leftW, m.small
  local bannerColor = p.warn
  children[#children + 1] = {
    type = "label", x = m.leftX, y = m.captionY, w = captionW, align = LEFT, font = captionFont,
    text = function()
      local snap = state.inflight
      if type(snap) ~= "table" then return "" end
      local banner = profileBanner(snap, t, captionW, captionFont)
      if banner ~= nil then return fitText(banner, captionW, captionFont) end
      return ""
    end,
    color = function() return bannerColor end
  }

  children[#children + 1] = {
    type = "label",
    x = m.leftX, y = m.valueY, w = m.valueW,
    color = p.accent, align = LEFT, font = m.valueFont,
    text = function()
      local snap = state.inflight
      if type(snap) ~= "table" then return UNKNOWN_VALUE end
      local value = snap.activeValue
      if value == nil then return UNKNOWN_VALUE end
      -- Cut rather than wrapped, for the reason every other string on this surface is: a label
      -- whose text is wider than its box puts the overflow on a second line. Four digits fit by
      -- construction, so this only ever bites on a five-digit head speed.
      return fitText(tostring(math.floor(value + 0.5)), valueW, valueFont)
    end
  }

  -- WHERE IT WAS a step ago, beside where it is. The pilot's own ask after the third radio round,
  -- and it is the one number the surface could not answer: the big value moves when the board
  -- reports a step, and a number that has just changed says nothing about which way it went or by
  -- how much unless the previous one is beside it.
  --
  -- Reactive, and it has to be: it moves on exactly the events the value moves on, and baking it
  -- into the tree would put the pair one rebuild out of step with each other -- the worst possible
  -- state for two numbers a pilot is subtracting.
  local sideW = m.rowX - m.sideX - m.pad
  children[#children + 1] = {
    type = "label", x = m.sideX, y = m.sideY, w = sideW, align = LEFT, font = m.small,
    color = p.text,
    text = function()
      local snap = state.inflight
      local was = (type(snap) == "table") and snap.activePrevious or nil
      return t("widgets.dashboard.inflight_before", "before") .. " " .. formatValue(was)
    end
  }

  -- And where it started, which is the other half: one says what the last press did, the other
  -- how far the flight has moved from the setting the pilot took off with.
  appendLabel(children, m.sideX, m.sideY + m.lineH, sideW,
    t("widgets.dashboard.inflight_primed_short", "primed") .. " " .. formatValue(snapshot.activePrimed),
    p.dim, m.small, LEFT)

  -- Why a press did nothing, for as long as it is worth saying. The pilot's report after three
  -- rounds is "sometimes no step at all", and the cause his card log points at is a tap inside the
  -- cool-down: the flight controller cannot tell two steps that close apart, so the drive refuses
  -- the second -- correctly, silently, and indistinguishably from a control that is not wired up.
  -- Read through the clock like the banner, so no rebuild puts it up and none takes it down.
  local refusalText = t("widgets.dashboard.inflight_too_fast", "too fast - one step at a time")
  local hintW = m.rowX - m.leftX - m.pad
  children[#children + 1] = {
    type = "label", x = m.leftX, y = m.sideY + m.lineH * 2, w = hintW, align = LEFT, font = m.small,
    color = p.warn,
    text = function()
      local snap = state.inflight
      if type(snap) ~= "table" then return "" end
      local until_ = tonumber(snap.stepRefusedUntil)
      if until_ == nil then return "" end
      local clock = getTime
      if type(clock) ~= "function" or clock() >= until_ then return "" end
      return fitText(refusalText, hintW, m.small)
    end
  }
end

--- The six rows of the armed bank: number, the trim that drives it, its name and its value.
--
-- A row whose trim this radio does not have is hidden on the ZONE screen, where the trim is the
-- only way to reach it; in fullscreen every row is shown, because a tap reaches it there.
local function appendRows(children, widget, m, w, t, p, interactive)
  local snapshot = widget.state.inflight or {}
  local drive = widget._inflight
  local rows = snapshot.rows or {}
  local state = widget.state
  local rowW = w - m.rowX - m.pad
  -- See appendChips: on the surface whose rows take a press the frame goes down first and the
  -- button is inset inside it.
  local inset = interactive and OUTLINE_W or 0

  appendLabel(children, m.rowNumX, m.bodyY - m.smallH - 2 + m.textOff, rowW,
    pickText(t("widgets.dashboard.inflight_row_caption", "row = trim = inc/dec window"),
             t("widgets.dashboard.inflight_row_caption_short", "row = trim"), rowW, m.small),
    p.dim, m.small, LEFT)

  for row = 1, Functions.ROW_COUNT do
    local entry = rows[row] or {}
    local visible = interactive or entry.trim == true
    if visible and m.rowH > 0 then
      local rowY = m.bodyY + (row - 1) * m.rowH
      local isActive = (snapshot.row == row)
      -- See appendChips: the frame goes down first and the object that takes the press sits
      -- inside it, because an object drawn over a button takes the touch away from it.
      if isActive then
        children[#children + 1] = {
          type = "rectangle", x = m.rowX, y = rowY, w = rowW, h = m.rowH - 2,
          color = p.accent, filled = false
        }
      end
      local node = {
        type = interactive and "button" or "rectangle",
        x = m.rowX + inset, y = rowY + inset,
        w = rowW - inset * 2, h = m.rowH - 2 - inset * 2,
        -- The other reactive closure: which row is armed moves with the pilot's trims, and
        -- repainting the whole scene for it would cost a build per press. The row that is not
        -- armed is painted in the background so that the list reads as text rather than as six
        -- boxes, which is what the drawing asks for.
        color = function()
          local snap = state.inflight
          if type(snap) == "table" and snap.row == row then return p.rowFill end
          return p.bg
        end
      }
      -- See appendChips: a button has no `filled`.
      if not interactive then node.filled = true end
      if interactive and drive then
        node.press = function()
          drive:selectRow(row)
          -- See appendChips: the rebuild is asked for, never taken.
          widget._tuningKeyDirty = true
        end
      end
      children[#children + 1] = node

      appendCentredLabel(children, m.rowNumX, rowY, m.rowTrimX - m.rowNumX, m.rowH - 2,
        tostring(row), isActive and p.accent or p.dim, m.small, LEFT, m)
      -- The trim that drives this row, under the radio's own name for it. In navigate mode a row
      -- has no trim of its own -- one trim adjusts whichever row is selected -- and the drive
      -- publishes no name, so the column simply stays empty.
      if entry.trimName ~= nil then
        appendCentredLabel(children, m.rowTrimX, rowY, m.rowTrimW, m.rowH - 2,
          fitText(entry.trimName, m.rowTrimW, m.small), p.dim, m.small, LEFT, m)
      end
      -- All four columns in the small font, which is what the drawing has: six rows of a
      -- parameter name and a number have to fit in a third of the screen, and the row a pilot is
      -- on is told apart by its colour and its frame rather than by its size.
      local label = entry.name or t("widgets.dashboard.inflight_unassigned", "Unassigned")
      appendCentredLabel(children, m.rowNameX, rowY, m.rowNameW, m.rowH - 2,
        fitText(label, m.rowNameW, m.small), isActive and p.text or p.dim, m.small, LEFT, m)
      -- Four pixels clear of the row's own frame, which is two pixels wide and was taking the
      -- last column of every value's last digit.
      --
      -- REACTIVE, like the big value above the list, and for the same reason the pair up there is:
      -- this column is what the board's own report moves, the report lands while the pulse that
      -- asked for the step is still on the value variable, and a rebuild to put the new number in
      -- would spend that window. The closure reads the snapshot's own row table -- replaced whole
      -- whenever a value moves -- so the number follows the board per frame and the tree stands.
      appendCentredLabel(children, m.rowX + m.rowW - m.rowValueW - 4, rowY, m.rowValueW, m.rowH - 2,
        function()
          local snap = state.inflight
          local list = (type(snap) == "table") and snap.rows or nil
          local current = (type(list) == "table") and list[row] or nil
          return formatValue(current and current.value or nil)
        end, isActive and p.text or p.dim, m.small, RIGHT, m)
    end
  end
end

-- ---------------------------------------------------------------------------
-- The zone screen
-- ---------------------------------------------------------------------------

--- The overlay in the widget's own zone, while the interlock is on.
--
-- No controls out here: the trims drive it and this is the read-out. WHICH read-out is the phase's
-- to say, and that is the pilot's core change after the third radio round. The interlock is the
-- one entry he has, and what it shows follows the flight rather than the switch -- the preflight
-- read-out on the ground, the tuning surface in the air, and the delta and the undo on the ground
-- after a flight that moved something. Three screens on one switch, and nothing to remember.
function M.buildZone(children, widget)
  local w = (widget.zone and widget.zone.w) or LCD_W or 480
  local h = (widget.zone and widget.zone.h) or LCD_H or 272
  local t = translator(widget)
  local p = palette()
  local m = metrics(w, h, false)
  local snapshot = widget.state.inflight or {}

  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = w, h = h, color = p.bg, filled = true }
  appendHeader(children, widget, m, w, t, p, 0)

  if snapshot.phase == "post" then
    M.buildPost(children, widget, m, w, h, t, p, false)
    return
  end
  if snapshot.phase ~= "live" then
    M.buildGround(children, widget, m, w, h, t, p, false)
    return
  end

  appendChips(children, widget, m, t, p, false)
  appendActive(children, widget, m, t, p)
  appendRows(children, widget, m, w, t, p, false)

  appendLabel(children, m.pad, h - m.lineH, w - m.pad * 2,
    t("widgets.dashboard.inflight_hint_touch", "long press for touch controls"), p.dim, m.small, CENTER)
end

-- ---------------------------------------------------------------------------
-- The fullscreen screen
-- ---------------------------------------------------------------------------

local function closeWidth(m)
  return m.large and 44 or 20
end

local function appendClose(children, widget, m, w, p)
  local size = closeWidth(m)
  local x = w - size - (m.large and 8 or 1)
  local y = math.floor((m.headerH - size) / 2)
  children[#children + 1] = {
    type = "button", x = x, y = y, w = size, h = size, color = COLOR_THEME_SECONDARY1 or RED,
    press = function()
      -- The same three lines widgets/dashboard/fullscreen_menu.lua closes with: drop what is
      -- built, drop the render key, leave fullscreen.
      widget.built = false
      widget.renderKey = nil
      if lcd and type(lcd.exitFullScreen) == "function" then
        lcd.exitFullScreen()
      end
    end
  }
  appendCentredLabel(children, x, y, size, size, "X", p.text, m.font, CENTER, m)
end

--- The two step controls, and the three lines that say what they and the trims do.
--
-- A momentary button reports its press AND its release, which is what a held control needs: the
-- value stays written for as long as the finger is down and the flight controller repeats its own
-- step. Where the firmware's LVGL build does not offer one -- the table is asked, not assumed --
-- a plain button stands in and a tap is one step.
--
-- The glyph is drawn as a label over the button, the label-over-button idiom their fullscreen
-- menu is built from, and it is centred on the GLYPH FONT's own height. Centring it on a line
-- height instead is what put the two glyphs outside their buttons on the first cut.
local function appendActions(children, widget, m, w, t, p)
  local drive = widget._inflight
  if drive == nil then return end
  local momentary = lvgl and type(lvgl.momentaryButton) == "function"

  local specs = {
    { x = m.pad, up = false, label = "-" },
    { x = m.pad * 2 + m.buttonW, up = true, label = "+" }
  }

  for i = 1, #specs do
    local spec = specs[i]
    -- See appendChips: the frame first, the control inside it. This is the object the finding
    -- was measured on -- with the outline laid over it, not one press in a whole run reached the
    -- drive, and the trace was clean because nothing had gone wrong.
    children[#children + 1] = {
      type = "rectangle", x = spec.x, y = m.actionY, w = m.buttonW, h = m.actionH,
      color = p.text, filled = false
    }
    local node = {
      type = momentary and "momentaryButton" or "button",
      x = spec.x + OUTLINE_W, y = m.actionY + OUTLINE_W,
      w = m.buttonW - OUTLINE_W * 2, h = m.actionH - OUTLINE_W * 2, color = p.button
    }
    if momentary then
      node.press = function() drive:press(drive.row, spec.up) end
      node.release = function() drive:release() end
    else
      node.press = function() drive:tap(drive.row, spec.up) end
    end
    children[#children + 1] = node
    appendCentredLabel(children, spec.x, m.actionY, m.buttonW, m.actionH,
      spec.label, p.text, m.glyphFont, CENTER, m)
  end

  local snapshot = widget.state.inflight or {}
  local hintW = m.hintW
  appendLabel(children, m.hintX, m.hintY, hintW,
    pickText(t("widgets.dashboard.inflight_hint_tap", "tap = one pulse = one step"),
             t("widgets.dashboard.inflight_hint_tap_short", "tap = one step"), hintW, m.small),
    p.text, m.small, LEFT)
  appendLabel(children, m.hintX, m.hintY + m.lineH, hintW,
    pickText(t("widgets.dashboard.inflight_hint_hold", "hold = the board repeats"),
             t("widgets.dashboard.inflight_hint_hold_short", "hold = repeats"), hintW, m.small),
    p.dim, m.small, LEFT)
  -- The third line names the trim the pilot actually configured, because the whole point of it is
  -- that he does not have to look at the screen to use it.
  if snapshot.activeTrim ~= nil then
    local head = t("widgets.dashboard.inflight_hint_trim", "or the") .. " " .. snapshot.activeTrim .. " "
    appendLabel(children, m.hintX, m.hintY + m.lineH * 2, hintW,
      pickText(head .. t("widgets.dashboard.inflight_hint_trim_tail", "trim, eyes off"),
               head .. t("widgets.dashboard.inflight_hint_trim_tail_short", "trim"),
               hintW, m.small), p.dim, m.small, LEFT)
  end
end

-- ---------------------------------------------------------------------------
-- The ground surface
-- ---------------------------------------------------------------------------

-- The cap on the delta list is gone with the pilot's third radio round. It used to be eight rows
-- with "+9 more" under them, on a board that has ALREADY written all of them to its own storage --
-- so the ones the cap hid were the ones nobody would ever see again. The postflight surface pages
-- the whole list instead, with the walk trim; see M.buildPost.

--- That the values are in, and when -- with the wall clock where the radio has one.
--
-- A pilot standing beside the machine wants to know whether this read was this session or the last
-- one, and "Primed" cannot tell him.
local function readWords(snapshot, t)
  local at = snapshot.readAt
  if type(at) == "string" then
    return t("widgets.dashboard.inflight_prime_done_at", "Values read") .. " " .. at
  end
  return t("widgets.dashboard.inflight_prime_done", "Values read")
end

--- Where the ground half has got to, in one phrase.
--
-- `ground` carries what the snapshot cannot: whether the board HAS BEEN READ and whether the last
-- attempt at reading it again was given up, both read off the drive once when the surface is built,
-- and the width this line has to fit. The two facts move only when a read finishes or is given up,
-- and both of those bump the value epoch the widget's render key carries -- so a build is exactly
-- the moment they are answered again. What the closure needs from pass to pass is the COUNTER, and
-- that is on the snapshot where it has always been.
local function describePrime(snapshot, t, ground)
  local state = snapshot.prime
  local phase = (type(state) == "table") and state.phase or nil

  -- Whether a read STANDS, which a finished run is no longer evidence of on its own: a session
  -- closed on the ground drops the cache and the evidence with it, while the run that filled it
  -- remains the last one there ever was. Where no caller supplied the drive's answer, the run's own
  -- phase is all there is.
  local hasRead, interrupted, width, font
  if type(ground) == "table" then
    hasRead = ground.hasRead == true
    interrupted, width, font = ground.interrupted == true, ground.width or 0, ground.font
  else
    hasRead, interrupted, width, font = (phase == "done"), false, 0, nil
  end

  if phase ~= nil and phase ~= "idle" and phase ~= "error" and phase ~= "done" then
    return t("widgets.dashboard.inflight_prime_running", "Priming") .. " "
      .. tostring(state.done or 0) .. "/" .. tostring(state.total or 0)
  end

  -- Nothing is running, and what the LAST RUN did is not the question a pilot is asking: whether
  -- the board has been read is. A re-read he armed into leaves the run idle over a full cache, and
  -- a line reading "values not read" above an intact backup line -- which is what the fourth radio
  -- round photographed -- describes the run rather than the screen it is on. So the read is
  -- reported, with what happened to the attempt after it as a second clause WHERE THERE IS ROOM:
  -- on a 480-pixel zone the two together are within a character or two of the width, and a line cut
  -- in the middle of the clause would lose the read time as well on the next translation.
  if hasRead then
    local text = readWords(snapshot, t)
    local tail = nil
    if interrupted then
      tail = t("widgets.dashboard.inflight_prime_interrupted", "re-read interrupted")
    elseif phase == "error" then
      tail = t("widgets.dashboard.inflight_prime_failed", "Prime failed")
    end
    if tail == nil then return text end
    return pickText(text .. " - " .. tail, text, width, font)
  end

  if phase == "error" then
    return t("widgets.dashboard.inflight_prime_failed", "Prime failed")
  end
  return t("widgets.dashboard.inflight_prime_never", "Not primed")
end

--- Where the rows came from, and whether the flight controller agrees with them.
--
-- Said in words because the three cases look exactly alike on the rest of the screen. In the
-- STANDARD layout the set is this build's own and the board's table was read only to be held
-- against it, so what belongs here is the verdict: the board carries this set, the board carries
-- something else in so many of its slots, or the board carries nothing at all. In the CUSTOM
-- layout the set IS the board's table, so what belongs here is whether that table could be used
-- -- a set that quietly fell back to the documented layout and one that came off this board are
-- otherwise indistinguishable -- and how many of its slots the overlay had to leave out, since a
-- continuous slot has no park position and a pilot who configured one and cannot find it on the
-- screen has no other way of learning why.
local function describeSet(snapshot, t)
  if snapshot.setSource == "standard" then
    local text = t("widgets.dashboard.inflight_set_standard", "Standard set")
    local compare = snapshot.compare
    local verdict = (type(compare) == "table") and compare.verdict or nil
    if verdict == "match" then
      return text .. " - " .. t("widgets.dashboard.inflight_board_matches", "board matches")
    elseif verdict == "empty" then
      return text .. " - " .. t("widgets.dashboard.inflight_board_empty", "board empty")
    elseif verdict == "differ" then
      -- Named rather than counted when the step is all of it: the pilot changed a field on the
      -- radio and the remedy is one button, not thirty-six slots to look at.
      if compare.stepOnly == true then
        return text .. " - " .. t("widgets.dashboard.inflight_board_step", "step differs: set the board up again")
      end
      return text .. " - " .. t("widgets.dashboard.inflight_board_differs", "board differs in")
        .. " " .. tostring(compare.count)
    elseif verdict == "unmapped" then
      return text .. " - " .. t("widgets.dashboard.inflight_board_unmapped", "channels not on the receiver map")
    end
    return text .. " - " .. t("widgets.dashboard.inflight_board_unknown", "board not compared")
  end

  local text
  if snapshot.setSource == "board" then
    text = t("widgets.dashboard.inflight_set_board", "Set from the board")
  else
    text = t("widgets.dashboard.inflight_set_reference", "Documented layout")
  end
  local state = snapshot.prime
  local skipped = (type(state) == "table") and tonumber(state.skipped) or nil
  if skipped ~= nil and skipped > 0 then
    text = text .. " (" .. tostring(skipped) .. " " .. t("widgets.dashboard.inflight_set_skipped", "skipped") .. ")"
  end
  return text
end

--- Every reason a backup or a restore was refused, in words a pilot can act on.
--
-- The pilot's third radio round asked for exactly this: a refusal that names a code he has never
-- seen is a button that did nothing. Each of them says what is wrong AND where he changes it.
local function refusalWords(reason, t)
  if reason == "unset" then
    return t("widgets.dashboard.inflight_refuse_unset",
      "Choose the backup profile in the settings")
  end
  if reason == "same" then
    return t("widgets.dashboard.inflight_refuse_same",
      "The backup profile is the one being flown: choose another")
  end
  if reason == "other_profile" then
    return t("widgets.dashboard.inflight_restore_other_profile",
      "The backup was taken from another profile: switch back to it first")
  end
  if reason == "unknown_profile" then
    return t("widgets.dashboard.inflight_restore_unknown_profile",
      "Which profile the backup holds is not known: take a fresh one")
  end
  if reason == "unprimed" then
    return t("widgets.dashboard.inflight_backup_unprimed", "Read the board before taking a backup")
  end
  if reason == "reading" then
    return t("widgets.dashboard.inflight_backup_reading",
      "The board is being read: try again in a moment")
  end
  if reason == "range" then
    return t("widgets.dashboard.inflight_refuse_range",
      "This flight controller has no such profile")
  end
  if reason == "no_active" then
    return t("widgets.dashboard.inflight_refuse_no_active",
      "The profile being flown is unknown")
  end
  if reason == "no_link" then
    return t("widgets.dashboard.inflight_refuse_no_link", "No link to the flight controller")
  end
  if reason == "armed" then
    return t("widgets.dashboard.inflight_refuse_armed", "Disarm first")
  end
  return t("widgets.dashboard.inflight_transfer_refused", "Profile copy refused")
    .. ": " .. tostring(reason)
end

--- Whether an undo exists, and what the last attempt at making one did.
--
-- A refusal is shown HERE rather than on the delta line below, because this is the line under the
-- button the pilot pressed. The delta line says its own thing about the same state -- that there
-- is nothing to compare a flight with -- and the two are deliberately both on the screen: one
-- answers "why did that button do nothing", the other answers "why is this list empty".
local function describeBackup(snapshot, t, ground)
  local transfer = snapshot.transfer
  if type(transfer) == "table" and transfer.state == "busy" then
    return t("widgets.dashboard.inflight_transfer_busy", "Copying profile")
  end
  if type(transfer) == "table" and transfer.state == "refused" then
    return refusalWords(transfer.reason, t)
  end
  if type(transfer) == "table" and transfer.state == "error" then
    return t("widgets.dashboard.inflight_transfer_failed", "Profile copy failed")
  end
  local backup = snapshot.backup
  if type(backup) == "table" then
    local text = t("widgets.dashboard.inflight_backup_held", "Backup in profile") .. " " .. tostring(backup.profile)
    -- Which profile it was taken FROM, because a backup is only an undo for that one: the
    -- firmware's adjustments act on whichever profile is active, so a restore into a different
    -- one would overwrite a profile the backup never described.
    if backup.source ~= nil then
      text = text .. " (" .. t("widgets.dashboard.inflight_backup_from", "from") .. " "
        .. tostring(backup.source) .. ")"
    end
    -- and whether that profile is the one being flown, which until now the pilot had to work out
    -- for himself by holding this line against the profile in the header. It is the same fact the
    -- restore refuses on, and the photograph of it was a backup line reading "from 1" under a
    -- header reading "profile 2" with nothing saying the two disagreed.
    --
    -- It costs the WALL CLOCK on a narrow zone, and that is the trade rather than an oversight: a
    -- backup that cannot be put back where the pilot is standing is worth more said than timed,
    -- and the long form keeps both wherever it fits.
    local active = tonumber(snapshot.profile)
    if backup.source ~= nil and active ~= nil and active ~= tonumber(backup.source) then
      local width = (type(ground) == "table") and ground.width or 0
      local font = (type(ground) == "table") and ground.font or nil
      local timed = text
      if type(backup.clock) == "string" then timed = timed .. " " .. backup.clock end
      return pickText(
        timed .. " - " .. t("widgets.dashboard.inflight_backup_not_active", "another profile is active"),
        text .. " - " .. t("widgets.dashboard.inflight_backup_not_active_short", "not active"),
        width, font)
    end
    if type(backup.clock) == "string" then text = text .. " " .. backup.clock end
    return text
  end
  -- No backup, and the reason is usually that no profile has been chosen to keep one in. Saying
  -- WHERE to choose it is the difference between a screen that reports a state and one a pilot can
  -- act on: the two buttons beside this line read "Backup to -" until he does.
  if (tonumber(snapshot.backupProfile) or 0) <= 0 then
    return refusalWords("unset", t)
  end
  return t("widgets.dashboard.inflight_backup_none", "No backup")
end

--- One action, as the button-with-a-label-over-it their fullscreen menu is built from: an LVGL
-- button carries the press and a label drawn on top of it carries the text.
local function appendAction(children, m, x, y, width, label, p, press)
  children[#children + 1] = {
    type = "button", x = x, y = y, w = width, h = m.actionH, color = p.button, press = press
  }
  appendCentredLabel(children, x, y, width, m.actionH, label, p.text, m.small, CENTER, m)
end

--- The surface the pilot meets BEFORE a flight: what the overlay knows and what it can undo.
--
-- Four lines and, in full screen, three actions. Nothing steps here -- the phase machine keeps the
-- controls in the air -- so the bank chips went with them: a strip saying which bank a step would
-- land in is a strip about something that cannot happen on this screen.
--
-- The BACKUP is made without being asked for, on the interlock opening (inflight/prime.lua). The
-- button stays because a pilot who has changed profile wants a fresh one on his own word, and
-- because every refusal reads the same whichever of the two asked.
function M.buildGround(children, widget, m, w, h, t, p, interactive)
  local drive = widget._inflight
  local Prime = prime()
  local armed = (widget.state and widget.state.armed) == true
  local state = widget.state

  local y = m.chipY
  local lineW = w - m.pad * 2

  -- The font the whole block is drawn in, chosen once here.
  --
  -- ONE font for four lines rather than one each: they are four answers to the same question and
  -- three sizes would read as three kinds of thing. It is the larger rung where every one of them
  -- fits at it, measured on what the snapshot says at build time -- a label narrower than its text
  -- does not clip, it WRAPS -- and each line is cut to the chosen font as well, for the ones that
  -- grow between two builds. The PITCH does not depend on this choice (see m.statusLineH), so the
  -- block and the actions under it stand in the same place whichever rung is picked.
  local snapNow = (type(state.inflight) == "table") and state.inflight or nil
  -- What the ground half has actually achieved, as opposed to what its last run did. Read here,
  -- once per build, for the reason describePrime gives: neither of them can move without the epoch
  -- moving with it, and the epoch is what brings this builder back.
  local ground = {
    hasRead = (drive ~= nil and Prime ~= nil and type(Prime.hasRead) == "function")
      and Prime.hasRead(drive) or false,
    interrupted = (drive ~= nil) and drive.primeInterrupted == true or false,
    width = lineW, font = m.font
  }
  local checkText = t("widgets.dashboard.inflight_check", "SETUP") .. ": "
    .. M.describeCheck(M.checkVerdict(widget), t)
  local lineFont = m.small
  if m.font ~= m.small and snapNow ~= nil
    and textFits(checkText, lineW, m.font)
    and textFits(describeSet(snapNow, t), lineW, m.font)
    and textFits(describePrime(snapNow, t, ground), lineW, m.font)
    and textFits(describeBackup(snapNow, t, ground), lineW, m.font) then
    lineFont = m.font
  end
  -- The rung the block was actually drawn in, so the second clause of the line above is chosen
  -- against the font it will be measured in rather than against the one that was offered.
  ground.font = lineFont

  -- 1: is this model wired up at all.
  appendLabel(children, m.pad, y, lineW, fitText(checkText, lineW, lineFont), p.text, lineFont, LEFT)
  y = y + m.statusLineH

  -- 2: does the flight controller carry the set, and 3: when the values were read. Both reactive
  -- rather than baked in, and that is the pilot's third radio round: a read used to bump the
  -- drive's epoch on every reply, the epoch is in the widget's render key, and the whole tree came
  -- down and went up again once per reply while his radio was answering them.
  children[#children + 1] = {
    type = "label", x = m.pad, y = y, w = lineW, color = p.text, align = LEFT, font = lineFont,
    text = function()
      local snap = state.inflight
      if type(snap) ~= "table" then return "" end
      return fitText(describeSet(snap, t), lineW, lineFont)
    end
  }
  y = y + m.statusLineH

  children[#children + 1] = {
    type = "label", x = m.pad, y = y, w = lineW, color = p.text, align = LEFT, font = lineFont,
    text = function()
      local snap = state.inflight
      if type(snap) ~= "table" then return "" end
      return fitText(describePrime(snap, t, ground), lineW, lineFont)
    end
  }
  y = y + m.statusLineH

  -- 4: the undo. What it is, when it was made, or why the last attempt was refused.
  children[#children + 1] = {
    type = "label", x = m.pad, y = y, w = lineW, color = p.text, align = LEFT, font = lineFont,
    text = function()
      local snap = state.inflight
      if type(snap) ~= "table" then return "" end
      return fitText(describeBackup(snap, t, ground), lineW, lineFont)
    end
  }
  y = y + m.statusLineH + m.pad

  -- Why the ground half is refusing, when it is not simply that the board is armed. The one case
  -- so far is the arm sensor never having answered: the ground half then refuses everything,
  -- because a model whose sensor 99 is not in the telemetry list reads as disarmed for ever and
  -- MSP sent on that reading goes to a helicopter in the air.
  local refusal = (Prime ~= nil and type(Prime.groundRefusal) == "function") and Prime.groundRefusal(widget) or nil

  local blocked = false
  if armed then
    -- Nothing here can reach the board while it is armed -- the MSP runtime clears its queue on
    -- every armed tick -- so the actions are absent rather than present and refusing.
    appendLabel(children, m.pad, y, lineW,
      fitText(t("widgets.dashboard.inflight_ground_armed", "Disarm to read or copy a profile"),
              lineW, lineFont),
      p.text, lineFont, LEFT)
    y = y + m.statusLineH
    blocked = true
  elseif refusal == "no_arm_sensor" then
    appendLabel(children, m.pad, y, lineW,
      fitText(t("widgets.dashboard.inflight_ground_no_arm", "Arm sensor not seen: is sensor 99 selected?"),
              lineW, lineFont),
      p.warn, lineFont, LEFT)
    y = y + m.statusLineH
    blocked = true
  end

  if not interactive then
    -- The zone screen has no buttons at all -- whether an LVGL button in a widget zone even takes
    -- a press is unmeasured -- so it says where the three actions are instead. It says it whatever
    -- else stands above it: the two states that used to return before this line are exactly the
    -- ones a pilot is looking for something to do about, and the hint is the only thing on the
    -- zone that tells him this screen has more on it than he can see.
    appendLabel(children, m.pad, y, lineW,
      fitText(t("widgets.dashboard.inflight_hint_touch", "long press for touch controls"), lineW, m.small),
      p.dim, m.small, LEFT)
    return
  end
  if blocked then return end
  if drive == nil or Prime == nil then return end

  -- A profile nobody has chosen is a dash and not a zero. "Backup to 0" reads as a profile number
  -- on a board whose profiles start at one, and the pilot read it as one.
  local profile = math.floor(tonumber(drive.settings.backup_profile) or 0)
  local slot = (profile > 0) and tostring(profile) or UNKNOWN_VALUE
  local buttonW = math.floor((w - m.pad * 4) / 3)
  appendAction(children, m, m.pad, y, buttonW,
    t("widgets.dashboard.inflight_prime", "Read values"), p, function()
      -- Refused while one is already running. A second press would put a second chain into the
      -- same queue with no order between the two, and the surface has no way of showing which of
      -- them the counter belongs to.
      if Prime.isRunning(drive) then return end
      Prime.start(widget, drive)
      widget._tuningKeyDirty = true
    end)
  appendAction(children, m, m.pad * 2 + buttonW, y, buttonW,
    t("widgets.dashboard.inflight_backup", "Back up to") .. " " .. slot, p, function()
      Prime.backup(widget, drive)
      widget._tuningKeyDirty = true
    end)
  appendAction(children, m, m.pad * 3 + buttonW * 2, y, buttonW,
    t("widgets.dashboard.inflight_restore", "Restore from") .. " " .. slot, p, function()
      Prime.restore(widget, drive)
      widget._tuningKeyDirty = true
    end)
end

-- ---------------------------------------------------------------------------
-- The postflight surface
-- ---------------------------------------------------------------------------

--- What the flight changed, in full and readable, one page at a time.
--
-- The pilot's core ask after the third radio round. The delta used to be four lines at the bottom
-- of the ground screen with "+9 more" under them -- a list that names the changes it has room for
-- and hides the rest, on a board that has ALREADY written all of them to its own storage. The ones
-- it hid were the ones nobody would ever see again. So it gets the whole screen, and the walk trim
-- pages it: the same thumb and the same gesture that walked the parameters in the air.
--
-- Built into the tree rather than read by a closure. Disarmed, nothing moves a value, so the list
-- only changes when the page does -- and the page moves the drive's epoch, which is in the render
-- key, so the rebuild that shows the next page is the one the key was going to cause anyway.
function M.buildPost(children, widget, m, w, h, t, p, interactive)
  local drive = widget._inflight
  local Prime = prime()
  local lineW = w - m.pad * 2
  local y = m.chipY

  local list, verdict = nil, nil
  if drive ~= nil and Prime ~= nil then list, verdict = Prime.delta(drive) end

  -- The footer first, because everything above it is measured against where it starts. It says the
  -- one thing a pilot has to know standing there: the board has ALREADY written this to its own
  -- storage, half a second after disarm, so the list is a record and not a pending change.
  local footerY = h - m.lineH - 2
  local footer = interactive
    and t("widgets.dashboard.inflight_post_saved", "the board has saved this")
    or t("widgets.dashboard.inflight_post_saved_zone", "board has saved - restore: full screen")
  appendLabel(children, m.pad, footerY, lineW, fitText(footer, lineW, m.small), p.dim, m.small, LEFT)

  local bottom = footerY - m.pad
  if interactive then bottom = bottom - m.actionH - m.pad end

  if list == nil then
    -- A comparison REFUSED reads nothing like a comparison that has nothing to measure against,
    -- and the pilot acts on the two differently: one is answered by switching the profile back or
    -- taking a fresh undo, the other by reading the board. So the verdict gets the title line the
    -- list itself would have had, and the profiles it is refusing to compare go under it -- two
    -- lines, because on a 480-pixel zone the sentence does not fit on one.
    if verdict == "other_profile" then
      appendLabel(children, m.pad, y, lineW,
        t("widgets.dashboard.inflight_delta_no_compare", "NO COMPARISON"), p.accent, m.small, LEFT)
      local source = (type(drive.backup) == "table") and tonumber(drive.backup.source) or nil
      local active0 = Prime.activeProfile0(drive)
      local text = t("widgets.dashboard.inflight_delta_backup_profile", "Backup from profile")
        .. " " .. (source and tostring(source) or UNKNOWN_VALUE) .. ", "
        .. t("widgets.dashboard.inflight_delta_active", "active is")
        .. " " .. (active0 and tostring(active0 + 1) or UNKNOWN_VALUE)
      appendLabel(children, m.pad, y + m.lineH, lineW, fitText(text, lineW, m.small),
        p.text, m.small, LEFT)
      return
    end
    appendLabel(children, m.pad, y, lineW,
      fitText(t("widgets.dashboard.inflight_delta_unprimed", "Read the values first: nothing to compare against"),
              lineW, m.small),
      p.text, m.small, LEFT)
    return
  end
  if #list == 0 then
    appendLabel(children, m.pad, y, lineW,
      t("widgets.dashboard.inflight_delta_none", "Nothing has changed"), p.text, m.small, LEFT)
    return
  end

  appendLabel(children, m.pad, y, lineW,
    t("widgets.dashboard.inflight_delta_title", "CHANGED SINCE THE BACKUP"), p.accent, m.small, LEFT)
  y = y + m.lineH

  -- How many rows this radio's zone actually holds, and never fewer than one: a page of nothing
  -- would page for ever.
  local perPage = math.floor((bottom - y) / m.lineH)
  if perPage < 1 then perPage = 1 end
  local pages = math.ceil(#list / perPage)
  -- Handed back to the drive, because how many rows fit is a property of THIS surface and the trim
  -- that pages has no other way of knowing when to wrap.
  if drive ~= nil then
    drive.deltaPages = pages
    if (drive.deltaPage or 1) > pages then drive.deltaPage = pages end
  end
  local page = (drive ~= nil and drive.deltaPage) or 1

  local nameW = math.floor(w * 0.52)
  local valueX = m.pad + nameW
  local valueW = w - m.pad - valueX
  local first = (page - 1) * perPage + 1
  local last = first + perPage - 1
  if last > #list then last = #list end
  for i = first, last do
    local entry = list[i]
    local rowY = y + (i - first) * m.lineH
    appendLabel(children, m.pad, rowY, nameW, fitText(entry.name or "?", nameW, m.small),
      p.text, m.small, LEFT)
    appendLabel(children, valueX, rowY, valueW,
      formatValue(entry.old) .. " -> " .. formatValue(entry.new), p.accent, m.small, RIGHT)
  end

  if pages > 1 then
    appendLabel(children, m.pad, footerY, lineW,
      tostring(page) .. "/" .. tostring(pages), p.dim, m.small, RIGHT)
  end

  if not interactive or drive == nil or Prime == nil then return end
  local profile = math.floor(tonumber(drive.settings.backup_profile) or 0)
  local slot = (profile > 0) and tostring(profile) or UNKNOWN_VALUE
  appendAction(children, m, m.pad, footerY - m.actionH - m.pad, math.floor((w - m.pad * 2) / 2),
    t("widgets.dashboard.inflight_restore", "Restore from") .. " " .. slot, p, function()
      Prime.restore(widget, drive)
      widget._tuningKeyDirty = true
    end)
end

--- The overlay with its controls. Reached by a long press while the interlock is on, and from the
-- quick settings menu while it is off -- there the drive is inert and what is shown instead is
-- the ground surface.
function M.buildFullscreen(children, widget)
  local w = (widget.zone and widget.zone.w) or LCD_W or 480
  local h = (widget.zone and widget.zone.h) or LCD_H or 272
  local t = translator(widget)
  local p = palette()
  local m = metrics(w, h, true)

  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = w, h = h, color = p.bg, filled = true }
  appendHeader(children, widget, m, w, t, p, closeWidth(m))
  appendClose(children, widget, m, w, p)

  -- The same three phases the zone screen picks between, with the touch controls added. Reached
  -- from the quick settings menu as well, with the interlock OFF: there the drive is inert, the
  -- phase is nil, and what stands is the ground surface -- which is exactly right, because the
  -- ground actions are the only ones that could do anything without an interlock.
  local snapshot = widget.state.inflight or {}
  if snapshot.phase == "post" then
    M.buildPost(children, widget, m, w, h, t, p, true)
    return
  end
  if snapshot.live ~= true or snapshot.phase ~= "live" then
    M.buildGround(children, widget, m, w, h, t, p, true)
    return
  end

  -- No setup verdict on the LIVE surface. It is a sentence about a model that cannot change while
  -- the pilot is flying it, it belongs to the ground surface where he can act on it, and on the
  -- shortest radio the line it needed was the line the parameter name was drawn on.
  appendChips(children, widget, m, t, p, true)
  appendActive(children, widget, m, t, p)
  appendRows(children, widget, m, w, t, p, true)
  appendActions(children, widget, m, w, t, p)
end

return M
