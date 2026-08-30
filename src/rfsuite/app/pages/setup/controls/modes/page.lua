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
local BoxIdsApi = nil
local BoxNamesApi = nil
local ModeRangesApi = nil
local ModeRangesExtraApi = nil
local RxMapApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

local MODE_LOGIC_OPTIONS = {"OR", "AND"}
-- Rotorflight firmware limit: MAX_SUPPORTED_RC_CHANNEL_COUNT (18) - CONTROL_CHANNEL_COUNT (5) = 13 (AUX 1..13, indices 0..12)
local AUX_CHANNEL_COUNT = 13
local RANGE_MIN = 875
local RANGE_MAX = 2125
local RANGE_STEP = 5
local RANGE_SNAP_DELTA_US = 50

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  boxNames = {},
  boxIds = {},
  modeRanges = {},
  modeRangesExtra = {},
  modes = {},
  selectedModeIndex = 1,
  autoDetectSlots = {},
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
  if not BoxIdsApi then BoxIdsApi = loadModule("tasks/msp/api/boxids.lua") end
  if not BoxNamesApi then BoxNamesApi = loadModule("tasks/msp/api/boxnames.lua") end
  if not ModeRangesApi then ModeRangesApi = loadModule("tasks/msp/api/mode_ranges.lua") end
  if not ModeRangesExtraApi then ModeRangesExtraApi = loadModule("tasks/msp/api/mode_ranges_extra.lua") end
  if not RxMapApi then RxMapApi = loadModule("tasks/msp/api/rx_map.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_modes") or nil end

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

local function quantizeUs(value)
  return clamp(math.floor((value + (RANGE_STEP / 2)) / RANGE_STEP) * RANGE_STEP, RANGE_MIN, RANGE_MAX)
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

