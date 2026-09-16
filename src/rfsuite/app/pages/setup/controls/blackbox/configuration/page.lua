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
local Common = nil
local MspRuntime = nil
local BlackboxConfigApi = nil
local FeatureConfigApi = nil
local StatusApi = nil
local DebugConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local t = nil

local DEBUG_MODES = {
  [0] = "NONE",
  [1] = "CYCLETIME",
  [2] = "BATTERY",
  [3] = "GYRO_FILTERED",
  [4] = "ACCELEROMETER",
  [5] = "PIDLOOP",
  [6] = "GYRO_RAW",
  [7] = "HUT",
  [8] = "RC_INTERPOLATION",
  [9] = "ANGLERATE",
  [10] = "ESC_SENSOR",
  [11] = "SCHEDULER",
  [12] = "STACK",
  [13] = "ESC_SENSOR_RPM",
  [14] = "ESC_SENSOR_TMP",
  [15] = "ALTITUDE",
  [16] = "THREADS",
  [17] = "REMOTERX",
  [18] = "GYRO_NOTCH",
  [19] = "ACC_DIFFERENTIAL",
  [20] = "PWM",
  [21] = "DSHOT_TELEMETRY",
  [22] = "GREETING",
  [23] = "AIRMODE",
  [24] = "PARITY",
  [25] = "RX_FRSKY_SPI",
  [26] = "RUNAWAY_TAKEOFF",
  [27] = "ALIGNMENT",
  [28] = "SPEED_LIMITING",
  [29] = "SENSORS",
  [30] = "BOXES",
  [31] = "CRSF_LINK_STATISTICS",
  [32] = "DSHOT_RPM",
  [33] = "RPM_FILTER",
  [34] = "DSHOT_BIND",
  [35] = "FLIGHT_ANGLERATE",
  [36] = "DEDICATED_HID",
  [37] = "CRSF_LINK_STATISTICS_HYBRID",
  [38] = "CRSF_PACKET_TIMES",
  [39] = "SMARTPORT",
  [40] = "IBUS_TELEMETRY",
  [41] = "FPORT_TELEMETRY",
  [42] = "CROSSFIRE_TELEMETRY",
  [43] = "GHST_TELEMETRY",
  [44] = "LTM_TELEMETRY",
  [45] = "SERIAL_RX",
  [46] = "ESC_COMMAND",
  [47] = "ACC_RAW",
  [48] = "COMPASS",
  [49] = "MSP_PROBE",
  [50] = "TIMING",
  [51] = "RC_COMMAND",
  [52] = "VOLTAGE_CORRECTION"
}

local ui = {
  loaded = false,
  dirty = false,
  featureBitmap = 0,
  pidDeltaUs = 1000,
  cfg = {
    blackbox_supported = 0,
    device = 0,
    mode = 0,
    denom = 8,
    fields = 0,
    initialEraseFreeSpaceKiB = 0,
    rollingErase = 0,
    gracePeriod = 5
  },
  debug = {
    debug_count = 8,
    debug_value_count = 8,
    debug_mode = 0,
    debug_axis = 0
  },
  media = {
    dataflashSupported = true,
    sdcardSupported = true
  },
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil
  },
  loading = false,
  progress = 0,
  baseTitle = nil
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not BlackboxConfigApi then BlackboxConfigApi = loadModule("tasks/msp/api/blackbox_config.lua") end
  if not FeatureConfigApi then FeatureConfigApi = loadModule("tasks/msp/api/feature_config.lua") end
  if not StatusApi then StatusApi = loadModule("tasks/msp/api/status.lua") end
  if not DebugConfigApi then DebugConfigApi = loadModule("tasks/msp/api/debug_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_blackbox") or nil end
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

