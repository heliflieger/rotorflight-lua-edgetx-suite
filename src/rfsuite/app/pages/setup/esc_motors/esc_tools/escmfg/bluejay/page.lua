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
local EscParametersBluejayApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local BluejayInit = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  config = {
    -- Basic / General
    motor_direction = 0,
    rpm_power_slope = 0,
    startup_power_min = 1000,
    startup_power_max = 1300,
    pwm_frequency = 0,

    -- Advanced / Brake
    commutation_timing = 0,
    demag_compensation = 0,
    brake_on_stop = 0,
    braking_strength = 0,
    led_control = 0,

    -- Beacon
    beep_strength = 40,
    beacon_strength = 80,
    beacon_delay = 4,
    startup_beep = 0,

    -- Other
    temperature_protection = 0,
    low_rpm_power_protection = 0,
    power_rating = 0,
    force_edt_arm = 0,
    dithering = 0,
    threshold_96to48 = 0,
    threshold_48to24 = 0
  },
  currentSection = 1,
  parsedCache = nil,
  layoutRevision = nil,
  supportsLedControl = false,
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
  if not EscParametersBluejayApi then EscParametersBluejayApi = loadModule("tasks/msp/api/esc_parameters_bluejay.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not BluejayInit then BluejayInit = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/bluejay/init.lua") end
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
    Log.emit("rfsuite.bluejay", msg, level or "debug")
  end
end

