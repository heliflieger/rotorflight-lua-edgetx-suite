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
local EscParametersYgeApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local YgeInit = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  config = {
    -- Basic (Section 1)
    governor = 0,
    lv_bec_voltage = 55,
    auto_restart_time = 0,
    cell_cutoff = 0,
    current_limit = 10000,
    -- Flag bits (mapped to/from U8 flags field)
    flags_direction = 0,
    flags_f3cauto = 0,
    flags_keepmah = 0,
    flags_bec12v = 0,

    -- Advanced (Section 2)
    acceleration = 0,
    min_start_power = 0,
    max_start_power = 0,
    throttle_response = 0,
    timing = 0,
    active_freewheel = 0,

    -- Other (Section 3)
    gov_p = 5,
    gov_i = 5,
    motor_poll_pairs = 1,
    main_teeth = 1,
    pinion_teeth = 1,
    stick_zero_us = 1000,
    stick_range_us = 1000
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
  if not EscParametersYgeApi then EscParametersYgeApi = loadModule("tasks/msp/api/esc_parameters_yge.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  -- The model table, which this page used to keep a second copy of. Loaded the way the omp,
  -- xdfly and ztw pages already load their own init module.
  if not YgeInit then YgeInit = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/yge/init.lua") end
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
    Log.emit("rfsuite.yge", msg, level or "debug")
  end
end

local function unpackFlags(flagsVal)
  ui.config.flags_direction = (flagsVal >> 0) & 1
  ui.config.flags_f3cauto = (flagsVal >> 1) & 1
  ui.config.flags_keepmah = (flagsVal >> 2) & 1
  ui.config.flags_bec12v = (flagsVal >> 3) & 1
end

local function packFlags()
  local f = 0
  if ui.config.flags_direction == 1 then f = f | (1 << 0) end
  if ui.config.flags_f3cauto == 1 then f = f | (1 << 1) end
  if ui.config.flags_keepmah == 1 then f = f | (1 << 2) end
  if ui.config.flags_bec12v == 1 then f = f | (1 << 3) end
  return f
end

local function queueYgeReadActual(queue)
  queue:add({
    command = EscParametersYgeApi.command,
    timeout = 15,
    simulatorResponse = EscParametersYgeApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = EscParametersYgeApi.parse(buf)
      if parsed then
        for k, v in pairs(ui.config) do
          if parsed[k] ~= nil then
            ui.config[k] = parsed[k]
          end
        end

        unpackFlags(parsed.flags or 0)

        ui.parsedCache = parsed

        local escModel = YgeInit and type(YgeInit.getEscModel) == "function" and YgeInit.getEscModel(buf) or nil
        local escVersion = YgeInit and type(YgeInit.getEscVersion) == "function" and YgeInit.getEscVersion(buf) or nil
        local escFirmware = YgeInit and type(YgeInit.getEscFirmware) == "function" and YgeInit.getEscFirmware(buf) or nil

        ui.escModel = escModel
        ui.escVersion = escVersion
        ui.escFirmware = escFirmware

        local session = getSession()
        if session then
          session.setup_esc_motors_esc_tools_yge = {
            config = {},
            parsedCache = ui.parsedCache,
            escModel = escModel,
            escVersion = escVersion,
            escFirmware = escFirmware
          }
          for k, v in pairs(ui.config) do
            session.setup_esc_motors_esc_tools_yge.config[k] = v
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

local function queueYgeRead(isAutoReload)
  if not MspRuntime or not EscParametersYgeApi or type(MspRuntime.getState) ~= "function" then
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

  queueYgeReadActual(queue)
  return true, nil
end

local function queueYgeWrite(requestRebuild)
  if not MspRuntime or not EscParametersYgeApi or type(MspRuntime.getState) ~= "function" then
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

  writeData.flags = packFlags()

  ui.saving = true
  if requestRebuild and type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end

  queue:add({
    command = EscParametersYgeApi.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = EscParametersYgeApi.buildWritePayload(writeData),
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
  local cached = session and session.setup_esc_motors_esc_tools_yge or nil
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

local function supports12vBec()
  local typeId = ui.parsedCache and ui.parsedCache.esc_type
  if not typeId or not YgeInit then return false end
  local models = YgeInit.escModels
  local model = type(models) == "table" and models[typeId] or nil
  return model ~= nil and model.bec12v == true
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
  queueYgeRead(false)
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
  local ok, err = queueYgeWrite(ctx and ctx.requestRebuild)
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
  queueYgeRead(false)
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

  local title = "YGE Configurator"
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
        queueYgeRead(false)
      end
    end)
    cursorY = cursorY + rowH
  end

  local sectionOptions = {
    { value = 1, label = "Basic" },
    { value = 2, label = "Advanced" },
    { value = 3, label = "Other" }
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
    local modeOpts = {
      { value = 0, label = "Mode Free" },
      { value = 1, label = "Mode Ext" },
      { value = 2, label = "Mode Heli" },
      { value = 3, label = "Mode Store" },
      { value = 4, label = "Mode Glider" },
      { value = 5, label = "Mode Air" },
      { value = 6, label = "Mode F3A" }
    }
    local governorModeLabel = pageText(i18n, "esc_governor_mode", "Governor Mode")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, governorModeLabel, modeOpts, ui.config.governor, function(val)
      ui.config.governor = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local rotOpts = {
      { value = 0, label = "Normal" },
      { value = 1, label = "Reverse" }
    }
    local directionLabel = pageText(i18n, "esc_direction", "Direction")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, directionLabel, rotOpts, ui.config.flags_direction, function(val)
      ui.config.flags_direction = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local maxVal = 84
    if supports12vBec() then
      maxVal = 120
    end

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_bec_voltage", "BEC Voltage"), {
      min = 55, max = maxVal, step = 1,
      display = function(val) return string.format("%.1fV", val / 10) end,
      get = function() return ui.config.lv_bec_voltage end,
      set = function(val)
        ui.config.lv_bec_voltage = val
        if val == 120 then
          ui.config.flags_bec12v = 1
        else
          ui.config.flags_bec12v = 0
        end
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    local autoRestartOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "Slowdown" },
      { value = 2, label = "Cutoff" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, pageText(i18n, "esc_auto_restart_type", "Auto Restart Type"), autoRestartOpts, ui.config.auto_restart_time, function(val)
      ui.config.auto_restart_time = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local cutoffOpts = {
      { value = 0, label = "2.9 V" },
      { value = 1, label = "3.0 V" },
      { value = 2, label = "3.1 V" },
      { value = 3, label = "3.2 V" },
      { value = 4, label = "3.3 V" },
      { value = 5, label = "3.4 V" }
    }
    local cellCutoffLabel = pageText(i18n, "esc_cell_cutoff", "Cell Cutoff")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, cellCutoffLabel, cutoffOpts, ui.config.cell_cutoff, function(val)
      ui.config.cell_cutoff = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_current_limit", "Current Limit"), {
      min = 1, max = 65500, step = 100,
      display = function(val) return string.format("%.2fA", val / 100) end,
      get = function() return ui.config.current_limit end,
      set = function(val)
        ui.config.current_limit = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    local f3cOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "On" }
    }
    local f3cAutoLabel = pageText(i18n, "esc_f3c_auto", "F3C Auto")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, f3cAutoLabel, f3cOpts, ui.config.flags_f3cauto, function(val)
      ui.config.flags_f3cauto = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    -- Bit 2 of the flags byte, which unpackFlags and packFlags have always carried; it simply
    -- had no row. Without one the bit is read off the ESC and written straight back, so the
    -- setting could be seen in the ESC's own tool and not here.
    local keepMahOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "On" }
    }
    local keepMahLabel = pageText(i18n, "esc_keep_mah", "Keep mAh")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, keepMahLabel, keepMahOpts, ui.config.flags_keepmah, function(val)
      ui.config.flags_keepmah = val
      markDirty()
    end)
    cursorY = cursorY + rowH

  elseif ui.currentSection == 2 then
    -- Advanced Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_min_start_power", "Min Start Power"), {
      min = 0, max = 26, step = 1, suffix = "%",
      get = function() return ui.config.min_start_power end,
      set = function(val)
        ui.config.min_start_power = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_max_start_power", "Max Start Power"), {
      min = 0, max = 31, step = 1, suffix = "%",
      get = function() return ui.config.max_start_power end,
      set = function(val)
        ui.config.max_start_power = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    -- `acceleration` in the field spec, and the same word of the parameter block that the
    -- older Lua suite draws as `Startup Response` -- it sits between max start power and
    -- throttle response there too. The ESC takes two values.
    local startupOpts = {
      { value = 0, label = "Normal" },
      { value = 1, label = "Smooth" }
    }
    local startupResponseLabel = pageText(i18n, "esc_startup_response", "Startup Response")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, startupResponseLabel, startupOpts, ui.config.acceleration, function(val)
      ui.config.acceleration = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local respOpts = {
      { value = 0, label = "Slow" },
      { value = 1, label = "Medium" },
      { value = 2, label = "Fast" },
      { value = 3, label = "Custom" }
    }
    local throttleResponseLabel = pageText(i18n, "esc_throttle_response", "Throttle Response")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, throttleResponseLabel, respOpts, ui.config.throttle_response, function(val)
      ui.config.throttle_response = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local timingOpts = {
      { value = 0, label = "Auto Normal" },
      { value = 1, label = "Auto Efficient" },
      { value = 2, label = "Auto Power" },
      { value = 3, label = "Auto Extreme" },
      { value = 4, label = "0 deg" },
      { value = 5, label = "6 deg" },
      { value = 6, label = "12 deg" },
      { value = 7, label = "18 deg" },
      { value = 8, label = "24 deg" },
      { value = 9, label = "30 deg" }
    }
    local motorTimingLabel = pageText(i18n, "esc_motor_timing", "Motor Timing")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, motorTimingLabel, timingOpts, ui.config.timing, function(val)
      ui.config.timing = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local fwOpts = {
      { value = 0, label = "Off" },
      { value = 1, label = "Auto" },
      { value = 2, label = "Unused" },
      { value = 3, label = "Always On" }
    }
    local activeFreewheelLabel = pageText(i18n, "esc_active_freewheel", "Active Freewheel")
    rowH = Controls.appendComboSelect(children, x, cursorY, w, activeFreewheelLabel, fwOpts, ui.config.active_freewheel, function(val)
      ui.config.active_freewheel = val
      markDirty()
    end)
    cursorY = cursorY + rowH

  elseif ui.currentSection == 3 then
    -- Other Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_governor_p_gain", "Governor P Gain"), {
      min = 1, max = 10, step = 1,
      get = function() return ui.config.gov_p end,
      set = function(val)
        ui.config.gov_p = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_governor_i_gain", "Governor I Gain"), {
      min = 1, max = 10, step = 1,
      get = function() return ui.config.gov_i end,
      set = function(val)
        ui.config.gov_i = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_motor_pole_pairs", "Motor Pole Pairs"), {
      min = 1, max = 100, step = 1,
      get = function() return ui.config.motor_poll_pairs end,
      set = function(val)
        ui.config.motor_poll_pairs = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_main_gear_teeth", "Main Gear Teeth"), {
      min = 1, max = 1800, step = 1,
      get = function() return ui.config.main_teeth end,
      set = function(val)
        ui.config.main_teeth = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_pinion_teeth", "Pinion Teeth"), {
      min = 1, max = 255, step = 1,
      get = function() return ui.config.pinion_teeth end,
      set = function(val)
        ui.config.pinion_teeth = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_stick_zero", "Stick Zero"), {
      min = 900, max = 1900, step = 10, suffix = "us",
      get = function() return ui.config.stick_zero_us end,
      set = function(val)
        ui.config.stick_zero_us = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "esc_stick_range", "Stick Range"), {
      min = 600, max = 1500, step = 10, suffix = "us",
      get = function() return ui.config.stick_range_us end,
      set = function(val)
        ui.config.stick_range_us = val
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
  EscParametersYgeApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  YgeInit = nil
  t = nil
end

return M
