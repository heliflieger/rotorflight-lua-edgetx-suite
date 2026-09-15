-- Fired once, right after a model is created from the Rotorflight template.
--
-- EdgeTX runs the script that sits beside a template's yml as a standalone script the moment
-- the template is applied (gui/colorlcd/model/model_select.cpp, the "wizard Lua script" hook).
-- The yml has already delivered everything no script can set later -- the ARM function switch,
-- the warnings, the static reference channels, the dashboard. What is still open is the
-- pilot's half: WHICH switch carries which function. That is asked with the radio's OWN
-- pickers -- the source picker filtered to switches for the four whole-switch answers, the
-- position picker for the one position the reference construction stores, the hold gate --
-- and written in the reference models' shape: plain lines at full weight, active low, the
-- hold as a MAX line gated by the named position, the governor beneath it.
--
-- The setup assistant asks its own position questions later, against a connected flight
-- controller and with a read-back to prove them -- this wizard deliberately stops at the
-- reference-model shape a pilot could also have built by hand.
--
-- Strings carry i18n markers like every suite source: the packager resolves them per locale
-- at build time, so the standalone script needs none of the suite's i18n helpers at runtime.

local RADIO_MODULE = "/SCRIPTS/TOOLS/rfsuite-core/app/pages/setup_wizard/radio.lua"

local R = nil          -- the assistant's radio-side module, loaded below
local loadError = nil

-- The five rows. `whole` answers with a SWITCH through the radio's source picker (any of its
-- positions may carry the function -- the reference encodes the rest as convention, active
-- low); the hold row answers with the one POSITION the reference construction stores. `min`
-- is the position count the function needs: governor and profiles carry three values across
-- the travel, arming and rescue work on two or three (the reference arms on a three-position
-- switch).
local ROWS = {
  { key = "arm", whole = true, min = 2, label = "@i18n(templates.rotorflight.row_arm)@" },
  { key = "hold", whole = false, label = "@i18n(templates.rotorflight.row_hold)@" },
  { key = "gov", whole = true, min = 3, label = "@i18n(templates.rotorflight.row_gov)@" },
  { key = "profile", whole = true, min = 3, label = "@i18n(templates.rotorflight.row_profile)@" },
  { key = "rescue", whole = true, min = 2, label = "@i18n(templates.rotorflight.row_rescue)@" }
}

local answers = {}      -- key -> swsrc: a switch's first position, or the hold position
local message = nil     -- what stands between the pilot and the Create button, in words
local written = nil     -- per-channel results of the write, once it ran
local view = nil        -- nil (not built) | "form" | "done"
local quit = false      -- the closing screen's button asked to leave

-- ---------------------------------------------------------------------------------------------
-- The write: the REFERENCE construction, with the pilot's switches in it.
--
--   input Arm   <arm switch>  +100                   -> CH5 "Arming"
--   input Thr   MAX -100 gated by the hold position,
--               then <governor> +100  ("Hold"/"GOV") -> CH6 "Thr"
--   input Prof  <profile switch> +100 ("Prof")       -> CH7 "Prof"
--   input Res   <rescue switch>  +100 ("Rescue")     -> CH8 "Rescue"
--
-- Expo lines are alternatives: the first line whose gate matches wins, so the hold line rules
-- exactly one position and every other position carries the governor -- the reference's own
-- trick, and the reason the hold is the one position asked for. Active is LOW throughout, as
-- both reference models have it. The assistant recognises the plain lines and re-asks what it
-- cannot read when it later walks the flight-controller half.
-- ---------------------------------------------------------------------------------------------

local function sourceByName(name)
  local id = getSourceIndex ~= nil and getSourceIndex(name) or nil
  if id ~= nil then return tonumber(id) end
  local info = getFieldInfo ~= nil and getFieldInfo(name) or nil
  if type(info) == "table" and info.id ~= nil then return tonumber(info.id) end
  return nil
end

local function clearInput(index)
  for _ = 1, (model.getInputsCount(index) or 0) do
    model.deleteInput(index, 0)
  end
end

