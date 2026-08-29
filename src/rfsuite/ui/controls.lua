-- ui/controls.lua
-- Reusable UX control components for LVGL declarative UI.
--
-- All functions append LVGL widget entries to a children table.
local Controls = {}

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  if loadScript then
    local chunk = loadScript(fullPath, "t")
    if type(chunk) == "function" then
      local ok, mod = pcall(chunk)
      if ok and type(mod) == "table" then
        return mod
      end
    end
  end
  return nil
end

local DisplayProfile = nil

local function getDisplayProfile()
  if not DisplayProfile then
    DisplayProfile = loadModule("core/display_profile.lua")
  end
  if DisplayProfile and type(DisplayProfile.current) == "function" then
    return DisplayProfile.current()
  end
  return nil
end

local function getNativeCtrlH()
  if lvgl and lvgl.UI_ELEMENT_HEIGHT then
    return lvgl.UI_ELEMENT_HEIGHT
  end
  local w = _G.LCD_W or 480
  if w >= 760 then return 44 end
  if w <= 320 then return 26 end
  return 32
end

local function getNativeFontH()
  if lvgl and lvgl.LCD_SCALE then
    return math.floor(21 * lvgl.LCD_SCALE + 0.5)
  end
  local w = _G.LCD_W or 480
  if w >= 760 then return 29 end
  if w <= 320 then return 17 end
  return 21
end

local function getRowH()
  local prof = getDisplayProfile()
  if prof and prof.rowH then return prof.rowH end
  local w = _G.LCD_W or 480
  if w >= 760 then return 50 end
  return 40
end

local function getHorizontalRowH()
  local prof = getDisplayProfile()
  if prof and prof.horizontalRowH then return prof.horizontalRowH end
  local w = _G.LCD_W or 480
  if w >= 760 then return 68 end
  return 56
end

local function getSectionH()
  local prof = getDisplayProfile()
  if prof and prof.sectionH then return prof.sectionH end
  local w = _G.LCD_W or 480
  if w >= 760 then return 46 end
  return 38
end

local function getStaticSectionH()
  local prof = getDisplayProfile()
  if prof and prof.staticSectionH then return prof.staticSectionH end
  local w = _G.LCD_W or 480
  if w >= 760 then return 46 end
  return 38
end

local CTRL_H = getNativeCtrlH()
local LABEL_H = getNativeFontH()
-- ── SectionHeader ─────────────────────────────────────────────────────────────
-- Collapsible accordion section title with a blue bottom bar (like tile highlight).
--
-- Layout:
--   y+2            title label     MIDSIZE, COLOR_THEME_PRIMARY1
--   y+44           3 px blue bar   COLOR_THEME_SECONDARY1
--   y+49           1 px divider    COLOR_THEME_SECONDARY2
--
-- Controls.SECTION_H is exported so callers stay in sync.

local ROW_H = getRowH()
local HORIZONTAL_ROW_H = getHorizontalRowH()
local SECTION_H = getSectionH()
local STATIC_SECTION_H = getStaticSectionH()
local SECTION_BAR_H        = 3
local SECTION_ARROW_W      = 30
local SECTION_ARROW_H      = 30

Controls.CTRL_H = CTRL_H
Controls.LABEL_H = LABEL_H
Controls.SECTION_H = SECTION_H
Controls.STATIC_SECTION_H = STATIC_SECTION_H
Controls.ROW_H = ROW_H
Controls.HORIZONTAL_ROW_H = HORIZONTAL_ROW_H

function Controls.controlY(y, rowH, ctrlH)
  ctrlH = ctrlH or Controls.CTRL_H
  rowH = rowH or Controls.ROW_H
  return y + math.floor((rowH - ctrlH) / 2)
end

function Controls.labelY(y, rowH, labelH)
  labelH = labelH or Controls.LABEL_H
  rowH = rowH or Controls.ROW_H
  return y + math.floor((rowH - labelH) / 2)
end

local function clampInt(v, lo, hi)
  v = math.floor((tonumber(v) or lo) + 0.5)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Shared responsive grid metrics for table-like pages (PIDs, rates, etc.).
