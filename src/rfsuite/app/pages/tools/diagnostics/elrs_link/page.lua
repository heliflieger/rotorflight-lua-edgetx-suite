local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then 
    if _G and _G.rfsuite and _G.rfsuite.Log then
      _G.rfsuite.Log.emit("rfsuite.elrs", "loadModule pcall error: " .. tostring(mod), "error")
    end
    return nil 
  end
  return mod
end

local Common = nil
local ElrsTask = nil
local t = nil

local state = {
  loaded = false,
  rows = {},
  rowSignature = "",
  requestRebuild = nil,
  lastRefreshAt = 0,
  refreshIntervalSec = 0.5,
  i18n = nil,
  taskRunning = false,
  fetchingConfig = false
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

local LoadingOverlay = nil

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not ElrsTask then 
    ElrsTask = loadModule("app/pages/tools/diagnostics/elrs_link/elrslink_task.lua") 
    if not ElrsTask and _G and _G.rfsuite and _G.rfsuite.Log then
      _G.rfsuite.Log.emit("rfsuite.elrs", "Failed to load elrslink_task.lua", "error")
    end
  end
  if not t then t = Common and Common.pageT("diagnostics_elrs_link") or nil end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
end

local function pageText(i18n, key, fallback)
  local obj = i18n or state.i18n
  if t then return t(obj, key, fallback) end
  return fallback
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function log(msg, level)
  local rf = _G.rfsuite
  if rf and rf.Log and type(rf.Log.emit) == "function" then
    rf.Log.emit("rfsuite.elrs.page", msg, level or "debug")
  end
end

local function requestTelemetryConfig(force)
  if state.fetchingConfig and not force then return end
  local session = getSession()
  if not session or not session.isConnected then return end
  
  local TelemetryApi = loadModule("tasks/msp/api/telemetry_config.lua")
  local msp = loadModule("tasks/msp/runtime.lua")
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not TelemetryApi or not mspState or not mspState.queue then 
    log("requestTelemetryConfig: missing dependencies", "warn")
    return 
  end
  
  log("requestTelemetryConfig: requesting MSP 73 (force=" .. tostring(force) .. ")")
  state.fetchingConfig = true
  mspState.queue:add({
    command = TelemetryApi.command,
    simulatorResponse = TelemetryApi.simulatorResponse,
    processReply = function(_, buf)
      log("requestTelemetryConfig: received reply bytes=" .. tostring(buf and #buf or 0))
      local parsed = TelemetryApi.parse(buf)
      if parsed then
        session.crsfTelemetryConfig = {
          mode = parsed.crsf_telemetry_mode,
          linkRate = parsed.crsf_telemetry_link_rate,
          linkRatio = parsed.crsf_telemetry_link_ratio
        }
        session.telemetryConfigBuffer = parsed.buffer
        log("requestTelemetryConfig: successfully populated session config")
      end
      state.fetchingConfig = false
      state.answered = true
      if type(state.requestRebuild) == "function" then state.requestRebuild() end
    end,
    errorHandler = function()
      log("requestTelemetryConfig: MSP 73 failed", "warn")
      state.fetchingConfig = false
    end
  })
end

local function formatRotorflightSummary(i18n)
    local session = getSession()
    local fcConfig = session and session.crsfTelemetryConfig
    if not session or session.isConnected ~= true then
        return pageText(i18n, "status_connect_first", "Please connect first")
    end
    if session.telemetryType ~= "crsf" then
        return pageText(i18n, "status_requires_crsf", "Requires CRSF")
    end
    if type(fcConfig) ~= "table" then
        requestTelemetryConfig()
        return pageText(i18n, "status_waiting_telemetry_config", "Waiting for config")
    end

    local modeLabel = fcConfig.mode == 0 and pageText(i18n, "mode_native", "Native") or pageText(i18n, "mode_custom", "Custom")
    local rateLabel = (fcConfig.linkRate and fcConfig.linkRate > 0) and (tostring(fcConfig.linkRate) .. "Hz") or tostring(fcConfig.linkRate or "?")
    local ratioLabel = (fcConfig.linkRatio and fcConfig.linkRatio > 0) and ("1:" .. tostring(fcConfig.linkRatio)) or tostring(fcConfig.linkRatio or "?")
    return "mode=" .. modeLabel .. ", rate=" .. rateLabel .. ", ratio=" .. ratioLabel
end

local function formatElrsSummary(i18n)
    local session = getSession()
    local linkConfig = session and session.elrsLinkConfig
    if type(linkConfig) ~= "table" then
        return pageText(i18n, "status_not_probed", "Not probed yet")
    end

    local rateText = linkConfig.packetRateLabel
    if not rateText or rateText == "" then
        if linkConfig.packetRate and linkConfig.packetRate > 0 then
            rateText = tostring(linkConfig.packetRate) .. "Hz"
        else
            rateText = "?"
        end
    end

    local ratioText = linkConfig.telemetryRatioLabel
    if not ratioText or ratioText == "" then
        if linkConfig.telemetryRatio and linkConfig.telemetryRatio > 0 then
            ratioText = "1:" .. tostring(linkConfig.telemetryRatio)
        else
            ratioText = "?"
        end
    end

    return "rate=" .. tostring(rateText) .. ", ratio=" .. tostring(ratioText)
end

local function actionModeLabel(i18n, mode)
    if mode == ElrsTask.MODE_ROTORFLIGHT_TO_ELRS then
        return pageText(i18n, "action_rf_to_elrs", "RF -> ELRS")
    end
    if mode == ElrsTask.MODE_ELRS_TO_ROTORFLIGHT then
        return pageText(i18n, "action_elrs_to_rf", "ELRS -> RF")
    end
    return pageText(i18n, "action_probe_only", "Probe only")
end

local function rebuildRows(i18n)
  if not ElrsTask then return false end
  
  local statusKey, statusDef = ElrsTask.getStatus()
  local status = pageText(i18n, statusKey, statusDef)
  local isRunning = ElrsTask.isRunning()

  local rows = {
    { label = pageText(i18n, "status", "Status"), value = status },
    { label = pageText(i18n, "rotorflight", "Rotorflight"), value = formatRotorflightSummary(i18n) },
    { label = pageText(i18n, "elrs_module", "ELRS Module"), value = formatElrsSummary(i18n) },
    { label = pageText(i18n, "action", "Action"), value = actionModeLabel(i18n, ElrsTask.getMode()) },
  }

  local signatureParts = {}
  for i = 1, #rows do
    signatureParts[#signatureParts + 1] = tostring(rows[i].label) .. "|" .. tostring(rows[i].value)
  end
  signatureParts[#signatureParts + 1] = tostring(isRunning)
  local signature = table.concat(signatureParts, "|")
  if signature == state.rowSignature then
    return false
  end

  state.rows = rows
  state.rowSignature = signature
  state.taskRunning = isRunning
  return true
end

function M.getModuleTitle()
  return "ELRS Telemetry"
end

function M.getHeaderActions()
  return { reload = true, save = false, help = false }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  requestTelemetryConfig(true)
  if ElrsTask then
    ElrsTask.start(ElrsTask.MODE_PROBE)
  end
  return true
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild
  state.i18n = ctx.i18n

  local i18n = ctx.i18n
  
  if not state.loaded then
    state.loaded = true
    requestTelemetryConfig(true)
  end
  
  rebuildRows(i18n)

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w

  -- Until the first reply lands there is nothing to draw but zeroes, and the host paints no
  -- frame in front of a page -- so without this the page simply appears empty and the pilot
  -- cannot tell a slow read from a page that has no data. Only the FIRST read is covered:
  -- the page re-reads on demand, and an overlay on every re-read would flash.
  if not state.answered and state.fetchingConfig and LoadingOverlay
     and type(LoadingOverlay.append) == "function" then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = ctx.h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_message", "Reading link configuration..."),
      progress = 0.3
    })
    return
  end
  local rowY = y + 6
  local rowH = 44
  local labelW = math.floor(w * 0.35)
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
      color = COLOR_THEME_PRIMARY1,
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

  -- Bottom Buttons
  if ElrsTask then
    local btnY = rowY + (#state.rows * rowH) + 15
    local gap = 10
    local btnW = math.floor((w - gap * 2) / 3)
    local btnH = 40
    local textOffY = -4

    local buttonsEnabled = function()
      return not state.taskRunning
    end

    -- Probe
    children[#children + 1] = {
      type = "button",
      x = x, y = btnY, w = btnW, h = btnH,
      color = COLOR_THEME_SECONDARY1,
      text = pageText(i18n, "action_probe", "Probe"),
      textColor = WHITE,
      active = buttonsEnabled,
      press = function()
        requestTelemetryConfig(true)
        ElrsTask.start(ElrsTask.MODE_PROBE)
      end
    }

    -- RF -> ELRS
    children[#children + 1] = {
      type = "button",
      x = x + btnW + gap, y = btnY, w = btnW, h = btnH,
      color = COLOR_THEME_SECONDARY1,
      text = pageText(i18n, "action_rf_to_elrs", "RF -> ELRS"),
      textColor = WHITE,
      active = buttonsEnabled,
      press = function()
        requestTelemetryConfig(true)
        ElrsTask.start(ElrsTask.MODE_ROTORFLIGHT_TO_ELRS)
      end
    }

    -- ELRS -> RF
    children[#children + 1] = {
      type = "button",
      x = x + (btnW + gap) * 2, y = btnY, w = btnW, h = btnH,
      color = COLOR_THEME_SECONDARY1,
      text = pageText(i18n, "action_elrs_to_rf", "ELRS -> RF"),
      textColor = WHITE,
      active = buttonsEnabled,
      press = function()
        requestTelemetryConfig(true)
        ElrsTask.start(ElrsTask.MODE_ELRS_TO_ROTORFLIGHT)
      end
    }
  end
end

function M.wakeup()
  if ElrsTask and ElrsTask.isRunning() then
    ElrsTask.wakeup()
  end

  local now = nowSeconds()
  if (now - (state.lastRefreshAt or 0)) < state.refreshIntervalSec then
    return
  end
  state.lastRefreshAt = now
  
  if rebuildRows(state.i18n) and type(state.requestRebuild) == "function" then
    state.requestRebuild()
  end
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  if ElrsTask then ElrsTask.reset() end
  state.loaded = false
  state.rows = {}
  state.rowSignature = ""
  state.requestRebuild = nil
  state.lastRefreshAt = 0
  state.i18n = nil
  state.fetchingConfig = false
  state.answered = false
  LoadingOverlay = nil
  Common = nil
  ElrsTask = nil
  t = nil
end

return M
