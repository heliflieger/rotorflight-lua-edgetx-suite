-- Diagnostics: System Status.
--
-- Read-only view of the two packed telemetry sensors the flight controller sends from MSP API
-- 12.10: System Status (CRSF `STAT`, S.Port `5140`) and System Config (CRSF `SCFG`, S.Port `5141`).
-- Each word is shown raw and decoded field by field after the firmware's
-- src/main/telemetry/status.h, and the five fields the dedicated sensors also carry -- arm state,
-- governor state, PID, rate and battery profile -- are shown once more beside the dedicated
-- sensor's own reading, so a disagreement between the two sources is visible.
--
-- The page reads the radio's telemetry sensors and sends nothing to the flight controller. The
-- sensors are the one path both links share: on CRSF they are written by the suite's background
-- decoder, on S.Port by the radio itself. They are read here directly with getSourceValue(), not
-- through Sensors.getValue(): that one takes the five shared fields from the packed words whenever
-- the dedicated sensor is absent, so the comparison would set the word against itself. Only the
-- sensor names are taken from lib/sensors.lua, so both read the same sensors.
--
-- A moving value is not a rebuild. The value column is drawn through closures that return strings
-- formatted once per read; the page is rebuilt only when its SHAPE changes, which is whether each
-- word is being received.

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
local Sensors = nil
local t = nil

-- The firmware sends System Status every 100 ms and System Config every 500 ms by default
-- (telemetry/crsf.c, telemetry/smartport.c). Twice a second keeps a changing bit visible without
-- reading the radio on every pass.
local READ_INTERVAL_SEC = 0.5
-- A source whose sensor the model does not carry is looked for again this often: EdgeTX adds a
-- sensor while discovery is on and the first frame carrying it arrives.
local SEARCH_INTERVAL_SEC = 2.0

local ROW_H = 30

-- The seven sources, by their names in lib/sensors.lua's search lists.
local WORDS = { "system_status", "system_config" }
local SHARED = { "armflags", "governor", "pid_profile", "rate_profile", "battery_profile" }

local state = {
  i18n = nil,
  requestRebuild = nil,
  -- source -> { name = sensor name or nil, nextSearch = seconds, kind = "none" | "never" |
  -- "stale" | "live", value = number or nil }
  sources = {},
  names = nil,
  -- The value column, formatted once per read and read by the label closures.
  text = {},
  shape = "",
  builtShape = nil,
  lastReadAt = 0,
  builtThisPass = false,
  readDeferred = false,
}

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  return 0
end

-- Stands in for app/pages/settings/common.lua if it cannot be loaded, so the names below fall
-- back to English rather than failing the page.
local NO_COMMON = {
  t = function(_, _, _, fallback) return fallback end,
  pageT = function() return nil end,
}

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") or NO_COMMON end
  if not t then t = Common and Common.pageT("diagnostics_system_status") or nil end
end

local function pageText(i18n, key, fallback)
  local obj = i18n or state.i18n
  if t then return t(obj, key, fallback) end
  return fallback
end

