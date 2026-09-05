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
local RxMapApi = nil
local AdjustmentRangesApi = nil
local GetAdjRangeApi = nil
local GetAdjFuncsApi = nil
local SetAdjustmentRangeApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local t = nil

-- Rotorflight firmware limit: MAX_SUPPORTED_RC_CHANNEL_COUNT (18) - CONTROL_CHANNEL_COUNT (5) = 13 (AUX 1..13, indices 0..12)
local AUX_CHANNEL_COUNT = 13
local RANGE_MIN = 875
local RANGE_MAX = 2125
local RANGE_STEP = 5
local RANGE_SNAP_DELTA_US = 50
local AUTODETECT_DELTA_US = 120

local ADJUST_FUNCTIONS = {
  {id = 0, key = "fn_none", default = "None", min = 0, max = 100},
  {id = 1, key = "fn_rate_profile", default = "Rate Profile", min = 1, max = 6},
  {id = 2, key = "fn_pid_profile", default = "PID Profile", min = 1, max = 6},
  {id = 3, key = "fn_led_profile", default = "LED Profile", min = 1, max = 4},
  {id = 4, key = "fn_osd_profile", default = "OSD Profile", min = 1, max = 3},
  {id = 5, key = "fn_pitch_rate", default = "Pitch Rate", min = 0, max = 255},
  {id = 6, key = "fn_roll_rate", default = "Roll Rate", min = 0, max = 255},
  {id = 7, key = "fn_yaw_rate", default = "Yaw Rate", min = 0, max = 255},
  {id = 8, key = "fn_pitch_rc_rate", default = "Pitch RC Rate", min = 0, max = 255},
  {id = 9, key = "fn_roll_rc_rate", default = "Roll RC Rate", min = 0, max = 255},
  {id = 10, key = "fn_yaw_rc_rate", default = "Yaw RC Rate", min = 0, max = 255},
  {id = 11, key = "fn_pitch_rc_expo", default = "Pitch RC Expo", min = 0, max = 100},
  {id = 12, key = "fn_roll_rc_expo", default = "Roll RC Expo", min = 0, max = 100},
  {id = 13, key = "fn_yaw_rc_expo", default = "Yaw RC Expo", min = 0, max = 100},
  {id = 14, key = "fn_pitch_p", default = "Pitch P", min = 0, max = 250},
  {id = 15, key = "fn_pitch_i", default = "Pitch I", min = 0, max = 250},
  {id = 16, key = "fn_pitch_d", default = "Pitch D", min = 0, max = 250},
  {id = 17, key = "fn_pitch_f", default = "Pitch F", min = 0, max = 250},
  {id = 18, key = "fn_roll_p", default = "Roll P", min = 0, max = 250},
  {id = 19, key = "fn_roll_i", default = "Roll I", min = 0, max = 250},
  {id = 20, key = "fn_roll_d", default = "Roll D", min = 0, max = 250},
  {id = 21, key = "fn_roll_f", default = "Roll F", min = 0, max = 250},
  {id = 22, key = "fn_yaw_p", default = "Yaw P", min = 0, max = 250},
  {id = 23, key = "fn_yaw_i", default = "Yaw I", min = 0, max = 250},
  {id = 24, key = "fn_yaw_d", default = "Yaw D", min = 0, max = 250},
  {id = 25, key = "fn_yaw_f", default = "Yaw F", min = 0, max = 250},
  {id = 26, key = "fn_yaw_cw_stop_gain", default = "Yaw CW Stop Gain", min = 25, max = 250},
  {id = 27, key = "fn_yaw_ccw_stop_gain", default = "Yaw CCW Stop Gain", min = 25, max = 250},
  {id = 28, key = "fn_yaw_cyclic_ff", default = "Yaw Cyclic FF", min = 0, max = 250},
  {id = 29, key = "fn_yaw_collective_ff", default = "Yaw Collective FF", min = 0, max = 250},
  {id = 30, key = "fn_yaw_collective_dyn", default = "Yaw Collective Dyn", min = -125, max = 125, maxApi = {12, 0, 7}},
  {id = 31, key = "fn_yaw_collective_decay", default = "Yaw Collective Decay", min = 1, max = 250, maxApi = {12, 0, 7}},
  {id = 32, key = "fn_pitch_collective_ff", default = "Pitch Collective FF", min = 0, max = 250},
  {id = 33, key = "fn_pitch_gyro_cutoff", default = "Pitch Gyro Cutoff", min = 0, max = 250},
  {id = 34, key = "fn_roll_gyro_cutoff", default = "Roll Gyro Cutoff", min = 0, max = 250},
  {id = 35, key = "fn_yaw_gyro_cutoff", default = "Yaw Gyro Cutoff", min = 0, max = 250},
  {id = 36, key = "fn_pitch_dterm_cutoff", default = "Pitch Dterm Cutoff", min = 0, max = 250},
  {id = 37, key = "fn_roll_dterm_cutoff", default = "Roll Dterm Cutoff", min = 0, max = 250},
  {id = 38, key = "fn_yaw_dterm_cutoff", default = "Yaw Dterm Cutoff", min = 0, max = 250},
  {id = 39, key = "fn_rescue_climb_collective", default = "Rescue Climb Coll", min = 0, max = 1000},
  {id = 40, key = "fn_rescue_hover_collective", default = "Rescue Hover Coll", min = 0, max = 1000},
  {id = 41, key = "fn_rescue_hover_altitude", default = "Rescue Hover Alt", min = 0, max = 2500},
  {id = 42, key = "fn_rescue_alt_p", default = "Rescue Alt P", min = 0, max = 250},
  {id = 43, key = "fn_rescue_alt_i", default = "Rescue Alt I", min = 0, max = 250},
  {id = 44, key = "fn_rescue_alt_d", default = "Rescue Alt D", min = 0, max = 250},
  {id = 45, key = "fn_angle_level_gain", default = "Angle Level Gain", min = 0, max = 200},
  {id = 46, key = "fn_horizon_level_gain", default = "Horizon Level Gain", min = 0, max = 200},
  {id = 47, key = "fn_acro_trainer_gain", default = "Acro Trainer Gain", min = 25, max = 255},
  {id = 48, key = "fn_governor_gain", default = "Governor Gain", min = 0, max = 250},
  {id = 49, key = "fn_governor_p", default = "Governor P", min = 0, max = 250},
  {id = 50, key = "fn_governor_i", default = "Governor I", min = 0, max = 250},
  {id = 51, key = "fn_governor_d", default = "Governor D", min = 0, max = 250},
  {id = 52, key = "fn_governor_f", default = "Governor F", min = 0, max = 250},
  {id = 53, key = "fn_governor_tta", default = "Governor TTA", min = 0, max = 250},
  {id = 54, key = "fn_governor_cyclic_ff", default = "Gov Cyclic FF", min = 0, max = 250},
  {id = 55, key = "fn_governor_collective_ff", default = "Gov Collective FF", min = 0, max = 250},
  {id = 56, key = "fn_pitch_b", default = "Pitch B", min = 0, max = 250},
  {id = 57, key = "fn_roll_b", default = "Roll B", min = 0, max = 250},
  {id = 58, key = "fn_yaw_b", default = "Yaw B", min = 0, max = 250},
  {id = 59, key = "fn_pitch_o", default = "Pitch O", min = 0, max = 250},
  {id = 60, key = "fn_roll_o", default = "Roll O", min = 0, max = 250},
  {id = 61, key = "fn_cross_coupling_gain", default = "Cross Coupling Gain", min = 0, max = 250},
  {id = 62, key = "fn_cross_coupling_ratio", default = "Cross Coupling Ratio", min = 0, max = 250},
  {id = 63, key = "fn_cross_coupling_cutoff", default = "Cross Coupling Cutoff", min = 0, max = 250},
  {id = 64, key = "fn_acc_trim_pitch", default = "Acc Trim Pitch", min = -300, max = 300},
  {id = 65, key = "fn_acc_trim_roll", default = "Acc Trim Roll", min = -300, max = 300},
  {id = 66, key = "fn_yaw_inertia_precomp_gain", default = "Yaw Inertia Precomp Gain", min = 0, max = 250, minApi = {12, 0, 8}},
  {id = 67, key = "fn_yaw_inertia_precomp_cutoff", default = "Yaw Inertia Precomp Cutoff", min = 0, max = 250, minApi = {12, 0, 8}},
  {id = 68, key = "fn_pitch_setpoint_boost_gain", default = "Pitch Setpoint Boost Gain", min = 0, max = 255, minApi = {12, 0, 8}},
  {id = 69, key = "fn_roll_setpoint_boost_gain", default = "Roll Setpoint Boost Gain", min = 0, max = 255, minApi = {12, 0, 8}},
  {id = 70, key = "fn_yaw_setpoint_boost_gain", default = "Yaw Setpoint Boost Gain", min = 0, max = 255, minApi = {12, 0, 8}},
  {id = 71, key = "fn_col_setpoint_boost_gain", default = "Col Setpoint Boost Gain", min = 0, max = 255, minApi = {12, 0, 8}},
  {id = 72, key = "fn_yaw_dyn_ceiling_gain", default = "Yaw Dyn Ceiling Gain", min = 0, max = 250, minApi = {12, 0, 8}},
  {id = 73, key = "fn_yaw_dyn_deadband_gain", default = "Yaw Dyn Deadband Gain", min = 0, max = 250, minApi = {12, 0, 8}},
  {id = 74, key = "fn_yaw_dyn_deadband_filter", default = "Yaw Dyn Deadband Filter", min = 0, max = 250, minApi = {12, 0, 8}},
  {id = 75, key = "fn_yaw_precomp_cutoff", default = "Yaw Precomp Cutoff", min = 0, max = 250, minApi = {12, 0, 8}},
  {id = 76, key = "fn_gov_idle_throttle", default = "Gov Idle Throttle", min = 0, max = 250, minApi = {12, 0, 9}},
  {id = 77, key = "fn_gov_auto_throttle", default = "Gov Auto Throttle", min = 0, max = 250, minApi = {12, 0, 9}},
  {id = 78, key = "fn_gov_max_throttle", default = "Gov Max Throttle", min = 0, max = 100, minApi = {12, 0, 9}},
  {id = 79, key = "fn_gov_min_throttle", default = "Gov Min Throttle", min = 0, max = 100, minApi = {12, 0, 9}},
  {id = 80, key = "fn_gov_headspeed", default = "Gov Headspeed", min = 0, max = 10000, minApi = {12, 0, 9}},
  {id = 81, key = "fn_gov_yaw_ff", default = "Gov Yaw FF", min = 0, max = 250, minApi = {12, 0, 9}},
  {id = 82, key = "fn_battery_profile", default = "Battery Profile", min = 1, max = 6}
}

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  adjustmentRanges = {},
  selectedRangeIndex = 1,
  showFunctionNames = false,
  functionIds = {},
  slotLoaded = {},
  awaitingApiVersion = false,
  readError = false,
  dirtySlots = {},
  autoDetectEnaSlots = {},
  autoDetectAdjSlots = {},
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil
  }
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not RxMapApi then RxMapApi = loadModule("tasks/msp/api/rx_map.lua") end
  if not AdjustmentRangesApi then AdjustmentRangesApi = loadModule("tasks/msp/api/adjustment_ranges.lua") end
  if not GetAdjRangeApi then GetAdjRangeApi = loadModule("tasks/msp/api/get_adjustment_range.lua") end
  if not GetAdjFuncsApi then GetAdjFuncsApi = loadModule("tasks/msp/api/get_adjustment_function_ids.lua") end
  if not SetAdjustmentRangeApi then SetAdjustmentRangeApi = loadModule("tasks/msp/api/set_adjustment_range.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_adjustments") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil
    }
  end
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function toS8Byte(value)
  local v = clamp(math.floor(value + 0.5), -128, 127)
  if v < 0 then return v + 256 end
  return v
