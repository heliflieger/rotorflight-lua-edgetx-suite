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
local RcTuningApi = nil
local LoadingOverlay = nil
local Sensors = nil
local Profile = nil
local ApiVersion = nil
local t = nil

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    fieldSetters = {},
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
  if not RcTuningApi then RcTuningApi = loadModule("tasks/msp/api/rc_tuning.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_rates_advanced_advanced") or nil end
  
  if Common then
    if not ui.runtimeBase then
      ui.runtimeBase = Common.createProfileAwareRuntime({ profileType = "rate" })
    end
    if type(ui.runtime) ~= "table" then
      ui.runtime = newRuntime()
      setmetatable(ui.runtime, { __index = ui.runtimeBase })
    end
  end
end

local function pageText(i18n, key)
  if t then
    local translated = t(i18n, key)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return key
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.rc_tuning) ~= "table" then
    session.rc_tuning = session.rcTuning or {}
  end
  session.rcTuning = session.rc_tuning
  return session.rc_tuning
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
  if not RcTuningApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
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
    command = RcTuningApi.command,
    simulatorResponse = RcTuningApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = RcTuningApi.parse(buf)
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
  if not RcTuningApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
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
    command = RcTuningApi.writeCommand,
    payload = RcTuningApi.buildWritePayload(rcConfig),
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

local function getLiveProfile()
  return Profile and Profile.getActiveRateProfile(1) or 1
end

local function getBaseTitle()
  return pageText(nil, "title", "Dynamics")
end

local function buildSessionSignature()
  return tostring(getLiveProfile() or "1")
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

local function isAtLeastVersion(req)
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  if not rawApiVersion or rawApiVersion == "" or tostring(rawApiVersion) == "0" then
    return true -- default true if offline/simulator
  end
  return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, req)
end

local function formatValue(val, scale, mult)
  val = tonumber(val) or 0
  scale = tonumber(scale) or 1
  mult = tonumber(mult) or 1
  
  local displayVal = (val * mult) / scale
  if scale == 10 then
    return string.format("%.1f", displayVal)
  else
    return string.format("%.0f", displayVal)
  end
end

local function parseValue(str, scale, mult)
  local num = tonumber(str)
  if not num then return 0 end
  scale = tonumber(scale) or 1
  mult = tonumber(mult) or 1
  return math.floor((num * scale) / mult + 0.5)
end

local function getFieldSetter(fieldName, spec)
  local setter = ui.runtime.fieldSetters[fieldName]
  if setter then return setter end
  setter = function(value)
    local rawVal
    if type(value) == "number" then
      rawVal = math.floor(value + 0.5)
    elseif type(value) == "string" then
      rawVal = parseValue(value, spec.scale, spec.mult)
    else
      rawVal = tonumber(value) or 0
    end
    
    if ui.config[fieldName] == rawVal then return end
    ui.config[fieldName] = rawVal
    ui.dirty = true
  end
  ui.runtime.fieldSetters[fieldName] = setter
  return setter
end

local function getGridMetrics(w, numCols)
  local labelMin = 140
  local labelMax = 180
  local gapMin = 3
  local gapMax = 8
  local cellMin = 54
  if w >= 700 then
    labelMin = 140
    labelMax = 200
    gapMin = 5
    gapMax = 10
    cellMin = 62
  end

  if Controls and type(Controls.computeGridMetrics) == "function" then
    local m = Controls.computeGridMetrics(w, numCols, {
      labelRatio = 0.24,
      labelMin = labelMin,
      labelMax = labelMax,
      gapMin = gapMin,
      gapMax = gapMax,
      cellMin = cellMin
    })
    return m.labelW, m.gap, m.cellW
  end
  local labelW = math.floor(w * 0.24)
  local gap = 8
  local cellW = math.floor((w - labelW - (gap * (numCols - 1))) / numCols)
  return labelW, gap, cellW
end

local function getLayoutProfile(w, h)
  local profile = {
    headerFont = SMLSIZE,
    headerTextY = 0,
    headerLineY = 24,
    headerH = 30,
    rowFont = SMLSIZE,
    rowH = 42,
    rowLabelY = 10,
    cellTop = 5,
    afterHeaderGap = 6
  }

  if w >= 700 then
    profile.headerFont = SMLSIZE
    profile.headerTextY = 2
    profile.headerLineY = 32
    profile.headerH = 38
    profile.rowFont = SMLSIZE
    profile.rowH = 50
    profile.rowLabelY = 10
    profile.cellTop = 3
    profile.afterHeaderGap = 6
  elseif w < 560 then
    profile.headerFont = SMLSIZE
    profile.headerTextY = 0
    profile.headerLineY = 22
    profile.headerH = 26
    profile.rowFont = SMLSIZE
    profile.rowH = 40
    profile.rowLabelY = 9
    profile.cellTop = 4
    profile.afterHeaderGap = 4
  end

  return profile