-- Every display string, resolved once per visit. The governor names are the ones the suite
-- already uses for the governor announcements and the governor setup page.
local function loadNames(i18n)
  return {
    yes = pageText(i18n, "yes", "Yes"),
    no = pageText(i18n, "no", "No"),
    live = pageText(i18n, "receiving", "Receiving"),
    stale = pageText(i18n, "not_current", "Not current"),
    never = pageText(i18n, "not_received", "Not received"),
    none = pageText(i18n, "no_sensor", "No sensor"),
    differs = pageText(i18n, "differs_fmt", "%s (differs)"),
    -- One label per field, by the field's key in STATUS_FIELDS / CONFIG_FIELDS.
    labels = {
      armed = pageText(i18n, "armed", "Armed"),
      airborne = pageText(i18n, "airborne", "Airborne"),
      motors_running = pageText(i18n, "motors_running", "Motors running"),
      rx_link_up = pageText(i18n, "rx_link_up", "RX link up"),
      failsafe_phase = pageText(i18n, "failsafe_phase", "Failsafe phase"),
      gps_fix = pageText(i18n, "gps_fix", "GPS fix"),
      gps_healthy = pageText(i18n, "gps_healthy", "GPS healthy"),
      spooled_up = pageText(i18n, "spooled_up", "Spooled up"),
      battery_state = pageText(i18n, "battery_state", "Battery state"),
      control_saturated = pageText(i18n, "control_saturated", "Control saturated"),
      gyro_overflow = pageText(i18n, "gyro_overflow", "Gyro overflow"),
      acc_not_calibrated = pageText(i18n, "acc_not_calibrated", "ACC not calibrated"),
      override_active = pageText(i18n, "override_active", "Override active"),
      rescue_state = pageText(i18n, "rescue_state", "Rescue state"),
      blackbox_logging = pageText(i18n, "blackbox_logging", "Blackbox logging"),
      governor_state = pageText(i18n, "governor_state", "Governor state"),
      pid_profile = pageText(i18n, "pid_profile", "PID profile"),
      rate_profile = pageText(i18n, "rate_profile", "Rate profile"),
      battery_profile = pageText(i18n, "battery_profile", "Battery profile"),
      unsaved_changes = pageText(i18n, "unsaved_changes", "Unsaved changes"),
      saving = pageText(i18n, "saving", "Saving"),
      reboot_required = pageText(i18n, "reboot_required", "Reboot required"),
      beeper_on = pageText(i18n, "beeper_on", "Beeper on"),
      acc_present = pageText(i18n, "acc_present", "ACC present"),
      baro_present = pageText(i18n, "baro_present", "Baro present"),
      mag_present = pageText(i18n, "mag_present", "Mag present"),
      gps_present = pageText(i18n, "gps_present", "GPS present"),
      blackbox_full = pageText(i18n, "blackbox_full", "Blackbox full"),
      rpm_source_active = pageText(i18n, "rpm_source_active", "RPM source active"),
      governor_mode = pageText(i18n, "governor_mode", "Governor mode"),
    },
    -- failsafePhase_e (flight/failsafe.h)
    failsafe = {
      [0] = pageText(i18n, "failsafe_idle", "Idle"),
      pageText(i18n, "failsafe_rx_loss_detected", "RX loss detected"),
      pageText(i18n, "failsafe_landing", "Landing"),
      pageText(i18n, "failsafe_landed", "Landed"),
      pageText(i18n, "failsafe_rx_loss_monitoring", "RX loss monitoring"),
      pageText(i18n, "failsafe_rx_loss_recovered", "RX loss recovered"),
      pageText(i18n, "failsafe_gps_rescue", "GPS rescue"),
    },
    -- telemetryGpsFix_e (telemetry/status.h)
    gpsFix = {
      [0] = pageText(i18n, "gps_fix_none", "None"),
      pageText(i18n, "gps_fix_ok", "Fix"),
      pageText(i18n, "gps_fix_home", "Fix and home"),
    },
    -- batteryState_e (sensors/battery.h)
    battery = {
      [0] = pageText(i18n, "battery_ok", "OK"),
      pageText(i18n, "battery_warning", "Warning"),
      pageText(i18n, "battery_critical", "Critical"),
      pageText(i18n, "battery_not_present", "Not present"),
      pageText(i18n, "battery_init", "Init"),
    },
    -- rescueState_e (flight/rescue.h)
    rescue = {
      [0] = pageText(i18n, "rescue_off", "Off"),
      pageText(i18n, "rescue_pullup", "Pull-up"),
      pageText(i18n, "rescue_flip", "Flip"),
      pageText(i18n, "rescue_climb", "Climb"),
      pageText(i18n, "rescue_hover", "Hover"),
      pageText(i18n, "rescue_exit", "Exit"),
    },
    -- govState_e (flight/governor.h)
    govState = {
      [0] = Common.t(i18n, "settings_audio_events", "governor_state_off", "Off"),
      Common.t(i18n, "settings_audio_events", "governor_state_idle", "Idle"),
      Common.t(i18n, "settings_audio_events", "governor_state_spoolup", "Spool-up"),
      Common.t(i18n, "settings_audio_events", "governor_state_recovery", "Recovery"),
      Common.t(i18n, "settings_audio_events", "governor_state_active", "Active"),
      Common.t(i18n, "settings_audio_events", "governor_state_thr_off", "Throttle off"),
      Common.t(i18n, "settings_audio_events", "governor_state_lost_hs", "Lost headspeed"),
      Common.t(i18n, "settings_audio_events", "governor_state_autorot", "Autorotation"),
      Common.t(i18n, "settings_audio_events", "governor_state_bailout", "Bailout"),
      Common.t(i18n, "settings_audio_events", "governor_state_bypass", "Bypass"),
    },
    -- govMode_e (flight/governor.h)
    govMode = {
      [0] = Common.t(i18n, "setup_governor", "mode_off", "OFF"),
      Common.t(i18n, "setup_governor", "mode_limit", "LIMIT"),
      Common.t(i18n, "setup_governor", "mode_direct", "DIRECT"),
      Common.t(i18n, "setup_governor", "mode_electric", "ELECTRIC"),
      Common.t(i18n, "setup_governor", "mode_nitro", "NITRO"),
    },
  }