end

local function toS16Bytes(value)
  local v = clamp(math.floor(value + 0.5), -32768, 32767)
  if v < 0 then v = v + 65536 end
  return v % 256, math.floor(v / 256)
end

local function quantizeUs(value)
  return clamp(math.floor((value + (RANGE_STEP / 2)) / RANGE_STEP) * RANGE_STEP, RANGE_MIN, RANGE_MAX)
end

local function setUsRangeStart(rangeTable, value)
  local adjusted = quantizeUs(value)
  local currentEnd = quantizeUs((rangeTable and rangeTable["end"]) or RANGE_MAX)

  if adjusted <= currentEnd then
    rangeTable.start = adjusted
    rangeTable["end"] = currentEnd
  else
    rangeTable.start = currentEnd
    rangeTable["end"] = adjusted
  end
end

local function setUsRangeEnd(rangeTable, value)
  local adjusted = quantizeUs(value)
  local currentStart = quantizeUs((rangeTable and rangeTable.start) or RANGE_MIN)

  if adjusted >= currentStart then
    rangeTable.start = currentStart
    rangeTable["end"] = adjusted
  else
    rangeTable.start = adjusted
    rangeTable["end"] = currentStart
  end
end

local function getFunctionById(id)
  for i = 1, #ADJUST_FUNCTIONS do
    local item = ADJUST_FUNCTIONS[i]
    if item.id == id then return item end
  end
  return nil
end

local function getFunctionDisplayName(i18n, fnId)
  local fn = getFunctionById(math.floor(fnId or 0))
  if fn then
    return pageText(i18n, fn.key, fn.default)
  end
  return pageText(i18n, "function_label", "Function") .. " " .. tostring(math.floor(fnId or 0))
end

local function buildRangeSlotOptions(i18n)
  local options = {}
  for i = 1, 42 do
    local label = pageText(i18n, "range", "Range") .. " " .. tostring(i)
    if ui.showFunctionNames then
      local slotRange = ui.adjustmentRanges[i]
      local fnId = slotRange and slotRange.adjFunction or 0
      if fnId > 0 then
        label = label .. " - " .. getFunctionDisplayName(i18n, fnId)
      end
    end
    options[i] = { value = i, label = label }
  end
  return options
end

local function apiVersionIsAtLeast(required)
  local session = getSession()
  local current = session and session.apiVersion
  if not current or current == "" or tostring(current) == "0" then
    return false
  end
  return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(current, required)
end

local function apiVersionIsAtMost(required)
  local session = getSession()
  local current = session and session.apiVersion
  if not current or current == "" or tostring(current) == "0" then
    return false
  end
  local reqPlusOne = {required[1], required[2], required[3] + 1}
  return not ApiVersion.isAtLeast(current, reqPlusOne)
end

local function functionVisible(def)
  if def.minApi and not apiVersionIsAtLeast(def.minApi) then return false end
  if def.maxApi and not apiVersionIsAtMost(def.maxApi) then return false end
  return true
end

local function buildFunctionOptions(i18n)
  local entries = {}
  for i = 1, #ADJUST_FUNCTIONS do
    local def = ADJUST_FUNCTIONS[i]
    if functionVisible(def) then
      entries[#entries + 1] = {
        value = def.id,
        label = pageText(i18n, def.key, def.default)
      }
    end
  end
  table.sort(entries, function(a, b) return a.value < b.value end)
  return entries
end

local function channelRawToUs(value)
  if value == nil then return nil end
  if value >= -1200 and value <= 1200 then
    return clamp(math.floor(1500 + (value * 500 / 1024) + 0.5), RANGE_MIN, RANGE_MAX)
  end
  if value >= 700 and value <= 2300 then
    return clamp(math.floor(value + 0.5), RANGE_MIN, RANGE_MAX)
  end
  return nil