local function canEdit()
  return ui.loaded and tonumber(ui.cfg.blackbox_supported or 0) == 1
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.blackbox) ~= "table" or type(session.blackbox.config) ~= "table" then return false end
  ui.featureBitmap = tonumber(session.blackbox.feature and session.blackbox.feature.enabledFeatures or 0) or 0
  ui.pidDeltaUs = tonumber(session.blackbox.pidDeltaUs or 1000) or 1000
  local parsed = session.blackbox.config
  ui.cfg.blackbox_supported = tonumber(parsed.blackbox_supported or 0) or 0
  ui.cfg.device = tonumber(parsed.device or 0) or 0
  ui.cfg.mode = tonumber(parsed.mode or 0) or 0
  ui.cfg.denom = tonumber(parsed.denom or 1) or 1
  ui.cfg.fields = tonumber(parsed.fields or 0) or 0
  ui.cfg.initialEraseFreeSpaceKiB = tonumber(parsed.initialEraseFreeSpaceKiB or 0) or 0
  ui.cfg.rollingErase = tonumber(parsed.rollingErase or 0) or 0
  ui.cfg.gracePeriod = tonumber(parsed.gracePeriod or 0) or 0

  local dbg = session.blackbox.debug or nil
  if dbg then
    ui.debug.debug_count = tonumber(dbg.debug_count or 8) or 8
    ui.debug.debug_value_count = tonumber(dbg.debug_value_count or 8) or 8
    ui.debug.debug_mode = tonumber(dbg.debug_mode or 0) or 0
    ui.debug.debug_axis = tonumber(dbg.debug_axis or 0) or 0
  end

  local media = session.blackbox.media or nil
  if media then
    ui.media.dataflashSupported = media.dataflashSupported ~= false
    ui.media.sdcardSupported = media.sdcardSupported ~= false
  end
  return true
end

local function queueBlackboxRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not BlackboxConfigApi or not FeatureConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = true
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  local step2, step3, step4, finalizeRead

  -- Step 1: Read STATUS
  local function step1()
    if not ui.runtime or not ui.runtime.readPending then return end
    if StatusApi then
      queue:add({
        command = StatusApi.command,
        simulatorResponse = StatusApi.simulatorResponse,
        processReply = function(self, buf)
          if not ui.runtime or not ui.runtime.readPending then return end
          local status = StatusApi.parse(buf)
          if type(status) ~= "table" then return Common.failPageRead(ui) end
          if status and status.task_delta_time_pid then
            ui.pidDeltaUs = status.task_delta_time_pid
          end
          step2()
        end,
        errorHandler = function()
          readValid = false
          if not ui.runtime or not ui.runtime.readPending then return end
          step2()
        end
      })
    else
      step2()
    end
  end

  -- Step 2: Read FEATURE_CONFIG
  function step2()
    if not ui.runtime or not ui.runtime.readPending then return end
    queue:add({
      command = FeatureConfigApi.command,
      simulatorResponse = FeatureConfigApi.simulatorResponse,
      processReply = function(self, buf)
        if not ui.runtime or not ui.runtime.readPending then return end
        local reply = FeatureConfigApi.parse(buf)
        if type(reply) ~= "table" then return Common.failPageRead(ui) end
        ui.featureBitmap = (reply and reply.enabledFeatures) or 0
        step3()
      end,
      errorHandler = function()
        readValid = false
        if not ui.runtime or not ui.runtime.readPending then return end
        step3()
      end
    })
  end

  -- Step 3: Read BLACKBOX_CONFIG
  function step3()
    if not ui.runtime or not ui.runtime.readPending then return end
    queue:add({
      command = BlackboxConfigApi.command,
      simulatorResponse = BlackboxConfigApi.simulatorResponse,
      processReply = function(self, buf)
        if not ui.runtime or not ui.runtime.readPending then return end
        local parsed = BlackboxConfigApi.parse(buf)
        if type(parsed) ~= "table" then return Common.failPageRead(ui) end
        if parsed then
          ui.cfg.blackbox_supported = parsed.blackbox_supported or 0
          ui.cfg.device = parsed.device or 0
          ui.cfg.mode = parsed.mode or 0
          ui.cfg.denom = parsed.denom or 1
          ui.cfg.fields = parsed.fields or 0
          ui.cfg.initialEraseFreeSpaceKiB = parsed.initialEraseFreeSpaceKiB or 0
          ui.cfg.rollingErase = parsed.rollingErase or 0
          ui.cfg.gracePeriod = parsed.gracePeriod or 0
        end
        step4()
      end,
      errorHandler = function()
        readValid = false
        if not ui.runtime or not ui.runtime.readPending then return end
        step4()
      end
    })
  end

  -- Step 4: Read DEBUG_CONFIG
  function step4()
    if not ui.runtime or not ui.runtime.readPending then return end
    if DebugConfigApi then
      queue:add({
        command = DebugConfigApi.command,
        simulatorResponse = DebugConfigApi.simulatorResponse,
        processReply = function(self, buf)
          if not ui.runtime or not ui.runtime.readPending then return end
          local parsed = DebugConfigApi.parse(buf)
          if type(parsed) ~= "table" then return Common.failPageRead(ui) end
          if parsed then
            ui.debug.debug_count = parsed.debug_count or 8
            ui.debug.debug_value_count = parsed.debug_value_count or 8
            ui.debug.debug_mode = parsed.debug_mode or 0
            ui.debug.debug_axis = parsed.debug_axis or 0
          end
          finalizeRead()
        end,
        errorHandler = function()
          readValid = false
          if not ui.runtime or not ui.runtime.readPending then return end
          finalizeRead()
        end
      })
    else
      finalizeRead()
    end
  end

  -- Finalize Read
  function finalizeRead()
    if not ui.runtime or not ui.runtime.readPending then return end
    -- Sync to session
    local session = getSession()
    if session then
      if type(session.blackbox) ~= "table" then
        session.blackbox = {}
      end
      session.blackbox.feature = { enabledFeatures = ui.featureBitmap }
      session.blackbox.config = {
        blackbox_supported = ui.cfg.blackbox_supported,
        device = ui.cfg.device,
        mode = ui.cfg.mode,
        denom = ui.cfg.denom,
        fields = ui.cfg.fields,
        initialEraseFreeSpaceKiB = ui.cfg.initialEraseFreeSpaceKiB,
        rollingErase = ui.cfg.rollingErase,
        gracePeriod = ui.cfg.gracePeriod
      }
      session.blackbox.media = {
        dataflashSupported = ui.media.dataflashSupported,
        sdcardSupported = ui.media.sdcardSupported
      }
      session.blackbox.debug = {
        debug_count = ui.debug.debug_count,
        debug_value_count = ui.debug.debug_value_count,
        debug_mode = ui.debug.debug_mode,
        debug_axis = ui.debug.debug_axis
      }
      session.blackbox.pidDeltaUs = ui.pidDeltaUs
    end

    ui.runtime.readPending = false
    ui.loading = false
    ui.dirty = false
    ui.progress = 100
    ui.runtime.readComplete = readValid
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  step1()
  return true, nil
