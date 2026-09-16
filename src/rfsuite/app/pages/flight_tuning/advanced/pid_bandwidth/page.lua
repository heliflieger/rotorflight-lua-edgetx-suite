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
local PidProfileApi = nil
local LoadingOverlay = nil
local Sensors = nil
local Profile = nil
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
  if not PidProfileApi then PidProfileApi = loadModule("tasks/msp/api/pid_profile.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_advanced_pid_bandwidth") or nil end
  
  if Common then
    if not ui.runtimeBase then
      ui.runtimeBase = Common.createProfileAwareRuntime({ profileType = "pid" })
    end
    if type(ui.runtime) ~= "table" then
      ui.runtime = newRuntime()
      setmetatable(ui.runtime, { __index = ui.runtimeBase })
    end
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
  if type(session.pid_profile) ~= "table" then
    session.pid_profile = session.pidProfile or {}
  end
  session.pidProfile = session.pid_profile
  return session.pid_profile
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
  if not PidProfileApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
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
    command = PidProfileApi.command,
    simulatorResponse = PidProfileApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = PidProfileApi.parse(buf)
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
  if not PidProfileApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
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
    command = PidProfileApi.writeCommand,
    payload = PidProfileApi.buildWritePayload(rcConfig),
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
  return Profile and Profile.getActivePidProfile(1) or 1
end

local function getBaseTitle()
  return pageText(nil, "title", "PID Bandwidth")
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

local function formatValue(val, spec)
  val = tonumber(val) or 0
  local scale = spec.scale or 1
  local mult = spec.mult or 1
  local decimals = spec.decimals or 0
  
  local displayVal = (val * mult) / scale
  local fmt = "%." .. tostring(decimals) .. "f"
  return string.format(fmt, displayVal)
end

local function getGridMetrics(w)
  local labelW = math.floor(w * 0.38)
  local gap = 8
  local cellW = math.floor((w - labelW - (gap * 2)) / 3)
  return labelW, gap, cellW
end

local function drawColumnHeader(children, x, y, w, i18n)
  local labelW, gap, cellW = getGridMetrics(w)
  local headerH = 34
  local headerLineY = 28
  local headerTextY = 0

  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y + headerLineY,
    w = w, h = 1,
    color = COLOR_THEME_SECONDARY2, filled = true
  }

  local columns = { "roll", "pitch", "yaw" }
  for i = 1, 3 do
    local cellX = x + labelW + ((i - 1) * (cellW + gap))
    local headerText = string.upper(pageText(i18n, columns[i], string.upper(columns[i])))
    children[#children + 1] = {
      type = "label",
      x = cellX, y = y + headerTextY,
      w = cellW,
      text = headerText,
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE,
      align = CENTER
    }
  end

  return headerH
end

local function appendBandwidthRow(children, x, y, w, i18n, labelText, key0, key1, key2, spec)
  local rowH = (Controls and Controls.ROW_H) or 64
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  local labelW, gap, cellW = getGridMetrics(w)

  -- Row label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = labelW - 8,
    text  = labelText,
    color = COLOR_THEME_PRIMARY1,
    font  = SMLSIZE
  }

  local keys = { key0, key1, key2 }
  local rawMin = spec.min or 0
  local rawMax = spec.max or 250
  local stepSize = spec.step or 1

  for i = 1, 3 do
    local key = keys[i]
    local cellX = x + labelW + ((i - 1) * (cellW + gap))
    
    children[#children + 1] = {
      type = "numberEdit",
      x = cellX,
      y = cellTop,
      w = cellW,
      min = math.floor(rawMin / stepSize),
      max = math.ceil(rawMax / stepSize),
      active = function() return true end,
      get = function()
        local rVal = ui.config[key] or rawMin
        if rVal < rawMin then rVal = rawMin end
        if rVal > rawMax then rVal = rawMax end
        return math.floor(rVal / stepSize)
      end,
      set = function(val)
        local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
        if rVal < rawMin then rVal = rawMin end
        if rVal > rawMax then rVal = rawMax end
        ui.config[key] = rVal
        ui.dirty = true
      end,
      display = function(val)
        local rVal = math.floor((tonumber(val) or math.floor(rawMin / stepSize)) * stepSize)
        return formatValue(rVal, spec) .. spec.suffix
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
      message = pageText(i18n, "loading_message", "Reading PID Bandwidth settings"),
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
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  -- Column Headers: Roll, Pitch, Yaw
  cursorY = cursorY + drawColumnHeader(children, x, cursorY, w, i18n)

  -- Specs
  local specHz = { scale=1, mult=1, min=0, max=250, suffix="Hz", decimals=0 }

  -- 1) PID Bandwidth (gyro_cutoff_0 / 1 / 2)
  cursorY = cursorY + appendBandwidthRow(children, x, cursorY, w, i18n,
    pageText(i18n, "gyro_cutoff", "PID Bandwidth"),
    "gyro_cutoff_0", "gyro_cutoff_1", "gyro_cutoff_2", specHz
  )

  -- 2) D-term cut-off (dterm_cutoff_0 / 1 / 2)
  cursorY = cursorY + appendBandwidthRow(children, x, cursorY, w, i18n,
    pageText(i18n, "dterm_cutoff", "D-term cut-off"),
    "dterm_cutoff_0", "dterm_cutoff_1", "dterm_cutoff_2", specHz
  )

  -- 3) B-term cut-off (bterm_cutoff_0 / 1 / 2)
  cursorY = cursorY + appendBandwidthRow(children, x, cursorY, w, i18n,
    pageText(i18n, "bterm_cutoff", "B-term cut-off"),
    "bterm_cutoff_0", "bterm_cutoff_1", "bterm_cutoff_2", specHz
  )
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
  local help = loadModule("app/pages/flight_tuning/advanced/pid_bandwidth/help.lua")
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
  PidProfileApi = nil
  LoadingOverlay = nil
  Sensors = nil
  t = nil
end

ui.runtimeBase = nil
M.ui = ui
return M