end

-- The field at bit `shift` of `word`, cut by `mask`: the *_SHIFT / *_MASK pairs of
-- telemetry/status.h, written here as they read there (0x7 is three bits, 0x1 one flag bit).
-- Integer operators: a float division would round the word on a radio whose numbers are single
-- precision, and a word with any bit above 24 set (System Config always has one) then
-- loses its low bits -- the PID profile among them.
local function field(word, shift, mask)
  return (word >> shift) & mask
end

local function flag(names, word, bit)
  return field(word, bit, 0x1) == 1 and names.yes or names.no
end

local function enum(table_, value)
  return table_[value] or tostring(value)
end

-- One row per field of status.h, in bit order: { key, decode }. The key names the row's value in
-- state.text and its label in loadNames().labels.
local STATUS_FIELDS = {
  { "armed", function(n, w) return flag(n, w, 0) end },
  { "airborne", function(n, w) return flag(n, w, 1) end },
  { "motors_running", function(n, w) return flag(n, w, 2) end },
  { "rx_link_up", function(n, w) return flag(n, w, 3) end },
  { "failsafe_phase", function(n, w) return enum(n.failsafe, field(w, 6, 0x7)) end },
  { "gps_fix", function(n, w) return enum(n.gpsFix, field(w, 9, 0x3)) end },
  { "gps_healthy", function(n, w) return flag(n, w, 11) end },
  { "spooled_up", function(n, w) return flag(n, w, 12) end },
  { "battery_state", function(n, w) return enum(n.battery, field(w, 14, 0x7)) end },
  { "control_saturated", function(n, w) return flag(n, w, 17) end },
  { "gyro_overflow", function(n, w) return flag(n, w, 18) end },
  { "acc_not_calibrated", function(n, w) return flag(n, w, 19) end },
  { "override_active", function(n, w) return flag(n, w, 20) end },
  { "rescue_state", function(n, w) return enum(n.rescue, field(w, 21, 0x7)) end },
  { "blackbox_logging", function(n, w) return flag(n, w, 24) end },
  { "governor_state", function(n, w) return enum(n.govState, field(w, 25, 0xF)) end },
}

