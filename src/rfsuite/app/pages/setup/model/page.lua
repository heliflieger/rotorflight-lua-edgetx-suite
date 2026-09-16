-- The model configuration the FLIGHT CONTROLLER carries, and the radio-side features it asks
-- for. Read and written over MSP_PILOT_CONFIG / MSP_SET_PILOT_CONFIG.
--
-- Three (type, value) slots let a craft carry its own settings and have the radio apply them on
-- connect: a slot can name one of the radio's three flight timers or one of GV1..GV9. A flag
-- bit, from API 12.09 onwards, lets the craft say whether it renames the radio's model.
--
-- These belong here rather than in the suite's own settings because they are stored on the
-- BOARD: they travel with the helicopter, not with the radio, and a second radio flying the
-- same craft gets them too.

local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Controls = nil
local Common = nil
local MspRuntime = nil
local SavePipeline = nil
local PilotConfigApi = nil
local LoadingOverlay = nil
local t = nil

local PARAM_SLOTS = 3

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

-- The parameter types, in the firmware's own order: nothing, the three timers, then GV1..GV9.
local function typeOptions(i18n)
  local out = { { value = 0, label = pageText(i18n, "param_none", "None") } }
  for i = 1, 3 do
    out[#out + 1] = { value = i, label = pageText(i18n, "param_timer", "Timer") .. " " .. i }
  end
  for i = 1, 9 do
    out[#out + 1] = { value = 3 + i, label = "GV" .. i }
  end
  return out
end

local function newRuntime()
  return { readPending = false, requestRebuild = nil }
end

-- The two radio-side preferences this page now also owns, and why they are here.
--
-- Both decide whether something the BOARD carries is applied to the radio, so they belong beside
-- what they act on rather than in a settings page of their own. The name is the sharper case:
-- from MSP API 12.09 the craft carries a MODEL_SET_NAME bit and the preference is not consulted
-- at all, so one control has to stand for both mechanisms and pick by what the board reported.
--
-- They are radio-WIDE, unlike everything else on this page. That is not something to hide behind
-- a per-model heading, so each says so where it is drawn.
local prefs = {
  loaded = false,
  dirty = false,
  syncname = false,
  syncparams = false,
}

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  config = {
    model_id = 0,
    model_flags = nil,          -- nil until a flight controller that HAS the field answers
  },
  sections = { params = true, features = true },
  runtime = newRuntime(),
}

local function prefBool(value)
  return value == true or value == "true" or value == 1 or value == "1"
end

local function loadPrefs(preferences)
  if prefs.loaded then return end
  local general = (preferences and preferences.general) or {}
  prefs.syncname = prefBool(general.syncname)
  prefs.syncparams = prefBool(general.syncparams)
  prefs.loaded = true
end

-- A switch over one of them. The setter marks its own dirty flag, because the save has two
-- destinations and only one of them should be written when only the other changed.
local function prefSwitch(children, x, cursorY, w, label, key)
  return Controls.appendRadioSwitch(children, x, cursorY, w, label,
    function() return prefs[key] == true end,
    function(on)
      if prefs[key] == on then return end
      prefs[key] = on
      prefs.dirty = true
    end)
end

local function appendRadioWideNote(children, x, cursorY, w, i18n)
  children[#children + 1] = {
    type = "label", x = x + 10, y = cursorY, w = w - 10,
    text = pageText(i18n, "radio_wide", "Stored on this radio, for every model"),
    color = COLOR_THEME_SECONDARY1,
    font = SMLSIZE,
  }
  return cursorY + 20
end

for i = 1, PARAM_SLOTS do
  ui.config["model_param" .. i .. "_type"] = 0
  ui.config["model_param" .. i .. "_value"] = 0
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not PilotConfigApi then PilotConfigApi = loadModule("tasks/msp/api/pilot_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_model") or nil end
  if type(ui.runtime) ~= "table" then ui.runtime = newRuntime() end
  if not ui.form and Common and type(Common.createFormRuntime) == "function" then
    ui.form = Common.createFormRuntime(ui)
  end
end

local function rebuild()
  if type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
end

-- ─── The read ────────────────────────────────────────────────────────────────

local function queueRead()
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or not PilotConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return false, "msp_queue_unavailable" end

  ui.runtime.readPending = true
  ui.loading = true
  rebuild()

  queue:add({
    command = PilotConfigApi.command,
    simulatorResponse = PilotConfigApi.simulatorResponse,
    processReply = function(_, buf)
      local parsed = PilotConfigApi.parse(buf)
      if parsed then
        ui.config.model_id = parsed.model_id or 0
        -- Left nil when the board did not send the word. That is not the same as zero, and the
        -- write path depends on the difference: a zero written back to a board that HAS the
        -- field would clear both bits without anybody asking.
        ui.config.model_flags = parsed.model_flags
        for i = 1, PARAM_SLOTS do
          ui.config["model_param" .. i .. "_type"] = parsed["model_param" .. i .. "_type"] or 0
          ui.config["model_param" .. i .. "_value"] = parsed["model_param" .. i .. "_value"] or 0
        end
        ui.loaded = true
        ui.dirty = false
      end
      ui.runtime.readPending = false
      ui.loading = false
      rebuild()
    end,
    errorHandler = function()
      ui.runtime.readPending = false
      ui.loading = false
      rebuild()
    end
  })
  return true, nil
end

-- ─── The write ───────────────────────────────────────────────────────────────

local function queueWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not PilotConfigApi then return false, "msp_runtime_unavailable" end

  local payload = { model_id = ui.config.model_id, model_flags = ui.config.model_flags }
  for i = 1, PARAM_SLOTS do
    payload["model_param" .. i .. "_type"] = ui.config["model_param" .. i .. "_type"]
    payload["model_param" .. i .. "_value"] = ui.config["model_param" .. i .. "_value"]
  end

  return SavePipeline.start({
    pageId = "setup_model",
    steps = {
      {
        label = "MSP_SET_PILOT_CONFIG",
        command = PilotConfigApi.writeCommand,
        payload = PilotConfigApi.buildWritePayload(payload)
      }
    },
    -- No reboot. This writes a parameter group and the commit persists it; nothing here changes
    -- anything the flight controller has to restart to pick up.
    reboot = false,
    onSaved = function() ui.dirty = false end,
    onDone = function(result)
      if result.status ~= "done" then ui.dirty = true end
      rebuild()
    end
  })
end

-- ─── Sections ────────────────────────────────────────────────────────────────

local function slotGetterSetter(key)
  return function() return ui.config[key] end,
         function(v)
           if ui.config[key] == v then return end
           ui.config[key] = v
           ui.dirty = true
         end
end

local function buildParams(cursorY, children, x, w, i18n)
  local options = typeOptions(i18n)
  for i = 1, PARAM_SLOTS do
    local typeKey = "model_param" .. i .. "_type"
    local valueKey = "model_param" .. i .. "_value"
    local getType, setType = slotGetterSetter(typeKey)
    local getValue, setValue = slotGetterSetter(valueKey)

    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      string.format(pageText(i18n, "param_type", "Parameter %d Type"), i),
      options, getType(),
      -- The value, not the index: appendComboSelect resolves the index itself and hands the
      -- option's own value over. The first version of this page took it for an index and would
      -- have written Timer 1 wherever the pilot chose None.
      function(value) setType(value) end)

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
      string.format(pageText(i18n, "param_value", "Parameter %d Value"), i),
      { min = -32000, max = 32000, step = 1, get = getValue, set = setValue,
        enabled = function() return getType() ~= 0 end })
  end

  -- Whether the radio applies them at all. There is no MODEL_SET_PARAMS bit -- the flags word
  -- governs the name and the capacity announcement only -- so this one is the radio's decision on
  -- every firmware, and it has no version to branch on.
  cursorY = cursorY + prefSwitch(children, x, cursorY, w,
    pageText(i18n, "sync_params", "Synchronize Model Parameters"), "syncparams")
  cursorY = appendRadioWideNote(children, x, cursorY, w, i18n)

  return cursorY
