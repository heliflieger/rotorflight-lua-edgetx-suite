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
local MspRuntime = nil
local LoadingOverlay = nil
local Controls = nil
local RawImuApi = nil
local t = nil

local SENSORS = {
  { key = "acc_x", label = "Acc X", field = "ax", scale = 1/512 },
  { key = "acc_y", label = "Acc Y", field = "ay", scale = 1/512 },
  { key = "acc_z", label = "Acc Z", field = "az", scale = 1/512 },
  { key = "gyro_x", label = "Gyro X", field = "gx", scale = 1/16.4 },
  { key = "gyro_y", label = "Gyro Y", field = "gy", scale = 1/16.4 },
  { key = "gyro_z", label = "Gyro Z", field = "gz", scale = 1/16.4 },
}

local state = {
  loaded = false,
  requestRebuild = nil,
  lastRefreshAt = 0,
  refreshIntervalSec = 1.0, -- UI Update rate (1Hz baseline)
  i18n = nil,
  streaming = false,
  selectedSensorIdx = 1,
  history = {},
  maxPoints = 80,
  minVal = -2,
  maxVal = 2,
  lastMspRequestAt = 0,
  mspRequestIntervalSec = 0.1, -- MSP sampling (10Hz)
  pendingRequest = false,
  values = {
    ax = 0, ay = 0, az = 0,
    gx = 0, gy = 0, gz = 0
  }
}

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

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not RawImuApi then RawImuApi = loadModule("tasks/msp/api/raw_imu.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("diagnostics_fblsensors") or nil end
end

local function pageText(i18n, key, fallback)
  local obj = i18n or state.i18n
  if t then return t(obj, key, fallback) end
  return fallback
end

local function resetGraph()
  state.history = {}
  state.minVal = -1
  state.maxVal = 1
end

local function requestData()
  if state.pendingRequest then return end
  
  local msp = MspRuntime
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue or not RawImuApi then return end

  state.pendingRequest = true
  mspState.queue:add({
    command = RawImuApi.command,
    simulatorResponse = RawImuApi.simulatorResponse,
    processReply = function(_, buf)
      state.pendingRequest = false
      state.answered = true
      local parsed = RawImuApi.parse(buf)
      if parsed then
        state.values = parsed
        
        -- Add to history
        local sensor = SENSORS[state.selectedSensorIdx]
        if sensor then
          local rawVal = parsed[sensor.field] or 0
          local val = rawVal * (sensor.scale or 1)
          
          table.insert(state.history, val)
          if #state.history > state.maxPoints then
            table.remove(state.history, 1)
          end
          
          -- Auto-scale
          if val < state.minVal then state.minVal = val end
          if val > state.maxVal then state.maxVal = val end
        end
      end
    end,
    errorHandler = function()
      state.pendingRequest = false
    end
  })
end

function M.getModuleTitle()
  return "FBL Sensors"
end

function M.getHeaderActions()
  return { reload = true, save = false, help = false }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  resetGraph()
  if not state.streaming then
    requestData()
  end
  return true
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild
  state.i18n = ctx.i18n

  local i18n = ctx.i18n
  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  
  if not state.loaded then
    state.loaded = true
  end

  -- Until the first reply lands there is nothing to draw but zeroes, and the host paints no
  -- frame in front of a page -- so without this the page simply appears empty and the pilot
  -- cannot tell a slow read from a page that has no data. Only the FIRST read is covered:
  -- this page polls, and an overlay on every poll would flash.
  if not state.answered and LoadingOverlay and type(LoadingOverlay.append) == "function" then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_message", "Reading sensors..."),
      progress = 0.3
    })
    return
  end

  local rowY = y + 5
  local rowH = 40
  local ctrlH = 36
  local lblOffY = 9
  
  -- ── Top Row (Sensor + Stream) ───────────────────────────────────────────────
  
  -- Col 1: Sensor Label + Choice
  local sensorLabelW = 55
  children[#children + 1] = {
    type = "label",
    x = x, y = rowY + lblOffY, w = sensorLabelW,
    text = pageText(i18n, "sensor", "Sensor"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
  
  local comboW = 125
  local optionLabels = {}
  for i, s in ipairs(SENSORS) do
    optionLabels[i] = pageText(i18n, s.key, s.label)
  end
  
  children[#children + 1] = {
    type  = "choice",
    x = x + sensorLabelW + 5, y = rowY,
    w = comboW, h = ctrlH,
    values = optionLabels,
    get = function() return state.selectedSensorIdx end,
    set = function(val)
      state.selectedSensorIdx = val
      resetGraph()
      if type(state.requestRebuild) == "function" then state.requestRebuild() end
    end
  }

  -- Col 2: Stream Toggle (Right aligned)
  local toggleW = 64
  local toggleX = x + w - toggleW - 5
  children[#children + 1] = {
    type = "toggle",
    x = toggleX, y = rowY + 5, w = toggleW, h = 26,
    get = function() return state.streaming end,
    set = function(val)
      state.streaming = val
      state.lastRefreshAt = 0
    end
  }
  
  local streamLabelW = 140 -- Wide enough for "Echtzeit-Stream"
  children[#children + 1] = {
    type = "label",
    x = toggleX - streamLabelW - 5, y = rowY + lblOffY, w = streamLabelW,
    text = pageText(i18n, "stream", "Echtzeit-Stream"),
    color = COLOR_THEME_PRIMARY1,
    align = RIGHT,
    font = SMLSIZE
  }
  
  -- Row divider
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = rowY + rowH + 2, w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  -- ── Graph Area (Responsive & Shorter to avoid scroll) ────────────────────────
  
  local graphTopGap = 10
  local graphY = rowY + rowH + graphTopGap
  local graphH = h - (graphY - y) - 35 -- 35px safety margin at the bottom
  if graphH < 40 then graphH = 40 end
  local graphW = w - 20
  local graphX = x + 10
  
  -- Border
  children[#children + 1] = {
    type = "rectangle",
    x = graphX, y = graphY, w = graphW, h = graphH,
    color = COLOR_THEME_SECONDARY2, filled = false
  }
  
  -- Zero line
  if state.minVal < 0 and state.maxVal > 0 then
    local zeroY = graphY + math.floor(graphH * (state.maxVal / (state.maxVal - state.minVal)))
    children[#children + 1] = {
      type = "rectangle",
      x = graphX, y = zeroY, w = graphW, h = 1,
      color = COLOR_THEME_SECONDARY2, filled = true
    }
  end

  -- Draw Data
  if #state.history > 1 then
    local range = state.maxVal - state.minVal
    if range == 0 then range = 1 end
    
    local dx = graphW / (state.maxPoints - 1)
    local lastX = nil
    local lastY = nil
    
    for i, val in ipairs(state.history) do
      local px = graphX + (i-1) * dx
      local py = graphY + math.floor(graphH * ((state.maxVal - val) / range))
      
      if lastX then
        local segW = math.ceil(px - lastX)
        if segW < 1 then segW = 1 end
        
        children[#children + 1] = {
          type = "rectangle",
          x = math.floor(lastX), y = math.min(lastY, py), w = segW, h = math.abs(py - lastY) + 1,
          color = COLOR_THEME_SECONDARY1, filled = true
        }
      end
      lastX = px
      lastY = py
    end
  end
  
  -- Current Value Label
  local sensor = SENSORS[state.selectedSensorIdx]
  local currentVal = 0
  if sensor then
    currentVal = (state.values[sensor.field] or 0) * (sensor.scale or 1)
  end
  
  children[#children + 1] = {
    type = "label",
    x = graphX + 5, y = graphY + 5, w = graphW - 10,
    text = string.format("%.2f", currentVal),
    color = COLOR_THEME_PRIMARY1, font = SMLSIZE
  }
end

function M.wakeup()
  if not state.streaming then return end

  local now = nowSeconds()
  -- 1. MSP Request (10Hz)
  if (now - state.lastMspRequestAt) >= state.mspRequestIntervalSec then
    state.lastMspRequestAt = now
    requestData()
  end

  -- 2. UI Refresh (1Hz baseline)
  if (now - state.lastRefreshAt) >= state.refreshIntervalSec then
    state.lastRefreshAt = now
    if type(state.requestRebuild) == "function" then
        state.requestRebuild()
    end
  end
end

function M.paint()
end

function M.handleEvent(eventData)
  state.lastRefreshAt = nowSeconds() + 1.2
  return eventData
end

function M.closePage()
  state.loaded = false
  state.streaming = false
  state.history = {}
  state.requestRebuild = nil
  state.i18n = nil
  Common = nil
  MspRuntime = nil
  LoadingOverlay = nil
  state.answered = false
  Controls = nil
  RawImuApi = nil
  t = nil
end

return M
