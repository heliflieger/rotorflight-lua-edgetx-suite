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
local ValidateSensors = nil
local t = nil
local hasMspSensor
local isFblConnected

local state = {
  loaded = false,
  rows = {},
  rowSignature = "",
  requestRebuild = nil,
  lastRefreshAt = 0,
  refreshIntervalSec = 5.0,
}

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then
      return v / 100
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
  if not ValidateSensors then ValidateSensors = loadModule("app/pages/tools/diagnostics/validate_sensors/page.lua") end
  if not t then t = Common and Common.pageT("diagnostics_rfstatus") or nil end
end

local function pageText(i18n, key, fallback)
  if t then return t(i18n, key, fallback) end
  return fallback
end

local function getRootState()
  local root = _G and _G.rfsuite
  return root or nil
end

local function getSession()
  local root = getRootState()
  return root and root.session or nil
end

local function isBackgroundTaskHealthy()
  local root = getRootState()
  local tasks = root and root.tasks or nil
  if type(tasks) == "table" and type(tasks.events) == "table" then
    return true
  end
  local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
  return type(runtimeState) == "table" and runtimeState.available == true
end

local function isRfModuleEnabled()
  if type(model) ~= "table" or type(model.getModule) ~= "function" then
    return nil
  end

  local function readModuleEnabled(mod)
    if type(mod) ~= "table" then
      return nil
    end
    if type(mod.enable) == "function" then
      local ok, enabled = pcall(mod.enable, mod)
      if ok then
        return enabled == true
      end
    end
    if type(mod.enable) == "boolean" then
      return mod.enable
    end
    if type(mod.enabled) == "boolean" then
      return mod.enabled
    end
    return nil
  end

  local ok0, m0 = pcall(model.getModule, 0)
  if not ok0 then m0 = nil end
  local ok1, m1 = pcall(model.getModule, 1)
  if not ok1 then m1 = nil end

  local s0 = readModuleEnabled(m0)
  local s1 = readModuleEnabled(m1)
  local linkFallback = hasMspSensor() == true or isFblConnected() == true
  if s0 == true or s1 == true then
    return true
  end
  if s0 == false or s1 == false then
    return false
  end
  if linkFallback then
    return true
  end
  if m0 == nil and m1 == nil then
    return nil
  end
  return nil
end

hasMspSensor = function()
  local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil

  if type(system) ~= "table" or type(system.getSource) ~= "function" then
    if type(runtimeState) == "table" and runtimeState.lastConnected ~= nil then
      return runtimeState.lastConnected == true
    end
    return nil
  end

  local ok, sensor = pcall(system.getSource, { appId = 0xF101 })
  if ok and sensor then
    return true
  end

  ok, sensor = pcall(system.getSource, { crsfId = 0x14, subIdStart = 0, subIdEnd = 1 })
  if ok and sensor then
    return true
  end

  if type(runtimeState) == "table" and runtimeState.lastConnected == true then
    return true
  end

  return false
end

isFblConnected = function()
  if MspRuntime and type(MspRuntime.isFblConnected) == "function" then
    return MspRuntime.isFblConnected()
  end

  local session = getSession()
  if type(session) == "table" and session.fblConnected ~= nil then
    return session.fblConnected == true
  end

  return nil
end

local function getApiStatus()
  local session = getSession()
  if type(session) ~= "table" then
    return nil
  end
  if session.apiSupported == false then
    return false
  end
  if type(session.apiVersion) == "string" and session.apiVersion ~= "" and session.apiVersion ~= "0" then
    return true
  end
  return nil
end

local function getTelemetrySensorsStatus()
  if not ValidateSensors or type(ValidateSensors.getValidationSummary) ~= "function" then
    return nil
  end

  local summary = ValidateSensors.getValidationSummary({ passive = true })
  if type(summary) ~= "table" then
    return nil
  end
  if tonumber(summary.total or 0) <= 0 then
    return false
  end
  return tonumber(summary.invalid or 0) == 0
end

local function statusText(i18n, ok)
  if ok == nil then
    return "-"
  end
  if ok then
    return pageText(i18n, "ok", "OK")
  end
  return pageText(i18n, "error", "ERROR")
end

local function statusColor(ok)
  if ok == nil then
    return COLOR_THEME_PRIMARY1
  end
  return ok and GREEN or RED
end

local function rebuildRows(i18n)
  local backgroundTaskOk = isBackgroundTaskHealthy()
  local rfModuleOk = isRfModuleEnabled()
  local mspSensorOk = hasMspSensor()
  local telemetrySensorsOk = getTelemetrySensorsStatus()
  local fblConnectedOk = isFblConnected()
  local apiOk = getApiStatus()

  local rows = {
    { label = pageText(i18n, "background_task", "Background Task"), value = statusText(i18n, backgroundTaskOk), kind = "status", ok = backgroundTaskOk },
    { label = pageText(i18n, "rf_module", "RF Module"), value = statusText(i18n, rfModuleOk), kind = "status", ok = rfModuleOk },
    { label = pageText(i18n, "msp_sensor", "MSP Sensor"), value = statusText(i18n, mspSensorOk), kind = "status", ok = mspSensorOk },
    { label = pageText(i18n, "telemetry_sensors", "Telemetry Sensors"), value = statusText(i18n, telemetrySensorsOk), kind = "status", ok = telemetrySensorsOk },
    { label = pageText(i18n, "fbl_connected", "FBL connected"), value = statusText(i18n, fblConnectedOk), kind = "status", ok = fblConnectedOk },
    { label = pageText(i18n, "api_version", "API version"), value = statusText(i18n, apiOk), kind = "status", ok = apiOk },
  }

  local signatureParts = {}
  for i = 1, #rows do
    signatureParts[#signatureParts + 1] = tostring(rows[i].label) .. "|" .. tostring(rows[i].value)
  end
  local signature = table.concat(signatureParts, "|")
  if signature == state.rowSignature then
    return false
  end

  state.rows = rows
  state.rowSignature = signature
  return true
end

function M.getModuleTitle()
  return "Rotorflight Status"
end

function M.getHeaderActions()
  return { reload = false, save = false, help = false }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  return false
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild

  local i18n = ctx.i18n
  
  if not state.loaded then
    state.loaded = true
  end
  
  rebuildRows(i18n)

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local rowY = y + 6
  local rowH = 44
  local labelW = math.floor(w * 0.58)
  local valueX = x + labelW
  local valueW = w - labelW

  for i = 1, #state.rows do
    local row = state.rows[i]
    local thisY = rowY + (i - 1) * rowH

    children[#children + 1] = {
      type = "label",
      x = x,
      y = thisY + 8,
      w = labelW - 10,
      text = row.label,
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "label",
      x = valueX,
      y = thisY + 8,
      w = valueW - 6,
      text = tostring(row.value),
      color = row.kind == "value" and COLOR_THEME_PRIMARY1 or statusColor(row.ok),
      align = RIGHT,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = thisY + rowH - 2,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY1,
      filled = true
    }
  end
end

function M.wakeup()
  local now = nowSeconds()
  if (now - (state.lastRefreshAt or 0)) < state.refreshIntervalSec then
    return
  end
  state.lastRefreshAt = now
  
  if rebuildRows(nil) and type(state.requestRebuild) == "function" then
    state.requestRebuild()
  end
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.loaded = false
  state.rows = {}
  state.rowSignature = ""
  state.requestRebuild = nil
  state.lastRefreshAt = 0
  Common = nil
  MspRuntime = nil
  ValidateSensors = nil
  t = nil
end

return M