end

local function auxIndexToMember(auxIndex)
  local idx = clamp(auxIndex or 0, 0, AUX_CHANNEL_COUNT - 1)
  local session = getSession()
  local rx = session and session.rx
  local map = rx and rx.map or nil

  if map then
    if idx == 0 and map.aux1 ~= nil then return map.aux1 end
    if idx == 1 and map.aux2 ~= nil then return map.aux2 end
    if idx == 2 and map.aux3 ~= nil then return map.aux3 end
  end

  local base = 5
  if map and map.aux1 ~= nil then base = map.aux1 end
  return base + idx
end

local function getAuxPulseUs(auxIndex)
  local member = auxIndexToMember(auxIndex)
  local chName = "ch" .. tostring(member + 1)
  local getV = _G.getValue
  if type(getV) ~= "function" then return nil end
  local ok, raw = pcall(getV, chName)
  if not ok or raw == nil or type(raw) ~= "number" then return nil end
  return channelRawToUs(raw)
end

local function getAdjustmentType(adjRange)
  if (adjRange.adjFunction or 0) == 0 then return 0 end
  if (adjRange.adjStep or 0) > 0 then return 2 end
  return 1
end

local function isWithin(value, rangeTable)
  if value == nil or rangeTable == nil then return false end
  return value >= (rangeTable.start or RANGE_MIN) and value <= (rangeTable["end"] or RANGE_MAX)
end

local function calcPreview(adjRange, adjType, enaUs, adjUs)
  local result = {active = false, text = "-"}
  if adjType == 0 then return result end

  local enabled = false
  if adjRange.enaChannel == 255 then
    enabled = true
  else
    enabled = isWithin(enaUs, adjRange.enaRange)
  end
  if not enabled then return result end

  if adjType == 1 then
    if adjUs == nil then return result end

    local rangeWidth = (adjRange.adjRange1["end"] or RANGE_MAX) - (adjRange.adjRange1.start or RANGE_MIN)
    local valueWidth = (adjRange.adjMax or 0) - (adjRange.adjMin or 0)

    local value
    if rangeWidth > 0 and valueWidth > 0 then
      local offset = rangeWidth / 2
      value = (adjRange.adjMin or 0) + math.floor((((adjUs - (adjRange.adjRange1.start or RANGE_MIN)) * valueWidth) + offset) / rangeWidth)
      value = clamp(value, adjRange.adjMin or -32768, adjRange.adjMax or 32767)
    else
      value = adjRange.adjMin or 0
    end

    result.active = true
    result.text = tostring(value)
    return result
  end

  if adjType == 2 and adjUs ~= nil then
    if isWithin(adjUs, adjRange.adjRange1) then
      result.active = true
      result.text = "-" .. tostring(adjRange.adjStep or 0)
      return result
    end

    if isWithin(adjUs, adjRange.adjRange2) then
      result.active = true
      result.text = "+" .. tostring(adjRange.adjStep or 0)
      return result
    end
  end

  return result
end

local function getChannelUsForRangeSet(channelIndex, autoTable, slot, i18n)
  if autoTable and autoTable[slot] then
    ui.notice = {
      title = pageText(i18n, "title", "Adjustments"),
      message = pageText(i18n, "msg_auto_detect_lock_first", "Auto-detect is active for this row. Toggle to lock AUX first.")
    }
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
    return nil
  end

  local us = getAuxPulseUs(channelIndex or 0)
  if not us then
    ui.notice = {
      title = pageText(i18n, "title", "Adjustments"),
      message = pageText(i18n, "msg_live_channel_unavailable", "Live channel value unavailable.")
    }
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
    return nil
  end
  return us
end

local function applyRangeSetFromChannel(title, rangeTable, us, slotIndex, i18n)
  local targetStart = quantizeUs(us - RANGE_SNAP_DELTA_US)
  local targetEnd = quantizeUs(us + RANGE_SNAP_DELTA_US)
  if targetStart > targetEnd then
    local mid = quantizeUs(us)
    targetStart = mid
    targetEnd = mid
  end

  if ConfirmDialog and type(ConfirmDialog.show) == "function" then
    ConfirmDialog.show({
      title = title,
      message = pageText(i18n, "confirm_use_current", "Use current value") .. " " .. tostring(us) .. "us?\n\n" ..
                pageText(i18n, "min_label", "Min") .. ": " .. tostring(targetStart) .. "us\n" ..
                pageText(i18n, "max_label", "Max") .. ": " .. tostring(targetEnd) .. "us",
      onConfirm = function()
        rangeTable.start = targetStart
        rangeTable["end"] = targetEnd
        ui.dirtySlots[slotIndex] = true
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    })
  end
end

local function sanitizeAdjustmentRange(adjRange)
  if type(adjRange) ~= "table" then adjRange = {} end
  adjRange.adjFunction = clamp(math.floor(adjRange.adjFunction or 0), 0, 255)
  if adjRange.enaChannel ~= 255 then
    adjRange.enaChannel = clamp(math.floor(adjRange.enaChannel or 0), 0, AUX_CHANNEL_COUNT - 1)
  end
  adjRange.adjChannel = clamp(math.floor(adjRange.adjChannel or 0), 0, AUX_CHANNEL_COUNT - 1)
  adjRange.adjStep = clamp(math.floor(adjRange.adjStep or 0), 0, 255)

  if type(adjRange.enaRange) ~= "table" then adjRange.enaRange = { start = 1300, ["end"] = 1700 } end
  if type(adjRange.adjRange1) ~= "table" then adjRange.adjRange1 = { start = 1300, ["end"] = 1700 } end
  if type(adjRange.adjRange2) ~= "table" then adjRange.adjRange2 = { start = 1300, ["end"] = 1700 } end

  adjRange.enaRange.start = quantizeUs(adjRange.enaRange.start or 1300)
  adjRange.enaRange["end"] = quantizeUs(adjRange.enaRange["end"] or 1700)
  adjRange.adjRange1.start = quantizeUs(adjRange.adjRange1.start or 1300)
  adjRange.adjRange1["end"] = quantizeUs(adjRange.adjRange1["end"] or 1700)
  adjRange.adjRange2.start = quantizeUs(adjRange.adjRange2.start or 1300)
  adjRange.adjRange2["end"] = quantizeUs(adjRange.adjRange2["end"] or 1700)

  local cfg = getFunctionById(adjRange.adjFunction)
  if adjRange.adjFunction == 0 then
    adjRange.adjMin = 0
    adjRange.adjMax = 100
    adjRange.adjStep = 0
  else
    local minLimit = cfg and cfg.min or -32768
    local maxLimit = cfg and cfg.max or 32767
    adjRange.adjMin = clamp(math.floor(adjRange.adjMin or minLimit), minLimit, maxLimit)
    adjRange.adjMax = clamp(math.floor(adjRange.adjMax or maxLimit), minLimit, maxLimit)
    if adjRange.adjMin > adjRange.adjMax then adjRange.adjMax = adjRange.adjMin end
  end

  if adjRange.enaChannel == 255 then
    adjRange.enaRange.start = 1500
    adjRange.enaRange["end"] = 1500
  end

  return adjRange
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_controls_adjustments) ~= "table" then
    session.setup_controls_adjustments = {}
  end
  return session.setup_controls_adjustments
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end

  ui.selectedRangeIndex = rcConfig.selectedRangeIndex or 1
  ui.showFunctionNames = rcConfig.showFunctionNames or false

  if type(rcConfig.adjustmentRanges) == "table" and #rcConfig.adjustmentRanges > 0 then
    ui.adjustmentRanges = rcConfig.adjustmentRanges
  end
  if type(rcConfig.functionIds) == "table" then
    ui.functionIds = rcConfig.functionIds
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end

  rcConfig.selectedRangeIndex = ui.selectedRangeIndex
  rcConfig.showFunctionNames = ui.showFunctionNames
  rcConfig.adjustmentRanges = ui.adjustmentRanges
  rcConfig.functionIds = ui.functionIds