-- Returns stable spacing/cell widths across different radios.
function Controls.computeGridMetrics(totalW, columns, opts)
  opts = opts or {}
  local colCount = tonumber(columns) or 1
  if colCount < 1 then colCount = 1 end

  local w = tonumber(totalW) or 0
  if w < 1 then w = 1 end

  local labelRatio = tonumber(opts.labelRatio) or 0.24
  local labelMin = tonumber(opts.labelMin) or 72
  local labelMax = tonumber(opts.labelMax) or math.max(labelMin, w - colCount)
  local gapMin = tonumber(opts.gapMin) or 2
  local gapMax = tonumber(opts.gapMax) or 8
  local cellMin = tonumber(opts.cellMin) or 42

  local labelW = clampInt(w * labelRatio, labelMin, labelMax)
  local available = w - labelW
  if available < colCount then
    labelW = math.max(0, w - colCount)
    available = w - labelW
  end

  local gap = clampInt(available * 0.02, gapMin, gapMax)
  local function computeCellWidth()
    return math.floor((w - labelW - (gap * (colCount - 1))) / colCount)
  end

  local cellW = computeCellWidth()
  while cellW < cellMin and gap > gapMin do
    gap = gap - 1
    cellW = computeCellWidth()
  end

  while cellW < cellMin and labelW > labelMin do
    labelW = labelW - 1
    cellW = computeCellWidth()
  end

  if cellW < 1 then cellW = 1 end
  return {
    labelW = labelW,
    gap = gap,
    cellW = cellW
  }
end

function Controls.appendSectionHeader(children, x, y, w, title, expanded, onToggle)
  local sectionH = SECTION_H

  -- Title label
  children[#children + 1] = {
    type  = "label",
    x = x, y = y + 2,
    text  = title,
    color = COLOR_THEME_PRIMARY1,
    font  = MIDSIZE
  }

  -- Expand/collapse button (styled chevron control)
  local btnX = x + w - SECTION_ARROW_W
  local btnY = y + math.floor((sectionH - 6 - SECTION_ARROW_H) / 2)
  local icon = expanded and "v" or ">"
  children[#children + 1] = {
    type  = "button",
    x = btnX,
    y = btnY,
    w = SECTION_ARROW_W,
    h = SECTION_ARROW_H,
    text  = "",
    color = COLOR_THEME_SECONDARY1,
    press = onToggle
  }

  children[#children + 1] = {
    type  = "label",
    x = btnX,
    y = btnY + 3,
    w = SECTION_ARROW_W,
    text  = icon,
    color = COLOR_THEME_PRIMARY1,
    align = CENTER,
    font  = SMLSIZE
  }

  -- Blue accent bar (below title)
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + sectionH - 6,
    w = w, h = SECTION_BAR_H,
    color  = COLOR_THEME_SECONDARY1, filled = true
  }

  -- Divider line (bottom edge)
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + sectionH - 1,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }
end

function Controls.appendStaticSectionHeader(children, x, y, w, title)
  local staticSectionH = STATIC_SECTION_H

  children[#children + 1] = {
    type  = "label",
    x = x, y = y + 2,
    text  = title,
    color = COLOR_THEME_PRIMARY1,
    font  = MIDSIZE
  }

  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + staticSectionH - 6,
    w = w, h = 3,
    color  = COLOR_THEME_SECONDARY1, filled = true
  }
end

-- ── RadioSwitch ───────────────────────────────────────────────────────────────
-- Slider-style boolean toggle with dynamic visuals.
-- Visual state updates are driven by getter functions, so callers can avoid
-- full-page rebuilds on each toggle and keep focus stable.
--
-- Parameters:
--   children             – LVGL children array
--   x, y, w              – bounds of the full content row
--   labelText            – descriptive label on the left
--   value                – boolean: true = ON
--   onToggle             – press callback (no arguments)

local TOGGLE_W       = 64

local NUMBER_W       = 172
local HELP_BTN_W     = 30
local HELP_BTN_H     = 30
local HELP_BTN_GAP   = 6

local function showHelpAlert(helpText, helpTitle)
  if not (lvgl and lvgl.message) then return end
  lvgl.message({
    title = helpTitle or "Help",
    message = tostring(helpText or "")
  })
end

