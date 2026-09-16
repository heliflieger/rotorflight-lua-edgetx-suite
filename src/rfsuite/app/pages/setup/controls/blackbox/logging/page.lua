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
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local t = nil

local FEATURE_BITS = {
  gps = 7,
  governor = 26,
  esc_sensor = 27
}

local FIELD_DEFS = {
  { key = "log_command", default = "Command", bit = 0 },
  { key = "log_setpoint", default = "Setpoint", bit = 1 },
  { key = "log_mixer", default = "Mixer", bit = 2 },
  { key = "log_pid", default = "PID", bit = 3 },
  { key = "log_attitude", default = "Attitude", bit = 4 },
  { key = "log_gyro_raw", default = "Gyro Raw", bit = 5 },
  { key = "log_gyro", default = "Gyro", bit = 6 },
  { key = "log_acc", default = "Acc", bit = 7 },
  { key = "log_mag", default = "Mag", bit = 8 },
  { key = "log_alt", default = "Alt", bit = 9 },
  { key = "log_battery", default = "Battery", bit = 10 },
  { key = "log_rssi", default = "RSSI", bit = 11 },
  { key = "log_gps", default = "GPS", bit = 12, featureBit = FEATURE_BITS.gps },
  { key = "log_rpm", default = "RPM", bit = 13 },
  { key = "log_motors", default = "Motors", bit = 14 },
  { key = "log_servos", default = "Servos", bit = 15 },
  { key = "log_vbec", default = "VBEC", bit = 16 },
  { key = "log_vbus", default = "VBUS", bit = 17 },
  { key = "log_temps", default = "Temps", bit = 18 },
  { key = "log_esc", default = "ESC", bit = 19, apiversiongte = { 12, 0, 7 }, featureBit = FEATURE_BITS.esc_sensor },
  { key = "log_bec", default = "BEC", bit = 20, apiversiongte = { 12, 0, 7 }, featureBit = FEATURE_BITS.esc_sensor },
  { key = "log_esc2", default = "ESC2", bit = 21, apiversiongte = { 12, 0, 7 }, featureBit = FEATURE_BITS.esc_sensor },
  { key = "log_governor", default = "Governor", bit = 22, apiversiongte = { 12, 0, 9 }, featureBit = FEATURE_BITS.governor }
}

local ui = {
  loaded = false,
  dirty = false,
  featureBitmap = 0,
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

local function hasBit(mask, bit)
  local b = tonumber(bit or 0) or 0
  return (((tonumber(mask or 0) or 0) & (1 << b)) ~= 0)
end

local function setBit(mask, bit, enable)
  local m = tonumber(mask or 0) or 0
  local b = tonumber(bit or 0) or 0
  local f = (1 << b)
  if enable then
    return (m | f)
  end
  return (m & (~f))
end

local function supportsField(def, rawApiVersion)
  if def.apiversiongte and ApiVersion then
    if not ApiVersion.isAtLeast(rawApiVersion, def.apiversiongte) then
      return false
    end
  end
  if def.featureBit and not hasBit(ui.featureBitmap, def.featureBit) then
    return false
  end
  return true
end

local function canEdit()
  local supported = tonumber(ui.cfg.blackbox_supported or 0) == 1
  local device = tonumber(ui.cfg.device or 0) or 0
  local mode = tonumber(ui.cfg.mode or 0) or 0
  return ui.loaded and supported and device ~= 0 and mode ~= 0
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.blackbox) ~= "table" or type(session.blackbox.config) ~= "table" then return false end
  ui.featureBitmap = tonumber(session.blackbox.feature and session.blackbox.feature.enabledFeatures or 0) or 0
  local parsed = session.blackbox.config
  ui.cfg.blackbox_supported = tonumber(parsed.blackbox_supported or 0) or 0
  ui.cfg.device = tonumber(parsed.device or 0) or 0
  ui.cfg.mode = tonumber(parsed.mode or 0) or 0
  ui.cfg.denom = tonumber(parsed.denom or 1) or 1
  ui.cfg.fields = tonumber(parsed.fields or 0) or 0
  ui.cfg.initialEraseFreeSpaceKiB = tonumber(parsed.initialEraseFreeSpaceKiB or 0) or 0
  ui.cfg.rollingErase = tonumber(parsed.rollingErase or 0) or 0
  ui.cfg.gracePeriod = tonumber(parsed.gracePeriod or 0) or 0
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

  -- Queue FEATURE_CONFIG read first
  queue:add({
    command = FeatureConfigApi.command,
    simulatorResponse = FeatureConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local reply = FeatureConfigApi.parse(buf)
      if type(reply) ~= "table" then return Common.failPageRead(ui) end
      ui.featureBitmap = (reply and reply.enabledFeatures) or 0

      -- Now queue BLACKBOX_CONFIG read
      queue:add({
        command = BlackboxConfigApi.command,
        simulatorResponse = BlackboxConfigApi.simulatorResponse,
        processReply = function(self2, buf2)
          local parsed = BlackboxConfigApi.parse(buf2)
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
    end,
    errorHandler = function()
      readValid = false
      -- If feature config fails, still try to read blackbox config
      queue:add({
        command = BlackboxConfigApi.command,
        simulatorResponse = BlackboxConfigApi.simulatorResponse,
        processReply = function(self2, buf2)
          local parsed = BlackboxConfigApi.parse(buf2)
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
    end
  })

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

  queue:add({
    command = BlackboxConfigApi.writeCommand,
    payload = payload,
    isWrite = true,
    simulatorResponse = {},
    processReply = function()
      -- Step 2: Write EEPROM
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
    end,
    errorHandler = function()
      ui.saving = false
      if type(requestRebuild) == "function" then
        requestRebuild()
      end
    end
  })

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
    local msgText = ui.loading and pageText(i18n, "loading_logging", "Loading blackbox logging...") or pageText(i18n, "saving_logging", "Saving blackbox logging...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Logging"
  local title = pageText(i18n, "title_logging", displayTitle)
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

  for i = 1, #FIELD_DEFS do
    local def = FIELD_DEFS[i]
    if supportsField(def, rawApiVersion) then
      local label = pageText(i18n, def.key, def.default)
      cursorY = cursorY + Controls.appendRadioSwitch(
        children, x, cursorY, w,
        label,
        function()
          return hasBit(ui.cfg.fields, def.bit)
        end,
        function(v)
          ui.cfg.fields = setBit(ui.cfg.fields, def.bit, v)
          ui.dirty = true
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        function() return canEdit() end
      )
    end
  end

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
  local help = loadModule("app/pages/setup/controls/blackbox/logging/help.lua")
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
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

return M