local CONFIG_FIELDS = {
  { "pid_profile", function(_, w) return tostring(field(w, 0, 0x7)) end },
  { "rate_profile", function(_, w) return tostring(field(w, 3, 0x7)) end },
  { "battery_profile", function(_, w) return tostring(field(w, 6, 0x7)) end },
  { "unsaved_changes", function(n, w) return flag(n, w, 12) end },
  { "saving", function(n, w) return flag(n, w, 13) end },
  { "reboot_required", function(n, w) return flag(n, w, 14) end },
  { "beeper_on", function(n, w) return flag(n, w, 15) end },
  { "acc_present", function(n, w) return flag(n, w, 16) end },
  { "baro_present", function(n, w) return flag(n, w, 17) end },
  { "mag_present", function(n, w) return flag(n, w, 18) end },
  { "gps_present", function(n, w) return flag(n, w, 19) end },
  { "blackbox_full", function(n, w) return flag(n, w, 21) end },
  { "rpm_source_active", function(n, w) return flag(n, w, 22) end },
  { "governor_mode", function(n, w) return enum(n.govMode, field(w, 23, 0x7)) end },
}

-- The five shared fields: the word, its decode, and how the dedicated sensor's value reads as the
-- same field. ARM carries the whole arming-flags word; only its ARMED bit is the shared field.
local SHARED_FIELDS = {
  armflags = { word = "system_status", row = "armed", decode = function(n, w) return flag(n, w, 0) end,
    dedicated = function(n, v) return flag(n, v, 0) end },
  governor = { word = "system_status", row = "governor_state", decode = function(n, w) return enum(n.govState, field(w, 25, 0xF)) end,
    dedicated = function(n, v) return enum(n.govState, v) end },
  pid_profile = { word = "system_config", row = "pid_profile", decode = function(_, w) return tostring(field(w, 0, 0x7)) end,
    dedicated = function(_, v) return tostring(v) end },
  rate_profile = { word = "system_config", row = "rate_profile", decode = function(_, w) return tostring(field(w, 3, 0x7)) end,
    dedicated = function(_, v) return tostring(v) end },
  battery_profile = { word = "system_config", row = "battery_profile", decode = function(_, w) return tostring(field(w, 6, 0x7)) end,
    dedicated = function(_, v) return tostring(v) end },
}

local function sourceEntry(key)
  local entry = state.sources[key]
  if not entry then
    entry = { name = nil, nextSearch = 0, kind = "none", value = nil }
    state.sources[key] = entry
  end
  return entry
end

-- The first name on the source's search list that the model carries as a sensor.
local function findName(key)
  local paths = Sensors and Sensors.search_paths and Sensors.search_paths[key]
  local getFInfo = _G.getFieldInfo
  if type(paths) ~= "table" or type(getFInfo) ~= "function" then return nil end
  for i = 1, #paths do
    local ok, info = pcall(getFInfo, paths[i])
    if ok and type(info) == "table" then return paths[i] end
  end
  return nil
end

-- getSourceValue() answers nothing for a sensor never received since the model was loaded, and
-- its second result is false once the sensor has been silent for the radio's sensor timeout or
-- the link is down; getValue() would answer 0 for both.
local function readSource(key, now)
  local entry = sourceEntry(key)
  if not entry.name and now >= entry.nextSearch then
    entry.nextSearch = now + SEARCH_INTERVAL_SEC
    entry.name = findName(key)
  end
  entry.value = nil
  if not entry.name then
    entry.kind = "none"
    return entry
  end
  local getSrcV = _G.getSourceValue
  local ok, value, current
  if type(getSrcV) == "function" then
    ok, value, current = pcall(getSrcV, entry.name)
  else
    ok, value = pcall(_G.getValue, entry.name)
  end
  if not ok or type(value) ~= "number" then
    entry.kind = "never"
    return entry
  end
  entry.value = math.floor(value)
  entry.kind = (current == false) and "stale" or "live"
  return entry
end

local function kindText(names, entry)
  return names[entry.kind] or names.none
end