local function buildAuxOptions(i18n)
  local options = { "AUTO" }
  for i = 1, AUX_CHANNEL_COUNT do
    options[#options + 1] = "AUX " .. tostring(i)
  end
  return options
end

local function buildModesFromRaw()
  ui.modes = {}
  local idToModeIndex = {}

  local count = math.max(#ui.boxIds, #ui.boxNames)
  if count == 0 and #ui.modeRanges > 0 then
    local seen = {}
    for i = 1, #ui.modeRanges do
      local id = ui.modeRanges[i] and ui.modeRanges[i].id
      if id and id > 0 and not seen[id] then
        seen[id] = true
        ui.boxIds[#ui.boxIds + 1] = id
      end
    end
    table.sort(ui.boxIds)
    count = #ui.boxIds
  end

  for i = 1, count do
    local id = ui.boxIds[i]
    if id == nil then id = i - 1 end
    local name = ui.boxNames[i]
    if not name or name == "" then name = "Mode " .. tostring(id) end

    ui.modes[i] = {
      id = id,
      name = name,
      ranges = {}
    }
    idToModeIndex[id] = i
  end

  for slot = 1, #ui.modeRanges do
    local range = ui.modeRanges[slot]
    local extra = ui.modeRangesExtra[slot] or {id = 0, modeLogic = 0, linkedTo = 0}
    local modeIndex = idToModeIndex[range.id]

    if modeIndex and (extra.linkedTo or 0) == 0 and range.range and (range.range.start or 0) < (range.range["end"] or 0) then
      ui.modes[modeIndex].ranges[#ui.modes[modeIndex].ranges + 1] = {
        slot = slot,
        auxChannelIndex = range.auxChannelIndex or 0,
        range = {
          start = clamp(range.range.start or RANGE_MIN, RANGE_MIN, RANGE_MAX),
          ["end"] = clamp(range.range["end"] or RANGE_MAX, RANGE_MIN, RANGE_MAX)
        },
        modeLogic = extra.modeLogic or 0
      }
    end
  end

  ui.selectedModeIndex = clamp(ui.selectedModeIndex, 1, math.max(#ui.modes, 1))
end

local function removeRangeSlot(slot)
  if not slot then return end

  ui.modeRanges[slot] = {
    id = 0,
    auxChannelIndex = 0,
    range = { start = 900, ["end"] = 900 }
  }
  ui.modeRangesExtra[slot] = {
    id = 0,
    modeLogic = 0,
    linkedTo = 0
  }
  ui.autoDetectSlots[slot] = nil

  ui.dirty = true
  buildModesFromRaw()
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

local function onPressSetRange(slot, rawRange, i18n)
  if ui.autoDetectSlots[slot] then
    ui.notice = {
      title = pageText(i18n, "title", "Modes"),
      message = pageText(i18n, "msg_auto_detect_lock_first", "Auto-detect is active for this row. Toggle to lock AUX first.")
    }
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
    return
  end

  local us = getAuxPulseUs(rawRange.auxChannelIndex or 0)
  if not us then
    ui.notice = {
      title = pageText(i18n, "title", "Modes"),
      message = pageText(i18n, "msg_live_channel_unavailable", "Live channel value unavailable.")
    }
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
    return
  end

  local targetStart = quantizeUs(us - RANGE_SNAP_DELTA_US)
  local targetEnd = quantizeUs(us + RANGE_SNAP_DELTA_US)
  if targetStart > targetEnd then
    local mid = quantizeUs(us)
    targetStart = mid
    targetEnd = mid
  end

  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if ConfirmDialog and type(ConfirmDialog.show) == "function" then
    ConfirmDialog.show({
      title = pageText(i18n, "set_range_title", "Set Range"),
      message = pageText(i18n, "msg_use_current", "Use current value") .. " " .. tostring(us) .. "us?\n\n" ..
                pageText(i18n, "min_label", "Min") .. ": " .. tostring(targetStart) .. "us\n" ..
                pageText(i18n, "max_label", "Max") .. ": " .. tostring(targetEnd) .. "us",
      onConfirm = function()
        rawRange.range.start = targetStart
        rawRange.range["end"] = targetEnd
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    })
  end
end

local function addRangeToSelectedMode(i18n)
  local mode = ui.modes[ui.selectedModeIndex]
  if not mode then return end

  local freeSlot = nil
  for i = 1, #ui.modeRanges do
    local range = ui.modeRanges[i]
    if (range.id or 0) == 0 and range.range and (range.range.start or 0) >= (range.range["end"] or 0) then
      freeSlot = i
      break
    end
  end

  if not freeSlot then
    ui.notice = {
      title = pageText(i18n, "title", "Modes"),
      message = pageText(i18n, "msg_no_free_slots", "No free mode slots remain. Delete an existing range first.")
    }
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
    return
  end

  ui.modeRanges[freeSlot] = {
    id = mode.id,
    auxChannelIndex = 0,
    range = { start = 1300, ["end"] = 1700 }
  }
  ui.modeRangesExtra[freeSlot] = {
    id = mode.id,
    modeLogic = 0,
    linkedTo = 0
  }

  ui.dirty = true
  buildModesFromRaw()
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

local function appendRangeRow(children, x, y, w, rangeIndex, modeRange, i18n)
  local slot = modeRange.slot
  local rawRange = slot and ui.modeRanges[slot] or nil
  local rawExtra = slot and ui.modeRangesExtra[slot] or nil
  if not rawRange or not rawExtra or not rawRange.range then return 0 end

  local singleRowH = (Controls and Controls.ROW_H) or 64
  local labelY1 = (Controls and Controls.labelY and Controls.labelY(y, singleRowH)) or (y + math.floor((singleRowH - 21) / 2))
  local controlY1 = (Controls and Controls.controlY and Controls.controlY(y, singleRowH)) or (y + math.floor((singleRowH - 32) / 2))
  local rightPadding = 10
  local gap = 6

  -- Line 1: "Range X", Live Value, "Set" Button
  local wSet = 60
  local xSet = x + w - wSet - rightPadding
  local wLive = 120
  local xLive = xSet - gap - wLive

  -- Range Label
  children[#children + 1] = {
    type = "label",
    x = x + 10, y = labelY1,
    text = pageText(i18n, "range", "Range") .. " " .. tostring(rangeIndex),
    color = COLOR_THEME_PRIMARY1,
    font = MIDSIZE
  }

  -- Live Value Label
  local liveText = "--"
  local autoState = ui.autoDetectSlots[slot]
  if autoState then
    liveText = "AUTO..."
  else
    local us = getAuxPulseUs(rawRange.auxChannelIndex or 0)
    if us then
      local inRange = us >= (rawRange.range.start or RANGE_MIN) and us <= (rawRange.range["end"] or RANGE_MAX)
      liveText = tostring(us) .. "us"
      if inRange then liveText = liveText .. " *" end
    end
  end

  children[#children + 1] = {
    type = "label",
    x = xLive, y = labelY1,
    w = wLive,
    text = liveText,
    color = COLOR_THEME_SECONDARY1,
    align = RIGHT,
    font = SMLSIZE
  }

  -- Set button
  children[#children + 1] = {
    type = "button",
    x = xSet, y = controlY1,
    w = wSet,
    text = pageText(i18n, "set", "Set"),
    press = function()
      onPressSetRange(slot, rawRange, i18n)
    end
  }

  -- Line 2: Dropdowns, numeric fields and delete
  local wDel = 36
  local wAvailable = w - 80
  local wAux = math.floor(wAvailable * 0.28)
  local wLogic = math.floor(wAvailable * 0.18)
  local wNum = math.floor(wAvailable * 0.27)

  local xDel = x + w - wDel - rightPadding
  local xEnd = xDel - gap - wNum
  local xStart = xEnd - gap - wNum
  local xLogic = xStart - gap - wLogic
  local xAux = xLogic - gap - wAux

  local line2Y = y + singleRowH
  local controlY2 = (Controls and Controls.controlY and Controls.controlY(line2Y, singleRowH)) or (line2Y + math.floor((singleRowH - 32) / 2))

  -- AUX Choice
  local auxOptions = buildAuxOptions(i18n)

  children[#children + 1] = {
    type = "choice",
    x = xAux, y = controlY2,
    w = wAux,
    title = pageText(i18n, "mode", "Mode"),
    values = auxOptions,
    get = function()
      if ui.autoDetectSlots[slot] then return 1 end
      return clamp((rawRange.auxChannelIndex or 0) + 2, 2, #auxOptions)
    end,
    set = function(value)
      local val = tonumber(value) or 2
      if val == 1 then
        ui.autoDetectSlots[slot] = { baseline = nil }
      else
        ui.autoDetectSlots[slot] = nil
        rawRange.auxChannelIndex = clamp(val - 2, 0, AUX_CHANNEL_COUNT - 1)
      end
      ui.dirty = true
    end
  }

  -- Logic Choice (OR/AND)
  local logicValues = { "OR", "AND" }
  children[#children + 1] = {
    type = "choice",
    x = xLogic, y = controlY2,
    w = wLogic,
    title = pageText(i18n, "mode", "Mode"),
    values = logicValues,
    get = function()
      return clamp((rawExtra.modeLogic or 0) + 1, 1, 2)
    end,
    set = function(value)
      local val = tonumber(value) or 1
      rawExtra.modeLogic = clamp(val - 1, 0, 1)
      ui.dirty = true
    end
  }

  -- Start value field
  children[#children + 1] = {
    type = "numberEdit",
    x = xStart, y = controlY2,
    w = wNum,
    min = math.floor(RANGE_MIN / RANGE_STEP),
    max = math.floor(RANGE_MAX / RANGE_STEP),
    get = function()
      local current = tonumber(rawRange.range.start) or RANGE_MIN
      return math.floor(current / RANGE_STEP)
    end,
    set = function(val)
      local nextVal = (tonumber(val) or math.floor(RANGE_MIN / RANGE_STEP)) * RANGE_STEP
      rawRange.range.start = clamp(nextVal, RANGE_MIN, RANGE_MAX)
      if rawRange.range["end"] < rawRange.range.start then
        rawRange.range["end"] = rawRange.range.start
      end
      ui.dirty = true
    end,
    display = function(val)
      local shown = (tonumber(val) or math.floor(RANGE_MIN / RANGE_STEP)) * RANGE_STEP
      return tostring(shown) .. "us"
    end
  }

  -- End value field
  children[#children + 1] = {
    type = "numberEdit",
    x = xEnd, y = controlY2,
    w = wNum,
    min = math.floor(RANGE_MIN / RANGE_STEP),
    max = math.floor(RANGE_MAX / RANGE_STEP),
    get = function()
      local current = tonumber(rawRange.range["end"]) or RANGE_MAX
      return math.floor(current / RANGE_STEP)
    end,
    set = function(val)
      local nextVal = (tonumber(val) or math.floor(RANGE_MAX / RANGE_STEP)) * RANGE_STEP
      rawRange.range["end"] = clamp(nextVal, RANGE_MIN, RANGE_MAX)
      if rawRange.range.start > rawRange.range["end"] then
        rawRange.range.start = rawRange.range["end"]
      end
      ui.dirty = true
    end,
    display = function(val)
      local shown = (tonumber(val) or math.floor(RANGE_MAX / RANGE_STEP)) * RANGE_STEP
      return tostring(shown) .. "us"
    end
  }

  -- Delete button
  children[#children + 1] = {
    type = "button",
    x = xDel, y = controlY2,
    w = wDel,
    text = "X",
    press = function()
      removeRangeSlot(slot)
    end
  }

  -- Row divider
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = line2Y + singleRowH,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2, filled = true
  }

  return (singleRowH * 2) + 1
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return "Modes"
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_modes) ~= "table" then return end
  local saved = session.setup_modes
  if type(saved.boxIds) == "table" then ui.boxIds = saved.boxIds end
  if type(saved.boxNames) == "table" then ui.boxNames = saved.boxNames end
  if type(saved.modeRanges) == "table" then ui.modeRanges = saved.modeRanges end
  if type(saved.modeRangesExtra) == "table" then ui.modeRangesExtra = saved.modeRangesExtra end
  ui.selectedModeIndex = tonumber(saved.selectedModeIndex) or 1
  buildModesFromRaw()
end

local function saveToSession()
  local session = getSession()
  if not session then return end
  session.setup_modes = {
    boxIds = ui.boxIds,
    boxNames = ui.boxNames,
    modeRanges = ui.modeRanges,
    modeRangesExtra = ui.modeRangesExtra,
    selectedModeIndex = ui.selectedModeIndex
  }
end

local function startLoad(requestRebuild)
  if ui.runtime.readPending then return false end
  ui.runtime.readPending = true
  ui.loading = true
  ui.progress = 0

  local function triggerRebuild()
    local fn = requestRebuild or ui.runtime.requestRebuild
    if type(fn) == "function" then
      fn()
    end
  end

  triggerRebuild()

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    ui.runtime.readPending = false
    ui.loading = false
    return false
  end

  local function failed(reason)
    ui.runtime.readPending = false
    ui.loading = false
    ui.progress = 0
    triggerRebuild()
  end

  -- Step 1: BOXIDS
  queue:add({
    command = BoxIdsApi.command,
    simulatorResponse = BoxIdsApi.simulatorResponse,
    processReply = function(self, buf)
      local parsedObj = BoxIdsApi.parse(buf)
      if parsedObj and parsedObj.box_ids then
        ui.boxIds = parsedObj.box_ids
      end
      ui.progress = 20
      triggerRebuild()

      -- Step 2: BOXNAMES
      queue:add({
        command = BoxNamesApi.command,
        simulatorResponse = BoxNamesApi.simulatorResponse,
        processReply = function(self2, buf2)
          local parsedObj2 = BoxNamesApi.parse(buf2)
          if parsedObj2 and parsedObj2.box_names then
            ui.boxNames = parsedObj2.box_names
          end
          ui.progress = 40
          triggerRebuild()

          -- Step 3: MODE_RANGES
          queue:add({
            command = ModeRangesApi.command,
            simulatorResponse = ModeRangesApi.simulatorResponse,
            processReply = function(self3, buf3)
              local parsedObj3 = ModeRangesApi.parse(buf3)
              if parsedObj3 and parsedObj3.mode_ranges then
                ui.modeRanges = parsedObj3.mode_ranges
              end
              ui.progress = 60
              triggerRebuild()

              -- Step 4: MODE_RANGES_EXTRA
              queue:add({
                command = ModeRangesExtraApi.command,
                simulatorResponse = ModeRangesExtraApi.simulatorResponse,
                processReply = function(self4, buf4)
                  local parsedObj4 = ModeRangesExtraApi.parse(buf4)
                  if parsedObj4 and parsedObj4.mode_ranges_extra then
                    ui.modeRangesExtra = parsedObj4.mode_ranges_extra
                  end
                  ui.progress = 80
                  triggerRebuild()

                  -- Step 5: RX_MAP
                  queue:add({
                    command = RxMapApi.command,
                    simulatorResponse = RxMapApi.simulatorResponse,
                    processReply = function(self5, buf5)
                      local rxParsed = RxMapApi.parse(buf5)
                      if rxParsed then
                        local session = getSession()
                        if session then
                          session.rx = session.rx or {}
                          session.rx.map = rxParsed
                        end
                      end
                      
                      buildModesFromRaw()

                      ui.runtime.readPending = false
                      ui.loading = false
                      ui.dirty = false
                      ui.progress = 100
                      triggerRebuild()
                    end,
                    errorHandler = failed
                  })
                end,
                errorHandler = failed
              })
            end,
            errorHandler = failed
          })
        end,
            errorHandler = failed
      })
    end,
    errorHandler = failed
  })

  return true
end

local function queueModesWrite(requestRebuild, i18n, ctx)
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end

  local slot = 1
  local total = #ui.modeRanges

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
    if slot > total then
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
            ui.progress = 100
            saveToSession()
            if type(requestRebuild) == "function" then
              requestRebuild()
            end
            if ctx and type(ctx.reportSave) == "function" then
              ctx.reportSave({
                ok = true,
                title = pageText(i18n, "saved_title", "Saved"),
                message = pageText(i18n, "saved_message", "Mode configuration saved")
              })
            end
          end,
          errorHandler = function() failed("EEPROM write failed") end
        })
      else
        ui.saving = false
        ui.dirty = false
        ui.progress = 100
        saveToSession()
        if type(requestRebuild) == "function" then
          requestRebuild()
        end
        if ctx and type(ctx.reportSave) == "function" then
          ctx.reportSave({
            ok = true,
            title = pageText(i18n, "saved_title", "Saved"),
            message = pageText(i18n, "saved_message", "Mode configuration saved")
          })
        end
      end
      return
    end

    local range = ui.modeRanges[slot] or {id = 0, auxChannelIndex = 0, range = {start = 900, ["end"] = 900}}
    local extra = ui.modeRangesExtra[slot] or {id = 0, modeLogic = 0, linkedTo = 0}

    local startStep = clamp((range.range.start - 1500) / 5, -125, 125)
    local endStep = clamp((range.range["end"] - 1500) / 5, -125, 125)
    local payload = {
      slot - 1,
      clamp(range.id or 0, 0, 255),
      clamp(range.auxChannelIndex or 0, 0, AUX_CHANNEL_COUNT - 1),
      toS8Byte(startStep),
      toS8Byte(endStep),
      clamp(extra.modeLogic or 0, 0, 1),
      clamp(extra.linkedTo or 0, 0, 255)
    }

    ui.progress = math.floor((slot - 1) * 90 / total)
    if type(requestRebuild) == "function" then
      requestRebuild()
    end

    queue:add({
      command = 35, -- SET_MODE_RANGE
      payload = payload,
      isWrite = true,
      simulatorResponse = {},
      processReply = function()
        slot = slot + 1
        writeNext()
      end,
      errorHandler = function()
        failed("SET_MODE_RANGE failed at slot " .. tostring(slot))
      end
    })
  end

  writeNext()
  return true, nil
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

local lastLiveValues = {}
local lastInRangeStates = {}

local function checkLiveUpdates()
  if not ui.loaded or ui.loading or ui.saving then return end

  local selectedMode = ui.modes[ui.selectedModeIndex]
  local ranges = selectedMode and selectedMode.ranges or {}
  local needsRebuild = false

  for i = 1, #ranges do
    local range = ranges[i]
    local slot = range.slot
    local rawRange = ui.modeRanges[slot]
    if rawRange then
      local autoState = ui.autoDetectSlots[slot]
      if autoState then
        for auxIdx = 0, AUX_CHANNEL_COUNT - 1 do
          local us = getAuxPulseUs(auxIdx)
          if us then
            if not autoState.baseline then autoState.baseline = {} end
            if autoState.baseline[auxIdx] == nil then
              autoState.baseline[auxIdx] = us
            else
              local delta = math.abs(us - autoState.baseline[auxIdx])
              if delta >= 120 then
                rawRange.auxChannelIndex = auxIdx
                ui.autoDetectSlots[slot] = nil
                ui.dirty = true
                needsRebuild = true
                break
              end
            end
          end
        end
      else
        local us = getAuxPulseUs(rawRange.auxChannelIndex or 0)
        local lastUs = lastLiveValues[slot]
        local inRange = false
        if us then
          inRange = us >= (rawRange.range.start or RANGE_MIN) and us <= (rawRange.range["end"] or RANGE_MAX)
        end
        local lastInRange = lastInRangeStates[slot]

        if us ~= lastUs or inRange ~= lastInRange then
          lastLiveValues[slot] = us
          lastInRangeStates[slot] = inRange

          if not lastUs or math.abs(us - lastUs) >= 15 or inRange ~= lastInRange then
            needsRebuild = true
          end
        end
      end
    end
  end

  if needsRebuild then
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end
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

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
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

local lastCheckTime = 0
function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
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

  if ui.loading then
    local titleText = "@i18n(app.loading)@"
    local msgText = pageText(i18n, "loading", "Loading mode data...")
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
  if type(ctx.syncHeaderTitle) == "function" then
    ctx.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  -- Mode select
  local modeOptions = {}
  for i = 1, #ui.modes do
    modeOptions[i] = { value = i, label = ui.modes[i].name }
  end
  if #modeOptions == 0 then
    modeOptions[1] = { value = 1, label = pageText(i18n, "no_modes", "No modes") }
  end

  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "mode", "Mode"),
    modeOptions,
    ui.selectedModeIndex,
    function(newVal)
      ui.selectedModeIndex = newVal
      buildModesFromRaw()
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  )

  local selectedMode = ui.modes[ui.selectedModeIndex]
  local ranges = selectedMode and selectedMode.ranges or {}

  -- Action bar
  local rightPadding = 10
  local buttonW = math.floor(w * 0.24)
  local rowH = (Controls and Controls.ROW_H) or 64
  local labelY = (Controls and Controls.labelY and Controls.labelY(cursorY, rowH)) or (cursorY + math.floor((rowH - 21) / 2))
  local btnY = (Controls and Controls.controlY and Controls.controlY(cursorY, rowH)) or (cursorY + math.floor((rowH - 32) / 2))

  local activeStr = pageText(i18n, "active_ranges", "Active ranges") .. ": " .. tostring(#ranges) .. " / " .. tostring(#ui.modeRanges)
  children[#children + 1] = {
    type = "label",
    x = x + 10, y = labelY,
    text = activeStr,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  if ui.dirty then
    children[#children + 1] = {
      type = "label",
      x = x + 200, y = labelY,
      text = pageText(i18n, "unsaved_changes", "Unsaved changes"),
      color = COLOR_THEME_SECONDARY1,
      font = SMLSIZE
    }
  end

  children[#children + 1] = {
    type = "button",
    x = x + w - buttonW - rightPadding, y = btnY,
    w = buttonW,
    text = "+ Add",
    press = function()
      addRangeToSelectedMode(i18n)
    end
  }

  children[#children + 1] = {
    type = "rectangle",
    x = x, y = cursorY + rowH,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2, filled = true
  }
  cursorY = cursorY + rowH + 1

  if #ranges == 0 then
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = (Controls and Controls.labelY and Controls.labelY(cursorY, rowH)) or (cursorY + math.floor((rowH - 21) / 2)),
      text = pageText(i18n, "no_ranges", "No ranges configured for this mode."),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    return
  end

  for i = 1, #ranges do
    cursorY = cursorY + appendRangeRow(children, x, cursorY, w, i, ranges[i], i18n)
  end
end

function M.onSave(ctx)
  local ok, err = queueModesWrite(ctx and ctx.requestRebuild, ctx and ctx.i18n, ctx)
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
  local help = loadModule("app/pages/setup/controls/modes/help.lua")
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
  BoxIdsApi = nil
  BoxNamesApi = nil
  ModeRangesApi = nil
  ModeRangesExtraApi = nil
  RxMapApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

return M