function Controls.appendRadioSwitch(children, x, y, w, labelText, value,
                                     onToggle, active, opts)
  if type(active) == "table" and opts == nil then
    opts = active
    active = opts.active
  else
    opts = opts or {}
  end
  local getValue
  local setValue
  if type(value) == "function" then
    getValue = value
  else
    local localValue = value == true
    getValue = function() return localValue end
    setValue = function(nextBool)
      localValue = nextBool == true
    end
  end

  local barW   = TOGGLE_W
  local barX   = x + w - barW - 15
  local trackX = barX
  local rowH   = opts.rowH or Controls.ROW_H
  local trackY = Controls.controlY(y, rowH)
  local labelY = Controls.labelY(y, rowH)

  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = barX - x - 8,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  children[#children + 1] = {
    type = "toggle",
    x = trackX,
    y = trackY,
    w = TOGGLE_W,
    active = active,
    get = function()
      return getValue()
    end,
    set = function(nextVal)
      local nextBool
      if nextVal == nil then
        -- Some EdgeTX builds call toggle.set() without a payload.
        nextBool = not getValue()
      else
        local t = type(nextVal)
        if t == "boolean" then
          nextBool = nextVal
        elseif t == "number" then
          nextBool = nextVal ~= 0
        elseif t == "string" then
          local s = string.lower(nextVal)
          nextBool = s == "1" or s == "true" or s == "on"
        else
          nextBool = not getValue()
        end
      end
      if nextBool ~= getValue() then
        if setValue then setValue(nextBool) end
        onToggle(nextBool)
      end
    end
  }

  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

-- ── NumberField ──────────────────────────────────────────────────────────────
-- Numeric input field using native numberEdit behavior.
-- Focus field and turn wheel to adjust value.
--
-- Parameters:
--   opts - table:
--     enabled=true/false
--     min, max
--     suffix="°"
--     get=function() return number end
--     set=function(number) end

function Controls.appendNumberField(children, x, y, w, labelText, opts)
  opts = opts or {}
  w = tonumber(w) or NUMBER_W
  local enabledGetter
  if type(opts.enabled) == "function" then
    enabledGetter = opts.enabled
  elseif type(opts.active) == "function" then
    enabledGetter = opts.active
  else
    local enabled = (opts.enabled ~= false) and (opts.active ~= false)
    enabledGetter = function() return enabled end
  end
  local suffix = opts.suffix or ""
  local displayFn = opts.display
  local minVal = tonumber(opts.min) or 0
  local maxVal = tonumber(opts.max) or 100
  local stepVal = tonumber(opts.step) or 1
  local getter = opts.get or function() return minVal end
  local setter = opts.set or function() end

  local fieldW = NUMBER_W
  if fieldW > w then fieldW = w end
  local helpText = opts.helpText
  local helpTitle = opts.helpTitle
  local hasHelp = type(helpText) == "string" and helpText ~= ""
  local fieldX = x + w - fieldW - 10
  if hasHelp then
    fieldX = fieldX - HELP_BTN_W - HELP_BTN_GAP
  end
  local rowH = opts.rowH or Controls.ROW_H
  local fieldY = Controls.controlY(y, rowH)
  local labelY = Controls.labelY(y, rowH)

  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = fieldX - x - 8,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }
  children[#children + 1] = {
    type = "numberEdit",
    x = fieldX,
    y = fieldY,
    w = fieldW,
    min = math.floor(minVal / stepVal),
    max = math.ceil(maxVal / stepVal),
    active = function()
      return enabledGetter()
    end,
    get = function()
      local current = tonumber(getter()) or minVal
      if current < minVal then current = minVal end
      if current > maxVal then current = maxVal end
      return math.floor(current / stepVal)
    end,
    set = function(val)
      local nextVal = (tonumber(val) or math.floor(minVal / stepVal)) * stepVal
      if nextVal < minVal then nextVal = minVal end
      if nextVal > maxVal then nextVal = maxVal end
      if getter() == nextVal then
        return
      end
      setter(nextVal)
    end,
    display = function(val)
      local shown = (tonumber(val) or math.floor(minVal / stepVal)) * stepVal
      if type(displayFn) == "function" then
        local ok, text = pcall(displayFn, shown)
        if ok and type(text) == "string" then
          return text
        end
      end
      return tostring(shown) .. suffix
    end
  }

  if hasHelp then
    local helpBtnY = y + math.floor((rowH - HELP_BTN_H) / 2)
    children[#children + 1] = {
      type = "button",
      x = fieldX + fieldW + HELP_BTN_GAP,
      y = helpBtnY,
      w = HELP_BTN_W,
      h = HELP_BTN_H,
      text = "?",
      press = function()
        if type(opts.onHelp) == "function" then
          opts.onHelp(helpText, helpTitle)
        else
          showHelpAlert(helpText, helpTitle)
        end
      end
    }
  end

  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

-- ── ComboSelect ───────────────────────────────────────────────────────────────
-- Generic dropdown using native lvgl.choice.
-- Returns the effective row height + 1 so callers can advance cursorY.
--
-- Parameters:
--   options       – array of { value = any, label = string }
--   selectedValue – currently selected value (compared with ==)
--   onSelect      – called with (value) when an option is chosen

