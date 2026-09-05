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
local EscParametersHw5Api = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local Hw5Profile = nil
local Hw5Init = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  config = {
    -- Basic (Section 1)
    flight_mode = 0,
    rotation = 0,
    bec_voltage = 0,
    lipo_cell_count = 0,
    cutoff_type = 0,
    volt_cutoff_type = 0,
    cutoff_voltage = 3,

    -- Advanced (Section 2)
    gov_p_gain = 6,
    gov_i_gain = 5,
    startup_time = 15,
    restart_time = 1,
    auto_restart = 25,
    timing = 24,
    startup_power = 2,
    active_freewheel = 0,
    response_time = 0,
    brake_type = 0,
    brake_force = 0
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
  if not EscParametersHw5Api then EscParametersHw5Api = loadModule("tasks/msp/api/esc_parameters_hw5.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not Hw5Profile then Hw5Profile = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/hw5/profile.lua") end
  if not Hw5Init then Hw5Init = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/hw5/init.lua") end
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
    Log.emit("rfsuite.hw5", msg, level or "debug")
  end
end

-- `retryOnError` is set only for the read that FOLLOWS a write. The firmware invalidates
-- its parameter cache on a successful commit and answers both the read and the next write
-- with an error until a fresh readback from the ESC has been cached, so that first refusal
-- is a wait rather than a failure. The queue already knows how to wait for one.
local function queueHw5ReadActual(queue, retryOnError)
  queue:add({
    command = EscParametersHw5Api.command,
    timeout = 15,
    retryOnErrorReply = retryOnError or nil,
    simulatorResponse = EscParametersHw5Api.simulatorResponse,
    processReply = function(self, buf)
      local parsed = EscParametersHw5Api.parse(buf)
      if parsed then
        for k, v in pairs(ui.config) do
          if parsed[k] ~= nil then
            ui.config[k] = parsed[k]
          end
        end

        ui.parsedCache = parsed

        local escModel = Hw5Init and type(Hw5Init.getEscModel) == "function" and Hw5Init.getEscModel(buf) or nil
        if not escModel or escModel == "" then
          escModel = (parsed.esc_type2 or "") .. " " .. (parsed.esc_type or "")
        end
        local escVersion = Hw5Init and type(Hw5Init.getEscVersion) == "function" and Hw5Init.getEscVersion(buf) or nil
        if not escVersion or escVersion == "" then
          escVersion = parsed.hardware_version
        end
        local escFirmware = Hw5Init and type(Hw5Init.getEscFirmware) == "function" and Hw5Init.getEscFirmware(buf) or nil
        if not escFirmware or escFirmware == "" then
          escFirmware = parsed.firmware_version
        end

        ui.escModel = escModel
        ui.escVersion = escVersion
        ui.escFirmware = escFirmware

        local session = getSession()
        if session then
          session.escDetails = {
            version = escVersion,
            model = escModel,
            firmware = escFirmware
          }
          session.setup_esc_motors_esc_tools_hw5 = {
            config = {},
            parsedCache = ui.parsedCache,
            escModel = escModel,
            escVersion = escVersion,
            escFirmware = escFirmware
          }
          for k, v in pairs(ui.config) do
            session.setup_esc_motors_esc_tools_hw5.config[k] = v
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

local function queueHw5Read(isAutoReload, retryOnError)
  if not MspRuntime or not EscParametersHw5Api or type(MspRuntime.getState) ~= "function" then
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

  queueHw5ReadActual(queue, retryOnError)
  return true, nil
end

local function queueHw5Write(requestRebuild)
  if not MspRuntime or not EscParametersHw5Api or type(MspRuntime.getState) ~= "function" then
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
    command = EscParametersHw5Api.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = EscParametersHw5Api.buildWritePayload(writeData),
    isWrite = true,
    processReply = function(self, buf)
      ui.dirty = false
      ui.saving = false
      ui.progress = 100
      if requestRebuild and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
      -- Read back what was just written. Two reasons, and the second is the one that is
      -- easy to miss: the values on screen are now unconfirmed, AND the flight
      -- controller cannot accept another write until it has re-cached the parameters
      -- from the ESC. This read is what makes it do that.
      queueHw5Read(true, true)
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
  local cached = session and session.setup_esc_motors_esc_tools_hw5 or nil
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
  queueHw5Read(false)
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
  local ok, err = queueHw5Write(ctx and ctx.requestRebuild)
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
  queueHw5Read(false)
  return true
end

local function isFieldAllowed(apikey, sectionKey)
  if not Hw5Profile then return true end
  return Hw5Profile.isFieldAllowed(apikey)
end

local function getFieldOptions(apikey, fallbackList)
  if not Hw5Profile then return fallbackList or {} end
  local profile = Hw5Profile.getProfile()
  local tables = profile and profile.tables or {}
  local list = tables[apikey]
  if not list then
    local defaultProfile = Hw5Profile.PROFILES and Hw5Profile.PROFILES.default or {}
    local defaultTables = defaultProfile.tables or {}
    list = defaultTables[apikey]
  end

  if not list then
    return fallbackList or {}
  end

  local options = {}
  for i, label in ipairs(list) do
    options[i] = { value = i - 1, label = label }
  end
  return options
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

  local title = "Hobbywing V5 Configurator"
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
    local model = (ui.escModel and ui.escModel ~= "" and ui.escModel)
               or (ui.parsedCache and ui.parsedCache.model_name and ui.parsedCache.model_name ~= "" and ui.parsedCache.model_name)
    if model and model ~= title then
      if string.find(string.lower(model), string.lower(title), 1, true) then
        headerTitle = model
      else
        headerTitle = title .. " - " .. model
      end
    end
    Controls.appendStaticSectionHeader(children, x, cursorY, w, headerTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  if Controls and type(Controls.appendEscSubheader) == "function" then
    local fw = ui.escFirmware or (ui.parsedCache and ui.parsedCache.firmware_version)
    local ver = ui.escVersion or (ui.parsedCache and ui.parsedCache.hardware_version)
    cursorY = cursorY + Controls.appendEscSubheader(children, x, cursorY, w, fw, ver)
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
        queueHw5Read(false)
      end
    end)
    cursorY = cursorY + rowH
  end

  local sectionOptions = {
    { value = 1, label = "Basic" },
    { value = 2, label = "Advanced" }
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
    if isFieldAllowed("flight_mode") then
      local fmOpts = {
        { value = 0, label = "Fixed-wing" },
        { value = 1, label = "Heli (Linear Throttle)" },
        { value = 2, label = "Heli (Elf Gov)" },
        { value = 3, label = "Heli (Store Gov)" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Flight Mode", fmOpts, ui.config.flight_mode, function(val)
        ui.config.flight_mode = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("rotation") then
      local rotOpts = getFieldOptions("rotation", {
        { value = 0, label = "CW" },
        { value = 1, label = "CCW" }
      })
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Rotation", rotOpts, ui.config.rotation, function(val)
        ui.config.rotation = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("bec_voltage") then
      local becOpts = getFieldOptions("bec_voltage")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "BEC Voltage", becOpts, ui.config.bec_voltage, function(val)
        ui.config.bec_voltage = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("lipo_cell_count") then
      local lipoOpts = getFieldOptions("lipo_cell_count")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Lipo Cells", lipoOpts, ui.config.lipo_cell_count, function(val)
        ui.config.lipo_cell_count = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("cutoff_type") then
      local cutoffTypeOpts = {
        { value = 0, label = "Soft Cutoff" },
        { value = 1, label = "Hard Cutoff" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Cutoff Type", cutoffTypeOpts, ui.config.cutoff_type or ui.config.volt_cutoff_type or 0, function(val)
        ui.config.cutoff_type = val
        ui.config.volt_cutoff_type = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("cutoff_voltage") then
      local cutoffVoltsOpts = getFieldOptions("cutoff_voltage")
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Cutoff Voltage", cutoffVoltsOpts, ui.config.cutoff_voltage, function(val)
        ui.config.cutoff_voltage = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

  elseif ui.currentSection == 2 then
    -- Advanced Settings
    if isFieldAllowed("gov_p_gain") then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Governor P Gain", {
        min = 0, max = 9, step = 1,
        get = function() return ui.config.gov_p_gain end,
        set = function(val)
          ui.config.gov_p_gain = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("gov_i_gain") then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Governor I Gain", {
        min = 0, max = 9, step = 1,
        get = function() return ui.config.gov_i_gain end,
        set = function(val)
          ui.config.gov_i_gain = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("startup_time") then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Startup Time", {
        min = 4, max = 25, step = 1, suffix = "s",
        get = function() return ui.config.startup_time end,
        set = function(val)
          ui.config.startup_time = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("auto_restart") then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Auto Restart Time", {
        min = 0, max = 90, step = 1, suffix = "s",
        get = function() return ui.config.auto_restart end,
        set = function(val)
          ui.config.auto_restart = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("restart_time") then
      local restartOpts = {
        { value = 0, label = "1s" },
        { value = 1, label = "1.5s" },
        { value = 2, label = "2s" },
        { value = 3, label = "2.5s" },
        { value = 4, label = "3s" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Restart Time", restartOpts, ui.config.restart_time, function(val)
        ui.config.restart_time = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("timing") then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Motor Timing", {
        min = 0, max = 30, step = 1, suffix = "deg",
        get = function() return ui.config.timing end,
        set = function(val)
          ui.config.timing = val
          markDirty()
        end
      })
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("startup_power") then
      local powerOpts = {
        { value = 0, label = "1" },
        { value = 1, label = "2" },
        { value = 2, label = "3" },
        { value = 3, label = "4" },
        { value = 4, label = "5" },
        { value = 5, label = "6" },
        { value = 6, label = "7" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Startup Power", powerOpts, ui.config.startup_power, function(val)
        ui.config.startup_power = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("active_freewheel") then
      local afOpts = {
        { value = 0, label = "Enabled" },
        { value = 1, label = "Disabled" }
      }
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Active Freewheel", afOpts, ui.config.active_freewheel, function(val)
        ui.config.active_freewheel = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("response_time") then
      local respOpts = getFieldOptions("response_time", {
        { value = 0, label = "1" },
        { value = 1, label = "2" },
        { value = 2, label = "3" },
        { value = 3, label = "4" },
        { value = 4, label = "5" },
        { value = 5, label = "6" },
        { value = 6, label = "7" },
        { value = 7, label = "8" },
        { value = 8, label = "9" },
        { value = 9, label = "10" }
      })
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Response Time", respOpts, ui.config.response_time, function(val)
        ui.config.response_time = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("brake_type") then
      local brakeOpts = getFieldOptions("brake_type", {
        { value = 0, label = "Disabled" },
        { value = 1, label = "Normal" },
        { value = 2, label = "Proportional" },
        { value = 3, label = "Reverse" }
      })
      rowH = Controls.appendComboSelect(children, x, cursorY, w, "Brake Type", brakeOpts, ui.config.brake_type, function(val)
        ui.config.brake_type = val
        markDirty()
      end)
      cursorY = cursorY + rowH
    end

    if isFieldAllowed("brake_force") then
      rowH = Controls.appendNumberField(children, x, cursorY, w, "Brake Force", {
        min = 0, max = 100, step = 1, suffix = "%",
        get = function() return ui.config.brake_force end,
        set = function(val)
          ui.config.brake_force = val
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
  EscParametersHw5Api = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  Hw5Profile = nil
  Hw5Init = nil
  t = nil
end

return M