end

local function newDefaultAdjustmentRange()
  return {
    adjFunction = 0,
    enaChannel = 0,
    enaRange = { start = 1300, ["end"] = 1700 },
    adjChannel = 0,
    adjRange1 = { start = 1300, ["end"] = 1700 },
    adjRange2 = { start = 1300, ["end"] = 1700 },
    adjMin = 0,
    adjMax = 100,
    adjStep = 0
  }
end

--- Which route this firmware offers for the adjustment table.
---
--- MSP_GET_ADJUSTMENT_RANGE (156) and MSP_GET_ADJUSTMENT_FUNCTION_IDS (167) arrived together in
--- API 12.09. Below it neither exists, and MSP_ADJUSTMENT_RANGES (52) is the only read there is.
--- Every place that has to know which commands exist asks here, so the two routes are separated
--- once rather than at each call.
local PAGED_READ_API = {12, 0, 9}

local function hasPagedReads()
  return apiVersionIsAtLeast(PAGED_READ_API)
end

--- Reads one slot's record with MSP_GET_ADJUSTMENT_RANGE (156).
---
--- 156 and MSP_GET_ADJUSTMENT_FUNCTION_IDS (167) are the paged accessors for the adjustment
--- table, and they cost 14 and 42 bytes. The whole-table MSP_ADJUSTMENT_RANGES (52) costs
--- MAX_ADJUSTMENT_RANGE_COUNT * 14 = 588, while the shared telemetry response buffer the CRSF
--- path serialises into is MSP_TLM_OUTBUF_SIZE = 320 bytes and the serialiser has no bound
--- check -- so asking for it makes the flight controller write past the end of a static buffer.
--- Over USB that command is safe, because there the buffer is much larger, which is why the
--- Configurator uses it.
local function queueSlotRead(slotIndex, requestRebuild, onDone)
  local function done(ok)
    if type(onDone) == "function" then onDone(ok) end
  end

  -- The module's own precondition, stated here rather than left to the caller: below API 12.09
  -- this command does not exist and must not be sent, whoever asks.
  if not hasPagedReads() then
    done(false)
    return false
  end

  slotIndex = tonumber(slotIndex)
  if not slotIndex or slotIndex < 1 or slotIndex > 42 then
    done(false)
    return false
  end

  if not GetAdjRangeApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    done(false)
    return false
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    done(false)
    return false
  end

  queue:add({
    command = GetAdjRangeApi.command,
    payload = { slotIndex - 1 },
    isWrite = false,
    simulatorResponse = GetAdjRangeApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = GetAdjRangeApi.parse(buf)
      local record = parsed and parsed.adjustment_range
      if record then
        ui.adjustmentRanges[slotIndex] = sanitizeAdjustmentRange(record)
        ui.slotLoaded[slotIndex] = true
      end
      if type(requestRebuild) == "function" then requestRebuild() end
      done(record ~= nil)
    end,
    errorHandler = function()
      done(false)
    end
  })

  return true
end

local function startLoad(requestRebuild)
  if ui.runtime.readPending then return false end

  local rebuild = requestRebuild or ui.runtime.requestRebuild

  -- The API version decides which commands can answer the table, so nothing is asked for before
  -- it is known. An unanswered connect sequence is not an old flight controller: leave the page
  -- unloaded and let the next pass try again.
  local currentSession = getSession()
  local apiVersion = currentSession and currentSession.apiVersion
  ui.awaitingApiVersion = not apiVersion or apiVersion == "" or tostring(apiVersion) == "0"
  if ui.awaitingApiVersion then
    return false
  end

  ui.runtime.readPending = true
  ui.loading = true
  ui.progress = 0

  if type(rebuild) == "function" then
    rebuild()
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    ui.runtime.readPending = false
    ui.loading = false
    return false
  end

  ui.slotLoaded = {}
  local paged = hasPagedReads()

  -- A read that did not answer leaves whatever the page already held and says so. Replacing
  -- the table with defaults would render an I/O error as a flight controller with no
  -- adjustment configured, which is indistinguishable from the real thing.
  local function failed(reason)
    ui.runtime.readPending = false
    ui.loading = false
    ui.progress = 0
    ui.readError = true
    local rebuildFn = requestRebuild or ui.runtime.requestRebuild
    if type(rebuildFn) == "function" then
      rebuildFn()
    end
  end

  local function finishLoad()
    ui.runtime.readPending = false
    ui.loading = false
    ui.dirty = false
    ui.progress = 100
    ui.loaded = true
    ui.awaitingApiVersion = false
    ui.readError = false
    local rebuildFn = requestRebuild or ui.runtime.requestRebuild
    if type(rebuildFn) == "function" then rebuildFn() end
  end

  -- Step 2a, from API 12.09: the function of every slot in one 42-byte reply, and then the
  -- selected slot's own record. Every other slot is read when it is selected, so the whole
  -- table never has to cross this transport at all.
  local function readPaged()
    queue:add({
      command = GetAdjFuncsApi.command,
      simulatorResponse = GetAdjFuncsApi.simulatorResponse,
      processReply = function(self2, buf2)
        local parsedObj2 = GetAdjFuncsApi.parse(buf2)
        if not (parsedObj2 and parsedObj2.adjustment_function_ids) then
          failed("adjustment_function_ids")
          return
        end
        ui.functionIds = parsedObj2.adjustment_function_ids
        for i = 1, 42 do
          if not ui.adjustmentRanges[i] then
            ui.adjustmentRanges[i] = newDefaultAdjustmentRange()
          end
          ui.adjustmentRanges[i].adjFunction = tonumber(ui.functionIds[i]) or 0
        end
        ui.showFunctionNames = true
        ui.progress = 60
        if type(requestRebuild) == "function" then requestRebuild() end

        local started = queueSlotRead(ui.selectedRangeIndex, requestRebuild, function(ok)
          if ok then
            finishLoad()
          else
            failed("adjustment_range")
          end
        end)
        if not started then
          failed("adjustment_range")
        end
      end,
      errorHandler = failed
    })
  end

  -- Step 2b, below API 12.09: neither paged command exists on those firmwares, so the
  -- whole-table read is the only one there is and it is kept for them. It is the read this page
  -- used everywhere before, unchanged, and the flight controller answers it the way it always
  -- did -- which is why it is confined to the versions that offer no alternative.
  local function readWholeTable()
    queue:add({
      command = AdjustmentRangesApi.command,
      simulatorResponse = AdjustmentRangesApi.simulatorResponse,
      processReply = function(self2, buf2)
        local parsedObj2 = AdjustmentRangesApi.parse(buf2)
        if not (parsedObj2 and parsedObj2.adjustment_ranges) then
          failed("adjustment_ranges")
          return
        end
        ui.adjustmentRanges = {}
        for i = 1, 42 do
          local raw = parsedObj2.adjustment_ranges[i]
          ui.adjustmentRanges[i] = sanitizeAdjustmentRange(raw or {})
          ui.slotLoaded[i] = true
        end
        ui.progress = 60
        if type(requestRebuild) == "function" then requestRebuild() end
        finishLoad()
      end,
      errorHandler = failed
    })
  end

  -- Step 1: Read RX_MAP to know mapping of AUX1, AUX2, AUX3
  queue:add({
    command = RxMapApi.command,
    simulatorResponse = RxMapApi.simulatorResponse,
    processReply = function(self, buf)
      local rxParsed = RxMapApi.parse(buf)
      if rxParsed then
        local session = getSession()
        if session then
          session.rx = session.rx or {}
          session.rx.map = rxParsed
        end
      end
      ui.progress = 30
      if type(requestRebuild) == "function" then requestRebuild() end

      -- Step 2: the table itself, by whichever route this API version has
      if paged then
        readPaged()
      else
        readWholeTable()
      end
    end,
    errorHandler = failed
  })

  return true
