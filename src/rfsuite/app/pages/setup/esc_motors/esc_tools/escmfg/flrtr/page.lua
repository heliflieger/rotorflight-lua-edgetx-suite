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
local Controls = nil
local MspRuntime = nil
local EscParametersFlyrotorApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local FlrtrInit = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  config = {
    -- Basic (Section 1)
    cell_count = 6,
    low_voltage_protection = 30,
    temperature_protection = 125,
    bec_voltage = 1,
    electrical_angle = 0,
    motor_direction = 0,
    starting_torque = 3,
    response_speed = 5,
    buzzer_volume = 2,
    current_gain = 20,
    fan_control = 0,

    -- Advanced (Section 2)
    auto_restart_time = 30,
    restart_acc = 5,

    -- Governor (Section 3)
    esc_mode = 0,
    soft_start = 15,
    gov_p = 45,
    gov_i = 35
  },
  currentSection = 1,
  parsedCache = nil,
  escModel = nil,
  escVersion = nil,
  escFirmware = nil,
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil
  },
  loading = false,
  saving = false,
  progress = 0
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not EscParametersFlyrotorApi then EscParametersFlyrotorApi = loadModule("tasks/msp/api/esc_parameters_flyrotor.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not FlrtrInit then FlrtrInit = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/flrtr/init.lua") end
  if not t then t = Common and Common.pageT("setup_esc_motors") or nil end

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

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then
      return ticks / 100
    end
  end
  return 0
end

local function logMsg(msg, level)
  local Log = loadModule("lib/log.lua")
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.flrtr", msg, level or "debug")
  end
end

