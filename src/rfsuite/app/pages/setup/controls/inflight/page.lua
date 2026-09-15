-- Setup > Controls > In-flight tuning: the FLIGHT CONTROLLER's half of it.
--
-- The split is the pilot's, after three radio rounds. One page held both halves and they are not
-- one job: the radio side is a mixer, two global variables, a switch and six trims, and it is
-- true of the radio whether or not anything is connected; this side writes the flight
-- controller's own adjustment slots and cannot be looked at without one. He kept finding the
-- button that writes the board on a page he had opened to change a trim.
--
-- So the board's half sits where the board's other pages sit, beside Adjustments -- which is the
-- page these slots belong to and the page a pilot who wants to see what was written goes to. It
-- is gated on the link and locked while armed, like every one of its neighbours.
--
-- The STORE follows the split. What this page holds describes the MACHINE -- which parameters its
-- flight controller offers, how far one press moves them, which PID profile is the undo, and a
-- switch of its own saying the machine is set up for the overlay -- so it stays in the per-model
-- store's `inflight` section, keyed by the flight controller's MCU id. What the other page holds
-- describes the TRANSMITTER and lives in the radio's own preferences file. Each page writes only
-- its own keys, and each carries a line naming the other.
--
-- BOTH switches have to be on before anything drives. The radio's is the master: with it off
-- nothing happens on any model and the switch here has no effect at all.

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Common = nil
local Controls = nil
local Setup = nil
-- The action, loaded only when the button that uses it is pressed. It brings
-- widgets/dashboard/inflight/fcsetup.lua and the whole adjustment-function table with it, and a
-- page's entry cost is what the pilot's radio ran out of heap on -- so nothing that is not needed
-- to DRAW the page is loaded to draw it.
local FcAction = nil

local M = {}

local ui = {
  loaded = false,
  dirty = false,
  sections = {
    board = true,
    undo = false
  },
  config = nil
}