end

local function queueAdjustmentsWrite(requestRebuild, i18n, ctx)
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local changedSlots = {}
  for i = 1, #ui.adjustmentRanges do
    if ui.dirtySlots[i] then
      changedSlots[#changedSlots + 1] = i
    end
  end

  if #changedSlots == 0 then
    return true
  end

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end

  local slotPos = 1
  local total = #changedSlots

  local function failed(reason)
    ui.saving = false
    ui.progress = 0
    if type(requestRebuild) == "function" then
      requestRebuild()
    end
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        ok = false,
        title = pageText(i18n, "save_error_title", "Error"),
        message = tostring(reason or pageText(i18n, "save_error_message", "Save failed"))
      })
    end
  end

  local function writeNext()
    if slotPos > total then
      -- EEPROM write
      local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
      if eepromApi then
        queue:add({
          command = eepromApi.writeCommand,
          payload = {},
          isWrite = true,
          simulatorResponse = {},
          processReply = function()
            ui.saving = false
            ui.dirty = false
            ui.dirtySlots = {}
            ui.progress = 100
            saveToSession()
            if type(requestRebuild) == "function" then
              requestRebuild()
            end
            if ctx and type(ctx.reportSave) == "function" then
              ctx.reportSave({
                ok = true,
                title = pageText(i18n, "saved_title", "Saved"),
                message = pageText(i18n, "saved_message", "Adjustment configuration saved")
              })
            end
          end,
          errorHandler = function() failed("EEPROM write failed") end
        })
      else
        ui.saving = false
        ui.dirty = false
        ui.dirtySlots = {}
        ui.progress = 100
        saveToSession()
        if type(requestRebuild) == "function" then
          requestRebuild()
        end
        if ctx and type(ctx.reportSave) == "function" then
          ctx.reportSave({
            ok = true,
            title = pageText(i18n, "saved_title", "Saved"),
            message = pageText(i18n, "saved_message", "Adjustment configuration saved")
          })
        end
      end
      return
    end

    local slotIndex = changedSlots[slotPos]
    local adjRange = sanitizeAdjustmentRange(ui.adjustmentRanges[slotIndex] or {})
    ui.adjustmentRanges[slotIndex] = adjRange

    local enaStartStep = clamp((adjRange.enaRange.start - 1500) / 5, -125, 125)
    local enaEndStep = clamp((adjRange.enaRange["end"] - 1500) / 5, -125, 125)
    local adjRange1StartStep = clamp((adjRange.adjRange1.start - 1500) / 5, -125, 125)
    local adjRange1EndStep = clamp((adjRange.adjRange1["end"] - 1500) / 5, -125, 125)
    local adjRange2StartStep = clamp((adjRange.adjRange2.start - 1500) / 5, -125, 125)
    local adjRange2EndStep = clamp((adjRange.adjRange2["end"] - 1500) / 5, -125, 125)

    local minLo, minHi = toS16Bytes(adjRange.adjMin)
    local maxLo, maxHi = toS16Bytes(adjRange.adjMax)

    local enaChannel = adjRange.enaChannel
    if enaChannel ~= 255 then
      enaChannel = clamp(math.floor(enaChannel or 0), 0, AUX_CHANNEL_COUNT - 1)
    end
    local adjChannel = clamp(math.floor(adjRange.adjChannel or 0), 0, AUX_CHANNEL_COUNT - 1)

    local payload = {
      slotIndex - 1,
      clamp(adjRange.adjFunction, 0, 255),
      enaChannel,
      toS8Byte(enaStartStep),
      toS8Byte(enaEndStep),
      adjChannel,
      toS8Byte(adjRange1StartStep),
      toS8Byte(adjRange1EndStep),
      toS8Byte(adjRange2StartStep),
      toS8Byte(adjRange2EndStep),
      minLo,
      minHi,
      maxLo,
      maxHi,
      clamp(adjRange.adjStep, 0, 255)
    }

    -- The overlay is the only thing on screen while a save runs and it draws whole percent, so a
    -- rebuild is worth a scene teardown only when the number it shows actually changes.
    local progress = math.floor((slotPos - 1) * 90 / total)
    if progress ~= ui.progress then
      ui.progress = progress
      if type(requestRebuild) == "function" then
        requestRebuild()
      end
    end

    queue:add({
      command = SetAdjustmentRangeApi.writeCommand or 53,
      payload = payload,
      isWrite = true,
      simulatorResponse = {},
      processReply = function()
        slotPos = slotPos + 1
        writeNext()
      end,
      errorHandler = function()
        failed("SET_ADJUSTMENT_RANGE failed at slot " .. tostring(slotIndex))
      end
    })
  end

  writeNext()
  return true, nil
end

local lastEnaUs = nil
local lastValUs = nil
local lastPreviewText = nil

local function checkLiveUpdates()
  if not ui.loaded or ui.loading or ui.saving then return end

  local adjRange = ui.adjustmentRanges[ui.selectedRangeIndex]
  if not adjRange then return end

  local slot = ui.selectedRangeIndex
  local needsRebuild = false

  -- 1) Auto-detect Enable Channel
  local enaAutoState = ui.autoDetectEnaSlots[slot]
  if enaAutoState then
    for auxIdx = 0, AUX_CHANNEL_COUNT - 1 do
      local us = getAuxPulseUs(auxIdx)
      if us then
        if not enaAutoState.baseline then enaAutoState.baseline = {} end
        if enaAutoState.baseline[auxIdx] == nil then
          enaAutoState.baseline[auxIdx] = us
        else
          local delta = math.abs(us - enaAutoState.baseline[auxIdx])
          if delta >= AUTODETECT_DELTA_US then
            adjRange.enaChannel = auxIdx
            ui.autoDetectEnaSlots[slot] = nil
            ui.dirtySlots[slot] = true
            ui.dirty = true
            needsRebuild = true
            break
          end
        end
      end
    end
  end

  -- 2) Auto-detect Value Channel
  local adjAutoState = ui.autoDetectAdjSlots[slot]
  if adjAutoState then
    for auxIdx = 0, AUX_CHANNEL_COUNT - 1 do
      local us = getAuxPulseUs(auxIdx)
      if us then
        if not adjAutoState.baseline then adjAutoState.baseline = {} end
        if adjAutoState.baseline[auxIdx] == nil then
          adjAutoState.baseline[auxIdx] = us
        else
          local delta = math.abs(us - adjAutoState.baseline[auxIdx])
          if delta >= AUTODETECT_DELTA_US then
            adjRange.adjChannel = auxIdx
            ui.autoDetectAdjSlots[slot] = nil
            ui.dirtySlots[slot] = true
            ui.dirty = true
            needsRebuild = true
            break
          end
        end
      end
    end
  end

  -- 3) Monitor live values
  local enaUs = nil
  if adjRange.enaChannel == 255 then
    enaUs = 1500
  else
    enaUs = getAuxPulseUs(adjRange.enaChannel or 0)
  end

  local valUs = getAuxPulseUs(adjRange.adjChannel or 0)

  local preview = calcPreview(adjRange, getAdjustmentType(adjRange), enaUs, valUs)
  local previewText = preview.text
  if preview.active then
    previewText = previewText .. "*"
  end

  if enaUs ~= lastEnaUs or valUs ~= lastValUs or previewText ~= lastPreviewText then
    local diffEna = (enaUs and lastEnaUs) and math.abs(enaUs - lastEnaUs) or 100
    local diffVal = (valUs and lastValUs) and math.abs(valUs - lastValUs) or 100
    if diffEna >= 15 or diffVal >= 15 or previewText ~= lastPreviewText then
      lastEnaUs = enaUs
      lastValUs = valUs
      lastPreviewText = previewText
      needsRebuild = true
    end
  end

  if needsRebuild then
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end
end