local COMBO_OPTION_H = 44

Controls.COMBO_ROW_H    = ROW_H + 1
Controls.COMBO_OPTION_H = COMBO_OPTION_H

function Controls.appendComboSelect(children, x, y, w, labelText, options,
                                     selectedValue, onSelect, opts)

  opts = opts or {}

  local rowH = opts.rowH or Controls.ROW_H
  local comboW = 172
  if comboW > w then comboW = w end
  local helpText = opts.helpText
  local helpTitle = opts.helpTitle
  local hasHelp = type(helpText) == "string" and helpText ~= ""
  local comboX = x + w - comboW - 10
  if hasHelp then
    comboX = comboX - HELP_BTN_W - HELP_BTN_GAP
  end
  local comboY = Controls.controlY(y, rowH)
  local labelY = Controls.labelY(y, rowH)

  local values = {}
  local selectedIndex = nil
  for i, opt in ipairs(options) do
    values[i] = tostring(opt.label or "")
    if opt.value == selectedValue then
      selectedIndex = i
    end
  end

  -- A value the list does not contain used to leave selectedIndex at 1, so a board reporting
  -- something this build has no label for was drawn exactly like a board reporting the first
  -- option -- and there was nothing on the screen to tell the two apart. Show the raw value
  -- instead, in an entry appended past the end of `options`: the combo then says what was read,
  -- and the guard in `set` below keeps that entry from ever being chosen or handed to onSelect.
  local unknownIndex = nil
  if selectedIndex == nil and selectedValue ~= nil and #values > 0 then
    unknownIndex = #values + 1
    values[unknownIndex] = string.format("@i18n(app.unknown_value)@", tostring(selectedValue))
    selectedIndex = unknownIndex
  end

  if #values == 0 then
    values[1] = ""
    selectedIndex = 1
  end
  selectedIndex = selectedIndex or 1

  -- Left label (same style as radio rows)
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = comboX - x - 8,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  -- Native choice control with EdgeTX popup behavior/styling.
  children[#children + 1] = {
    type  = "choice",
    x = comboX, y = comboY,
    w = comboW,
    title = tostring(labelText or ""),
    values = values,
    active = opts.active,
    get = function()
      return selectedIndex
    end,
    set = function(nextIndex)
      local idx = tonumber(nextIndex) or selectedIndex
      if idx < 1 then idx = 1 end
      -- The placeholder is not one of the options. Selecting it is a no-op rather than a clamp
      -- onto the last real entry, which would write a value the pilot never chose.
      if unknownIndex and idx == unknownIndex then
        return
      end
      if idx > #options then idx = #options end
      if idx == selectedIndex then
        return
      end
      selectedIndex = idx
      local opt = options[idx]
      if opt and onSelect then
        onSelect(opt.value)
      end
    end
  }

  if hasHelp then
    local helpBtnY = y + math.floor((rowH - HELP_BTN_H) / 2)
    children[#children + 1] = {
      type = "button",
      x = comboX + comboW + HELP_BTN_GAP,
      y = helpBtnY,
      w = HELP_BTN_W,
      h = HELP_BTN_H,
      text = "?",
      press = function()
        if type(opts.onHelp) == "function" then
          opts.onHelp(helpText, helpTitle)
        else
          showHelpAlert(helpText, helpTitle)
        end
      end
    }
  end

  -- Row divider
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

function Controls.appendTextField(children, x, y, w, labelText, opts)
  opts = opts or {}
  local rowH = opts.rowH or Controls.ROW_H
  local labelY = Controls.labelY(y, rowH)

  local editW = 172
  if editW > w then editW = w end
  local editX = x + w - editW - 10
  local labelW = editX - x - 8
  local editY = Controls.controlY(y, rowH)

  local getter = opts.get or function() return "" end
  local setter = opts.set or function() end
  local activeGetter = opts.active
  if type(activeGetter) ~= "function" then
    local activeVal = opts.active ~= false
    activeGetter = function() return activeVal end
  end
  local maxLength = tonumber(opts.length) or 32

  -- Left label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = labelW,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  -- Text edit box
  children[#children + 1] = {
    type = "textEdit",
    x = editX,
    y = editY,
    w = editW,
    value = getter(),
    length = maxLength,
    active = activeGetter,
    set = function(newVal)
      setter(newVal)
    end
  }

  -- Row divider
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
end

return Controls
