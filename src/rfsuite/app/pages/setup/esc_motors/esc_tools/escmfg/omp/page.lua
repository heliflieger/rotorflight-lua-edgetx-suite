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
local EscParametersOmpApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local OmpInit = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  config = {
    -- Governor (Section 3)
    governor = 0,
    gov_p = 5,
    gov_i = 5,
    motor_poles = 10,

    -- Basic (Section 1)
    lv_bec_voltage = 0,
    hv_bec_voltage = 0,
    motor_direction = 0,
    startup_power = 0,
    led_color = 0,
    smart_fan = 0,

    -- Advanced (Section 2)
    timing = 0,
    acceleration = 1,
    brake_type = 0,
    brake_force = 0,
    sr_function = 0,
    capacity_correction = 10,
    auto_restart_time = 0,
    cell_cutoff = 2
  },
  currentSection = 1,
  parsedCache = nil,
  activeFields = nil,
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
  if not EscParametersOmpApi then EscParametersOmpApi = loadModule("tasks/msp/api/esc_parameters_omp.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not OmpInit then OmpInit = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/omp/init.lua") end
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
    Log.emit("rfsuite.omp", msg, level or "debug")
  end
end

local function queueOmpReadActual(queue)
  queue:add({
    command = EscParametersOmpApi.command,
    timeout = 15,
    simulatorResponse = EscParametersOmpApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = EscParametersOmpApi.parse(buf)
      if parsed then
        for k, v in pairs(ui.config) do
          if parsed[k] ~= nil then
            ui.config[k] = parsed[k]
          end
        end

        ui.parsedCache = parsed

        local escModel = OmpInit and type(OmpInit.getEscModel) == "function" and OmpInit.getEscModel(buf) or nil
        local escVersion = OmpInit and type(OmpInit.getEscVersion) == "function" and OmpInit.getEscVersion(buf) or nil
        local escFirmware = OmpInit and type(OmpInit.getEscFirmware) == "function" and OmpInit.getEscFirmware(buf) or nil

        ui.escModel = escModel
        ui.escVersion = escVersion
        ui.escFirmware = escFirmware

        if OmpInit and type(OmpInit.getActiveFields) == "function" then
          ui.activeFields = OmpInit.getActiveFields(buf)
        end

        local session = getSession()
        if session then
          session.setup_esc_motors_esc_tools_omp = {
            config = {},
            parsedCache = ui.parsedCache,
            activeFields = ui.activeFields,
            escModel = escModel,
            escVersion = escVersion,
            escFirmware = escFirmware
          }
          for k, v in pairs(ui.config) do
            session.setup_esc_motors_esc_tools_omp.config[k] = v
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

local function queueOmpRead(isAutoReload)
  if not MspRuntime or not EscParametersOmpApi or type(MspRuntime.getState) ~= "function" then
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

  queueOmpReadActual(queue)
  return true, nil
end

local function queueOmpWrite(requestRebuild)
  if not MspRuntime or not EscParametersOmpApi or type(MspRuntime.getState) ~= "function" then
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
    command = EscParametersOmpApi.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = EscParametersOmpApi.buildWritePayload(writeData),
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
  local cached = session and session.setup_esc_motors_esc_tools_omp or nil
  if type(cached) == "table" and type(cached.config) == "table" then
    for k, v in pairs(ui.config) do
      if cached.config[k] ~= nil then
        ui.config[k] = cached.config[k]
      end
    end
    ui.parsedCache = cached.parsedCache
    ui.activeFields = cached.activeFields
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
  queueOmpRead(false)
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
  local ok, err = queueOmpWrite(ctx and ctx.requestRebuild)
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
  queueOmpRead(false)
  return true
end

-- Helper to check if a field is active in this ESC firmware
local function isFieldActive(pos)
  if not ui.activeFields then return true end
  if not pos then return true end
  return ui.activeFields[pos] ~= 0
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

  local title = "OMP Configurator"
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
    local targetLabel = pageText(i18n, "esc_target", "ESC Target")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, targetLabel, escOptions, escTargetVal, function(val)
      local targetVal = tonumber(val) or 0
      if ui.escTarget ~= targetVal then
        ui.escTarget = targetVal
        ui.connState = 0
        ui.connTimer = nil
        ui.loaded = false
        ui.dirty = false
        queueOmpRead(false)
      end
    end)
    cursorY = cursorY + rowH
  end

  local sectionOptions = {
    { value = 1, label = "Basic" },
    { value = 2, label = "Advanced" },
    { value = 3, label = "Governor" }
  }
  local sectionLabel = pageText(i18n, "esc_section", "Section")
  rowH = Controls.appendComboSelect(children, x, cursorY, w, sectionLabel, sectionOptions, ui.currentSection, function(val)
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
    if isFieldActive(5) then
      local lvBecOpts = {
        { value = 0, label = "6.0V" },
        { value = 1, label = "7.4V" },
        { value = 2, label = "8.4V" }
      }
      local becVoltageLvLabel = pageText(i18n, "esc_bec_voltage_lv", "BEC Voltage (LV)")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, becVoltageLvLabel, lvBecOpts, ui.config.lv_bec_voltage, function(val)
        ui.config.lv_bec_voltage = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(11) then
      local hvBecOpts = {
        { value = 0, label = "6.0V" }, { value = 1, label = "6.2V" }, { value = 2, label = "6.4V" },
        { value = 3, label = "6.6V" }, { value = 4, label = "6.8V" }, { value = 5, label = "7.0V" },
        { value = 6, label = "7.2V" }, { value = 7, label = "7.4V" }, { value = 8, label = "7.6V" },
        { value = 9, label = "7.8V" }, { value = 10, label = "8.0V" }, { value = 11, label = "8.2V" },
        { value = 12, label = "8.4V" }, { value = 13, label = "8.6V" }, { value = 14, label = "8.8V" },
        { value = 15, label = "9.0V" }, { value = 16, label = "9.2V" }, { value = 17, label = "9.4V" },
        { value = 18, label = "9.6V" }, { value = 19, label = "9.8V" }, { value = 20, label = "10.0V" },
        { value = 21, label = "10.2V" }, { value = 22, label = "10.4V" }, { value = 23, label = "10.6V" },
        { value = 24, label = "10.8V" }, { value = 25, label = "11.0V" }, { value = 26, label = "11.2V" },
        { value = 27, label = "11.4V" }, { value = 28, label = "11.6V" }, { value = 29, label = "11.8V" },
        { value = 30, label = "12.0V" }
      }
      local becVoltageHvLabel = pageText(i18n, "esc_bec_voltage_hv", "BEC Voltage (HV)")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, becVoltageHvLabel, hvBecOpts, ui.config.hv_bec_voltage, function(val)
        ui.config.hv_bec_voltage = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(6) then
      local dirOpts = {
        { value = 0, label = "CW" },
        { value = 1, label = "CCW" }
      }
      local motorDirectionLabel = pageText(i18n, "esc_motor_direction", "Motor Direction")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, motorDirectionLabel, dirOpts, ui.config.motor_direction, function(val)
        ui.config.motor_direction = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(12) then
      local spOpts = {
        { value = 0, label = "Low" },
        { value = 1, label = "Medium" },
        { value = 2, label = "High" }
      }
      local startupPowerLabel = pageText(i18n, "esc_startup_power", "Startup Power")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, startupPowerLabel, spOpts, ui.config.startup_power, function(val)
        ui.config.startup_power = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(18) then
      local colorOpts = {
        { value = 0, label = "Red" },
        { value = 1, label = "Yellow" },
        { value = 2, label = "Orange" },
        { value = 3, label = "Green" },
        { value = 4, label = "Jade Green" },
        { value = 5, label = "Blue" },
        { value = 6, label = "Cyan" },
        { value = 7, label = "Purple" },
        { value = 8, label = "Pink" },
        { value = 9, label = "White" }
      }
      local ledColorLabel = pageText(i18n, "esc_led_color", "LED Color")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, ledColorLabel, colorOpts, ui.config.led_color, function(val)
        ui.config.led_color = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(19) then
      local fanOpts = {
        { value = 0, label = "On" },
        { value = 1, label = "Off" }
      }
      local smartFanLabel = pageText(i18n, "esc_smart_fan", "Smart Fan")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, smartFanLabel, fanOpts, ui.config.smart_fan, function(val)
        ui.config.smart_fan = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

  elseif ui.currentSection == 2 then
    -- Advanced Settings
    if isFieldActive(4) then
      local timingOpts = {
        { value = 0, label = "Auto" },
        { value = 1, label = "Low" },
        { value = 2, label = "Medium" },
        { value = 3, label = "High" }
      }
      local motorTimingLabel = pageText(i18n, "esc_motor_timing", "Motor Timing")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, motorTimingLabel, timingOpts, ui.config.timing, function(val)
        ui.config.timing = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(9) then
      local accelOpts = {
        { value = 0, label = "Fast" },
        { value = 1, label = "Normal" },
        { value = 2, label = "Slow" },
        { value = 3, label = "Very Slow" }
      }
      local accelerationLabel = pageText(i18n, "esc_acceleration", "Acceleration")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, accelerationLabel, accelOpts, ui.config.acceleration, function(val)
        ui.config.acceleration = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(14) then
      rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_brake_force", "Brake Force"), {
        min = 0, max = 100, step = 1, suffix = "%",
        get = function() return ui.config.brake_force end,
        set = function(val)
          ui.config.brake_force = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldActive(15) then
      local srOpts = {
        { value = 0, label = "On" },
        { value = 1, label = "Off" }
      }
      local synchronousRectificationLabel = pageText(i18n, "esc_synchronous_rectification", "Synchronous Rectification")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, synchronousRectificationLabel, srOpts, ui.config.sr_function, function(val)
        ui.config.sr_function = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(16) then
      rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_capacity_correction", "Capacity Correction"), {
        min = 0, max = 20, step = 1,
        display = function(val) return tostring(val - 10) .. "%" end,
        get = function() return ui.config.capacity_correction end,
        set = function(val)
          ui.config.capacity_correction = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldActive(10) then
      local restartOpts = {
        { value = 0, label = "Off" },
        { value = 1, label = "90s" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, pageText(i18n, "esc_auto_restart_time", "Auto Restart Time"), restartOpts, ui.config.auto_restart_time, function(val)
        ui.config.auto_restart_time = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(3) or isFieldActive(11) then
      -- Ethos used activeFieldPos = 11 for cell_cutoff in advanced
      local cutoffOpts = {
        { value = 0, label = "Off" },
        { value = 1, label = "2.7V" },
        { value = 2, label = "3.0V" },
        { value = 3, label = "3.2V" },
        { value = 4, label = "3.4V" },
        { value = 5, label = "3.6V" },
        { value = 6, label = "3.8V" }
      }
      local cellCutoffLabel = pageText(i18n, "esc_cell_cutoff", "Cell Cutoff")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, cellCutoffLabel, cutoffOpts, ui.config.cell_cutoff, function(val)
        ui.config.cell_cutoff = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

  elseif ui.currentSection == 3 then
    -- Governor Settings
    if isFieldActive(2) then
      local govOpts = {
        { value = 0, label = "ESC Gov" },
        { value = 1, label = "External Gov" },
        { value = 2, label = "Flybarless Gov" }
      }
      local governorModeLabel = pageText(i18n, "esc_governor_mode", "Governor Mode")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, governorModeLabel, govOpts, ui.config.governor, function(val)
        ui.config.governor = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldActive(7) then
      rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_governor_p_gain", "Governor P Gain"), {
        min = 1, max = 10, step = 1,
        get = function() return ui.config.gov_p end,
        set = function(val)
          ui.config.gov_p = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldActive(8) then
      rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_governor_i_gain", "Governor I Gain"), {
        min = 1, max = 10, step = 1,
        get = function() return ui.config.gov_i end,
        set = function(val)
          ui.config.gov_i = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldActive(17) then
      rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_motor_poles", "Motor Poles"), {
        min = 1, max = 55, step = 1,
        get = function() return ui.config.motor_poles end,
        set = function(val)
          ui.config.motor_poles = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end
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
  EscParametersOmpApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  OmpInit = nil
  t = nil
end

return M