local function putLine(index, lineNo, inputName, source, weight, gate, lineName)
  model.insertInput(index, lineNo, {
    name = lineName or "",
    inputName = inputName,
    source = source,
    weight = weight,
    offset = 0,
    switch = gate or 0,
    curveType = 0,
    curveValue = 0,
    scale = 0,
    side = 3,
    trimSource = R.TRIM_OFF,
    flightModes = 0
  })
end

local function wire(channel, input, channelName)
  if not R.clearChannel(channel) then return false, "clear_failed" end
  local ok = pcall(model.insertMix, channel - 1, 0, {
    source = R.inputSource(input),
    weight = 100,
    offset = 0,
    switch = 0,
    multiplex = 0,
    curveType = 0,
    curveValue = 0,
    flightModes = 0
  })
  if not ok then return false, "insert_failed" end
  R.setChannelName(channel, channelName)
  return true
end

local function writeAnswers()
  written = {}

  local function record(channel, name, ok, err)
    written[#written + 1] = { channel = channel, name = name, ok = ok and true or false, err = err }
  end

  local function simple(channel, input, inputName, channelName, swsrc, lineName)
    local source = R.switchSource(swsrc)
    if source == nil then record(channel, channelName, false, "no_source") return end
    clearInput(input)
    local okLine = pcall(putLine, input, 0, inputName, source, 100, 0, lineName)
    if not okLine then record(channel, channelName, false, "input_failed") return end
    local ok, err = wire(channel, input, channelName)
    record(channel, channelName, ok, err)
  end

  simple(5, 4, "Arm", "Arming", answers.arm)

  -- The throttle goes through the assistant's own writer: ONE construction, one place, and
  -- the assistant recognises its own work when it walks the flight-controller half later.
  do
    local throttleEntry = nil
    for _, entry in ipairs(R.CHANNELS) do
      if entry.key == "throttle" then throttleEntry = entry break end
    end
    if throttleEntry == nil then
      record(6, "Thr", false, "no_entry")
    else
      local ok, err = R.writeThrottleChannel(throttleEntry, answers.hold, answers.gov)
      record(6, "Thr", ok, err)
    end
  end

  simple(7, 6, "Prof", "Prof", answers.profile, "Prof")
  simple(8, 7, "Res", "Rescue", answers.rescue, "Rescue")
end

-- What still stands between the pilot and the write, in one sentence -- or nil, which is what
-- lets the button act.
local function firstProblem()
  for _, row in ipairs(ROWS) do
    local value = answers[row.key]
    if value == nil or value == 0 then
      return string.format("@i18n(templates.rotorflight.nothing_chosen)@", row.label)
    end
    if row.min ~= nil then
      local positions = R.switchPositionCount(value) or 0
      if positions < row.min then
        return string.format("@i18n(templates.rotorflight.too_few_positions)@",
          row.label, positions, row.min)
      end
    end
  end
  return nil
end


-- ---------------------------------------------------------------------------------------------
-- The form, out of the radio's own controls -- the same child tables the suite hands to
-- lvgl.build, source pickers without a `title` (the picker class does not carry the property
-- and raises on it).
-- ---------------------------------------------------------------------------------------------

-- Theme roles, with fallbacks for a stripped surface: strong foreground, muted secondary,
-- the header band and its on-band text, hairlines, and the two hard colors that carry a
-- meaning (a write that worked, a write that failed). Everything else stays theme-colored,
-- so the screens follow whatever theme the radio wears.
local COL_TEXT = COLOR_THEME_PRIMARY1 or BLACK or 0
local COL_MUTED = COLOR_THEME_PRIMARY3 or COL_TEXT
local COL_BAND = COLOR_THEME_SECONDARY1 or COL_TEXT
local COL_ON_BAND = COLOR_THEME_PRIMARY2 or WHITE or 0
local COL_LINE = COLOR_THEME_SECONDARY3 or COL_MUTED
local COL_WARN = COLOR_THEME_WARNING or ORANGE or COL_TEXT
local COL_OK_TXT = GREEN or COL_TEXT
local COL_BAD_TXT = RED or COL_TEXT
local FONT_TITLE = BOLD or 0
local BAND_H = 30

-- The picker filters. The bit values are the firmware's own (dataconstants.h); the source
-- filter is taken from the lvgl module where it exists, because that registered constant
-- already includes the function-switch bit -- the switches this template cares most about.
local SRC_SWITCH_FILTER = (lvgl ~= nil and lvgl.SRC_SWITCH) or 0xFFFFFFFF
local SW_SWITCH = 1
local SW_NONE = 1 << 20

local W = LCD_W or 480
local H = LCD_H or 272
local ROW_H = 36
local PICKER_W = 190
local LEFT = 12

local function sourceRow(children, y, row)
  children[#children + 1] = {
    type = "label", x = LEFT, y = y + 8, w = W - PICKER_W - 2 * LEFT - 8,
    text = row.label, color = COL_TEXT
  }
  children[#children + 1] = {
    type = "source",
    x = W - PICKER_W - LEFT, y = y + 2, w = PICKER_W, h = ROW_H - 6,
    filter = SRC_SWITCH_FILTER,
    get = function()
      local picked = answers[row.key]
      if picked == nil or picked == 0 then return 0 end
      return R.switchSource(picked) or 0
    end,
    set = function(value)
      answers[row.key] = R.switchFromSource(value) or 0
    end
  }
end

local function positionRow(children, y, row)
  children[#children + 1] = {
    type = "label", x = LEFT, y = y + 8, w = W - PICKER_W - 2 * LEFT - 8,
    text = row.label, color = COL_TEXT
  }
  children[#children + 1] = {
    type = "switch",
    x = W - PICKER_W - LEFT, y = y + 2, w = PICKER_W, h = ROW_H - 6,
    filter = SW_SWITCH | SW_NONE,
    get = function() return answers[row.key] or 0 end,
    set = function(value) answers[row.key] = tonumber(value) or 0 end
  }
end

-- The theme-colored band every screen opens with. Drawn first so it sits behind its title,
-- and kept above y=34, where the form's rows begin -- the row geometry is proven and stays.
local function bandWithTitle(children, title)
  children[#children + 1] = {
    type = "rectangle", x = 0, y = 0, w = W, h = BAND_H,
    color = COL_BAND, filled = true
  }
  children[#children + 1] = {
    type = "label", x = LEFT, y = 7, w = W - 2 * LEFT,
    text = title, color = COL_ON_BAND, font = FONT_TITLE
  }
end

local function buildForm()
  lvgl.clear()
  local children = {}
  bandWithTitle(children, "@i18n(templates.rotorflight.title_form)@")
  local y = 34
  for _, row in ipairs(ROWS) do
    if row.whole then sourceRow(children, y, row) else positionRow(children, y, row) end
    y = y + ROW_H
  end

  -- The one sentence that stands between the pilot and the button; the button's press
  -- rebuilds this form, which is what puts the sentence on screen. Warning-colored: it is
  -- the refusal, and it must not read like one more row label.
  if message ~= nil then
    children[#children + 1] = {
      type = "label", x = LEFT, y = y + 4, w = W - 2 * LEFT,
      color = COL_WARN, text = message
    }
  end

  children[#children + 1] = {
    type = "button", x = LEFT, y = y + 30, w = 200, h = 34,
    text = "@i18n(templates.rotorflight.create_button)@",
    press = function()
      message = firstProblem()
      -- Either way the view is rebuilt: with the write done it becomes the closing screen,
      -- with a problem it comes back carrying the sentence -- a live label alone stayed
      -- blank here, and a refusal nobody can read is a button that does nothing.
      if message == nil then writeAnswers() end
      view = nil
    end
  }
  children[#children + 1] = {
    type = "label", x = LEFT + 212, y = y + 38, w = W - LEFT - 212,
    text = "@i18n(templates.rotorflight.skip_hint)@", color = COL_MUTED
  }
  lvgl.build(children)
end

local function buildDone()
  lvgl.clear()
  local children = {}
  bandWithTitle(children, "@i18n(templates.rotorflight.title_done)@")

  -- One card, one row per channel written, the verdict as a colored word on the right --
  -- green carries "worked", red carries "failed: why", and nothing else on this screen
  -- wears a hard color, so a failure is the loudest thing on it.
  local rows = written or {}
  local rowH = 24
  local cardX, cardY = LEFT, BAND_H + 12
  local cardW = W - 2 * LEFT
  local cardH = #rows * rowH + 16
  -- A filled panel rather than a hairline: the outline drew in a near-background grey on the
  -- default theme and the card read as loose rows.
  children[#children + 1] = {
    type = "rectangle", x = cardX, y = cardY, w = cardW, h = cardH,
    color = COLOR_THEME_SECONDARY2 or COL_LINE, filled = true, rounded = 6
  }
  local statusW = 190
  local y = cardY + 8
  for _, result in ipairs(rows) do
    children[#children + 1] = {
      type = "label", x = cardX + 10, y = y + 3, w = cardW - statusW - 24,
      color = COL_TEXT,
      text = "CH" .. tostring(result.channel) .. "  " .. tostring(result.name)
    }
    children[#children + 1] = {
      type = "label", x = cardX + cardW - statusW - 10, y = y + 3, w = statusW,
      color = result.ok and COL_OK_TXT or COL_BAD_TXT,
      text = result.ok and "@i18n(templates.rotorflight.row_ok)@"
        or string.format("@i18n(templates.rotorflight.row_failed)@", tostring(result.err))
    }
    y = y + rowH
  end

  y = cardY + cardH + 12
  children[#children + 1] = {
    type = "label", x = LEFT, y = y, w = W - 2 * LEFT, color = COL_TEXT,
    text = "@i18n(templates.rotorflight.next_steps)@"
  }
  -- Two lines of room above the path: the sentence wraps at 480 px in more than one locale,
  -- and with only one line's gap it wrapped straight across the path.
  children[#children + 1] = {
    type = "label", x = LEFT, y = y + 40, w = W - 2 * LEFT, color = COL_MUTED,
    text = "@i18n(templates.rotorflight.next_steps_path)@"
  }

  -- A button to leave by, because a screen only RTN can close reads as stuck. RTN still
  -- works; the button says the same thing where a finger already is.
  children[#children + 1] = {
    type = "button", x = LEFT, y = H - 46, w = 160, h = 34,
    text = "@i18n(templates.rotorflight.close_button)@",
    press = function() quit = true end
  }
  lvgl.build(children)
end

local function init()
end

local function run(event)
  if quit or event == EVT_VIRTUAL_EXIT then return 1 end

  -- Without the suite there is no radio module to borrow, and half a wizard would leave half
  -- a layout. The template's yml part is already in the model either way. And without lvgl
  -- there is no picker to offer -- the same honest exit.
  if R == nil then
    if loadError == nil then
      local chunk = loadScript(RADIO_MODULE, "t")
      if type(chunk) == "function" then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" then R = mod else loadError = "load" end
      else
        loadError = "missing"
      end
      if lvgl == nil or type(lvgl.build) ~= "function" then loadError = "no_lvgl" end
      if R ~= nil and loadError == nil and (answers.arm == nil or answers.arm == 0) then
        -- SW1 is the switch the template PREPARED -- named ARM, red while armed -- so it is
        -- the one picker that starts filled. Everything else starts empty: those answers are
        -- not prepared anywhere.
        -- Every function switch arrives identically arm-ready; SW1 is preselected only
        -- because a filled picker is one decision fewer, not because it is special.
        for _, sw in ipairs(R.switches(2)) do
          if sw.name == "SW1" then answers.arm = sw.swsrc break end
        end
      end
    end
    if R == nil or loadError ~= nil then
      if event == EVT_VIRTUAL_ENTER then return 1 end
      if lcd ~= nil and lcd.clear ~= nil then
        lcd.clear()
        lcd.drawText(30, 40, "@i18n(templates.rotorflight.fallback_created)@", 0)
        lcd.drawText(30, 70, "@i18n(templates.rotorflight.fallback_needs_1)@", 0)
        lcd.drawText(30, 90, "@i18n(templates.rotorflight.fallback_needs_2)@", 0)
        lcd.drawText(30, 110, "@i18n(templates.rotorflight.fallback_needs_3)@", 0)
        lcd.drawText(30, 150, "@i18n(templates.rotorflight.fallback_close)@", 0)
      end
      return 0
    end
  end

  if written ~= nil and view ~= "done" then
    buildDone()
    view = "done"
  elseif written == nil and view ~= "form" then
    buildForm()
    view = "form"
  end

  return 0
end

return { init = init, run = run }
