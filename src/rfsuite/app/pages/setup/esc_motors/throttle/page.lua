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
    motor_pwm_rate = 250,
    mincommand = 1000,
    minthrottle = 1070,
    maxthrottle = 2000,
    use_unsynced_pwm = 0
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
  if not session or type(session.setup_esc_motors_throttle) ~= "table" then return end
  local cached = session.setup_esc_motors_throttle
  ui.config.motor_pwm_protocol = tonumber(cached.motor_pwm_protocol) or 0
  ui.config.motor_pwm_rate = tonumber(cached.motor_pwm_rate) or 250
  ui.config.mincommand = tonumber(cached.mincommand) or 1000
  ui.config.minthrottle = tonumber(cached.minthrottle) or 1070
  ui.config.maxthrottle = tonumber(cached.maxthrottle) or 2000
  ui.config.use_unsynced_pwm = tonumber(cached.use_unsynced_pwm) or 0
  ui.parsedCache = cached.parsedCache or {}
end

local function queueThrottleRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not MotorConfigApi or type(MspRuntime.getState) ~= "function" then
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

  queue:add({
    command = MotorConfigApi.command,
    simulatorResponse = MotorConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MotorConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.motor_pwm_protocol = parsed.motor_pwm_protocol or 0
        ui.config.motor_pwm_rate = parsed.motor_pwm_rate or 250
        ui.config.mincommand = parsed.mincommand or 1000
        ui.config.minthrottle = parsed.minthrottle or 1070
        ui.config.maxthrottle = parsed.maxthrottle or 2000
        ui.config.use_unsynced_pwm = parsed.use_unsynced_pwm or 0

        ui.parsedCache = parsed

        local session = getSession()
        if session then
          session.setup_esc_motors_throttle = {
            motor_pwm_protocol = ui.config.motor_pwm_protocol,
            motor_pwm_rate = ui.config.motor_pwm_rate,
            mincommand = ui.config.mincommand,
            minthrottle = ui.config.minthrottle,
            maxthrottle = ui.config.maxthrottle,
            use_unsynced_pwm = ui.config.use_unsynced_pwm,
            parsedCache = ui.parsedCache
          }
        end
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

  return true, nil
end

local function queueThrottleWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not MotorConfigApi then
    return false, "msp_runtime_unavailable"
  end

  local writeData = {}
  if ui.parsedCache then
    for k, v in pairs(ui.parsedCache) do
      writeData[k] = v
    end
  end

  writeData.motor_pwm_protocol = ui.config.motor_pwm_protocol
  writeData.motor_pwm_rate = ui.config.motor_pwm_rate
  writeData.mincommand = ui.config.mincommand
  writeData.minthrottle = ui.config.minthrottle
  writeData.maxthrottle = ui.config.maxthrottle
  writeData.use_unsynced_pwm = ui.config.use_unsynced_pwm

  -- The chain that stood here cleared the dirty flag inside the REBOOT step's processReply --
  -- the moment the restart was sent, not the moment the settings were stored. It is reported at
  -- the EEPROM acknowledgement now, and everything after it belongs to the pipeline.
  return SavePipeline.start({
    pageId = "setup_esc_motors_throttle",
    steps = {
      {
        label = "MSP_SET_MOTOR_CONFIG",
        command = MotorConfigApi.writeCommand,
        payload = MotorConfigApi.buildWritePayload(writeData)
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_esc_motors_throttle" },
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
    motor_pwm_rate = 250,
    mincommand = 1000,
    minthrottle = 1070,
    maxthrottle = 2000,
    use_unsynced_pwm = 0
  }
  ui.parsedCache = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  queueThrottleRead(false)
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
    SavePipeline.takeResult("setup_esc_motors_throttle")
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

local function isPwmRateEnabled(proto, hasCastle)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == 9 then return true end
  return false
end

local function isMincommandEnabled(proto, hasCastle)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == 9 then return true end
  return false
end

local function isMinthrottleEnabled(proto, hasCastle)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == 9 then return true end
  return false
end

local function isMaxthrottleEnabled(proto, hasCastle)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == 9 then return true end
  return false
end

local function isUnsyncedEnabled(proto, hasCastle)
  if proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  return false
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
    local msgText = pageText(i18n, "loading", "Loading throttle configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Throttle"
  local title = pageText(i18n, "title_throttle", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local hasCastle = false
  if rawApiVersion and ApiVersion then
    hasCastle = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 7})
  end

  local protocolOptions = {}
  local protocolValues = {}
  if hasCastle then
    protocolValues = {"PWM", "ONESHOT125", "ONESHOT42", "MULTISHOT", "BRUSHED", "DSHOT150", "DSHOT300", "DSHOT600", "PROSHOT", "CASTLE", "DISABLED"}
  else
    protocolValues = {"PWM", "ONESHOT125", "ONESHOT42", "MULTISHOT", "BRUSHED", "DSHOT150", "DSHOT300", "DSHOT600", "PROSHOT", "DISABLED"}
  end
  for idx, val in ipairs(protocolValues) do
    protocolOptions[idx] = { label = val, value = idx - 1 }
  end

  local proto = ui.config.motor_pwm_protocol

  -- 1. Throttle Protocol
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "throttle_protocol", "Throttle Protocol"),
    protocolOptions,
    proto,
    function(newVal)
      local val = tonumber(newVal) or 0
      if ui.config.motor_pwm_protocol ~= val then
        ui.config.motor_pwm_protocol = val
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  )

  -- 2. Update frequency
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "motor_pwm_rate", "Update frequency"),
    {
      min = 50,
      max = 8000,
      suffix = "Hz",
      active = function() return isPwmRateEnabled(proto, hasCastle) end,
      get = function() return ui.config.motor_pwm_rate end,
      set = function(v)
        ui.config.motor_pwm_rate = tonumber(v) or 250
        ui.dirty = true
      end
    }
  )

  -- 3. Motor Stop PWM Value
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "mincommand", "Motor Stop PWM Value"),
    {
      min = 50,
      max = 2250,
      suffix = "us",
      active = function() return isMincommandEnabled(proto, hasCastle) end,
      get = function() return ui.config.mincommand end,
      set = function(v)
        ui.config.mincommand = tonumber(v) or 1000
        ui.dirty = true
      end
    }
  )

  -- 4. 0% Throttle PWM Value
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "min_throttle", "0% Throttle PWM Value"),
    {
      min = 50,
      max = 2250,
      suffix = "us",
      active = function() return isMinthrottleEnabled(proto, hasCastle) end,
      get = function() return ui.config.minthrottle end,
      set = function(v)
        ui.config.minthrottle = tonumber(v) or 1070
        ui.dirty = true
      end
    }
  )

  -- 5. 100% Throttle PWM Value
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "max_throttle", "100% Throttle PWM Value"),
    {
      min = 50,
      max = 2250,
      suffix = "us",
      active = function() return isMaxthrottleEnabled(proto, hasCastle) end,
      get = function() return ui.config.maxthrottle end,
      set = function(v)
        ui.config.maxthrottle = tonumber(v) or 2000
        ui.dirty = true
      end
    }
  )

  -- 6. Unsynced ESC Update
  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    pageText(i18n, "unsynced", "Unsynced ESC Update"),
    function() return ui.config.use_unsynced_pwm ~= 0 end,
    function(nextBool)
      ui.config.use_unsynced_pwm = nextBool and 1 or 0
      ui.dirty = true
    end,
    function() return isUnsyncedEnabled(proto, hasCastle) end
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
  local ok, err = queueThrottleWrite(ctx and ctx.requestRebuild)
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
    queueThrottleRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/esc_motors/throttle/help.lua")
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
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

return M