local function queueBluejayReadActual(queue)
  queue:add({
    command = EscParametersBluejayApi.command,
    timeout = 15,
    simulatorResponse = EscParametersBluejayApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = EscParametersBluejayApi.parse(buf)
      if parsed then
        for k, v in pairs(ui.config) do
          if parsed[k] ~= nil then
            ui.config[k] = parsed[k]
          end
        end

        ui.parsedCache = parsed
        ui.layoutRevision = buf and buf[5] or nil

        local escModel = BluejayInit and type(BluejayInit.getEscModel) == "function" and BluejayInit.getEscModel(buf) or nil
        local escVersion = BluejayInit and type(BluejayInit.getEscVersion) == "function" and BluejayInit.getEscVersion(buf) or nil
        local escFirmware = BluejayInit and type(BluejayInit.getEscFirmware) == "function" and BluejayInit.getEscFirmware(buf) or nil

        ui.escModel = escModel
        ui.escVersion = escVersion
        ui.escFirmware = escFirmware

        if BluejayInit and type(BluejayInit.supportsLedControl) == "function" then
          ui.supportsLedControl = BluejayInit.supportsLedControl(buf)
        else
          ui.supportsLedControl = false
        end

        local session = getSession()
        if session then
          session.setup_esc_motors_esc_tools_bluejay = {
            config = {},
            parsedCache = ui.parsedCache,
            layoutRevision = ui.layoutRevision,
            supportsLedControl = ui.supportsLedControl,
            escModel = escModel,
            escVersion = escVersion,
            escFirmware = escFirmware
          }
          for k, v in pairs(ui.config) do
            session.setup_esc_motors_esc_tools_bluejay.config[k] = v
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

local function queueBluejayRead(isAutoReload)
  if not MspRuntime or not EscParametersBluejayApi or type(MspRuntime.getState) ~= "function" then
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

  local FwdProgApi = loadModule("tasks/msp/api/4wif_esc_fwd_prog.lua")
  if FwdProgApi then
    if not ui.connState or ui.connState == 0 then
      ui.connState = 1
      -- Step 1: Write target reset (100)
      queue:add({
        command = FwdProgApi.writeCommand,
        payload = FwdProgApi.buildWritePayload({ target = 100 }),
        isWrite = true,
        simulatorResponse = {},
        processReply = function()
          if not ui.runtime then return end
          ui.connState = 2
          ui.connTimer = nowSeconds()
          ui.runtime.readPending = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        errorHandler = function()
          if not ui.runtime then return end
          ui.connState = 0
          ui.loading = false
          ui.runtime.readPending = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    elseif ui.connState == 3 then
      -- Step 2: Write actual target
      queue:add({
        command = FwdProgApi.writeCommand,
        payload = FwdProgApi.buildWritePayload({ target = ui.escTarget or 0 }),
        isWrite = true,
        simulatorResponse = {},
        processReply = function()
          if not ui.runtime then return end
          ui.connState = 4
          ui.connTimer = nowSeconds()
          ui.runtime.readPending = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        errorHandler = function()
          if not ui.runtime then return end
          ui.connState = 0
          ui.loading = false
          ui.runtime.readPending = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    elseif ui.connState == 5 then
      queueBluejayReadActual(queue)
    else
      ui.runtime.readPending = false
    end
  else
    queueBluejayReadActual(queue)
  end

  return true, nil
end

local function queuePostSaveReset(target, nextState)
  local FwdProgApi = loadModule("tasks/msp/api/4wif_esc_fwd_prog.lua")
  if not FwdProgApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return
  end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue then return end

  queue:add({
    command = FwdProgApi.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = FwdProgApi.buildWritePayload({ target = target }),
    isWrite = true,
    simulatorResponse = {},
    processReply = function()
      ui.connState = nextState
      ui.connTimer = nowSeconds()
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      ui.connState = 5
      ui.saving = false
      ui.notice = {
        title = pageText(ui.i18n, "save_failed_title", "Save Failed"),
        message = pageText(ui.i18n, "save_failed_message", "ESC did not respond / write timed out.")
      }
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function queueBluejayWrite(requestRebuild)
  if not MspRuntime or not EscParametersBluejayApi or type(MspRuntime.getState) ~= "function" then
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
    command = EscParametersBluejayApi.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = EscParametersBluejayApi.buildWritePayload(writeData),
    isWrite = true,
    processReply = function(self, buf)
      ui.dirty = false
      ui.connState = 6
      ui.connTimer = nowSeconds()
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
  local cached = session and session.setup_esc_motors_esc_tools_bluejay or nil
  if type(cached) == "table" and type(cached.config) == "table" then
    for k, v in pairs(ui.config) do
      if cached.config[k] ~= nil then
        ui.config[k] = cached.config[k]
      end
    end
    ui.parsedCache = cached.parsedCache
    ui.layoutRevision = cached.layoutRevision
    ui.supportsLedControl = cached.supportsLedControl
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

  if not loadFromSession() then
    ui.layoutRevision = nil
    ui.supportsLedControl = false
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
  queueBluejayRead(false)
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

  -- 4way target switch delay timing and post-save cycle
  if ui.connState == 2 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 2.5 then
      ui.connState = 3
      queueBluejayRead(false)
    end
  elseif ui.connState == 4 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 5.0 then
      ui.connState = 5
      queueBluejayRead(false)
    end
  elseif ui.connState == 6 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 1.0 then
      ui.connState = 7
      queuePostSaveReset(100, 8)
    end
  elseif ui.connState == 8 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 1.0 then
      ui.connState = 9
      queuePostSaveReset(ui.escTarget or 0, 10)
    end
  elseif ui.connState == 10 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 0.5 then
      ui.connState = 5
      ui.saving = false
      queueBluejayRead(true)
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
  local ok, err = queueBluejayWrite(ctx and ctx.requestRebuild)
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
  ui.connState = 0
  ui.connTimer = nil
  queueBluejayRead(false)
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

  local title = "Bluejay Configurator"
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
        queueBluejayRead(false)
      end
    end)
    cursorY = cursorY + rowH
  end

  local sectionOptions = {
    { value = 1, label = "General" },
    { value = 2, label = "Brake" },
    { value = 3, label = "Beacon" },
    { value = 4, label = "Other" }
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
    -- General Settings
    local dirOpts = {
      { value = 0, label = "Normal" },
      { value = 1, label = "Reversed" },
      { value = 2, label = "Forward/Reverse (3D)" },
      { value = 3, label = "Forward/Reverse (3D) Rev" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Motor Direction", dirOpts, ui.config.motor_direction, function(val)
      ui.config.motor_direction = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    -- Rampup Power slope configuration
    if ui.layoutRevision == nil or ui.layoutRevision <= 200 then
      local startPowerOpts = {
        { value = 1, label = "0.5% (0.031)" },
        { value = 7, label = "5% (0.25)" },
        { value = 8, label = "7% (0.38)" },
        { value = 9, label = "10% (0.50)" },
        { value = 10, label = "15% (0.75)" },
        { value = 11, label = "20% (1.00)" },
        { value = 12, label = "24% (1.25)" },
        { value = 13, label = "29% (1.50)" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Rampup Start Power", startPowerOpts, ui.config.rpm_power_slope, function(val)
        ui.config.rpm_power_slope = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    else
      local rampPowerOpts = {
        { value = 1, label = "1x (More protection)" },
        { value = 2, label = "2x" },
        { value = 3, label = "3x" },
        { value = 4, label = "4x" },
        { value = 5, label = "5x" },
        { value = 6, label = "6x" },
        { value = 7, label = "7x" },
        { value = 8, label = "8x" },
        { value = 9, label = "9x" },
        { value = 10, label = "10x" },
        { value = 11, label = "11x" },
        { value = 12, label = "12x" },
        { value = 13, label = "13x (Less protection)" },
        { value = 0, label = "Off" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Rampup Power", rampPowerOpts, ui.config.rpm_power_slope, function(val)
        ui.config.rpm_power_slope = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Min Startup Power", {
      min = 1000, max = 1125, step = 5,
      get = function() return ui.config.startup_power_min end,
      set = function(val)
        ui.config.startup_power_min = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    if ui.layoutRevision == nil or ui.layoutRevision >= 201 then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Max Startup Power", {
        min = 1004, max = 1300, step = 4,
        get = function() return ui.config.startup_power_max end,
        set = function(val)
          ui.config.startup_power_max = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    local showPwmFrequency = (ui.layoutRevision == nil) or (ui.layoutRevision == 205) or (ui.layoutRevision >= 209)
    if showPwmFrequency then
      local pwmOpts = {}
      if ui.layoutRevision ~= nil and ui.layoutRevision >= 209 then
        pwmOpts = {
          { value = 24, label = "24kHz" },
          { value = 48, label = "48kHz" },
          { value = 96, label = "96kHz" },
          { value = 0, label = "Dynamic" }
        }
      else
        pwmOpts = {
          { value = 24, label = "24kHz" },
          { value = 48, label = "48kHz" },
          { value = 96, label = "96kHz" }
        }
      end
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "PWM Frequency", pwmOpts, ui.config.pwm_frequency, function(val)
        ui.config.pwm_frequency = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

  elseif ui.currentSection == 2 then
    -- Brake Settings
    local timingOpts = {
      { value = 0, label = "0 deg (Low)" },
      { value = 1, label = "7.5 deg (Medium Low)" },
      { value = 2, label = "15 deg (Medium)" },
      { value = 3, label = "22.5 deg (Medium High)" },
      { value = 4, label = "30 deg (High)" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Motor Timing", timingOpts, ui.config.commutation_timing, function(val)
      ui.config.commutation_timing = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local demagOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "Low" },
      { value = 2, label = "High" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Demag Compensation", demagOpts, ui.config.demag_compensation, function(val)
      ui.config.demag_compensation = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local brakeOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "On" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Brake on Stop", brakeOpts, ui.config.brake_on_stop, function(val)
      ui.config.brake_on_stop = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    if ui.layoutRevision == 202 then
      local brakingModeOpts = {
        { value = 0, label = "Off" },
        { value = 1, label = "Not during startup" },
        { value = 2, label = "On" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Braking Mode", brakingModeOpts, ui.config.braking_strength, function(val)
        ui.config.braking_strength = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    elseif ui.layoutRevision ~= nil and ui.layoutRevision >= 204 then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Braking Strength", {
        min = 0, max = 255, step = 1,
        get = function() return ui.config.braking_strength end,
        set = function(val)
          ui.config.braking_strength = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if ui.supportsLedControl then
      local ledOpts = {
        { value = 0x00, label = "Off" },
        { value = 0x03, label = "Blue" },
        { value = 0x0C, label = "Green" },
        { value = 0x30, label = "Red" },
        { value = 0x0F, label = "Cyan" },
        { value = 0x33, label = "Magenta" },
        { value = 0x3C, label = "Yellow" },
        { value = 0x3F, label = "White" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "LED Control", ledOpts, ui.config.led_control, function(val)
        ui.config.led_control = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

  elseif ui.currentSection == 3 then
    -- Beacon Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, "Beep Strength", {
      min = 1, max = 255, step = 1,
      get = function() return ui.config.beep_strength end,
      set = function(val)
        ui.config.beep_strength = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Beacon Strength", {
      min = 1, max = 255, step = 1,
      get = function() return ui.config.beacon_strength end,
      set = function(val)
        ui.config.beacon_strength = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    local beaconDelayOpts = {
      { value = 0, label = "1 minute" },
      { value = 1, label = "2 minutes" },
      { value = 2, label = "5 minutes" },
      { value = 3, label = "10 minutes" },
      { value = 4, label = "Infinite" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Beacon Delay", beaconDelayOpts, ui.config.beacon_delay, function(val)
      ui.config.beacon_delay = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local showStartupBeep = (ui.layoutRevision == nil) or (ui.layoutRevision <= 202) or (ui.layoutRevision == 205)
    if showStartupBeep then
      if ui.layoutRevision == 205 then
        local startupBeepOpts = {
          { value = 0, label = "Off" },
          { value = 1, label = "Normal" },
          { value = 2, label = "Custom" }
        }
        rowH = Controls.appendComboSelect(children, x, cursorY, w, "Startup Beep", startupBeepOpts, ui.config.startup_beep, function(val)
          ui.config.startup_beep = val
          markDirty()
        end)
        cursorY = cursorY + rowH
      else
        local startupBeepOpts = {
          { value = 0, label = "Off" },
          { value = 1, label = "On" }
        }
        rowH = Controls.appendComboSelect(children, x, cursorY, w, "Startup Beep", startupBeepOpts, ui.config.startup_beep, function(val)
          ui.config.startup_beep = val
          markDirty()
        end)
        cursorY = cursorY + rowH
      end
    end

  elseif ui.currentSection == 4 then
    -- Other Settings
    local tempOpts = {
      { value = 0, label = "Disabled" },
      { value = 1, label = "80C" },
      { value = 2, label = "90C" },
      { value = 3, label = "100C" },
      { value = 4, label = "110C" },
      { value = 5, label = "120C" },
      { value = 6, label = "130C" },
      { value = 7, label = "140C" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Temperature Protection", tempOpts, ui.config.temperature_protection, function(val)
      ui.config.temperature_protection = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    if ui.layoutRevision == nil or ui.layoutRevision <= 200 then
      local lowRpmOpts = {
        { value = 0, label = "Off" },
        { value = 1, label = "On" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Low RPM Power Protection", lowRpmOpts, ui.config.low_rpm_power_protection, function(val)
        ui.config.low_rpm_power_protection = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if ui.layoutRevision ~= nil and ui.layoutRevision >= 206 then
      local powerOpts = {
        { value = 0, label = "1S" },
        { value = 1, label = "2S+" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Power Rating", powerOpts, ui.config.power_rating, function(val)
        ui.config.power_rating = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if ui.layoutRevision ~= nil and ui.layoutRevision >= 207 then
      local edtOpts = {
        { value = 0, label = "Off" },
        { value = 1, label = "On" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Force EDT Arm", edtOpts, ui.config.force_edt_arm, function(val)
        ui.config.force_edt_arm = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if ui.layoutRevision == nil or ui.layoutRevision <= 207 then
      local ditherOpts = {
        { value = 0, label = "Off" },
        { value = 1, label = "On" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Dithering", ditherOpts, ui.config.dithering, function(val)
        ui.config.dithering = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if ui.layoutRevision ~= nil and ui.layoutRevision >= 209 then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Threshold 96to48", {
        min = 0, max = 100, step = 1, suffix = "%",
        get = function() return ui.config.threshold_96to48 end,
        set = function(val)
          ui.config.threshold_96to48 = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH

      rowH = Controls.appendNumberField(children, x, cursorY, w, "Threshold 48to24", {
        min = 0, max = 100, step = 1, suffix = "%",
        get = function() return ui.config.threshold_48to24 end,
        set = function(val)
          ui.config.threshold_48to24 = val
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
  -- Release ESC (target 100) on page close
  local FwdProgApi = loadModule("tasks/msp/api/4wif_esc_fwd_prog.lua")
  if FwdProgApi and MspRuntime and type(MspRuntime.getState) == "function" then
    local mspState = MspRuntime.getState()
    local queue = mspState and mspState.queue
    if queue then
      queue:add({
        command = FwdProgApi.writeCommand,
        payload = FwdProgApi.buildWritePayload({ target = 100 }),
        isWrite = true,
        simulatorResponse = {},
        processReply = function() end,
        errorHandler = function() end
      })
    end
  end

  ui.connState = nil
  ui.connTimer = nil
  ui.escTarget = nil
  ui.motorCount = nil
  ui.layoutRevision = nil
  ui.supportsLedControl = false
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
  EscParametersBluejayApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  BluejayInit = nil
  t = nil
end

return M
