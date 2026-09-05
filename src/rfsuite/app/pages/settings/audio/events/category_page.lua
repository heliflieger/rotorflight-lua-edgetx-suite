local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

-- Every page under Settings > Audio > Events is built here. The pages share one schema, one
-- preference table (`preferences.audio_events`), one save path and one set of translations;
-- what differs between them is which rows a page draws and which keys it writes. So each
-- category's page.lua names its category and nothing else, and lib/audio.lua goes on reading
-- one flat table.

-- The governor states in the order the firmware numbers them (govState_e, 0..9). lib/audio.lua
-- keeps the same order in its file map and in the preference keys it consults.
local GOVERNOR_STATES = {
  { key = "governor_state_off",      labelKey = "governor_state_off",      labelFallback = "Off" },
  { key = "governor_state_idle",     labelKey = "governor_state_idle",     labelFallback = "Idle" },
  { key = "governor_state_spoolup",  labelKey = "governor_state_spoolup",  labelFallback = "Spool-up" },
  { key = "governor_state_recovery", labelKey = "governor_state_recovery", labelFallback = "Recovery" },
  { key = "governor_state_active",   labelKey = "governor_state_active",   labelFallback = "Active" },
  { key = "governor_state_thr_off",  labelKey = "governor_state_thr_off",  labelFallback = "Throttle off" },
  { key = "governor_state_lost_hs",  labelKey = "governor_state_lost_hs",  labelFallback = "Lost headspeed" },
  { key = "governor_state_autorot",  labelKey = "governor_state_autorot",  labelFallback = "Autorotation" },
  { key = "governor_state_bailout",  labelKey = "governor_state_bailout",  labelFallback = "Bailout" },
  { key = "governor_state_bypass",   labelKey = "governor_state_bypass",   labelFallback = "Bypass" },
}

-- ─── Config schema ───────────────────────────────────────────────────────────
-- Single source of truth for all persisted audio event settings. `section` names the page
-- that draws and saves an entry: a save writes its own section's keys and leaves the rest of
-- the table as the other pages left it.

local CONFIG_SCHEMA = {
  { key = "arming_flags",      type = "bool", default = true,  section = "arming" },
  { key = "governor_state",    type = "bool", default = true,  section = "governor" },
  { key = "voltage_alert",     type = "bool", default = true,  section = "voltage" },
  { key = "pid_profile",       type = "bool", default = true,  section = "profiles" },
  { key = "rate_profile",      type = "bool", default = true,  section = "profiles" },
  { key = "esc_temperature",   type = "bool", default = false, section = "esc" },
  -- `scope = "model"` marks a value that describes the aircraft rather than the radio:
  -- the ESC's temperature limit is a property of one model's hardware. It is read and
  -- written through the per-model store whenever there is one, and falls back to the
  -- global file on a radio that has none.
  { key = "esc_threshold",     type = "number", default = 90, scope = "model", section = "esc" },
  { key = "adjustment_events", type = "bool", default = false, section = "adjustment" },
  { key = "fuel_alerts",       type = "bool", default = true,  section = "fuel" },
  { key = "fuel_callout_percent", type = "number", default = 10, section = "fuel" },
  { key = "fuel_repeat_below_zero", type = "number", default = 1, section = "fuel" },
  { key = "fuel_haptic_below_zero", type = "bool", default = false, section = "fuel" },
  { key = "battery_profile",   type = "bool", default = true,  section = "battery" },
  { key = "initial_fuel",      type = "bool", default = true,  section = "battery" },
  { key = "model_announcement",type = "bool", default = false, section = "other" },
}

-- One enable per governor state, under the `governor_state` master switch. They default to on,
-- so a preferences.ini written before they existed announces every state, as it did.
for i = 1, #GOVERNOR_STATES do
  CONFIG_SCHEMA[#CONFIG_SCHEMA + 1] = {
    key = GOVERNOR_STATES[i].key, type = "bool", default = true, section = "governor"
  }
end

-- ─── Sections ────────────────────────────────────────────────────────────────
-- One entry per page. An item with `requires` is drawn only while that switch is on: the
-- per-state rows qualify the governor master switch, and ten greyed-out rows under a switch
-- that is off would say nothing the switch does not.

