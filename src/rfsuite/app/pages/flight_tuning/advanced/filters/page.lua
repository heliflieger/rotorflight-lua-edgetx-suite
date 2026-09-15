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
local FilterConfigApi = nil
local LoadingOverlay = nil
local Sensors = nil
local ApiVersion = nil
local t = nil

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  config = {},
  runtime = newRuntime(),
  loading = false,
  progress = 0,
  baseTitle = nil
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not FilterConfigApi then FilterConfigApi = loadModule("tasks/msp/api/filter_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_advanced_filters") or nil end
  
  if type(ui.runtime) ~= "table" then
    ui.runtime = newRuntime()
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

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.filter_config) ~= "table" then
    session.filter_config = session.filterConfig or {}
  end
  session.filterConfig = session.filter_config
  return session.filter_config
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  for k, v in pairs(rcConfig) do
    ui.config[k] = v
  end
end

local function queueRcRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not FilterConfigApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = type(getSession()) == "table"
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = FilterConfigApi.command,
    simulatorResponse = FilterConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = FilterConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        local session = getSession()
        if session then
          local rcConfig = getRcConfig(session)
          for k, v in pairs(parsed) do
            rcConfig[k] = v
          end
          loadFromSession()
          ui.runtime.readPending = false
          ui.loading = false
          ui.dirty = false
          ui.progress = 100
          ui.runtime.readComplete = readValid
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      end
    end,
    errorHandler = function()
      readValid = false
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueRcWrite()
  if not FilterConfigApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local session = getSession()
  local rcConfig = getRcConfig(session)
  
  -- Update config values in session
  for k, v in pairs(ui.config) do
    rcConfig[k] = v
  end

  queue:add({
    command = FilterConfigApi.writeCommand,
    payload = FilterConfigApi.buildWritePayload(rcConfig),
    isWrite = true,
    processReply = function() 
      ui.dirty = false
      
      local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
      if eepromApi then
        queue:add({
          command = eepromApi.command,
          payload = {},
          isWrite = true,
          processReply = function()
            queueRcRead(true)
          end
        })
      else
        queueRcRead(true)
      end
    end,
    errorHandler = function() end
  })

  return true, nil
end

local function buildSessionSignature()
  return "1" -- static, global page
end

local function getBaseTitle()
  return pageText(nil, "title", "Filters")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueRcRead(false)
end

local function formatValue(val, spec)
  val = tonumber(val) or 0
  local scale = spec.scale or 1
  local mult = spec.mult or 1
  local decimals = spec.decimals or 0
  
  local displayVal = (val * mult) / scale
  local fmt = "%." .. tostring(decimals) .. "f"
  return string.format(fmt, displayVal)
end

local function isAtLeastVersion(req)
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  if not rawApiVersion or rawApiVersion == "" or tostring(rawApiVersion) == "0" then
    return true -- default true for offline/simulator
  end
  return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, req)
end