local function formatWord(names, prefix, entry, fields)
  local text = state.text
  text[prefix] = kindText(names, entry)
  text[prefix .. "_name"] = entry.name or "-"
  local word = entry.value
  if word == nil then
    text[prefix .. "_raw"] = nil
    for i = 1, #fields do text[fields[i][1]] = nil end
    return
  end
  text[prefix .. "_raw"] = string.format("0x%08X", word)
  for i = 1, #fields do
    local f = fields[i]
    text[f[1]] = f[2](names, word)
  end
end

local function formatShared(names, key)
  local text = state.text
  local spec = SHARED_FIELDS[key]
  local wordEntry = state.sources[spec.word]
  local own = state.sources[key]
  local fromWord = (wordEntry and wordEntry.value ~= nil) and spec.decode(names, wordEntry.value) or nil
  local fromSensor = (own and own.value ~= nil) and spec.dedicated(names, own.value) or nil
  text["cmp_" .. key .. "_word"] = fromWord or "-"
  if fromSensor == nil then
    text["cmp_" .. key .. "_sensor"] = own and kindText(names, own) or names.none
  elseif fromWord ~= nil and fromWord ~= fromSensor then
    text["cmp_" .. key .. "_sensor"] = string.format(names.differs, fromSensor)
  else
    text["cmp_" .. key .. "_sensor"] = fromSensor
  end
end

local function shapeOf()
  local status = state.sources.system_status
  local config = state.sources.system_config
  return ((status and status.value ~= nil) and "1" or "0") .. ((config and config.value ~= nil) and "1" or "0")
end

local function readAll(now)
  state.lastReadAt = now
  -- Loaded on the first read rather than in the build: only the read needs its name lists.
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  for i = 1, #WORDS do readSource(WORDS[i], now) end
  for i = 1, #SHARED do readSource(SHARED[i], now) end

  local names = state.names
  if names then
    formatWord(names, "status", state.sources.system_status, STATUS_FIELDS)
    formatWord(names, "config", state.sources.system_config, CONFIG_FIELDS)
    for i = 1, #SHARED do formatShared(names, SHARED[i]) end
  end

  state.shape = shapeOf()
  if state.shape ~= state.builtShape and type(state.requestRebuild) == "function" then
    state.requestRebuild()
  end
end

-- One row: a label on the left and a value on the right, the value drawn through a closure.
local function appendRow(children, x, y, w, label, key, emphasis)
  local labelW = math.floor(w * 0.5)
  local text = state.text
  children[#children + 1] = {
    type = "label", x = x, y = y + 4, w = labelW - 10,
    text = label,
    color = emphasis and COLOR_THEME_SECONDARY1 or COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "label", x = x + labelW, y = y + 4, w = w - labelW - 6,
    text = function() return text[key] or "-" end,
    color = COLOR_THEME_PRIMARY1, align = RIGHT, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "rectangle", x = x, y = y + ROW_H - 2, w = w, h = 1,
    color = COLOR_THEME_SECONDARY1, filled = true
  }
  return ROW_H
end

-- A row of three columns: the field, the packed word's reading and the dedicated sensor's
-- reading. The header row passes its column titles as strings; every other row passes the keys
-- of its two values, which are drawn through closures.
local function appendCompareRow(children, x, y, w, label, wordKey, sensorKey, header)
  local labelW = math.floor(w * 0.4)
  local colW = math.floor((w - labelW) / 2)
  local text = state.text
  local color = header and COLOR_THEME_SECONDARY1 or COLOR_THEME_PRIMARY1
  children[#children + 1] = {
    type = "label", x = x, y = y + 4, w = labelW - 10,
    text = label, color = color, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "label", x = x + labelW, y = y + 4, w = colW - 6,
    text = header and wordKey or function() return text[wordKey] or "-" end,
    color = color, align = RIGHT, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "label", x = x + labelW + colW, y = y + 4, w = colW - 6,
    text = header and sensorKey or function() return text[sensorKey] or "-" end,
    color = color, align = RIGHT, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "rectangle", x = x, y = y + ROW_H - 2, w = w, h = 1,
    color = COLOR_THEME_SECONDARY1, filled = true
  }
  return ROW_H