ui.runtime = nil
local t = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not Setup then
    Setup = loadModule("widgets/dashboard/inflight/setup.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("setup_controls_inflight")
  end
end

local function session()
  if type(_G) ~= "table" or not _G.rfsuite then return nil end
  if type(_G.rfsuite.session) ~= "table" then return nil end
  return _G.rfsuite.session
end

-- Per-model settings can only be stored while a flight controller is connected: the store is
-- keyed by its MCU id and there is no key without it. The page is gated on the link anyway; this
-- is the belt to that brace, because the gate is the manifest's and this is the file's.
local function hasModelStore()
  local s = session()
  return s ~= nil and s.mcu_id ~= nil
end

-- The radio's preferences, as the page context carries them. This page edits none of them; it
-- reads the two channels below and nothing else.
local function preferences(prefs)
  if type(prefs) ~= "table" then return {} end
  return prefs
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  local s = session()
  ui.config = Setup.loadModelSettings(s and s.modelPreferences or nil)

  -- The one place the two halves meet, and it is worth being explicit about rather than hiding in
  -- a merge. An adjustment slot is a function plus the CHANNEL it is read from, and those two
  -- channels belong to the radio -- so the write this page's button makes needs them even though
  -- nothing here may edit them. They are carried on the edited table for
  -- widgets/dashboard/inflight/fcsetup.lua to find and are never written back: saveToStore puts
  -- down the model's keys alone.
  local radio = Setup.loadRadioSettings(preferences(prefs))
  ui.config.bank_ch = radio.bank_ch
  ui.config.value_ch = radio.value_ch

  ui.fcRun = nil
  ui.fcNotice = nil
  ui.fcProgress = nil
  ui.fcPhase = nil
  ui.loaded = true
  ui.dirty = false
end

--- A field changed, so any verdict on the screen was reached about a different configuration.
local function markValue(key, value)
  if ui.config[key] == value then return end
  ui.config[key] = value
  -- The verdict on the flight controller was reached under the step and the layout that have just
  -- changed. A step is part of what every slot holds, so a changed step really does mean the board
  -- no longer matches -- which is what the help says and what the compare reports.
  ui.fcNotice = nil
  ui.runtime.markValueChanged()
end

local function saveToStore()
  local s = session()
  if s == nil or s.mcu_id == nil then return false, "missing_mcu_id" end
  if type(s.modelPreferences) ~= "table" then s.modelPreferences = {} end
  if type(s.modelPreferences.inflight) ~= "table" then s.modelPreferences.inflight = {} end
  Setup.storeModelSettings(s.modelPreferences.inflight, ui.config)

  local MP = loadModule("lib/model_preferences.lua")
  if type(MP) ~= "table" or type(MP.saveByMcuId) ~= "function" then return false, "model_preferences" end
  return MP.saveByMcuId(s.mcu_id, s.modelPreferences)
end

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end

function M.onReload(ctx)
  ensureDeps()
  ui.loaded = false
  ensureLoaded(ctx and ctx.preferences)
  if ctx and ctx.requestRebuild then ctx.requestRebuild() end
end

--- The outcome goes back through the suite's own save flow, not through a dialog of this page's.
--
-- ui/home.lua drives every page's save the same way: it puts up the overlay, calls this in one
-- pcall, and shows whatever `ctx.reportSave` was handed. There is no `ctx.showDialog` in that
-- context and never was, so a store write that failed -- no MCU id to key the model's settings by,
-- or a write the card refused -- was swallowed and the save looked as though it had worked. What
-- this page stores is per-model and keyed by the flight controller's MCU id, so the failure that
-- matters is exactly the one a pilot cannot see any other way.
function M.onSave(ctx)
  ensureDeps()
  local ok, err = saveToStore()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        ok = false,
        title = t(ctx.i18n, "save_error_title", "Error"),
        message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. tostring(err or "io")
      })
    end
    -- Nothing was stored and nothing on the page changed, so there is nothing to draw again. The
    -- flow reads this as "do not rebuild", which is what their adjustments page answers too.
    return false
  end

  ui.dirty = false
  if ctx and type(ctx.reportSave) == "function" then
    ctx.reportSave({
      ok = true,
      title = t(ctx.i18n, "saved_title", "Saved"),
      message = t(ctx.i18n, "saved_message", "In-flight tuning settings saved")
    })
  end
  if ctx and ctx.requestRebuild then ctx.requestRebuild() end
  return true
end

local function requestRepaint()
  local rebuild = ui.runtime and ui.runtime.requestRebuild
  if type(rebuild) == "function" then rebuild() end
end

--- The action itself lives in fcaction.lua beside this file and is read off the card only here,
-- on the press. It pulls the writer and the adjustment tables in with it.
local function offerFcSetup(i18n)
  if FcAction == nil then
    FcAction = loadModule("app/pages/setup/controls/inflight/fcaction.lua")
  end
  if type(FcAction) ~= "table" or type(FcAction.offer) ~= "function" then
    ui.fcNotice = t(i18n, "fc_unavailable", "This build cannot reach the flight controller.")
    requestRepaint()
    return
  end
  FcAction.offer({
    i18n = i18n,
    t = t,
    -- The settings module, so the action can build its own text helper from this page's key
    -- rather than borrow this one. Its own file has to carry the pageT call for the locale
    -- precompiler to see a prefix at all; loading a second copy of common.lua to get at it would
    -- be paid in the heap this page is split up to save.
    common = Common,
    config = ui.config,
    state = ui,
    repaint = requestRepaint
  })
end

-- ---------------------------------------------------------------------------
-- The sections
-- ---------------------------------------------------------------------------

local function appendNote(children, x, y, w, text)
  children[#children + 1] = {
    type = "label", x = x, y = y, w = w, text = text, color = COLOR_THEME_PRIMARY1, font = SMLSIZE
  }
  -- A label narrower than its text WRAPS rather than clipping, so a constant advance draws
  -- the next row on top of the second line -- which is what the longest note on this page
  -- did at 800 pixels, and what every note here would do on a 480-pixel screen. The library
  -- has the answer already: ui/controls.lua measures a wrapped label, and its own comment is
  -- about precisely this mistake. One line keeps the row height it always had, so nothing
  -- that fitted moves.
  local lines = 1
  if Controls and type(Controls.estimateWrappedTextHeight) == "function" then
    local total = Controls.estimateWrappedTextHeight(text, w, SMLSIZE)
    local one = Controls.estimateWrappedTextHeight("Ag", w, SMLSIZE)
    if type(total) == "number" and type(one) == "number" and one > 0 then
      lines = math.floor((total / one) + 0.5)
      if lines < 1 then lines = 1 end
    end
  end
  return lines * 24
