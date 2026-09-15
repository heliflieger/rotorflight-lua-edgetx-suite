local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Controls = nil
local SavePipeline = nil
local Common = nil
local MspRuntime = nil
local MotorConfigApi = nil
local FeatureConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  config = {
    motor_pwm_protocol = 0,
    use_dshot_telemetry = 0,
    main_rotor_gear_ratio_0 = 1,
    main_rotor_gear_ratio_1 = 1,
    tail_rotor_gear_ratio_0 = 1,
    tail_rotor_gear_ratio_1 = 1,
    motor_pole_count_0 = 10,
    enabledFeatures = 0
  },
  parsedCache = {},
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil
  }
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not MotorConfigApi then MotorConfigApi = loadModule("tasks/msp/api/motor_config.lua") end
  if not FeatureConfigApi then FeatureConfigApi = loadModule("tasks/msp/api/feature_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_esc_motors") or nil end
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

local function buildSessionSignature()
  local session = getSession()
  return session and session.signature or "1"
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_esc_motors_rpm) ~= "table" then return end
  local cached = session.setup_esc_motors_rpm
  ui.config.motor_pwm_protocol = tonumber(cached.motor_pwm_protocol) or 0
  ui.config.use_dshot_telemetry = tonumber(cached.use_dshot_telemetry) or 0
  ui.config.main_rotor_gear_ratio_0 = tonumber(cached.main_rotor_gear_ratio_0) or 1
  ui.config.main_rotor_gear_ratio_1 = tonumber(cached.main_rotor_gear_ratio_1) or 1
  ui.config.tail_rotor_gear_ratio_0 = tonumber(cached.tail_rotor_gear_ratio_0) or 1
  ui.config.tail_rotor_gear_ratio_1 = tonumber(cached.tail_rotor_gear_ratio_1) or 1
  ui.config.motor_pole_count_0 = tonumber(cached.motor_pole_count_0) or 10
  ui.config.enabledFeatures = tonumber(cached.enabledFeatures) or 0
  ui.parsedCache = cached.parsedCache or {}
end

local function bitIsSet(value, bit)
  local mask = 1 << bit
  return (value & mask) ~= 0
end

local function setBit(value, bit, enabled)
  local mask = 1 << bit
  if enabled then
    return value | mask
  end
  return value & (~mask)
end