end

local function appendNote(children, x, y, w, message)
  children[#children + 1] = {
    type = "label", x = x, y = y + 4, w = w,
    text = message,
    color = COLOR_THEME_PRIMARY1, font = SMLSIZE
  }
  return ROW_H
end

local function appendWord(children, x, y, w, i18n, prefix, title, fields, present, labels)
  y = y + appendRow(children, x, y, w, title, prefix, true)
  y = y + appendRow(children, x, y, w, pageText(i18n, "sensor", "Sensor"), prefix .. "_name")
  if not present then return y end
  y = y + appendRow(children, x, y, w, pageText(i18n, "raw_value", "Raw value"), prefix .. "_raw")
  for i = 1, #fields do
    local f = fields[i]
    y = y + appendRow(children, x, y, w, labels[f[1]], f[1])
  end
  return y
end

function M.getHeaderActions()
  return { reload = true, save = false, help = true }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  -- Read at once, and look for every sensor again: one may have been discovered or deleted.
  for _, entry in pairs(state.sources) do
    entry.name = nil
    entry.nextSearch = 0
  end
  state.lastReadAt = 0
  return true
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild
  state.i18n = ctx.i18n
  if not state.names then state.names = loadNames(ctx.i18n) end
  state.builtShape = state.shape
  state.builtThisPass = true

  local i18n = ctx.i18n
  local children = ctx.children
  local x = ctx.x
  local y = ctx.y + 4
  local w = ctx.w

  local statusPresent = string.sub(state.shape, 1, 1) == "1"
  local configPresent = string.sub(state.shape, 2, 2) == "1"

  if not statusPresent and not configPresent then
    local message
    if state.lastReadAt == 0 then
      message = pageText(i18n, "waiting", "Reading the telemetry sensors")
    else
      message = pageText(i18n, "no_words",
        "Neither System Status nor System Config is received. Both need MSP API 12.10 or later.")
    end
    appendNote(children, x, y, w, message)
    return
  end

  y = appendWord(children, x, y, w, i18n, "status", pageText(i18n, "system_status", "System Status"),
    STATUS_FIELDS, statusPresent, state.names.labels)
  y = appendWord(children, x, y, w, i18n, "config", pageText(i18n, "system_config", "System Config"),
    CONFIG_FIELDS, configPresent, state.names.labels)

  y = y + appendCompareRow(children, x, y, w, pageText(i18n, "shared_fields", "Shared fields"),
    pageText(i18n, "column_word", "Packed"), pageText(i18n, "column_sensor", "Own sensor"), true)
  local labels = state.names.labels
  for i = 1, #SHARED do
    local key = SHARED[i]
    local label = labels[SHARED_FIELDS[key].row]
    y = y + appendCompareRow(children, x, y, w, label, "cmp_" .. key .. "_word", "cmp_" .. key .. "_sensor")
  end
end

function M.wakeup()
  -- The pass that built the page carries no read: it is moved to the next pass, and only once in
  -- a row, so a page that rebuilds on consecutive passes still reads on the second of them.
  if state.builtThisPass then
    state.builtThisPass = false
    if not state.readDeferred then
      state.readDeferred = true
      return
    end
  end
  state.readDeferred = false

  local now = nowSeconds()
  if state.lastReadAt > 0 and (now - state.lastReadAt) < READ_INTERVAL_SEC then return end
  readAll(now)
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.i18n = nil
  state.requestRebuild = nil
  state.sources = {}
  state.names = nil
  state.text = {}
  state.shape = ""
  state.builtShape = nil
  state.lastReadAt = 0
  state.builtThisPass = false
  state.readDeferred = false
  Common = nil
  Sensors = nil
  t = nil
end

return M