end

--- The line under the button while a run is on, drawn through a CLOSURE.
--
-- A moving number and a rebuild are two different things, and this page's predecessor paid dearly
-- for confusing them: the read asked for a rebuild every time its percentage moved, which on the
-- pilot's radio was once per record for thirty-six records, on a tool with 134 kB of heap left. A
-- closure handed to lvgl.build runs in the firmware's reactive sweep and formats one string per
-- frame, which is what a counter needs and all it needs.
local function appendProgressNote(children, x, y, w, source)
  children[#children + 1] = {
    type = "label", x = x, y = y, w = w, color = COLOR_THEME_PRIMARY1, font = SMLSIZE,
    text = function()
      local fn = source()
      if type(fn) ~= "function" then return "" end
      local ok, text = pcall(fn)
      if not ok or type(text) ~= "string" then return "" end
      return text
    end
  }
  return 24
end

local function buildBoard(children, x, y, w, i18n)
  local cursorY = y

  -- The machine's own switch, and the first thing on the page because everything under it is
  -- inert without it. It is not the only one: the radio carries the master, and this says which
  -- of the machines on that radio the overlay is set up for.
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "enabled", "In-flight tuning on this model"),
    ui.runtime.getBoolGetter("enabled"),
    ui.runtime.getBoolSetter("enabled"))
  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "enabled_note",
      "The switch on Settings > Dashboard > In-Flight Tuning has to be on as well."))

  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "pointer_radio", "The switch, the channels, the variables and the trims are in Settings > Dashboard."))

  -- Which parameters the overlay offers, and whether it is allowed to put them on the board.
  local setOptions = {
    { value = Setup.SET_MODE_STANDARD, label = t(i18n, "set_mode_standard", "Standard") },
    { value = Setup.SET_MODE_CUSTOM, label = t(i18n, "set_mode_custom", "Custom") }
  }
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    t(i18n, "set_mode", "Set layout"), setOptions, ui.config.set_mode,
    function(value) markValue("set_mode", value) end)
  if ui.config.set_mode == Setup.SET_MODE_CUSTOM then
    cursorY = cursorY + appendNote(children, x, cursorY, w,
      t(i18n, "set_mode_custom_note",
        "The set is whatever the flight controller carries. Nothing is written to it."))
    return cursorY
  end

  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "set_mode_standard_note",
      "Six banks of six parameters, known in advance. The flight controller is read to compare."))

  -- What one press moves a parameter by, on the board. Four rungs rather than a free number: the
  -- firmware keeps the step in one byte per slot, and the four cover the range a pilot asks for.
  local stepOptions = {}
  for i = 1, #Setup.STEP_CHOICES do
    local choice = Setup.STEP_CHOICES[i]
    stepOptions[i] = { value = choice, label = tostring(choice) }
  end
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    t(i18n, "step", "Step size"), stepOptions, Setup.nearestStep(ui.config.step),
    function(value) markValue("step", tonumber(value) or Setup.DEFAULTS.step) end)

  -- The head speed apart from the rest, because it is the one cell whose range reaches 10000 where
  -- no other is bounded above 250, and the step that suits a gain would take thousands of presses
  -- to cross it.
  local headspeedOptions = {}
  for i = 1, #Setup.HEADSPEED_STEP_CHOICES do
    local choice = Setup.HEADSPEED_STEP_CHOICES[i]
    headspeedOptions[i] = { value = choice, label = tostring(choice) }
  end
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    t(i18n, "step_headspeed", "Head speed step"), headspeedOptions,
    Setup.nearestHeadspeedStep(ui.config.step_headspeed),
    function(value) markValue("step_headspeed", tonumber(value) or Setup.DEFAULTS.step_headspeed) end)
  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "step_note",
      "Both steps are written into the slots, so a change needs the flight controller set up again."))

  -- The only thing on this page that writes the flight controller. Offered in the standard layout
  -- alone: in the custom one the set is whatever the board carries, and a button that overwrote it
  -- would overwrite the very thing being read.
  -- Wider than the 240 the other action buttons take, because a button LABEL is clipped rather
  -- than wrapped: at 240 this one lost a character at each end of its English text, which is
  -- the longest label of the two pages and the one every locale falls back to.
  local btnW = math.min(320, w)
  local btnH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or Controls.CTRL_H or 32
  children[#children + 1] = {
    type = "button",
    x = x + math.floor((w - btnW) / 2), y = cursorY, w = btnW, h = btnH,
    text = t(i18n, "setup_fc", "Set up the flight controller"),
    press = function()
      -- One run at a time. A second press while the first chain is on the wire would put two sets
      -- of writes into one queue with no order between them.
      if ui.fcRun == nil then offerFcSetup(i18n) end
    end
  }
  cursorY = cursorY + btnH + 6

  -- While a run is on, the moving line; when it is over, the fixed one it left behind. Never both,
  -- and the closure is not built at all once there is nothing for it to say.
  if ui.fcProgress then
    cursorY = cursorY + appendProgressNote(children, x, cursorY, w, function() return ui.fcProgress end)
  elseif ui.fcNotice then
    cursorY = cursorY + appendNote(children, x, cursorY, w, ui.fcNotice)
  end
  return cursorY