end

local function queueBlackboxWrite(requestRebuild)
  if not MspRuntime or not BlackboxConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local payload = BlackboxConfigApi.buildWritePayload({
    device = ui.cfg.device,
    mode = ui.cfg.mode,
    denom = ui.cfg.denom,
    fields = ui.cfg.fields,
    initialEraseFreeSpaceKiB = ui.cfg.initialEraseFreeSpaceKiB,
    rollingErase = ui.cfg.rollingErase,
    gracePeriod = ui.cfg.gracePeriod
  })

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end

  local writeEEPROM

  -- Step 1: Write BLACKBOX_CONFIG
  queue:add({
    command = BlackboxConfigApi.writeCommand,
    payload = payload,
    isWrite = true,
    simulatorResponse = {},
    processReply = function()
      -- Step 2: Write DEBUG_CONFIG (if available)
      if DebugConfigApi then
        queue:add({
          command = DebugConfigApi.writeCommand,
          payload = DebugConfigApi.buildWritePayload({
            debug_mode = ui.debug.debug_mode,
            debug_axis = ui.debug.debug_axis
          }),
          isWrite = true,
          simulatorResponse = {},
          processReply = function()
            writeEEPROM()
          end,
          errorHandler = function()
            writeEEPROM()
          end
        })
      else
        writeEEPROM()
      end
    end,
    errorHandler = function()
      ui.saving = false
      if type(requestRebuild) == "function" then
        requestRebuild()
      end
    end
  })

  -- Write EEPROM
  function writeEEPROM()
    local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
    if eepromApi then
      queue:add({
        command = eepromApi.writeCommand,
        payload = {},
        isWrite = true,
        simulatorResponse = {},
        processReply = function()
          -- Success! Update local session
          local session = getSession()
          if session then
            if type(session.blackbox) ~= "table" then
              session.blackbox = {}
            end
            session.blackbox.config = {
              blackbox_supported = ui.cfg.blackbox_supported,
              device = ui.cfg.device,
              mode = ui.cfg.mode,
              denom = ui.cfg.denom,
              fields = ui.cfg.fields,
              initialEraseFreeSpaceKiB = ui.cfg.initialEraseFreeSpaceKiB,
              rollingErase = ui.cfg.rollingErase,
              gracePeriod = ui.cfg.gracePeriod
            }
            session.blackbox.debug = {
              debug_count = ui.debug.debug_count,
              debug_value_count = ui.debug.debug_value_count,
              debug_mode = ui.debug.debug_mode,
              debug_axis = ui.debug.debug_axis
            }
            session.blackbox.media = {
              dataflashSupported = ui.media.dataflashSupported,
              sdcardSupported = ui.media.sdcardSupported
            }
          end
          ui.dirty = false
          ui.saving = false
          queueBlackboxRead(true)
        end,
        errorHandler = function()
          ui.saving = false
          if type(requestRebuild) == "function" then
            requestRebuild()
          end
        end
      })
    else
      ui.dirty = false
      ui.saving = false
      if type(requestRebuild) == "function" then
        requestRebuild()
      end
    end
  end

  return true, nil
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
  ui.loading = false
  ui.saving = false
  ui.runtime.readPending = false

  ui.cfg = {
    blackbox_supported = 0,
    device = 0,
    mode = 0,
    denom = 8,
    fields = 0,
    initialEraseFreeSpaceKiB = 0,
    rollingErase = 0,
    gracePeriod = 5
  }
  ui.debug = {
    debug_count = 8,
    debug_value_count = 8,
    debug_mode = 0,
    debug_axis = 0
  }
  ui.pidDeltaUs = 1000

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  queueBlackboxRead(false)
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

  if ui.loading or ui.saving then
    local titleText = ui.loading and "@i18n(app.loading)@" or "@i18n(app.saving)@"
    local msgText = ui.loading and pageText(i18n, "loading", "Loading blackbox configuration...") or pageText(i18n, "saving", "Saving blackbox configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Configuration"
  local title = pageText(i18n, "title", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local edit = canEdit()
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isV12_0_8 = rawApiVersion and ApiVersion and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 8})

  -- Device options
  local deviceOptions = {
    { label = pageText(i18n, "device_disabled", "Disabled"), value = 0 }
  }
  if ui.media.dataflashSupported then
    deviceOptions[#deviceOptions + 1] = { label = pageText(i18n, "device_onboard_flash", "Onboard Flash"), value = 1 }
  end
  if ui.media.sdcardSupported then
    deviceOptions[#deviceOptions + 1] = { label = pageText(i18n, "device_sdcard", "SD Card"), value = 2 }
  end
  deviceOptions[#deviceOptions + 1] = { label = pageText(i18n, "device_serial_port", "Serial Port"), value = 3 }

  -- Mode options
  local modeOptions = {
    { label = pageText(i18n, "mode_off", "Off"), value = 0 },
    { label = pageText(i18n, "mode_normal", "Normal"), value = 1 },
    { label = pageText(i18n, "mode_armed", "Armed"), value = 2 },
    { label = pageText(i18n, "mode_switch", "Switch"), value = 3 }
  }

  -- Denom options
  local function formatRateHz(denom)
    local d = tonumber(denom or 1) or 1
    if d < 1 then d = 1 end
    local base = 1000000 / (ui.pidDeltaUs or 1000)
    local hz = base / d
    if math.floor(hz) == hz then
      return string.format("%dHz", hz)
    end
    return string.format("%.1fHz", hz)
  end

  local function getDenomOptions(currentDenom)
    local presets = {1, 2, 4, 10, 20, 40, 100}
    local options = {}
    local seen = false
    local current = tonumber(currentDenom or 1) or 1
    if current < 1 then current = 1 end

    for i = 1, #presets do
      local d = presets[i]
      if d == current then seen = true end
      options[#options + 1] = { label = formatRateHz(d), value = d }
    end

    if not seen then
      local customFmt = pageText(i18n, "rate_custom", "Custom %s [1/%d]")
      local label = string.format(customFmt, formatRateHz(current), current)
      options[#options + 1] = { label = label, value = current }
    end

    return options
  end

  -- Check if value is present in options
  local function isValuePresent(opts, val)
    for i = 1, #opts do
      if opts[i].value == val then return true end
    end
    return false
  end

  if not isValuePresent(deviceOptions, ui.cfg.device) then
    ui.cfg.device = 0
  end

  -- 1. Logging device
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "device", "Logging device"),
    deviceOptions,
    ui.cfg.device,
    function(v)
      ui.cfg.device = tonumber(v) or 0
      ui.dirty = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    { active = function() return edit end }
  )

  -- 2. Logging mode
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "logging_mode", "Logging mode"),
    modeOptions,
    ui.cfg.mode,
    function(v)
      ui.cfg.mode = tonumber(v) or 0
      ui.dirty = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    { active = function() return edit end }
  )

  -- 3. Logging rate
  local denomOpts = getDenomOptions(ui.cfg.denom)
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "logging_rate", "Logging rate"),
    denomOpts,
    ui.cfg.denom,
    function(v)
      ui.cfg.denom = tonumber(v) or 8
      ui.dirty = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    { active = function() return edit end }
  )

  -- 4. Disarm grace period
  local isGraceEnabled = edit and ui.cfg.device ~= 0 and (ui.cfg.mode == 1 or ui.cfg.mode == 2) and isV12_0_8
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "disarm_grace_period", "Disarm grace period"),
    {
      min = 0,
      max = 255,
      suffix = "s",
      active = function() return isGraceEnabled == true end,
      get = function() return ui.cfg.gracePeriod end,
      set = function(v)
        ui.cfg.gracePeriod = tonumber(v) or 5
        ui.dirty = true
      end
    }
  )

  -- 5. Initial erase
  local isOnboardFlashActive = edit and ui.cfg.device == 1 and isV12_0_8
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "initial_erase", "Initial erase"),
    {
      min = 0,
      max = 65535,
      suffix = "KiB",
      active = function() return isOnboardFlashActive == true end,
      get = function() return ui.cfg.initialEraseFreeSpaceKiB end,
      set = function(v)
        ui.cfg.initialEraseFreeSpaceKiB = tonumber(v) or 0
        ui.dirty = true
      end
    }
  )

  -- 6. Rolling erase
  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    pageText(i18n, "rolling_erase", "Rolling erase"),
    function()
      return tonumber(ui.cfg.rollingErase or 0) == 1
    end,
    function(v)
      ui.cfg.rollingErase = v and 1 or 0
      ui.dirty = true
    end,
    function() return isOnboardFlashActive == true end
  )

  -- 7. Debug Mode
  local debugModeOptions = {}
  local debugCount = tonumber(ui.debug.debug_count) or 8
  if debugCount < 1 then debugCount = 8 end
  for i = 0, debugCount - 1 do
    local label = DEBUG_MODES[i] or ("Custom " .. tostring(i))
    debugModeOptions[#debugModeOptions + 1] = { label = label, value = i }
  end

  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "debug_mode", "Debug Mode"),
    debugModeOptions,
    ui.debug.debug_mode,
    function(v)
      ui.debug.debug_mode = tonumber(v) or 0
      ui.dirty = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    { active = function() return edit end }
  )

  -- 8. Debug Selection (Axis)
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "debug_selection", "Debug Selection"),
    {
      min = 0,
      max = 255,
      step = 1,
      get = function() return ui.debug.debug_axis end,
      set = function(v)
        ui.debug.debug_axis = tonumber(v) or 0
        ui.dirty = true
      end,
      enabled = edit
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
  local ok, err = queueBlackboxWrite(ctx and ctx.requestRebuild)
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
    queueBlackboxRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/blackbox/configuration/help.lua")
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
  BlackboxConfigApi = nil
  FeatureConfigApi = nil
  StatusApi = nil
  DebugConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

return M