local function queueRpmRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not MotorConfigApi or not FeatureConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = type(getSession()) == "table"
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Step 1: Read MOTOR_CONFIG
  queue:add({
    command = MotorConfigApi.command,
    simulatorResponse = MotorConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsedMotor = MotorConfigApi.parse(buf)
      if type(parsedMotor) ~= "table" then return Common.failPageRead(ui) end
      if parsedMotor then
        ui.config.motor_pwm_protocol = parsedMotor.motor_pwm_protocol or 0
        ui.config.use_dshot_telemetry = parsedMotor.use_dshot_telemetry or 0
        ui.config.main_rotor_gear_ratio_0 = parsedMotor.main_rotor_gear_ratio_0 or 1
        ui.config.main_rotor_gear_ratio_1 = parsedMotor.main_rotor_gear_ratio_1 or 1
        ui.config.tail_rotor_gear_ratio_0 = parsedMotor.tail_rotor_gear_ratio_0 or 1
        ui.config.tail_rotor_gear_ratio_1 = parsedMotor.tail_rotor_gear_ratio_1 or 1
        ui.config.motor_pole_count_0 = parsedMotor.motor_pole_count_0 or 10

        ui.parsedCache = parsedMotor
      end

      -- Step 2: Read FEATURE_CONFIG
      queue:add({
        command = FeatureConfigApi.command,
        simulatorResponse = FeatureConfigApi.simulatorResponse,
        processReply = function(self, buf2)
          local parsedFeat = FeatureConfigApi.parse(buf2)
          if type(parsedFeat) ~= "table" then return Common.failPageRead(ui) end
          if parsedFeat then
            ui.config.enabledFeatures = parsedFeat.enabledFeatures or 0
          end

          -- Sync to session
          local session = getSession()
          if session then
            session.setup_esc_motors_rpm = {
              motor_pwm_protocol = ui.config.motor_pwm_protocol,
              use_dshot_telemetry = ui.config.use_dshot_telemetry,
              main_rotor_gear_ratio_0 = ui.config.main_rotor_gear_ratio_0,
              main_rotor_gear_ratio_1 = ui.config.main_rotor_gear_ratio_1,
              tail_rotor_gear_ratio_0 = ui.config.tail_rotor_gear_ratio_0,
              tail_rotor_gear_ratio_1 = ui.config.tail_rotor_gear_ratio_1,
              motor_pole_count_0 = ui.config.motor_pole_count_0,
              enabledFeatures = ui.config.enabledFeatures,
              parsedCache = ui.parsedCache
            }
          end

          ui.runtime.readPending = false
          ui.loading = false
          ui.dirty = false
          ui.progress = 100
          ui.runtime.readComplete = readValid
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        errorHandler = function()
          readValid = false
          ui.runtime.readPending = false
          ui.loading = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    errorHandler = function()
      readValid = false
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueRpmWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not MotorConfigApi or not FeatureConfigApi then
    return false, "msp_runtime_unavailable"
  end

  local writeData = {}
  if ui.parsedCache then
    for k, v in pairs(ui.parsedCache) do
      writeData[k] = v
    end
  end

  writeData.use_dshot_telemetry = ui.config.use_dshot_telemetry
  writeData.main_rotor_gear_ratio_0 = ui.config.main_rotor_gear_ratio_0
  writeData.main_rotor_gear_ratio_1 = ui.config.main_rotor_gear_ratio_1
  writeData.tail_rotor_gear_ratio_0 = ui.config.tail_rotor_gear_ratio_0
  writeData.tail_rotor_gear_ratio_1 = ui.config.tail_rotor_gear_ratio_1
  writeData.motor_pole_count_0 = ui.config.motor_pole_count_0

  -- The chain that stood here cleared the dirty flag inside the REBOOT step's processReply --
  -- the moment the restart was sent, not the moment the settings were stored. It is reported at
  -- the EEPROM acknowledgement now, and everything after it belongs to the pipeline. This page
  -- was also the only one of the nine that dropped its own session cache after the reboot; the
  -- pipeline does that for all of them, from the declaration below.
  return SavePipeline.start({
    pageId = "setup_esc_motors_rpm",
    steps = {
      {
        label = "MSP_SET_MOTOR_CONFIG",
        command = MotorConfigApi.writeCommand,
        payload = MotorConfigApi.buildWritePayload(writeData)
      },
      {
        label = "MSP_SET_FEATURE_CONFIG",
        command = FeatureConfigApi.writeCommand,
        payload = FeatureConfigApi.buildWritePayload({ enabledFeatures = ui.config.enabledFeatures })
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_esc_motors_rpm" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then
        ui.dirty = true
      end
      if type(requestRebuild) == "function" then
        requestRebuild()
      end
    end
  })
end

local function ensureLoaded()
  if ui.loaded then return end

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil,
      syncHeaderTitle = nil
    }
  end

  ui.config = {
    motor_pwm_protocol = 0,
    use_dshot_telemetry = 0,
    main_rotor_gear_ratio_0 = 1,
    main_rotor_gear_ratio_1 = 1,
    tail_rotor_gear_ratio_0 = 1,
    tail_rotor_gear_ratio_1 = 1,
    motor_pole_count_0 = 10,
    enabledFeatures = 0
  }
  ui.parsedCache = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  queueRpmRead(false)
end

function M.onLoad()
  ensureDeps()
  ensureLoaded()
end

function M.onActivate()
  ensureDeps()
  ensureLoaded()
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held
  -- back rather than raised over whatever page the user went to; claim it now.
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_esc_motors_rpm")
  end
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    ensureLoaded()
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    help = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.syncHeaderTitle = ctx and ctx.syncHeaderTitle or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.loading then
    local titleText = "@i18n(app.loading)@"
    local msgText = pageText(i18n, "loading_rpm", "Loading RPM configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "RPM"
  local title = pageText(i18n, "title_rpm", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- 1. RPM Sensor Source
  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    pageText(i18n, "rpm_sensor_source", "RPM Sensor"),
    function() return bitIsSet(ui.config.enabledFeatures or 0, 28) end,
    function(nextBool)
      local oldVal = ui.config.enabledFeatures or 0
      local newVal = setBit(oldVal, 28, nextBool == true)
      if oldVal ~= newVal then
        ui.config.enabledFeatures = newVal
        ui.dirty = true
      end
    end
  )

  -- 2. DShot RPM Telemetry
  local isDshotProto = ui.config.motor_pwm_protocol >= 5 and ui.config.motor_pwm_protocol <= 8
  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    pageText(i18n, "use_dshot_telemetry", "DShot RPM Telemetry"),
    function() return ui.config.use_dshot_telemetry ~= 0 end,
    function(nextBool)
      ui.config.use_dshot_telemetry = nextBool and 1 or 0
      ui.dirty = true
    end,
    function() return isDshotProto end
  )

  -- 3. Main Motor Ratio: Pinion
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "main_motor_ratio", "Main Motor Ratio") .. ": " .. pageText(i18n, "pinion", "Pinion"),
    {
      min = 1,
      max = 50000,
      step = 1,
      get = function() return ui.config.main_rotor_gear_ratio_0 end,
      set = function(v)
        ui.config.main_rotor_gear_ratio_0 = tonumber(v) or 1
        ui.dirty = true
      end
    }
  )

  -- 4. Main Motor Ratio: Main Gear
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "main_motor_ratio", "Main Motor Ratio") .. ": " .. pageText(i18n, "main", "Main"),
    {
      min = 1,
      max = 50000,
      step = 1,
      get = function() return ui.config.main_rotor_gear_ratio_1 end,
      set = function(v)
        ui.config.main_rotor_gear_ratio_1 = tonumber(v) or 1
        ui.dirty = true
      end
    }
  )

  -- 5. Tail Motor Ratio: Rear
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "tail_motor_ratio", "Tail Motor Ratio") .. ": " .. pageText(i18n, "rear", "Rear"),
    {
      min = 1,
      max = 50000,
      step = 1,
      get = function() return ui.config.tail_rotor_gear_ratio_0 end,
      set = function(v)
        ui.config.tail_rotor_gear_ratio_0 = tonumber(v) or 1
        ui.dirty = true
      end
    }
  )

  -- 6. Tail Motor Ratio: Front
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "tail_motor_ratio", "Tail Motor Ratio") .. ": " .. pageText(i18n, "front", "Front"),
    {
      min = 1,
      max = 50000,
      step = 1,
      get = function() return ui.config.tail_rotor_gear_ratio_1 end,
      set = function(v)
        ui.config.tail_rotor_gear_ratio_1 = tonumber(v) or 1
        ui.dirty = true
      end
    }
  )

  -- 7. Motor Pole Count
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "motor_pole_count", "Motor Pole Count"),
    {
      min = 2,
      max = 256,
      step = 2,
      get = function() return ui.config.motor_pole_count_0 end,
      set = function(v)
        ui.config.motor_pole_count_0 = tonumber(v) or 10
        ui.dirty = true
      end
    }
  )

  if ui.dirty then
    children[#children + 1] = {
      type = "label",
      x = x + 16, y = cursorY + 10,
      text = pageText(i18n, "unsaved_changes", "Unsaved changes"),
      color = COLOR_THEME_SECONDARY1,
      font = SMLSIZE
    }
  end
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  local ok, err = queueRpmWrite(ctx and ctx.requestRebuild)
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
  local session = getSession()
  if session then
    ui.dirty = false
    loadFromSession()
    queueRpmRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/esc_motors/rpm/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end


function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  MotorConfigApi = nil
  FeatureConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

return M