local function appendSingleFieldRow(children, x, y, w, labelText, label1, key1, spec1, customLabelW)
  local rowH = (Controls and Controls.ROW_H) or 40
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  local editW1   = math.floor(w * 0.24)
  local labelW1  = customLabelW or ((label1 and label1 ~= "") and math.floor(w * 0.24) or math.floor(w * 0.14))
  local margin   = 10
  local labelGap = 4
  
  local xEdit1  = x + w - editW1 - margin
  local xLabel1 = xEdit1 - labelW1 - 8
  local mainW   = (label1 and label1 ~= "") and (xLabel1 - x - 8) or (xEdit1 - x - 8)

  -- Left main label
  if labelText and labelText ~= "" then
    children[#children + 1] = {
      type  = "label",
      x = x, y = labelY,
      w = mainW,
      text  = labelText,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE
    }
  end

  -- Sublabel (if any)
  if label1 and label1 ~= "" then
    children[#children + 1] = {
      type  = "label",
      x = xLabel1, y = labelY,
      w = labelW1 - labelGap,
      text  = label1,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE,
      align = RIGHT
    }
  end

  local rawMin = spec1.min or 0
  local rawMax = spec1.max or 1000
  local stepSize = spec1.step or 1

  children[#children + 1] = {
    type = "numberEdit",
    x = xEdit1,
    y = cellTop,
    w = editW1,
    min = math.floor(rawMin / stepSize),
    max = math.ceil(rawMax / stepSize),
    active = function() return true end,
    get = function()
      local rVal = ui.config[key1] or rawMin
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      return math.floor(rVal / stepSize)
    end,
    set = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      ui.config[key1] = rVal
      ui.dirty = true
    end,
    display = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      return formatValue(rVal, spec1) .. spec1.suffix
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

local function appendDualFieldRow(children, x, y, w, rowLabel, label1, key1, spec1, label2, key2, spec2, customLabelW)
  local rowH = (Controls and Controls.ROW_H) or 40
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))
  
  local editW   = math.floor(w * 0.24)
  local labelW  = customLabelW or math.floor(w * 0.14)
  local gap     = 8
  local margin  = 10
  local labelGap = 4
  
  local xEdit2  = x + w - editW - margin
  local xLabel2 = xEdit2 - labelW - gap
  local xEdit1  = xLabel2 - editW - gap
  local xLabel1 = xEdit1 - labelW - gap
  local mainW   = xLabel1 - x - 8
  
  -- Left main label
  if rowLabel and rowLabel ~= "" then
    children[#children + 1] = {
      type  = "label",
      x = x, y = labelY,
      w = mainW,
      text  = rowLabel,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE
    }
  end
  
  -- Column 1
  children[#children + 1] = {
    type  = "label",
    x = xLabel1, y = labelY,
    w = labelW - labelGap,
    text  = label1,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE,
    align = RIGHT
  }
  
  local spec = spec1
  local rawMin = spec.min or 0
  local rawMax = spec.max or 1000
  local stepSize = spec.step or 1
  children[#children + 1] = {
    type = "numberEdit",
    x = xEdit1,
    y = cellTop,
    w = editW,
    min = math.floor(rawMin / stepSize),
    max = math.ceil(rawMax / stepSize),
    active = function() return true end,
    get = function()
      local rVal = ui.config[key1] or rawMin
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      return math.floor(rVal / stepSize)
    end,
    set = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      if rVal < rawMin then rVal = rawMin end
      if rVal > rawMax then rVal = rawMax end
      ui.config[key1] = rVal
      ui.dirty = true
    end,
    display = function(val)
      local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
      return formatValue(rVal, spec) .. spec.suffix
    end
  }

  -- Column 2
  if label2 and key2 and spec2 then
    children[#children + 1] = {
      type  = "label",
      x = xLabel2, y = labelY,
      w = labelW - labelGap,
      text  = label2,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE,
      align = RIGHT
    }
    
    local specB = spec2
    local rawMinB = specB.min or 0
    local rawMaxB = specB.max or 1000
    local stepSizeB = specB.step or 1
    children[#children + 1] = {
      type = "numberEdit",
      x = xEdit2,
      y = cellTop,
      w = editW,
      min = math.floor(rawMinB / stepSizeB),
      max = math.ceil(rawMaxB / stepSizeB),
      active = function() return true end,
      get = function()
        local rVal = ui.config[key2] or rawMinB
        if rVal < rawMinB then rVal = rawMinB end
        if rVal > rawMaxB then rVal = rawMaxB end
        return math.floor(rVal / stepSizeB)
      end,
      set = function(val)
        local rVal = math.floor((tonumber(val) or math.floor(rawMinB / stepSizeB)) * stepSizeB)
        if rVal < rawMinB then rVal = rawMinB end
        if rVal > rawMaxB then rVal = rawMaxB end
        ui.config[key2] = rVal
        ui.dirty = true
      end,
      display = function(val)
        local rVal = math.floor((tonumber(val) or math.floor(rawMinB / stepSizeB)) * stepSizeB)
        return formatValue(rVal, specB) .. specB.suffix
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

local function appendSingleChoiceRow(children, x, y, w, labelText, key, options)
  local rowH = (Controls and Controls.ROW_H) or 48
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  local comboW = math.floor(w * 0.24)
  local comboX = x + w - comboW - 10
  local mainW = comboX - x - 8

  -- Left label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = mainW,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  local values = {}
  for i, opt in ipairs(options) do
    values[i] = opt.label
  end

  children[#children + 1] = {
    type  = "choice",
    x = comboX, y = cellTop,
    w = comboW,
    title = labelText,
    values = values,
    get = function()
      local val = tonumber(ui.config[key]) or 0
      for idx, opt in ipairs(options) do
        if opt.value == val then return idx end
      end
      return 1
    end,
    set = function(nextIndex)
      local opt = options[nextIndex]
      if opt then
        ui.config[key] = opt.value
        ui.dirty = true
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

function M.onLoad()
  ensureDeps()
  ensureLoaded()
end

function M.onActivate()
  ensureDeps()
  ensureLoaded()
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    queueRcRead(false)
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
  
  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_message", "Reading Filter settings"),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
  end

  -- Specs
  local specHz = { scale=1, mult=1, min=0, max=4000, suffix="Hz", decimals=0 }
  local specQ  = { scale=10, mult=1, min=0, max=100, suffix="", decimals=1 }
  local specCount = { scale=1, mult=1, min=0, max=8, suffix="", decimals=0 }
  local specMinHz = { scale=1, mult=1, min=10, max=200, suffix="Hz", decimals=0 }
  local specMaxHz = { scale=1, mult=1, min=100, max=500, suffix="Hz", decimals=0 }
  local specRpmMin = { scale=1, mult=1, min=1, max=100, suffix="Hz", decimals=0 }

  local lpfOptions = {
    { value = 0, label = pageText(i18n, "tbl_none", "NONE") },
    { value = 1, label = pageText(i18n, "tbl_1st", "1ST") },
    { value = 2, label = pageText(i18n, "tbl_2nd", "2ND") }
  }

  -- 1) Lowpass 1 Filter type
  cursorY = cursorY + appendSingleChoiceRow(children, x, cursorY, w,
    pageText(i18n, "lowpass_1", "Lowpass 1") .. " " .. pageText(i18n, "filter_type", "Filter type"),
    "gyro_lpf1_type", lpfOptions
  )

  -- 2) Lowpass 1 Cutoff
  cursorY = cursorY + appendSingleFieldRow(children, x, cursorY, w,
    pageText(i18n, "lowpass_1", "Lowpass 1") .. " " .. pageText(i18n, "cutoff", "Cutoff"),
    "", "gyro_lpf1_static_hz", specHz
  )

  -- 3) Lowpass 1 dyn Min & Max Cutoff
  cursorY = cursorY + appendSingleFieldRow(children, x, cursorY, w,
    pageText(i18n, "lowpass_1_dyn", "Lowpass 1 dyn."),
    pageText(i18n, "min_cutoff", "Min cutoff"), "gyro_lpf1_dyn_min_hz", specHz
  )
  cursorY = cursorY + appendSingleFieldRow(children, x, cursorY, w,
    "",
    pageText(i18n, "max_cutoff", "Max cutoff"), "gyro_lpf1_dyn_max_hz", specHz
  )

  -- 4) Lowpass 2 Filter type
  cursorY = cursorY + appendSingleChoiceRow(children, x, cursorY, w,
    pageText(i18n, "lowpass_2", "Lowpass 2") .. " " .. pageText(i18n, "filter_type", "Filter type"),
    "gyro_lpf2_type", lpfOptions
  )

  -- 5) Lowpass 2 Cutoff
  cursorY = cursorY + appendSingleFieldRow(children, x, cursorY, w,
    pageText(i18n, "lowpass_2", "Lowpass 2") .. " " .. pageText(i18n, "cutoff", "Cutoff"),
    "", "gyro_lpf2_static_hz", specHz
  )

  -- 6) Notch 1 Center & Cutoff
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w,
    pageText(i18n, "notch_1", "Notch 1"),
    pageText(i18n, "center", "Center"), "gyro_soft_notch_hz_1", specHz,
    pageText(i18n, "cutoff", "Cutoff"), "gyro_soft_notch_cutoff_1", specHz
  )

  -- 7) Notch 2 Center & Cutoff
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w,
    pageText(i18n, "notch_2", "Notch 2"),
    pageText(i18n, "center", "Center"), "gyro_soft_notch_hz_2", specHz,
    pageText(i18n, "cutoff", "Cutoff"), "gyro_soft_notch_cutoff_2", specHz
  )

  -- 8) Dynamic Filters: Notch Count & Notch Q
  local filterLabelW = math.floor(w * 0.18)
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w,
    pageText(i18n, "dyn_notch", "Dynamic Filters"),
    pageText(i18n, "notch_c", "Notch Count"), "dyn_notch_count", specCount,
    pageText(i18n, "notch_q", "Notch Q"), "dyn_notch_q", specQ,
    filterLabelW
  )

  -- 9) Dynamic Filters: Min & Max HZ
  cursorY = cursorY + appendDualFieldRow(children, x, cursorY, w,
    "",
    pageText(i18n, "notch_min_hz", "Min"), "dyn_notch_min_hz", specMinHz,
    pageText(i18n, "notch_max_hz", "Max"), "dyn_notch_max_hz", specMaxHz,
    filterLabelW
  )

  -- 10) RPM Filter (only version >= 12.0.8)
  local showRpm = isAtLeastVersion({12, 0, 8})
  if showRpm then
    local rpmOptions = {
      { value = 0, label = pageText(i18n, "tbl_custom", "CUSTOM") },
      { value = 1, label = pageText(i18n, "tbl_low", "LOW") },
      { value = 2, label = pageText(i18n, "tbl_medium", "MEDIUM") },
      { value = 3, label = pageText(i18n, "tbl_high", "HIGH") }
    }

    cursorY = cursorY + appendSingleChoiceRow(children, x, cursorY, w,
      pageText(i18n, "rpm_filter", "RPM filter") .. " " .. pageText(i18n, "rpm_preset", "Type"),
      "rpm_preset", rpmOptions
    )

    cursorY = cursorY + appendSingleFieldRow(children, x, cursorY, w,
      pageText(i18n, "rpm_filter", "RPM filter") .. " " .. pageText(i18n, "rpm_min_hz", "Min. Frequency"),
      "", "rpm_min_hz", specRpmMin
    )
  end
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  queueRcWrite()
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    queueRcRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/flight_tuning/advanced/filters/help.lua")
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
  FilterConfigApi = nil
  LoadingOverlay = nil
  Sensors = nil
  ApiVersion = nil
  t = nil
end

return M