end

local function getDynamicsColumnTitle(i18n, key)
  if key == "roll" then return pageText(i18n, "roll") end
  if key == "pitch" then return pageText(i18n, "pitch") end
  if key == "yaw" then return pageText(i18n, "yaw") end
  if key == "col" then return pageText(i18n, "col") end
  return key
end

local function getDynamicsRowTitle(i18n, key)
  if key == "response_time" then return pageText(i18n, "response_time") end
  if key == "acc_limit" then return pageText(i18n, "acc_limit") end
  if key == "setpoint_boost_gain" then return pageText(i18n, "setpoint_boost_gain") end
  if key == "setpoint_boost_cutoff" then return pageText(i18n, "setpoint_boost_cutoff") end
  if key == "dyn_ceiling_gain" then return pageText(i18n, "dyn_ceiling_gain") end
  if key == "dyn_deadband_gain" then return pageText(i18n, "dyn_deadband_gain") end
  if key == "dyn_deadband_filter" then return pageText(i18n, "dyn_deadband_filter") end
  return key
end

local function drawColumnHeader(children, x, y, w, i18n, layout, cols)
  local labelW, gap, cellW = getGridMetrics(w, #cols)
  local headerFont = (layout and layout.headerFont) or MIDSIZE
  local headerTextY = (layout and layout.headerTextY) or 0
  local headerLineY = (layout and layout.headerLineY) or 28
  local headerH = (layout and layout.headerH) or 34

  children[#children + 1] = {
    type = "rectangle",
    x = x,
    y = y + headerLineY,
    w = w,
    h = 1,
    color = COLOR_THEME_SECONDARY2,
    filled = true
  }

  for i = 1, #cols do
    local cellX = x + labelW + ((i - 1) * (cellW + gap))
    local headerText = string.upper(getDynamicsColumnTitle(i18n, cols[i]))
    children[#children + 1] = {
      type = "label",
      x = cellX,
      y = y + headerTextY,
      w = cellW,
      text = headerText,
      color = COLOR_THEME_PRIMARY1,
      font = headerFont,
      align = CENTER
    }
  end
  return headerH
end

local DYNAMICS_TABLE = {
  cols = { "roll", "pitch", "yaw", "col" },
  fields = {
    -- row 1 (Response Time)
    { { apikey="response_time_1", scale=1, mult=1, min=0, max=250, suffix="ms" }, { apikey="response_time_2", scale=1, mult=1, min=0, max=250, suffix="ms" }, { apikey="response_time_3", scale=1, mult=1, min=0, max=250, suffix="ms" }, { apikey="response_time_4", scale=1, mult=1, min=0, max=250, suffix="ms" } },
    -- row 2 (Accel Limit)
    { { apikey="accel_limit_1", scale=1, mult=10, min=0, max=5000, suffix="°/s" }, { apikey="accel_limit_2", scale=1, mult=10, min=0, max=5000, suffix="°/s" }, { apikey="accel_limit_3", scale=1, mult=10, min=0, max=5000, suffix="°/s" }, { apikey="accel_limit_4", scale=1, mult=10, min=0, max=5000, suffix="°/s" } },
    -- row 3 (Setpoint boost gain)
    { { apikey="setpoint_boost_gain_1", scale=1, mult=1, min=0, max=250, suffix="" }, { apikey="setpoint_boost_gain_2", scale=1, mult=1, min=0, max=250, suffix="" }, { apikey="setpoint_boost_gain_3", scale=1, mult=1, min=0, max=250, suffix="" }, { apikey="setpoint_boost_gain_4", scale=1, mult=1, min=0, max=250, suffix="" } },
    -- row 4 (Setpoint boost cutoff)
    { { apikey="setpoint_boost_cutoff_1", scale=1, mult=1, min=0, max=250, suffix="Hz" }, { apikey="setpoint_boost_cutoff_2", scale=1, mult=1, min=0, max=250, suffix="Hz" }, { apikey="setpoint_boost_cutoff_3", scale=1, mult=1, min=0, max=250, suffix="Hz" }, { apikey="setpoint_boost_cutoff_4", scale=1, mult=1, min=0, max=250, suffix="Hz" } },
    -- row 5 (Dynamic ceiling gain)
    { nil, nil, { apikey="yaw_dynamic_ceiling_gain", scale=1, mult=1, min=0, max=250, suffix="" }, nil },
    -- row 6 (Dynamic deadband gain)
    { nil, nil, { apikey="yaw_dynamic_deadband_gain", scale=1, mult=1, min=0, max=250, suffix="" }, nil },
    -- row 7 (Dynamic deadband filter)
    { nil, nil, { apikey="yaw_dynamic_deadband_filter", scale=10, mult=1, min=0, max=250, suffix="Hz" }, nil }
  }
}

local function drawGrid(children, x, y, w, i18n, layoutParams, rowsConfig)
  local labelW, gap, cellW = getGridMetrics(w, #DYNAMICS_TABLE.cols)
  local cursorY = y
  local rowH = (layoutParams and layoutParams.rowH) or 44
  local rowLabelY = (layoutParams and layoutParams.rowLabelY) or 8
  local cellTop = (layoutParams and layoutParams.cellTop) or 4

  for i = 1, #rowsConfig do
    local rowDef = rowsConfig[i]
    local rowKey = rowDef.key
    local fieldIdx = rowDef.idx
    local labelText = getDynamicsRowTitle(i18n, rowKey)

    children[#children + 1] = {
      type = "label",
      x = x,
      y = cursorY + rowLabelY,
      w = labelW,
      text = labelText,
      color = COLOR_THEME_PRIMARY1,
      font = layoutParams and layoutParams.rowFont or MIDSIZE
    }

    local rowFields = DYNAMICS_TABLE.fields[fieldIdx]
    for j = 1, #DYNAMICS_TABLE.cols do
      local spec = rowFields[j]
      local cellX = x + labelW + ((j - 1) * (cellW + gap))
      
      if spec then
        local rawVal = ui.config[spec.apikey] or 0
        local stepSize = spec.step or 1
        local rawMin = spec.min or 0
        local rawMax = spec.max or 1000

        children[#children + 1] = {
          type = "numberEdit",
          x = cellX,
          y = cursorY + cellTop,
          w = cellW,
          min = math.floor(rawMin / stepSize),
          max = math.ceil(rawMax / stepSize),
          active = function() return true end,
          get = function()
            local rVal = ui.config[spec.apikey] or rawMin
            if rVal < rawMin then rVal = rawMin end
            if rVal > rawMax then rVal = rawMax end
            return math.floor(rVal / stepSize)
          end,
          set = function(val)
            local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
            if rVal < rawMin then rVal = rawMin end
            if rVal > rawMax then rVal = rawMax end
            local setter = getFieldSetter(spec.apikey, spec)
            setter(rVal)
          end,
          display = function(val)
            local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
            return formatValue(rVal, spec.scale, spec.mult) .. spec.suffix
          end
        }
      end
    end
    cursorY = cursorY + rowH
  end

  return cursorY
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
      title = pageText(i18n, "loading_title"),
      message = pageText(i18n, "loading_message"),
      progress = ui.progress / 100
    })
    return
  end

  local title = ui.baseTitle or getBaseTitle()
  local profile = getLiveProfile()
  local displayTitle = string.format("%s #%d", title, profile)

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
  end

  local rowsConfig = {
    { key = "response_time", idx = 1 },
    { key = "acc_limit", idx = 2 }
  }

  if isAtLeastVersion({12, 0, 8}) then
    rowsConfig[#rowsConfig + 1] = { key = "setpoint_boost_gain", idx = 3 }
    rowsConfig[#rowsConfig + 1] = { key = "setpoint_boost_cutoff", idx = 4 }
    rowsConfig[#rowsConfig + 1] = { key = "dyn_ceiling_gain", idx = 5 }
    rowsConfig[#rowsConfig + 1] = { key = "dyn_deadband_gain", idx = 6 }
    rowsConfig[#rowsConfig + 1] = { key = "dyn_deadband_filter", idx = 7 }
  end

  local layoutProfile = getLayoutProfile(w, h)
  local headerH = drawColumnHeader(children, x, cursorY, w, i18n, layoutProfile, DYNAMICS_TABLE.cols)
  cursorY = cursorY + headerH + (layoutProfile.afterHeaderGap or 6)

  cursorY = drawGrid(children, x, cursorY, w, i18n, layoutProfile, rowsConfig)
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
  RcTuningApi = nil
  LoadingOverlay = nil
  Sensors = nil
  ApiVersion = nil
  t = nil
end

M.ui = ui
return M