end

local function flagSwitch(children, x, cursorY, w, label, bit)
  return Controls.appendRadioSwitch(children, x, cursorY, w, label,
    function() return PilotConfigApi.flagSet(ui.config.model_flags, bit) == true end,
    function(on)
      local next_ = PilotConfigApi.withFlag(ui.config.model_flags, bit, on)
      if next_ == ui.config.model_flags then return end
      ui.config.model_flags = next_
      ui.dirty = true
    end)
end

-- ONE control for the model name, and which store it writes is decided by what the board sent.
--
-- From MSP API 12.09 the craft carries the decision, and `model_name_sync` reads that bit first;
-- below it the field is not in the message at all and the radio preference is the only thing that
-- can decide. A pilot should not have to know which of those he is looking at, and above all the
-- two must never both be offered -- one of them would then be answering a question the other had
-- already settled. `model_flags` is nil exactly when the board did not report the word, which is
-- the same test the task itself branches on.
--
-- Initial fuel announcement is governed by the radio preference under Audio Events settings.
local function buildFeatures(cursorY, children, x, w, i18n)
  local boardDecides = ui.config.model_flags ~= nil

  if boardDecides then
    cursorY = cursorY + flagSwitch(children, x, cursorY, w,
      pageText(i18n, "flag_set_name", "Set Model Name on the Radio"),
      PilotConfigApi.FLAG_SET_NAME)
    return cursorY
  end

  cursorY = cursorY + prefSwitch(children, x, cursorY, w,
    pageText(i18n, "flag_set_name", "Set Model Name on the Radio"), "syncname")
  cursorY = appendRadioWideNote(children, x, cursorY, w, i18n)

  return cursorY