local SECTIONS = {
  arming = {
    titleKey = "section_arming",
    titleFallback = "Arming Flags",
    items = {
      { key = "arming_flags", labelKey = "arming_flags", labelFallback = "Arming Flags" },
    },
  },
  governor = {
    titleKey = "section_governor",
    titleFallback = "Governor State",
    items = {
      { key = "governor_state", labelKey = "governor_state", labelFallback = "Governor State" },
      { kind = "subheader", labelKey = "section_governor_states", labelFallback = "Announced states", requires = "governor_state" },
    },
  },
  voltage = {
    titleKey = "section_voltage",
    titleFallback = "Voltage",
    items = {
      { key = "voltage_alert", labelKey = "voltage_alert", labelFallback = "Voltage" },
    },
  },
  profiles = {
    titleKey = "section_profiles",
    titleFallback = "PID/Rate Profile",
    items = {
      { key = "pid_profile",  labelKey = "pid_profile",  labelFallback = "PID Profile" },
      { key = "rate_profile", labelKey = "rate_profile", labelFallback = "Rate Profile" },
    },
  },
  esc = {
    titleKey = "section_esc",
    titleFallback = "ESC Temperature",
    items = {
      { kind = "bool", key = "esc_temperature", labelKey = "esc_temperature", labelFallback = "ESC Temperature" },
      { kind = "number", key = "esc_threshold", labelKey = "esc_threshold", labelFallback = "Threshold (°)", min = 60, max = 300, suffix = "°" },
    },
  },
  adjustment = {
    titleKey = "section_adjustment",
    titleFallback = "Adjustment Announcements",
    items = {
      { key = "adjustment_events", labelKey = "adjustment_events", labelFallback = "Adjustment Announcements" },
    },
  },
  fuel = {
    titleKey = "section_fuel",
    titleFallback = "Fuel",
    items = {
      { kind = "bool", key = "fuel_alerts", labelKey = "fuel_alerts", labelFallback = "Fuel" },
      { kind = "choice", key = "fuel_callout_percent", labelKey = "fuel_callout_percent", labelFallback = "Callout %" },
      { kind = "number", key = "fuel_repeat_below_zero", labelKey = "fuel_repeat_below_zero", labelFallback = "Repeats below 0%", min = 1, max = 10, suffix = "x" },
      { kind = "bool", key = "fuel_haptic_below_zero", labelKey = "fuel_haptic_below_zero", labelFallback = "Haptic below 0%" },
    },
  },
  battery = {
    titleKey = "section_battery",
    titleFallback = "Battery",
    items = {
      { key = "battery_profile", labelKey = "battery_profile", labelFallback = "Battery Capacity" },
      { key = "initial_fuel", labelKey = "initial_fuel", labelFallback = "Initial Fuel Announcement" },
    },
  },
  other = {
    titleKey = "section_other",
    titleFallback = "Other",
    items = {
      { key = "model_announcement", labelKey = "model_announcement", labelFallback = "Model Announcement" },
    },
  },
}

for i = 1, #GOVERNOR_STATES do
  local state = GOVERNOR_STATES[i]
  local items = SECTIONS.governor.items
  items[#items + 1] = {
    key = state.key, labelKey = state.labelKey, labelFallback = state.labelFallback, requires = "governor_state"
  }
end

local FUEL_CALLOUT_VALUES = { [0] = true, [5] = true, [10] = true, [20] = true, [25] = true, [50] = true }

-- The per-model store hangs off the session and exists only once the flight controller's
-- id has been read, so every caller here has to cope with it being absent. The session is
-- returned rather than a boolean, because every caller that asks then needs it.
local function modelStore()
  local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
  if not session or not session.mcu_id or type(session.modelPreferences) ~= "table" then
    return nil
  end
  return session
end

local function modelAudioEvents(create)
  local session = modelStore()
  if not session then return nil end
  if type(session.modelPreferences.audio_events) ~= "table" then
    if not create then return nil end
    session.modelPreferences.audio_events = {}
  end
  return session.modelPreferences.audio_events
end