end

local function buildUndo(children, x, y, w, i18n)
  local cursorY = y
  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "undo_note", "The board saves an in-flight change itself, shortly after disarm, so the undo has to exist beforehand."))
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    t(i18n, "backup_profile", "Backup PID profile"), {
      min = 0, max = Setup.PROFILE_MAX, step = 1,
      get = function() return ui.config.backup_profile end,
      set = function(value) markValue("backup_profile", value) end
    })
  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "backup_auto_note", "Taken by itself when the interlock is switched on, once per profile."))
  return cursorY
end

local SECTIONS = {
  { key = "board", titleKey = "section_board", titleFallback = "Flight controller", build = buildBoard },
  { key = "undo", titleKey = "section_undo", titleFallback = "Undo", build = buildUndo }
}

function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)
  ui.runtime.setRequestRebuild(ctx.requestRebuild)

  local children = ctx.children
  local x, w = ctx.x, ctx.w
  local i18n = ctx.i18n
  local cursorY = ctx.y

  if not hasModelStore() then
    cursorY = cursorY + appendNote(children, x, cursorY, w,
      t(i18n, "no_model", "Connect a flight controller: these settings are stored with the model."))
  end

  for i = 1, #SECTIONS do
    local section = SECTIONS[i]
    if i > 1 then cursorY = cursorY + 10 end
    Controls.appendSectionHeader(children, x, cursorY, w,
      t(i18n, section.titleKey, section.titleFallback),
      ui.sections[section.key],
      ui.runtime.getSectionToggleHandler(section.key))
    cursorY = cursorY + Controls.SECTION_H
    if ui.sections[section.key] then
      cursorY = section.build(children, x, cursorY, w, i18n)
    end
  end
end

function M.onClose()
  -- A READ the pilot walked away from is given up here, and its messages come out of the queue
  -- with it. A WRITE is not, and that is deliberate: stopped half way it leaves the flight
  -- controller holding part of one adjustment set and part of another. The screen says so while it
  -- runs, which is the honest way round.
  if type(FcAction) == "table" and type(FcAction.cancel) == "function" then
    pcall(FcAction.cancel, ui)
  end

  Common.resetPageState(ui)
  ui.fcRun = nil
  ui.fcProgress = nil
  ui.fcPhase = nil
  ui.fcNotice = nil
  Controls = nil
  Common = nil
  Setup = nil
  FcAction = nil
  t = nil
end

return M