end

local SECTIONS = {
  { key = "params",   titleKey = "section_params",   titleFallback = "Model Parameters", build = buildParams },
  { key = "features", titleKey = "section_features", titleFallback = "Radio Features",   build = buildFeatures },
}

-- ─── Module API ──────────────────────────────────────────────────────────────

function M.getHeaderActions()
  ensureDeps()
  return { save = true, reload = true, help = true }
end

function M.wakeup(ctx)
  ensureDeps()
  loadPrefs(ctx and ctx.preferences)
  if not ui.loaded and not ui.runtime.readPending then
    queueRead()
  end
end

function M.onReload(ctx)
  ensureDeps()
  -- Both stores go back to what is stored, because that is what a reload is for: a switch touched
  -- by mistake is put back here the same way a board-side field is, and an unsaved preference edit
  -- is dropped on close anyway, so keeping one across a reload only made the two disagree.
  prefs.loaded = false
  prefs.dirty = false
  loadPrefs(ctx and ctx.preferences)
  ui.loaded = false
  queueRead()
end

-- Two destinations, and each is written only when it changed.
--
-- The radio's file goes first: it is local, it cannot fail for a reason the pilot can fix from
-- here, and doing it first means a flight controller that has gone away does not also cost him the
-- setting he just made. They are independent stores and neither is a step of the other, so there
-- is nothing to roll back if the second one fails.
function M.onSave(ctx)
  ensureDeps()

  if prefs.dirty and ctx then
    if type(ctx.preferences) == "table" then
      if type(ctx.preferences.general) ~= "table" then ctx.preferences.general = {} end
      ctx.preferences.general.syncname = prefs.syncname
      ctx.preferences.general.syncparams = prefs.syncparams
    end
    if type(ctx.savePreferences) == "function" then
      -- It reports a file it could not write by RETURNING `false, err` rather than by raising, so
      -- the pcall status on its own would call an unwritten file saved and clear the flag that is
      -- still holding the edit.
      local called, ok = pcall(ctx.savePreferences)
      if called and ok then prefs.dirty = false end
    end
  end

  -- The board is written only when something of the board's changed. A save that moved nothing
  -- but a radio preference has nothing to send; sending anyway costs an EEPROM commit, and on a
  -- craft that has gone away it fails over a setting that was stored fine.
  if ui.dirty then queueWrite() end
end

function M.build(ctx)
  ensureDeps()
  loadPrefs(ctx and ctx.preferences)
  local children = ctx.children
  local x, w = ctx.x, ctx.w
  local i18n = ctx.i18n
  ui.runtime.requestRebuild = ctx.requestRebuild
  if ui.form and type(ui.form.setRequestRebuild) == "function" then
    ui.form.setRequestRebuild(ctx.requestRebuild)
  end
  local cursorY = ctx.y

  if ui.loading and LoadingOverlay and type(LoadingOverlay.append) == "function" then
    LoadingOverlay.append(children, {
      x = x, y = ctx.y, w = w, h = ctx.h or 0,
      title = pageText(i18n, "loading_title", "Model Configuration"),
      message = pageText(i18n, "loading_message", "Reading from the flight controller"),
      bar = false,
    })
    return
  end

  for i, section in ipairs(SECTIONS) do
    if i > 1 then cursorY = cursorY + 10 end
    local key = section.key
    Controls.appendSectionHeader(children, x, cursorY, w,
      pageText(i18n, section.titleKey, section.titleFallback),
      ui.sections[key],
      ui.form and ui.form.getSectionToggleHandler(key) or nil)
    cursorY = cursorY + Controls.SECTION_H
    if ui.sections[key] then
      cursorY = section.build(cursorY, children, x, w, i18n)
    end
  end
end

function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui)
  end
  ui.loaded = false
  ui.runtime = newRuntime()
  ui.form = nil
  -- Reload from the file next time. An unsaved edit is dropped on close here exactly as the
  -- board-side fields are, so the two halves of this page behave the same way.
  prefs.loaded = false
  prefs.dirty = false
  Controls = nil
  Common = nil
  MspRuntime = nil
  SavePipeline = nil
  PilotConfigApi = nil
  LoadingOverlay = nil
  t = nil
end

return M