local function buildSessionSignature()
  local session = getSession()
  return session and session.signature or "1"
end

local function getBaseTitle()
  return "Adjustments"
end

local function ensureLoaded()
  if ui.loaded then return end

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil,
      syncHeaderTitle = nil
    }
  end
  ui.loading = false
  ui.saving = false
  ui.runtime.readPending = false

  ui.adjustmentRanges = {}
  for i = 1, 42 do
    ui.adjustmentRanges[i] = newDefaultAdjustmentRange()
  end
  ui.slotLoaded = {}
  ui.readError = false
  ui.dirtySlots = {}
  ui.autoDetectEnaSlots = {}
  ui.autoDetectAdjSlots = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  startLoad(ui.runtime.requestRebuild)
end

function M.onLoad()
  ensureDeps()
  ensureLoaded()
end

function M.onActivate()
  ensureDeps()
  ensureLoaded()
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local lastCheckTime = 0
function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    ensureLoaded()
  end

  -- The API version may arrive after the page opened, and the load cannot start without it.
  -- Retrying is confined to that case, so a read that failed for any other reason is not
  -- re-issued on every pass.
  if ui.awaitingApiVersion and not ui.runtime.readPending then
    startLoad(ui.runtime.requestRebuild)
  end

  local now = nowSeconds()
  if now - lastCheckTime >= 0.15 then
    lastCheckTime = now
    checkLiveUpdates()
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    help = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.notice and LoadingOverlay and type(LoadingOverlay.appendNotice) == "function" then
    LoadingOverlay.appendNotice(children, {
      x = x, y = y, w = w, h = h,
      title = ui.notice.title,
      message = ui.notice.message,
      press = function()
        ui.notice = nil
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    })
    return
  end

  if ui.loading or ui.saving then
    local titleText = ui.loading and "@i18n(app.loading)@" or "@i18n(app.saving)@"
    local msgText = ui.loading and pageText(i18n, "loading", "Loading adjustment ranges...")
      or pageText(i18n, "saving", "Saving adjustment ranges...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()
  local title = pageText(i18n, "title", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local activeCount = 0
  for i = 1, 42 do
    if (ui.adjustmentRanges[i] and ui.adjustmentRanges[i].adjFunction or 0) > 0 then
      activeCount = activeCount + 1
    end
  end
  local activeStr = pageText(i18n, "active_ranges", "Active ranges") .. ": " .. tostring(activeCount) .. " / 42"
  local activeColor = COLOR_THEME_PRIMARY1
  if ui.readError then
    activeStr = pageText(i18n, "read_failed", "Could not read the adjustments from the flight controller")
    activeColor = COLOR_THEME_SECONDARY1
  end

  local enaUs = nil
  local adjRange = ui.adjustmentRanges[ui.selectedRangeIndex]
  if adjRange then
    if adjRange.enaChannel == 255 then
      enaUs = 1500
    else
      enaUs = getAuxPulseUs(adjRange.enaChannel or 0)
    end
  end
  local valUs = adjRange and getAuxPulseUs(adjRange.adjChannel or 0) or nil
  local preview = adjRange and calcPreview(adjRange, getAdjustmentType(adjRange), enaUs, valUs) or {active = false, text = "-"}
  local previewText = preview.text
  if preview.active then
    previewText = previewText .. "*"
  end
  local outputStr = pageText(i18n, "current_output", "Output") .. ": " .. previewText

  -- Status line row
  children[#children + 1] = {
    type = "label",
    x = x + 10, y = cursorY + 10,
    text = activeStr,
    color = activeColor,
    font = SMLSIZE
  }

  if ui.dirty then
    children[#children + 1] = {
      type = "label",
      x = x + 160, y = cursorY + 10,
      text = pageText(i18n, "unsaved_changes", "Unsaved changes"),
      color = COLOR_THEME_SECONDARY1,
      font = SMLSIZE
    }
  end

  children[#children + 1] = {
    type = "label",
    x = x + w - 180, y = cursorY + 10,
    w = 170,
    text = outputStr,
    color = COLOR_THEME_SECONDARY1,
    align = RIGHT,
    font = SMLSIZE
  }
  cursorY = cursorY + 40
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = cursorY,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2, filled = true
  }
  cursorY = cursorY + 8

  if not adjRange then return end

  -- 1) Active Range Dropdown
  local slotOptions = buildRangeSlotOptions(i18n)
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "range", "Range"),
    slotOptions,
    ui.selectedRangeIndex,
    function(val)
      ui.selectedRangeIndex = val
      -- Only the paged route leaves a slot unread; the whole-table route brought all 42 at
      -- once. So the question is when a read is NEEDED, and the module above answers when one
      -- is POSSIBLE -- neither standing in for the other.
      if hasPagedReads() and not ui.slotLoaded[val] then
        ui.loading = true
        queueSlotRead(val, ui.runtime.requestRebuild, function(ok)
          ui.loading = false
          ui.readError = not ok
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end)
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  )

  -- Everything below is the selected slot's own record, so it is drawn only once that
  -- record has been read. Editing what a failed read left behind would write defaults to the
  -- flight controller on the next save.
  if not ui.slotLoaded[ui.selectedRangeIndex] then return end

  -- 2) Type Dropdown
  local typeOptions = {
    { label = pageText(i18n, "type_off", "OFF"), value = 0 },
    { label = pageText(i18n, "type_mapped", "MAPPED"), value = 1 },
    { label = pageText(i18n, "type_stepped", "STEPPED"), value = 2 }
  }
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "type", "Type"),
    typeOptions,
    getAdjustmentType(adjRange),
    function(val)
      local prevType = getAdjustmentType(adjRange)
      if val == 0 then
        adjRange.adjFunction = 0
        adjRange.adjStep = 0
      elseif val == 1 then
        if adjRange.adjFunction == 0 then adjRange.adjFunction = 1 end
        adjRange.adjStep = 0
      else
        if adjRange.adjFunction == 0 then adjRange.adjFunction = 1 end
        if adjRange.adjStep == 0 then adjRange.adjStep = 1 end
      end
      adjRange = sanitizeAdjustmentRange(adjRange)
      ui.adjustmentRanges[ui.selectedRangeIndex] = adjRange
      ui.dirtySlots[ui.selectedRangeIndex] = true
      ui.dirty = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  )

  -- 3) Enable Channel Row (choice + live + set)
  local rowH = (Controls and Controls.ROW_H) or 64
  local controlY_offset = (Controls and Controls.controlY and Controls.controlY(0, rowH)) or math.floor((rowH - 32) / 2)
  local labelY_offset = (Controls and Controls.labelY and Controls.labelY(0, rowH)) or math.floor((rowH - 21) / 2)

  local enaRowY = cursorY
  local rightPadding = 10
  local gap = 6
  local labelW = math.floor(w * 0.32)
  local btnW = 60
  local liveW = 90
  local choiceW = w - labelW - btnW - liveW - rightPadding - 3 * gap

  local btnX = x + w - btnW - rightPadding
  local liveX = btnX - gap - liveW
  local choiceX = liveX - gap - choiceW

  children[#children + 1] = {
    type = "label",
    x = x + 10, y = enaRowY + labelY_offset,
    w = labelW - 10,
    text = pageText(i18n, "enable_channel", "Enable Channel"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  local auxOptions = { "AUTO", "Always" }
  for i = 1, AUX_CHANNEL_COUNT do
    auxOptions[#auxOptions + 1] = "AUX " .. tostring(i)
  end

  local function getSelectedEnaIndex()
    if ui.autoDetectEnaSlots[ui.selectedRangeIndex] then return 1 end
    if adjRange.enaChannel == 255 then return 2 end
    return clamp((adjRange.enaChannel or 0) + 3, 3, #auxOptions)
  end

  children[#children + 1] = {
    type = "choice",
    x = choiceX, y = enaRowY + controlY_offset,
    w = choiceW,
    title = pageText(i18n, "enable_channel", "Enable Channel"),
    values = auxOptions,
    get = getSelectedEnaIndex,
    set = function(value)
      local val = tonumber(value) or 2
      if val == 1 then
        ui.autoDetectEnaSlots[ui.selectedRangeIndex] = { baseline = nil }
      elseif val == 2 then
        ui.autoDetectEnaSlots[ui.selectedRangeIndex] = nil
        adjRange.enaChannel = 255
        adjRange.enaRange.start = 1500
        adjRange.enaRange["end"] = 1500
      else
        ui.autoDetectEnaSlots[ui.selectedRangeIndex] = nil
        adjRange.enaChannel = clamp(val - 3, 0, AUX_CHANNEL_COUNT - 1)
      end
      ui.dirtySlots[ui.selectedRangeIndex] = true
      ui.dirty = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  }

  local liveText_ena = "--"
  if ui.autoDetectEnaSlots[ui.selectedRangeIndex] then
    liveText_ena = "AUTO..."
  elseif adjRange.enaChannel == 255 then
    liveText_ena = pageText(i18n, "channel_always", "Always")
  else
    local us = getAuxPulseUs(adjRange.enaChannel or 0)
    if us then
      liveText_ena = tostring(us) .. "us"
    end
  end

  children[#children + 1] = {
    type = "label",
    x = liveX, y = enaRowY + labelY_offset,
    w = liveW,
    text = liveText_ena,
    color = COLOR_THEME_SECONDARY1,
    align = CENTER,
    font = SMLSIZE
  }

  children[#children + 1] = {
    type = "button",
    x = btnX, y = enaRowY + controlY_offset,
    w = btnW,
    text = pageText(i18n, "set", "Set"),
    press = function()
      if adjRange.enaChannel == 255 then
        return
      end
      local us = getChannelUsForRangeSet(adjRange.enaChannel, ui.autoDetectEnaSlots, ui.selectedRangeIndex, i18n)
      if us then
        applyRangeSetFromChannel(pageText(i18n, "set_enable_range", "Set Enable Range"), adjRange.enaRange, us, ui.selectedRangeIndex, i18n)
      end
    end,
    active = function()
      return adjRange.enaChannel ~= 255 and not ui.autoDetectEnaSlots[ui.selectedRangeIndex]
    end
  }

  children[#children + 1] = {
    type = "rectangle",
    x = x, y = enaRowY + rowH,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2, filled = true
  }
  cursorY = cursorY + rowH + 1

  -- 4) Enable Range Row
  local rangeRowY = cursorY
  local inputW = 100
  local inputGap = 10
  local inputEndX = x + w - inputW - rightPadding
  local inputStartX = inputEndX - inputW - inputGap

  children[#children + 1] = {
    type = "label",
    x = x + 10, y = rangeRowY + labelY_offset,
    w = inputStartX - x - 20,
    text = pageText(i18n, "enable_range", "Enable Range"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  children[#children + 1] = {
    type = "numberEdit",
    x = inputStartX, y = rangeRowY + controlY_offset,
    w = inputW,
    min = math.floor(RANGE_MIN / RANGE_STEP),
    max = math.floor(RANGE_MAX / RANGE_STEP),
    get = function()
      return math.floor(adjRange.enaRange.start / RANGE_STEP)
    end,
    set = function(val)
      setUsRangeStart(adjRange.enaRange, val * RANGE_STEP)
      ui.dirtySlots[ui.selectedRangeIndex] = true
      ui.dirty = true
    end,
    display = function(val)
      return tostring(val * RANGE_STEP) .. "us"
    end,
    active = function()
      return adjRange.enaChannel ~= 255
    end
  }

  children[#children + 1] = {
    type = "numberEdit",
    x = inputEndX, y = rangeRowY + controlY_offset,
    w = inputW,
    min = math.floor(RANGE_MIN / RANGE_STEP),
    max = math.floor(RANGE_MAX / RANGE_STEP),
    get = function()
      return math.floor(adjRange.enaRange["end"] / RANGE_STEP)
    end,
    set = function(val)
      setUsRangeEnd(adjRange.enaRange, val * RANGE_STEP)
      ui.dirtySlots[ui.selectedRangeIndex] = true
      ui.dirty = true
    end,
    display = function(val)
      return tostring(val * RANGE_STEP) .. "us"
    end,
    active = function()
      return adjRange.enaChannel ~= 255
    end
  }

  children[#children + 1] = {
    type = "rectangle",
    x = x, y = rangeRowY + rowH,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2, filled = true
  }
  cursorY = cursorY + rowH + 1

  -- 5) Mapped/Stepped Fields
  local adjType = getAdjustmentType(adjRange)
  if adjType > 0 then
    -- Value Channel Row
    local valChRowY = cursorY
    local choiceW_val = w - labelW - liveW - rightPadding - 2 * gap
    local liveX_val = x + w - liveW - rightPadding
    local choiceX_val = liveX_val - gap - choiceW_val

    children[#children + 1] = {
      type = "label",
      x = x + 10, y = valChRowY + labelY_offset,
      w = labelW - 10,
      text = pageText(i18n, "value_channel", "Value Channel"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    local adjAuxOptions = { "AUTO" }
    for i = 1, AUX_CHANNEL_COUNT do
      adjAuxOptions[#adjAuxOptions + 1] = "AUX " .. tostring(i)
    end

    children[#children + 1] = {
      type = "choice",
      x = choiceX_val, y = valChRowY + controlY_offset,
      w = choiceW_val,
      title = pageText(i18n, "value_channel", "Value Channel"),
      values = adjAuxOptions,
      get = function()
        if ui.autoDetectAdjSlots[ui.selectedRangeIndex] then return 1 end
        return clamp((adjRange.adjChannel or 0) + 2, 2, #adjAuxOptions)
      end,
      set = function(value)
        local val = tonumber(value) or 2
        if val == 1 then
          ui.autoDetectAdjSlots[ui.selectedRangeIndex] = { baseline = nil }
        else
          ui.autoDetectAdjSlots[ui.selectedRangeIndex] = nil
          adjRange.adjChannel = clamp(val - 2, 0, AUX_CHANNEL_COUNT - 1)
        end
        ui.dirtySlots[ui.selectedRangeIndex] = true
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    }

    local adjLiveText = "--"
    if ui.autoDetectAdjSlots[ui.selectedRangeIndex] then
      adjLiveText = "AUTO..."
    else
      local us = getAuxPulseUs(adjRange.adjChannel or 0)
      if us then
        adjLiveText = tostring(us) .. "us"
      end
    end

    children[#children + 1] = {
      type = "label",
      x = liveX_val, y = valChRowY + labelY_offset,
      w = liveW,
      text = adjLiveText,
      color = COLOR_THEME_SECONDARY1,
      align = CENTER,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x, y = valChRowY + rowH,
      w = w, h = 1,
      color = COLOR_THEME_SECONDARY2, filled = true
    }
    cursorY = cursorY + rowH + 1

    -- If stepped type, show Step Size
    if adjType == 2 then
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
        pageText(i18n, "step_size", "Step Size"),
        {
          min = 0,
          max = 255,
          step = 1,
          get = function() return adjRange.adjStep or 0 end,
          set = function(val)
            adjRange.adjStep = val
            ui.dirtySlots[ui.selectedRangeIndex] = true
            ui.dirty = true
          end,
          display = function(v) return tostring(v) end
        }
      )
    end

    -- Adjust Range or Decrease Range Row
    local r1Label = (adjType == 2) and pageText(i18n, "decrease_range", "Decrease Range") or pageText(i18n, "adjust_range", "Adjust Range")
    local r1RowY = cursorY
    local btnX_r1 = x + w - btnW - rightPadding
    local r1EndX = btnX_r1 - gap - inputW
    local r1StartX = r1EndX - inputGap - inputW

    children[#children + 1] = {
      type = "label",
      x = x + 10, y = r1RowY + labelY_offset,
      w = r1StartX - x - 20,
      text = r1Label,
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "numberEdit",
      x = r1StartX, y = r1RowY + controlY_offset,
      w = inputW,
      min = math.floor(RANGE_MIN / RANGE_STEP),
      max = math.floor(RANGE_MAX / RANGE_STEP),
      get = function()
        return math.floor(adjRange.adjRange1.start / RANGE_STEP)
      end,
      set = function(val)
        setUsRangeStart(adjRange.adjRange1, val * RANGE_STEP)
        ui.dirtySlots[ui.selectedRangeIndex] = true
        ui.dirty = true
      end,
      display = function(val)
        return tostring(val * RANGE_STEP) .. "us"
      end
    }

    children[#children + 1] = {
      type = "numberEdit",
      x = r1EndX, y = r1RowY + controlY_offset,
      w = inputW,
      min = math.floor(RANGE_MIN / RANGE_STEP),
      max = math.floor(RANGE_MAX / RANGE_STEP),
      get = function()
        return math.floor(adjRange.adjRange1["end"] / RANGE_STEP)
      end,
      set = function(val)
        setUsRangeEnd(adjRange.adjRange1, val * RANGE_STEP)
        ui.dirtySlots[ui.selectedRangeIndex] = true
        ui.dirty = true
      end,
      display = function(val)
        return tostring(val * RANGE_STEP) .. "us"
      end
    }

    children[#children + 1] = {
      type = "button",
      x = btnX_r1, y = r1RowY + controlY_offset,
      w = btnW,
      text = pageText(i18n, "set", "Set"),
      press = function()
        local us = getChannelUsForRangeSet(adjRange.adjChannel, ui.autoDetectAdjSlots, ui.selectedRangeIndex, i18n)
        if us then
          applyRangeSetFromChannel(r1Label, adjRange.adjRange1, us, ui.selectedRangeIndex, i18n)
        end
      end,
      active = function()
        return not ui.autoDetectAdjSlots[ui.selectedRangeIndex]
      end
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x, y = r1RowY + rowH,
      w = w, h = 1,
      color = COLOR_THEME_SECONDARY2, filled = true
    }
    cursorY = cursorY + rowH + 1

    -- If stepped type, show Increase Range Row
    if adjType == 2 then
      local r2Label = pageText(i18n, "increase_range", "Increase Range")
      local r2RowY = cursorY

      children[#children + 1] = {
        type = "label",
        x = x + 10, y = r2RowY + labelY_offset,
        w = r1StartX - x - 20,
        text = r2Label,
        color = COLOR_THEME_PRIMARY1,
        font = SMLSIZE
      }

      children[#children + 1] = {
        type = "numberEdit",
        x = r1StartX, y = r2RowY + controlY_offset,
        w = inputW,
        min = math.floor(RANGE_MIN / RANGE_STEP),
        max = math.floor(RANGE_MAX / RANGE_STEP),
        get = function()
          return math.floor(adjRange.adjRange2.start / RANGE_STEP)
        end,
        set = function(val)
          setUsRangeStart(adjRange.adjRange2, val * RANGE_STEP)
          ui.dirtySlots[ui.selectedRangeIndex] = true
          ui.dirty = true
        end,
        display = function(val)
          return tostring(val * RANGE_STEP) .. "us"
        end
      }

      children[#children + 1] = {
        type = "numberEdit",
        x = r1EndX, y = r2RowY + controlY_offset,
        w = inputW,
        min = math.floor(RANGE_MIN / RANGE_STEP),
        max = math.floor(RANGE_MAX / RANGE_STEP),
        get = function()
          return math.floor(adjRange.adjRange2["end"] / RANGE_STEP)
        end,
        set = function(val)
          setUsRangeEnd(adjRange.adjRange2, val * RANGE_STEP)
          ui.dirtySlots[ui.selectedRangeIndex] = true
          ui.dirty = true
        end,
        display = function(val)
          return tostring(val * RANGE_STEP) .. "us"
        end
      }

      children[#children + 1] = {
        type = "button",
        x = btnX_r1, y = r2RowY + controlY_offset,
        w = btnW,
        text = pageText(i18n, "set", "Set"),
        press = function()
          local us = getChannelUsForRangeSet(adjRange.adjChannel, ui.autoDetectAdjSlots, ui.selectedRangeIndex, i18n)
          if us then
            applyRangeSetFromChannel(r2Label, adjRange.adjRange2, us, ui.selectedRangeIndex, i18n)
          end
        end,
        active = function()
          return not ui.autoDetectAdjSlots[ui.selectedRangeIndex]
        end
      }

      children[#children + 1] = {
        type = "rectangle",
        x = x, y = r2RowY + rowH,
        w = w, h = 1,
        color = COLOR_THEME_SECONDARY2, filled = true
      }
      cursorY = cursorY + rowH + 1
    end

    -- Function Dropdown
    local funcOptions = buildFunctionOptions(i18n)
    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      pageText(i18n, "function", "Function"),
      funcOptions,
      adjRange.adjFunction or 0,
      function(val)
        adjRange.adjFunction = val
        adjRange = sanitizeAdjustmentRange(adjRange)
        ui.adjustmentRanges[ui.selectedRangeIndex] = adjRange
        ui.dirtySlots[ui.selectedRangeIndex] = true
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    )

    -- Value Range Row
    local valueCfg = getFunctionById(adjRange.adjFunction)
    local valMin = valueCfg and valueCfg.min or -32768
    local valMax = valueCfg and valueCfg.max or 32767

    local vRangeRowY = cursorY

    children[#children + 1] = {
      type = "label",
      x = x + 10, y = vRangeRowY + labelY_offset,
      w = inputStartX - x - 20,
      text = pageText(i18n, "value_range", "Value Range"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "numberEdit",
      x = inputStartX, y = vRangeRowY + controlY_offset,
      w = inputW,
      min = valMin,
      max = valMax,
      get = function()
        return adjRange.adjMin or 0
      end,
      set = function(val)
        adjRange.adjMin = val
        if adjRange.adjMax < val then adjRange.adjMax = val end
        ui.dirtySlots[ui.selectedRangeIndex] = true
        ui.dirty = true
      end,
      display = function(val)
        return tostring(val)
      end
    }

    children[#children + 1] = {
      type = "numberEdit",
      x = inputEndX, y = vRangeRowY + controlY_offset,
      w = inputW,
      min = valMin,
      max = valMax,
      get = function()
        return adjRange.adjMax or 100
      end,
      set = function(val)
        adjRange.adjMax = val
        if adjRange.adjMin > val then adjRange.adjMin = val end
        ui.dirtySlots[ui.selectedRangeIndex] = true
        ui.dirty = true
      end,
      display = function(val)
        return tostring(val)
      end
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x, y = vRangeRowY + rowH,
      w = w, h = 1,
      color = COLOR_THEME_SECONDARY2, filled = true
    }
    cursorY = cursorY + rowH + 1
  end
end

function M.onSave(ctx)
  local ok, err = queueAdjustmentsWrite(ctx and ctx.requestRebuild, ctx and ctx.i18n, ctx)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        ok = false,
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or pageText(ctx and ctx.i18n, "save_error_message", "Save failed"))
      })
    end
    return false
  end
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    startLoad(ctx and ctx.requestRebuild)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/adjustments/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end


function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  RxMapApi = nil
  AdjustmentRangesApi = nil
  GetAdjRangeApi = nil
  GetAdjFuncsApi = nil
  SetAdjustmentRangeApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

return M
