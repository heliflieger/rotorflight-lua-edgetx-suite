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
local EscParametersScorpionApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ScorpInit = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  config = {
    -- Basic (Section 1)
    esc_mode = 0,
    rotation = 0,
    bec_voltage = 0,
    telemetry_protocol = 0,

    -- Advanced (Section 2)
    soft_start_time = 10000,
    runup_time = 12000,
    bailout = 1500,
    gov_proportional = 100,
    gov_integral = 200,
    motor_startup_sound = 0,

    -- Limits (Section 3)
    protection_delay = 1000,
    cutoff_handling = 5000,
    max_temperature = 12000,
    max_current = 8000,
    min_voltage = 3000,
    max_used = 5000
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
  if not EscParametersScorpionApi then EscParametersScorpionApi = loadModule("tasks/msp/api/esc_parameters_scorpion.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ScorpInit then ScorpInit = loadModule("app/pages/setup/esc_motors/esc_tools/escmfg/scorp/init.lua") end
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
    Log.emit("rfsuite.scorp", msg, level or "debug")
  end
end

-- `retryOnError` is set only for the read that FOLLOWS a write. The firmware invalidates
-- its parameter cache on a successful commit and answers both the read and the next write
-- with an error until a fresh readback from the ESC has been cached, so that first refusal
-- is a wait rather than a failure. The queue already knows how to wait for one.
local function queueScorpionReadActual(queue, retryOnError)
  queue:add({
    command = EscParametersScorpionApi.command,
    timeout = 15,
    retryOnErrorReply = retryOnError or nil,
    simulatorResponse = EscParametersScorpionApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = EscParametersScorpionApi.parse(buf)
      if parsed then
        for k, v in pairs(ui.config) do
          if parsed[k] ~= nil then
            ui.config[k] = parsed[k]
          end
        end

        ui.parsedCache = parsed

        local escModel = ScorpInit and type(ScorpInit.getEscModel) == "function" and ScorpInit.getEscModel(buf) or nil
        local escVersion = ScorpInit and type(ScorpInit.getEscVersion) == "function" and ScorpInit.getEscVersion(buf) or nil
        local escFirmware = ScorpInit and type(ScorpInit.getEscFirmware) == "function" and ScorpInit.getEscFirmware(buf) or nil

        ui.escModel = escModel
        ui.escVersion = escVersion
        ui.escFirmware = escFirmware

        local session = getSession()
        if session then
          session.setup_esc_motors_esc_tools_scorp = {
            config = {},
            parsedCache = ui.parsedCache,
            escModel = escModel,
            escVersion = escVersion,
            escFirmware = escFirmware
          }
          for k, v in pairs(ui.config) do
            session.setup_esc_motors_esc_tools_scorp.config[k] = v
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

local function queueScorpionRead(isAutoReload, retryOnError)
  if not MspRuntime or not EscParametersScorpionApi or type(MspRuntime.getState) ~= "function" then
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

  queueScorpionReadActual(queue, retryOnError)
  return true, nil
end

local function queueScorpionWrite(requestRebuild)
  if not MspRuntime or not EscParametersScorpionApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  -- A Scorpion write is the whole 84-byte block, not the changed fields, so it can only be
  -- built from a block that was read. Without one, every field the page does not itself
  -- carry would be packed as zero and written to the ESC.
  if not ui.parsedCache then
    return false, "esc_not_read"
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

  writeData.esc_signature = writeData.esc_signature or (EscParametersScorpionApi and EscParametersScorpionApi.mspSignature) or 0x53
  writeData.esc_command = 0 -- Required by Scorpion ESC write specification

  ui.saving = true
  if requestRebuild and type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end

  queue:add({
    command = EscParametersScorpionApi.writeCommand,
    timeout = 5,
    maxRetries = 1,
    payload = EscParametersScorpionApi.buildWritePayload(writeData),
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
      queueScorpionRead(true, true)
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
  local cached = session and session.setup_esc_motors_esc_tools_scorp or nil
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
  queueScorpionRead(false)
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
  local ok, err = queueScorpionWrite(ctx and ctx.requestRebuild)
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
  queueScorpionRead(false)
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

  local title = "Scorpion Configurator"
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
        queueScorpionRead(false)
      end
    end)
    cursorY = cursorY + rowH
  end

  local sectionOptions = {
    { value = 1, label = "Basic" },
    { value = 2, label = "Advanced" },
    { value = 3, label = "Limits" }
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
    local modeOpts = {
      { value = 0, label = "Heli Gov" },
      { value = 1, label = "Heli Store" },
      { value = 2, label = "VBar Gov" },
      { value = 3, label = "Ext Gov" },
      { value = 4, label = "Airplane" },
      { value = 5, label = "Boat" },
      { value = 6, label = "Quad" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "ESC Mode", modeOpts, ui.config.esc_mode, function(val)
      ui.config.esc_mode = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local rotOpts = {
      { value = 0, label = "CCW" },
      { value = 1, label = "CW" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Motor Rotation", rotOpts, ui.config.rotation, function(val)
      ui.config.rotation = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local becOpts = {
      { value = 0, label = "5.1 V" },
      { value = 1, label = "6.1 V" },
      { value = 2, label = "7.3 V" },
      { value = 3, label = "8.3 V" },
      { value = 4, label = "Disabled" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "BEC Voltage", becOpts, ui.config.bec_voltage, function(val)
      ui.config.bec_voltage = val
      markDirty()
    end)
    cursorY = cursorY + rowH

    local teleOpts = {
      { value = 0, label = "Standard" },
      { value = 1, label = "VBar" },
      { value = 2, label = "ExBus" },
      { value = 3, label = "Unsolicited" },
      { value = 4, label = "Fut S.Bus" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Telemetry Protocol", teleOpts, ui.config.telemetry_protocol, function(val)
      ui.config.telemetry_protocol = val
      markDirty()
    end)
    cursorY = cursorY + rowH

  elseif ui.currentSection == 2 then
    -- Advanced Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, "Soft Start Time", {
      min = 0, max = 60000, step = 1000,
      display = function(val) return string.format("%ds", math.floor(val / 1000)) end,
      get = function() return ui.config.soft_start_time end,
      set = function(val)
        ui.config.soft_start_time = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Runup Time", {
      min = 0, max = 60000, step = 1000,
      display = function(val) return string.format("%ds", math.floor(val / 1000)) end,
      get = function() return ui.config.runup_time end,
      set = function(val)
        ui.config.runup_time = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Bailout Time", {
      min = 0, max = 100000, step = 1000,
      display = function(val) return string.format("%ds", math.floor(val / 1000)) end,
      get = function() return ui.config.bailout end,
      set = function(val)
        ui.config.bailout = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Governor P Gain", {
      min = 30, max = 180, step = 1,
      display = function(val) return string.format("%.2f", val / 100) end,
      get = function() return ui.config.gov_proportional end,
      set = function(val)
        ui.config.gov_proportional = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Governor I Gain", {
      min = 150, max = 250, step = 1,
      display = function(val) return string.format("%.2f", val / 100) end,
      get = function() return ui.config.gov_integral end,
      set = function(val)
        ui.config.gov_integral = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    local soundOpts = {
      { value = 0, label = "On" },
      { value = 1, label = "Off" }
    }
    rowH = Controls.appendComboSelect(children, x, cursorY, w, "Startup Sound", soundOpts, ui.config.motor_startup_sound, function(val)
      ui.config.motor_startup_sound = val
      markDirty()
    end)
    cursorY = cursorY + rowH

  elseif ui.currentSection == 3 then
    -- Limits Settings
    rowH = Controls.appendNumberField(children, x, cursorY, w, "Protection Delay", {
      min = 0, max = 5000, step = 1000,
      display = function(val) return string.format("%ds", math.floor(val / 1000)) end,
      get = function() return ui.config.protection_delay end,
      set = function(val)
        ui.config.protection_delay = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Cutoff Handling", {
      min = 0, max = 10000, step = 100,
      display = function(val) return string.format("%d%%", math.floor(val / 100)) end,
      get = function() return ui.config.cutoff_handling end,
      set = function(val)
        ui.config.cutoff_handling = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Max Temperature", {
      min = 0, max = 40000, step = 100,
      display = function(val) return string.format("%dC", math.floor(val / 100)) end,
      get = function() return ui.config.max_temperature end,
      set = function(val)
        ui.config.max_temperature = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Max Current", {
      min = 0, max = 30000, step = 100,
      display = function(val) return string.format("%dA", math.floor(val / 100)) end,
      get = function() return ui.config.max_current end,
      set = function(val)
        ui.config.max_current = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Min Voltage", {
      min = 0, max = 7000, step = 100,
      display = function(val) return string.format("%.1fV", val / 100) end,
      get = function() return ui.config.min_voltage end,
      set = function(val)
        ui.config.min_voltage = val
        markDirty()
      end
    })
    cursorY = cursorY + rowH

    rowH = Controls.appendNumberField(children, x, cursorY, w, "Max Capacity Used", {
      min = 0, max = 6000, step = 100,
      display = function(val) return string.format("%.1fAh", val / 100) end,
      get = function() return ui.config.max_used end,
      set = function(val)
        ui.config.max_used = val
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
  EscParametersScorpionApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ScorpInit = nil
  t = nil
end

return M
