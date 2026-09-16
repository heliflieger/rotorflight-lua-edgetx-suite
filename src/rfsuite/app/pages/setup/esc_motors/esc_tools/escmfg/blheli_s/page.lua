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
local EscParametersBlheliSApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local BlheliSInit = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  config = {
    -- Basic
    motor_direction = 0,
    startup_power = 0,
    commutation_timing = 0,
    demag_compensation = 0,
    brake_on_stop = 0,

    -- Advanced
    temperature_protection = 0,
    beep_strength = 40,
    beacon_strength = 80,
    beacon_delay = 4,

    -- Input
    ppm_min_throttle = 1100,
    ppm_max_throttle = 1900,
    ppm_center_throttle = 1500
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
  if not EscParametersBlheliSApi then EscParametersBlheliSApi = loadModule("tasks/msp/api/esc_parameters_blheli_s.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not BlheliSInit then BlheliSInit = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/blheli_s/init.lua") end
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
    Log.emit("rfsuite.blheli_s", msg, level or "debug")
  end
end

local function queueBlheliReadActual(queue)
  queue:add({
    command = EscParametersBlheliSApi.command,
    timeout = 15,
    simulatorResponse = EscParametersBlheliSApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = EscParametersBlheliSApi.parse(buf)
      if parsed then
        for k, v in pairs(ui.config) do
          if parsed[k] ~= nil then
            ui.config[k] = parsed[k]
          end
        end

        ui.parsedCache = parsed

        local escModel = BlheliSInit and type(BlheliSInit.getEscModel) == "function" and BlheliSInit.getEscModel(buf) or nil
        local escVersion = BlheliSInit and type(BlheliSInit.getEscVersion) == "function" and BlheliSInit.getEscVersion(buf) or nil
        local escFirmware = BlheliSInit and type(BlheliSInit.getEscFirmware) == "function" and BlheliSInit.getEscFirmware(buf) or nil

        ui.escModel = escModel
        ui.escVersion = escVersion
        ui.escFirmware = escFirmware

        local session = getSession()
        if session then
          session.setup_esc_motors_esc_tools_blheli_s = {
            config = {},
            parsedCache = ui.parsedCache,
            escModel = escModel,
            escVersion = escVersion,
            escFirmware = escFirmware
          }
          for k, v in pairs(ui.config) do
            session.setup_esc_motors_esc_tools_blheli_s.config[k] = v
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

local function queueBlheliRead(isAutoReload)
  if not MspRuntime or not EscParametersBlheliSApi or type(MspRuntime.getState) ~= "function" then
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
          ui.runtime.readPending = false -- Allow next wakeup to queue step 2
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
          ui.runtime.readPending = false -- Allow next wakeup to queue read
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
      queueBlheliReadActual(queue)
    else
      -- Waiting for timer in wakeup
      ui.runtime.readPending = false
    end
  else
    queueBlheliReadActual(queue)
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

local function queueBlheliWrite(requestRebuild)
  if not MspRuntime or not EscParametersBlheliSApi or type(MspRuntime.getState) ~= "function" then
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
    command = EscParametersBlheliSApi.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = EscParametersBlheliSApi.buildWritePayload(writeData),
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
  local cached = session and session.setup_esc_motors_esc_tools_blheli_s or nil
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
  queueBlheliRead(false)
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
      queueBlheliRead(false)
    end
  elseif ui.connState == 4 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 5.0 then
      ui.connState = 5
      queueBlheliRead(false)
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
      queueBlheliRead(true) -- Re-read settings from ESC
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
  local ok, err = queueBlheliWrite(ctx and ctx.requestRebuild)
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
  queueBlheliRead(false)
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

  local title = "BLHeli_S Configurator"
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
        queueBlheliRead(false)
      end
    end)
    cursorY = cursorY + rowH
  end

  local sectionOptions = {
    { value = 1, label = "Basic" },
    { value = 2, label = "Advanced" },
    { value = 3, label = "Input" }
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
    local dirOpts = {
      { value = 0, label = "Normal" },
      { value = 1, label = "Reversed" },
      { value = 2, label = "Bidirectional 3D" },
      { value = 3, label = "Bidirectional 3D Rev" }
    }
    local motorDirectionLabel = pageText(i18n, "esc_motor_direction", "Motor Direction")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, motorDirectionLabel, dirOpts, ui.config.motor_direction, function(val)
      ui.config.motor_direction = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local startupPowerOpts = {
      { value = 0, label = "0.031" },
      { value = 1, label = "0.047" },
      { value = 2, label = "0.063" },
      { value = 3, label = "0.094" },
      { value = 4, label = "0.125" },
      { value = 5, label = "0.188" },
      { value = 6, label = "0.25" },
      { value = 7, label = "0.38" },
      { value = 8, label = "0.50" },
      { value = 9, label = "0.75" },
      { value = 10, label = "1.00" },
      { value = 11, label = "1.25" },
      { value = 12, label = "1.50" }
    }
    local startupPowerLabel = pageText(i18n, "esc_startup_power", "Startup Power")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, startupPowerLabel, startupPowerOpts, ui.config.startup_power, function(val)
      ui.config.startup_power = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local timingOpts = {
      { value = 0, label = "Low" },
      { value = 1, label = "Medium Low" },
      { value = 2, label = "Medium" },
      { value = 3, label = "Medium High" },
      { value = 4, label = "High" }
    }
    local motorTimingLabel = pageText(i18n, "esc_motor_timing", "Motor Timing")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, motorTimingLabel, timingOpts, ui.config.commutation_timing, function(val)
      ui.config.commutation_timing = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local demagOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "Low" },
      { value = 2, label = "High" }
    }
    local demagCompensation = pageText(i18n, "esc_demag_compensation", "Demag Compensation")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, demagCompensation, demagOpts, ui.config.demag_compensation, function(val)
      ui.config.demag_compensation = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local brakeOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "On" }
    }
    local brakeOnStopLabel = pageText(i18n, "esc_brake_on_stop", "Brake on Stop")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, brakeOnStopLabel, brakeOpts, ui.config.brake_on_stop, function(val)
      ui.config.brake_on_stop = val
      markDirty()
    end)
    cursorY = cursorY + rowH

  elseif ui.currentSection == 2 then
    -- Advanced Settings
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
    rowH = Controls.appendComboSelect(children, x, cursorY, w, pageText(i18n, "esc_temperature_protection", "Temperature Protection"), tempOpts, ui.config.temperature_protection, function(val)
      ui.config.temperature_protection = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_beep_strength", "Beep Strength"), {
      min = 1, max = 255, step = 1,
      get = function() return ui.config.beep_strength end,
      set = function(val)
        ui.config.beep_strength = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_beacon_strength", "Beacon Strength"), {
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
    local beaconDelayLabel = pageText(i18n, "esc_beacon_delay", "Beacon Delay")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, beaconDelayLabel, beaconDelayOpts, ui.config.beacon_delay, function(val)
      ui.config.beacon_delay = val
      markDirty()
    end)
    cursorY = cursorY + rowH

  elseif ui.currentSection == 3 then
    -- Input Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_ppm_min_throttle", "PPM Min Throttle"), {
      min = 1000, max = 1500, step = 4, suffix = "us",
      get = function() return ui.config.ppm_min_throttle end,
      set = function(val)
        ui.config.ppm_min_throttle = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_ppm_max_throttle", "PPM Max Throttle"), {
      min = 1504, max = 2020, step = 4, suffix = "us",
      get = function() return ui.config.ppm_max_throttle end,
      set = function(val)
        ui.config.ppm_max_throttle = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_ppm_center_throttle", "PPM Center Throttle"), {
      min = 1000, max = 2020, step = 4, suffix = "us",
      get = function() return ui.config.ppm_center_throttle end,
      set = function(val)
        ui.config.ppm_center_throttle = val
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
  -- Release ESC (target 100) on page close to restore normal receiver-to-ESC signals
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
  EscParametersBlheliSApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  BlheliSInit = nil
  t = nil
end

return M