-- ctx.savePreferences() writes the global file only, so a page that puts a value in the
-- per-model store has to persist that store itself -- and has to be able to say so when
-- the write fails, or it reports a save the store never got.
local function saveModelStore()
  local session = modelStore()
  if not session then return true end
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", "t")
  if type(chunk) ~= "function" then return false, "model_preferences" end
  local loaded, MP = pcall(chunk)
  if not (loaded and type(MP) == "table" and type(MP.saveByMcuId) == "function") then
    return false, "model_preferences"
  end
  return MP.saveByMcuId(session.mcu_id, session.modelPreferences)
end

local function prefBool(value, default)
  if value == nil then return default end
  return value == true or value == "true" or value == 1 or value == "1"
end

-- ─── Page factory ────────────────────────────────────────────────────────────

function M.new(sectionKey)
  local section = SECTIONS[sectionKey]
  assert(section ~= nil, "unknown audio events category: " .. tostring(sectionKey))

  local page = {}
  local Controls = nil
  local Common = nil
  local t = nil

  local ui = {
    loaded = false,
    dirty = false,
    config = {},
    runtime = {
      escThresholdEnabled = nil,
      escThresholdGet = nil,
      escThresholdSet = nil,
      fuelEnabled = nil,
      fuelCalloutGet = nil,
      fuelCalloutSet = nil,
      fuelRepeatGet = nil,
      fuelRepeatSet = nil,
      fuelHapticGet = nil,
      fuelHapticSet = nil
    }
  }
  ui.runtimeBase = nil

  -- What copyFromPrefs put into ui.config. A save reads it to tell a field the pilot changed
  -- from one that merely carries the value it was loaded with.
  local loadedConfig = {}

  for _, field in ipairs(CONFIG_SCHEMA) do
    ui.config[field.key] = field.default
  end

  local function ownsField(field)
    return field.section == sectionKey
  end

  local function ensureDeps()
    if not Common then
      Common = loadModule("app/pages/settings/common.lua")
    end
    if not Controls then
      Controls = loadModule("ui/controls.lua")
    end
    if not ui.runtimeBase then
      ui.runtimeBase = Common.createFormRuntime(ui)
      if type(ui.runtime) ~= "table" then ui.runtime = {} end
      setmetatable(ui.runtime, {__index = ui.runtimeBase})
    end
    if not t then
      -- Every category page reads the same translation block: the labels were there before
      -- the page was split, and a split is not a reason to spell them twice.
      t = Common.pageT("settings_audio_events")
    end
  end

  local function getEscThresholdEnabled()
    if ui.runtime.escThresholdEnabled then return ui.runtime.escThresholdEnabled end
    ui.runtime.escThresholdEnabled = function()
      return ui.config.esc_temperature == true
    end
    return ui.runtime.escThresholdEnabled
  end

  local function getEscThresholdGetter(minVal, maxVal)
    if ui.runtime.escThresholdGet then return ui.runtime.escThresholdGet end
    ui.runtime.escThresholdGet = function()
      local current = tonumber(ui.config.esc_threshold) or minVal
      if current < minVal then current = minVal end
      if current > maxVal then current = maxVal end
      return current
    end
    return ui.runtime.escThresholdGet
  end

  local function getEscThresholdSetter(minVal, maxVal)
    if ui.runtime.escThresholdSet then return ui.runtime.escThresholdSet end
    ui.runtime.escThresholdSet = function(val)
      local nextVal = tonumber(val) or minVal
      if nextVal < minVal then nextVal = minVal end
      if nextVal > maxVal then nextVal = maxVal end
      if ui.config.esc_threshold ~= nextVal then
        ui.config.esc_threshold = nextVal
        ui.runtime.markValueChanged()
      end
    end
    return ui.runtime.escThresholdSet
  end

  local function getFuelEnabled()
    if ui.runtime.fuelEnabled then return ui.runtime.fuelEnabled end
    ui.runtime.fuelEnabled = function()
      return ui.config.fuel_alerts == true
    end
    return ui.runtime.fuelEnabled
  end

  local function getFuelCalloutOptions(i18n)
    return {
      { value = 0, label = t(i18n, "fuel_callout_only_10", "Only at 10%") },
      { value = 5, label = t(i18n, "fuel_callout_5", "Every 5%") },
      { value = 10, label = t(i18n, "fuel_callout_10", "Every 10%") },
      { value = 20, label = t(i18n, "fuel_callout_20", "Every 20%") },
      { value = 25, label = t(i18n, "fuel_callout_25", "Every 25%") },
      { value = 50, label = t(i18n, "fuel_callout_50", "Every 50%") },
    }
  end

  local function getFuelCalloutGetter()
    if ui.runtime.fuelCalloutGet then return ui.runtime.fuelCalloutGet end
    ui.runtime.fuelCalloutGet = function()
      local value = tonumber(ui.config.fuel_callout_percent) or 10
      if not FUEL_CALLOUT_VALUES[value] then return 10 end
      return value
    end
    return ui.runtime.fuelCalloutGet
  end

  local function getFuelCalloutSetter()
    if ui.runtime.fuelCalloutSet then return ui.runtime.fuelCalloutSet end
    ui.runtime.fuelCalloutSet = function(value)
      if ui.config.fuel_alerts ~= true then return end
      local nextValue = tonumber(value) or 10
      if not FUEL_CALLOUT_VALUES[nextValue] then nextValue = 10 end
      if ui.config.fuel_callout_percent ~= nextValue then
        ui.config.fuel_callout_percent = nextValue
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.fuelCalloutSet
  end

  local function getFuelRepeatGetter(minVal, maxVal)
    if ui.runtime.fuelRepeatGet then return ui.runtime.fuelRepeatGet end
    ui.runtime.fuelRepeatGet = function()
      local current = tonumber(ui.config.fuel_repeat_below_zero) or minVal
      if current < minVal then current = minVal end
      if current > maxVal then current = maxVal end
      return current
    end
    return ui.runtime.fuelRepeatGet
  end

  local function getFuelRepeatSetter(minVal, maxVal)
    if ui.runtime.fuelRepeatSet then return ui.runtime.fuelRepeatSet end
    ui.runtime.fuelRepeatSet = function(value)
      if ui.config.fuel_alerts ~= true then return end
      local nextValue = tonumber(value) or minVal
      if nextValue < minVal then nextValue = minVal end
      if nextValue > maxVal then nextValue = maxVal end
      if ui.config.fuel_repeat_below_zero ~= nextValue then
        ui.config.fuel_repeat_below_zero = nextValue
        ui.runtime.markValueChanged()
      end
    end
    return ui.runtime.fuelRepeatSet
  end

  local function getFuelHapticGetter()
    if ui.runtime.fuelHapticGet then return ui.runtime.fuelHapticGet end
    ui.runtime.fuelHapticGet = function(nextVal)
      if nextVal ~= nil then return end
      return ui.config.fuel_alerts == true and ui.config.fuel_haptic_below_zero == true
    end
    return ui.runtime.fuelHapticGet
  end

  local function getFuelHapticSetter()
    if ui.runtime.fuelHapticSet then return ui.runtime.fuelHapticSet end
    ui.runtime.fuelHapticSet = function(nextVal)
      if ui.config.fuel_alerts ~= true then return end
      local nextBool = (nextVal == true)
      if ui.config.fuel_haptic_below_zero ~= nextBool then
        ui.config.fuel_haptic_below_zero = nextBool
        ui.runtime.markDirty()
      end
    end
    return ui.runtime.fuelHapticSet
  end

  -- Loads this page's settings from preferences using the schema
  local function copyFromPrefs(prefs)
    local audio_events = (prefs and prefs.audio_events) or {}
    local modelEvents = modelAudioEvents(false)
    for _, field in ipairs(CONFIG_SCHEMA) do
      if ownsField(field) then
        local raw = audio_events[field.key]
        if field.scope == "model" and modelEvents and modelEvents[field.key] ~= nil then
          raw = modelEvents[field.key]
        end
        if field.type == "number" then
          ui.config[field.key] = tonumber(raw) or field.default
        else
          ui.config[field.key] = prefBool(raw, field.default)
        end
      end
    end

    if ui.config.esc_threshold < 60 then ui.config.esc_threshold = 60 end
    if ui.config.esc_threshold > 300 then ui.config.esc_threshold = 300 end
    if not FUEL_CALLOUT_VALUES[ui.config.fuel_callout_percent] then ui.config.fuel_callout_percent = 10 end
    if ui.config.fuel_repeat_below_zero < 1 then ui.config.fuel_repeat_below_zero = 1 end
    if ui.config.fuel_repeat_below_zero > 10 then ui.config.fuel_repeat_below_zero = 10 end

    -- After the clamps, so that correcting an out-of-range stored value does not read as an
    -- edit the pilot made.
    for _, field in ipairs(CONFIG_SCHEMA) do
      if ownsField(field) then
        loadedConfig[field.key] = ui.config[field.key]
      end
    end
  end

  local function ensureLoaded(prefs)
    if ui.loaded then return end
    copyFromPrefs(prefs)
    ui.loaded = true
  end

  -- The threshold is edited in the model's own store while a flight controller is connected and
  -- in the radio's file otherwise, and nothing on the page says which: a number entered with a
  -- model connected reads as the radio-wide default it no longer is. So the label carries a
  -- marker exactly while the model's store is the one being written.
  --
  -- The key is spelled out here rather than taken from the schema entry, because the packager
  -- resolves a translation whose key is a literal and a computed one would reach the radio raw.
  local function modelScopeLabel(i18n, key, plain)
    if key ~= "esc_threshold" or not modelStore() then return plain end
    return t(i18n, "esc_threshold_model", "Threshold (°) [Model]")
  end

  -- ─── Module API ────────────────────────────────────────────────────────────

  function page.getHeaderActions()
    ensureDeps()
    return { save = true, help = true }
  end

  function page.onReload(ctx)
    ensureDeps()
    copyFromPrefs(ctx.preferences)
    ui.dirty = false
    return true
  end

  function page.onSave(ctx)
    ensureDeps()
    if not ctx.preferences.audio_events then ctx.preferences.audio_events = {} end

    -- Saves this page's settings using the schema. A `scope = "model"` field goes into the
    -- per-model store when there is one to hold it; with no flight controller connected it stays
    -- in the global file, which is also what every model without a store of its own reads.
    --
    -- It goes there only once the model owns that value: either the model already carries one,
    -- or the pilot just changed it here. A model that was never given a limit of its own must
    -- not be pinned to whichever one is current by a save of the radio-wide settings beside it,
    -- because from then on it would no longer follow a change to the global default.
    local modelEvents = modelAudioEvents(false)
    local modelDirty = false
    local modelScoped = false
    for _, field in ipairs(CONFIG_SCHEMA) do
      if ownsField(field) then
        local toModel = false
        if field.scope == "model" then
          modelScoped = true
          if modelEvents and modelEvents[field.key] ~= nil then
            toModel = true
          elseif loadedConfig[field.key] ~= nil and ui.config[field.key] ~= loadedConfig[field.key] then
            modelEvents = modelEvents or modelAudioEvents(true)
            toModel = modelEvents ~= nil
          end
        end
        if toModel then
          if modelEvents[field.key] ~= ui.config[field.key] then modelDirty = true end
          modelEvents[field.key] = ui.config[field.key]
        else
          ctx.preferences.audio_events[field.key] = ui.config[field.key]
        end
      end
    end

    local modelOk, modelErr = true, nil
    if modelDirty then
      modelOk, modelErr = saveModelStore()
    end

    -- Diagnostic logging for save flow
    local okLog, Log = pcall(loadModule, "lib/log.lua")
    if okLog and type(Log) == "table" and type(Log.emit) == "function" then
      local parts = {}
      for _, field in ipairs(CONFIG_SCHEMA) do
        if ownsField(field) then
          parts[#parts + 1] = tostring(field.key) .. "=" .. tostring(ui.config[field.key])
        end
      end
      pcall(Log.emit, "rfsuite", "onSave[" .. sectionKey .. "]: audio_events " .. table.concat(parts, ","), "debug")
      if modelScoped then
        -- The line above shows the value the page holds, not where it went: a `scope = "model"`
        -- field is not written to the global store while the model holds it.
        local parts2 = {}
        for _, field in ipairs(CONFIG_SCHEMA) do
          if ownsField(field) and field.scope == "model" then
            local v = modelEvents and modelEvents[field.key]
            parts2[#parts2 + 1] = tostring(field.key) .. "=" .. tostring(v == nil and "<nil>" or v)
          end
        end
        pcall(Log.emit, "rfsuite", "onSave[" .. sectionKey .. "]: model.audio_events " .. table.concat(parts2, ",")
          .. " store=" .. tostring(modelEvents ~= nil)
          .. " written=" .. tostring(modelDirty)
          .. " ok=" .. tostring(modelOk)
          .. (modelErr and (" err=" .. tostring(modelErr)) or ""), "debug")
      end
    end

    local ok, err = nil, nil
    if type(ctx.savePreferences) == "function" then
      ok, err = ctx.savePreferences()
    else
      if okLog and type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite", "onSave: ctx.savePreferences not a function", "warn")
      end
      return false
    end

    -- Both stores, because a save is only done when both were believed.
    if ok and not modelOk then
      ok, err = false, modelErr
    end

    if ok then
      ui.dirty = false
      if okLog and type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite", "onSave: savePreferences OK", "info")
      end
      return true
    else
      if okLog and type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite", "onSave: savePreferences failed: " .. tostring(err or "?"), "error")
      end
      if ctx and type(ctx.reportSave) == "function" then
        ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"), message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. tostring(err or "io") })
      end
      return false
    end
  end

  function page.build(ctx)
    ensureDeps()
    ensureLoaded(ctx.preferences)

    local children       = ctx.children
    local x, w          = ctx.x, ctx.w
    local i18n           = ctx.i18n
    ui.runtime.setRequestRebuild(ctx.requestRebuild)
    local cursorY        = ctx.y

    Controls.appendStaticSectionHeader(children, x, cursorY, w, t(i18n, section.titleKey, section.titleFallback))
    cursorY = cursorY + Controls.STATIC_SECTION_H

    for _, item in ipairs(section.items) do
      local k = item.key
      if item.requires and ui.config[item.requires] ~= true then
        -- drawn only while the switch it qualifies is on
      elseif item.kind == "subheader" then
        cursorY = cursorY + 10
        Controls.appendStaticSectionHeader(children, x, cursorY, w, t(i18n, item.labelKey, item.labelFallback))
        cursorY = cursorY + Controls.STATIC_SECTION_H
      elseif item.kind == "choice" and k == "fuel_callout_percent" then
        local labelText = t(i18n, item.labelKey, item.labelFallback)
        cursorY = cursorY + Controls.appendComboSelect(
          children, x, cursorY, w,
          labelText,
          getFuelCalloutOptions(i18n),
          getFuelCalloutGetter()(),
          getFuelCalloutSetter()
        )
      elseif item.kind == "number" and k == "fuel_repeat_below_zero" then
        local minVal = item.min or 1
        local maxVal = item.max or 10
        local labelText = t(i18n, item.labelKey, item.labelFallback)
        cursorY = cursorY + Controls.appendNumberField(
          children, x, cursorY, w,
          labelText,
          {
            enabled = getFuelEnabled(),
            min = minVal,
            max = maxVal,
            suffix = item.suffix or "",
            get = getFuelRepeatGetter(minVal, maxVal),
            set = getFuelRepeatSetter(minVal, maxVal)
          }
        )
      elseif item.kind == "number" then
        local minVal = item.min or 0
        local maxVal = item.max or 100
        local labelText = t(i18n, item.labelKey, item.labelFallback)
        labelText = modelScopeLabel(i18n, k, labelText)
        cursorY = cursorY + Controls.appendNumberField(
          children, x, cursorY, w,
          labelText,
          {
            enabled = getEscThresholdEnabled(),
            min = minVal,
            max = maxVal,
            suffix = item.suffix or "",
            get = getEscThresholdGetter(minVal, maxVal),
            set = getEscThresholdSetter(minVal, maxVal)
          }
        )
      elseif item.kind == "bool" and k == "fuel_haptic_below_zero" then
        cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
          t(i18n, item.labelKey, item.labelFallback),
          getFuelHapticGetter(),
          getFuelHapticSetter()
        )
      else
        cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
          t(i18n, item.labelKey, item.labelFallback),
          ui.runtime.getBoolGetter(k),
          ui.runtime.getBoolSetter(k)
        )
      end
    end
  end

  function page.onClose()
    if type(ui.runtime) == "table" then
      setmetatable(ui.runtime, nil)
    end
    if Common then
      Common.resetPageState(ui, {
        tablesToWipe = { "runtime" }
      })
    end
    ui.runtimeBase = nil
    Controls = nil
    Common = nil
    t = nil
  end

  return page
end

return M