local function queueFlyrotorReadActual(queue)
  queue:add({
    command = EscParametersFlyrotorApi.command,
    timeout = 15,
    simulatorResponse = EscParametersFlyrotorApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = EscParametersFlyrotorApi.parse(buf)
      if parsed then
        for k, v in pairs(ui.config) do
          if parsed[k] ~= nil then
            ui.config[k] = parsed[k]
          end
        end

        ui.parsedCache = parsed

        local escModel = FlrtrInit and type(FlrtrInit.getEscModel) == "function" and FlrtrInit.getEscModel(buf) or nil
        local escVersion = FlrtrInit and type(FlrtrInit.getEscVersion) == "function" and FlrtrInit.getEscVersion(buf) or nil
        local escFirmware = FlrtrInit and type(FlrtrInit.getEscFirmware) == "function" and FlrtrInit.getEscFirmware(buf) or nil

        ui.escModel = escModel
        ui.escVersion = escVersion
        ui.escFirmware = escFirmware

        local session = getSession()
        if session then
          session.setup_esc_motors_esc_tools_flrtr = {
            config = {},
            parsedCache = ui.parsedCache,
            escModel = escModel,
            escVersion = escVersion,
            escFirmware = escFirmware
          }
          for k, v in pairs(ui.config) do
            session.setup_esc_motors_esc_tools_flrtr.config[k] = v
          end
        end
      end

      ui.runtime.readPending = false
      ui.loading = false
      ui.dirty = false
      ui.progress = 100
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function queueFlyrotorRead(isAutoReload)
  if not MspRuntime or not EscParametersFlyrotorApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  if ui.runtime.readPending then return true, nil end

  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queueFlyrotorReadActual(queue)
  return true, nil
end

local function queueFlyrotorWrite(requestRebuild)
  if not MspRuntime or not EscParametersFlyrotorApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local writeData = {}
  if ui.parsedCache then
    for k, v in pairs(ui.parsedCache) do
      writeData[k] = v
    end
  end

  for k, v in pairs(ui.config) do
    writeData[k] = v
  end

  ui.saving = true
  if requestRebuild and type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end

  queue:add({
    command = EscParametersFlyrotorApi.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = EscParametersFlyrotorApi.buildWritePayload(writeData),
    isWrite = true,
    processReply = function(self, buf)
      ui.dirty = false
      ui.saving = false
      ui.progress = 100
      if requestRebuild and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      ui.saving = false
      ui.notice = {
        title = pageText(ui.i18n, "save_failed_title", "Save Failed"),
        message = pageText(ui.i18n, "save_failed_message", "ESC did not respond / write timed out.")
      }
      if requestRebuild and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function buildSessionSignature()
  return tostring(ui.currentSection)
end

local function loadFromSession()
  local session = getSession()
  local cached = session and session.setup_esc_motors_esc_tools_flrtr or nil
  if type(cached) == "table" and type(cached.config) == "table" then
    for k, v in pairs(ui.config) do
      if cached.config[k] ~= nil then
        ui.config[k] = cached.config[k]
      end
    end
    ui.parsedCache = cached.parsedCache
    ui.escModel = cached.escModel
    ui.escVersion = cached.escVersion
    ui.escFirmware = cached.escFirmware
    return true
  end
  return false
end

local motorConfigRetryCount = 0

local function queueMotorConfigRead()
  ensureDeps()
  local MotorConfigApi = loadModule("tasks/msp/api/motor_config.lua")
  if not MotorConfigApi then
    logMsg("queueMotorConfigRead: MotorConfigApi module missing", "warn")
    return
  end

  local mspState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue then
    logMsg("queueMotorConfigRead: msp queue missing", "warn")
    return
  end

  logMsg("queueMotorConfigRead: queueing motor config read (cmd 131)")
  queue:add({
    command = MotorConfigApi.command,
    isWrite = false,
    simulatorResponse = { 10, 10, 10, 5, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 },
    processReply = function(self, buf)
      logMsg("queueMotorConfigRead processReply: buf_len=" .. tostring(buf and #buf or 0))
      local parsed = MotorConfigApi.parse(buf)
      if parsed and parsed.motor_count_blheli and parsed.motor_count_blheli > 0 then
        logMsg("queueMotorConfigRead parsed: motor_count_blheli=" .. tostring(parsed.motor_count_blheli) .. ", use_dshot_telemetry=" .. tostring(parsed.use_dshot_telemetry))
        local count = tonumber(parsed.motor_count_blheli) or 1
        ui.motorCount = count
        local session = getSession()
        if session then session.esc4WayMotorCount = count end
        if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      else
        logMsg("queueMotorConfigRead: empty buffer or parse failure", "warn")
        if (buf == nil or #buf == 0) and motorConfigRetryCount < 3 then
          motorConfigRetryCount = motorConfigRetryCount + 1
          logMsg("queueMotorConfigRead: scheduling retry " .. tostring(motorConfigRetryCount) .. "/3 on next wakeup", "info")
          ui.motorConfigRetryPending = true
          ui.motorConfigRetryTimer = nowSeconds()
        end
      end
    end,
    errorHandler = function()
      logMsg("queueMotorConfigRead: MSP read command 131 failed", "warn")
    end
  })
end

local function ensureLoaded()
  if ui.loaded then return end

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil
    }
  end
  ui.loading = false
  ui.saving = false
  ui.runtime.readPending = false
  if ui.escTarget == nil then
    ui.escTarget = 0
  end

  local session = getSession()
  if session and session.esc4WayMotorCount then
    ui.motorCount = session.esc4WayMotorCount
  else
    ui.motorCount = nil
    queueMotorConfigRead()
  end

  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  
  -- The safety warning is raised from HERE, which is inside the page build. A native
  -- lvgl.message raised there cannot be closed by a hardware key: Layer::push gives the
  -- dialog an empty LVGL group, but the same build goes on creating this page's objects
  -- afterwards and they land in it, so EXIT is delivered to a widget behind the modal. It
  -- is now the tool's own notice box, drawn into the page's own child list and dismissed
  -- by its own button -- which also keeps the tool's run loop reachable while it stands.
  ui.notice = {
    title = pageText(nil, "safety_warning_title", "Safety Warning"),
    message = pageText(nil, "remove_blades_warning", "Please remove main and tail blades before configuring the ESC!")
  }
  queueFlyrotorRead(false)
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
  
  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  if ui.motorConfigRetryPending and ui.motorConfigRetryTimer then
    if nowSeconds() - ui.motorConfigRetryTimer >= 0.5 then
      ui.motorConfigRetryPending = false
      ui.motorConfigRetryTimer = nil
      queueMotorConfigRead()
    end
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    menu = true
  }
end

function M.onSave(ctx)
  local ok, err = queueFlyrotorWrite(ctx and ctx.requestRebuild)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end
  return true
end

function M.onReload(ctx)
  ui.dirty = false
  queueFlyrotorRead(false)
  return true
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil
  ui.i18n = ctx and ctx.i18n or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  local title = "Flyrotor Configurator"
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

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
    local titleText = ui.loading and pageText(i18n, "loading", "Loading") or pageText(i18n, "saving", "Saving")
    local msgText = ui.loading and pageText(i18n, "loading_data", "Loading ESC parameters...") or pageText(i18n, "saving_data", "Saving ESC parameters...")
    if LoadingOverlay and type(LoadingOverlay.append) == "function" then
      LoadingOverlay.append(children, {
        x = x, y = y, w = w, h = h,
        title = titleText,
        message = msgText,
        progress = ui.progress / 100
      })
    end
    return
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    local headerTitle = title
    if ui.escModel and ui.escModel ~= "" and ui.escModel ~= title then
      if string.find(string.lower(ui.escModel), string.lower(title), 1, true) then
        headerTitle = ui.escModel
      else
        headerTitle = title .. " - " .. ui.escModel
      end
    end
    Controls.appendStaticSectionHeader(children, x, cursorY, w, headerTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  if Controls and type(Controls.appendEscSubheader) == "function" then
    cursorY = cursorY + Controls.appendEscSubheader(children, x, cursorY, w, ui.escFirmware, ui.escVersion)
  end

  local rowH
  local hasMultipleEscs = (ui.motorCount == nil) or (ui.motorCount >= 2)
  if hasMultipleEscs then
    local escOptions = {
      { value = 0, label = "ESC 1" },
      { value = 1, label = "ESC 2" }
    }
    local escTargetVal = ui.escTarget or 0
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "ESC Target", escOptions, escTargetVal, function(val)
      local targetVal = tonumber(val) or 0
      if ui.escTarget ~= targetVal then
        ui.escTarget = targetVal
        ui.connState = 0
        ui.connTimer = nil
        ui.loaded = false
        ui.dirty = false
        queueFlyrotorRead(false)
      end
    end)
    cursorY = cursorY + rowH
  end

  local sectionOptions = {
    { value = 1, label = "Basic" },
    { value = 2, label = "Advanced" },
    { value = 3, label = "Governor" }
  }
  rowH = Controls.appendComboSelect(children, x, cursorY, w, "Section", sectionOptions, ui.currentSection, function(val)
    ui.currentSection = val
    -- The section is the whole of the session signature, and `M.wakeup` compares that signature
    -- on the next tick. Recording it here means the rebuild requested below is the only one:
    -- without it the wakeup sees a change nobody else made and asks for a second, identical build.
    ui.runtime.lastSessionSignature = tostring(ui.currentSection)
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end)
  cursorY = cursorY + rowH

  local function markDirty()
    ui.dirty = true
  end

  if ui.currentSection == 1 then
    -- Basic Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, "Cell Count", {
      min = 4, max = 14, step = 1,
      get = function() return ui.config.cell_count end,
      set = function(val)
        ui.config.cell_count = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Low Voltage Protection", {
      min = 28, max = 38, step = 1,
      display = function(val) return string.format("%.1fV", val / 10) end,
      get = function() return ui.config.low_voltage_protection end,
      set = function(val)
        ui.config.low_voltage_protection = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Temperature Protection", {
      min = 50, max = 135, step = 5, suffix = "C",
      get = function() return ui.config.temperature_protection end,
      set = function(val)
        ui.config.temperature_protection = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    local becOpts = {
      { value = 0, label = "Disabled" },
      { value = 1, label = "7.5V" },
      { value = 2, label = "8.0V" },
      { value = 3, label = "8.5V" },
      { value = 4, label = "12.0V" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "BEC Voltage", becOpts, ui.config.bec_voltage, function(val)
      ui.config.bec_voltage = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local angleOpts = {
      { value = 0, label = "Auto" },
      { value = 1, label = "1 deg" },
      { value = 2, label = "2 deg" },
      { value = 3, label = "3 deg" },
      { value = 4, label = "4 deg" },
      { value = 5, label = "5 deg" },
      { value = 6, label = "6 deg" },
      { value = 7, label = "7 deg" },
      { value = 8, label = "8 deg" },
      { value = 9, label = "9 deg" },
      { value = 10, label = "10 deg" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Electrical Angle", angleOpts, ui.config.electrical_angle, function(val)
      ui.config.electrical_angle = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local dirOpts = {
      { value = 0, label = "CW" },
      { value = 1, label = "CCW" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Motor Direction", dirOpts, ui.config.motor_direction, function(val)
      ui.config.motor_direction = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Starting Torque", {
      min = 1, max = 15, step = 1,
      get = function() return ui.config.starting_torque end,
      set = function(val)
        ui.config.starting_torque = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Response Speed", {
      min = 1, max = 15, step = 1,
      get = function() return ui.config.response_speed end,
      set = function(val)
        ui.config.response_speed = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Buzzer Volume", {
      min = 1, max = 5, step = 1,
      get = function() return ui.config.buzzer_volume end,
      set = function(val)
        ui.config.buzzer_volume = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Current Gain", {
      min = 0, max = 40, step = 1,
      display = function(val) return tostring(val - 20) end,
      get = function() return ui.config.current_gain end,
      set = function(val)
        ui.config.current_gain = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    local fanOpts = {
      { value = 0, label = "Automatic" },
      { value = 1, label = "Always On" },
      { value = 2, label = "Always Off" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Fan Control", fanOpts, ui.config.fan_control, function(val)
      ui.config.fan_control = val
      markDirty()
    end)
    cursorY = cursorY + rowH

  elseif ui.currentSection == 2 then
    -- Advanced Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, "Auto Restart Time", {
      min = 0, max = 100, step = 1, suffix = "s",
      get = function() return ui.config.auto_restart_time end,
      set = function(val)
        ui.config.auto_restart_time = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Restart Acc", {
      min = 1, max = 10, step = 1,
      get = function() return ui.config.restart_acc end,
      set = function(val)
        ui.config.restart_acc = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

  elseif ui.currentSection == 3 then
    -- Governor Settings
    local modeOpts = {
      { value = 0, label = "ESC Gov" },
      { value = 1, label = "Linear Throttle" },
      { value = 2, label = "RF Gov" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "ESC Mode", modeOpts, ui.config.esc_mode, function(val)
      ui.config.esc_mode = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Soft Start", {
      min = 5, max = 55, step = 1, suffix = "s",
      get = function() return ui.config.soft_start end,
      set = function(val)
        ui.config.soft_start = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Governor P", {
      min = 0, max = 100, step = 1,
      get = function() return ui.config.gov_p end,
      set = function(val)
        ui.config.gov_p = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Governor I", {
      min = 0, max = 100, step = 1,
      get = function() return ui.config.gov_i end,
      set = function(val)
        ui.config.gov_i = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH
  end

  -- The label is built once and reads the flag itself, so a change that sets the flag
  -- does not have to replace the scene to show it. The text is resolved here rather
  -- than inside the closure: the closure runs on every refresh, the lookup need not.
  local unsavedText = pageText(i18n, "unsaved_changes", "Unsaved changes")
  children[#children + 1] = {
    type = "label",
    x = x + 16, y = cursorY + 10,
    text = function() return ui.dirty and unsavedText or "" end,
    color = COLOR_THEME_SECONDARY1,
    font = SMLSIZE
  }
end

function M.onClose()
  ui.escTarget = nil
  ui.motorCount = nil
  ui.motorConfigRetryPending = nil
  ui.motorConfigRetryTimer = nil
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Common = nil
  Controls = nil
  MspRuntime = nil
  EscParametersFlyrotorApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  FlrtrInit = nil
  t = nil
end

return M
