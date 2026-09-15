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
local GpsConfigApi = nil
local FeatureConfigApi = nil
local LoadingOverlay = nil
local SavePipeline = nil
local t = nil

local FEATURE_BIT_GPS = 7

-- Wire values of gpsConfig()->provider. They are the indices of the firmware's own CLI lookup
-- table for gps_provider, so a value read back from the board indexes straight into the list
-- built in getProviderOptions.
local PROVIDER_NMEA = 0
local PROVIDER_UBLOX = 1
local PROVIDER_FBUS = 3

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  config = {
    provider = PROVIDER_NMEA,
    sbas_mode = 0,
    auto_config = 1,
    auto_baud = 1,
    set_home_point_once = 0,
    ublox_use_galileo = 0
  },
  featureEnabled = nil,
  readFailed = false,
  runtime = newRuntime(),
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
  if not GpsConfigApi then GpsConfigApi = loadModule("tasks/msp/api/gps_config.lua") end
  if not FeatureConfigApi then FeatureConfigApi = loadModule("tasks/msp/api/feature_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_gps") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = newRuntime()
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

local function getGpsConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_gps) ~= "table" then
    session.setup_gps = {}
  end
  return session.setup_gps
end

local function loadFromSession()
  local session = getSession()
  local gpsConfig = getGpsConfig(session)
  if not gpsConfig then return end
  ui.config.provider = tonumber(gpsConfig.provider) or PROVIDER_NMEA
  ui.config.sbas_mode = tonumber(gpsConfig.sbas_mode) or 0
  ui.config.auto_config = tonumber(gpsConfig.auto_config) or 1
  ui.config.auto_baud = tonumber(gpsConfig.auto_baud) or 1
  ui.config.set_home_point_once = tonumber(gpsConfig.set_home_point_once) or 0
  ui.config.ublox_use_galileo = tonumber(gpsConfig.ublox_use_galileo) or 0
end

local function syncToSession()
  local session = getSession()
  local gpsConfig = getGpsConfig(session)
  if not gpsConfig then return end
  gpsConfig.provider = ui.config.provider
  gpsConfig.sbas_mode = ui.config.sbas_mode
  gpsConfig.auto_config = ui.config.auto_config
  gpsConfig.auto_baud = ui.config.auto_baud
  gpsConfig.set_home_point_once = ui.config.set_home_point_once
  gpsConfig.ublox_use_galileo = ui.config.ublox_use_galileo
end

local function finishRead(failed)
  ui.runtime.readPending = false
  ui.loading = false
  ui.readFailed = failed == true
  if not failed then
    ui.dirty = false
    ui.progress = 100
  end
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

local function queueGpsRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or not GpsConfigApi or not FeatureConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Step 1: FEATURE_CONFIG. These settings are writable whatever the feature bit says, but the
  -- receiver is only driven when the feature is on, so a page that stays silent about it lets
  -- a pilot pick a protocol and then watch nothing happen. This read decides one notice line.
  queue:add({
    command = FeatureConfigApi.command,
    simulatorResponse = FeatureConfigApi.simulatorResponse,
    processReply = function(_, buf)
      local parsedFeat = FeatureConfigApi.parse(buf)
      if parsedFeat then
        local features = tonumber(parsedFeat.enabledFeatures) or 0
        ui.featureEnabled = ((features >> FEATURE_BIT_GPS) & 1) == 1
      else
        ui.featureEnabled = nil
      end

      -- Step 2: GPS_CONFIG. A firmware built without GPS support does not answer this at all,
      -- which is the one case the page cannot fill in: it has nothing to show and nothing to
      -- write, so it says so instead of drawing defaults that would be saved as real values.
      queue:add({
        command = GpsConfigApi.command,
        simulatorResponse = GpsConfigApi.simulatorResponse,
        processReply = function(_, gpsBuf)
          local parsed = GpsConfigApi.parse(gpsBuf)
          if not parsed then
            finishRead(true)
            return
          end

          ui.config.provider = tonumber(parsed.provider) or PROVIDER_NMEA
          ui.config.sbas_mode = tonumber(parsed.sbas_mode) or 0
          ui.config.auto_config = tonumber(parsed.auto_config) or 0
          ui.config.auto_baud = tonumber(parsed.auto_baud) or 0
          ui.config.set_home_point_once = tonumber(parsed.set_home_point_once) or 0
          ui.config.ublox_use_galileo = tonumber(parsed.ublox_use_galileo) or 0

          syncToSession()
          finishRead(false)
        end,
        errorHandler = function()
          finishRead(true)
        end
      })
    end,
    errorHandler = function()
      finishRead(true)
    end
  })

  return true, nil
end

local function queueGpsWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not GpsConfigApi then
    return false, "msp_runtime_unavailable"
  end

  return SavePipeline.start({
    pageId = "setup_gps",
    steps = {
      {
        label = "MSP_SET_GPS_CONFIG",
        command = GpsConfigApi.writeCommand,
        payload = GpsConfigApi.buildWritePayload({
          provider = ui.config.provider,
          sbas_mode = ui.config.sbas_mode,
          auto_config = ui.config.auto_config,
          auto_baud = ui.config.auto_baud,
          set_home_point_once = ui.config.set_home_point_once,
          ublox_use_galileo = ui.config.ublox_use_galileo
        })
      }
    },
    -- The receiver is opened and configured while the serial port is brought up, so a changed
    -- protocol or baud policy does not take effect until the board restarts.
    reboot = true,
    invalidateSessionKeys = { "setup_gps" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then
        ui.dirty = true
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function buildSessionSignature()
  return "1" -- static, global page
end

local function getBaseTitle()
  return pageText(nil, "title", "GPS")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.readFailed = false
  ui.featureEnabled = nil
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueGpsRead(false)
end

function M.onLoad()
  ensureDeps()
  ensureLoaded()
end

function M.onActivate()
  ensureDeps()
  ensureLoaded()
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held back
  -- rather than raised over whatever page the user went to; claim it now.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_gps")
  end
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    queueGpsRead(false)
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

local function getProviderOptions()
  return {
    { value = 0, label = "NMEA" },
    { value = 1, label = "UBLOX" },
    { value = 2, label = "MSP" },
    { value = 3, label = "FBUS" }
  }
end

local function getSbasOptions(i18n)
  return {
    { value = 0, label = pageText(i18n, "sbas_auto", "Auto-detect") },
    { value = 1, label = pageText(i18n, "sbas_egnos", "European EGNOS") },
    { value = 2, label = pageText(i18n, "sbas_waas", "North American WAAS") },
    { value = 3, label = pageText(i18n, "sbas_msas", "Japanese MSAS") },
    { value = 4, label = pageText(i18n, "sbas_gagan", "Indian GAGAN") },
    { value = 5, label = pageText(i18n, "sbas_none", "None") }
  }
end

local function markDirty()
  ui.dirty = true
end

local function requestRebuild()
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

local function appendNotice(children, x, y, w, text)
  children[#children + 1] = {
    type = "label",
    x = x,
    y = y,
    w = w,
    text = text,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_message", "Reading GPS configuration"),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  if ui.readFailed then
    appendNotice(children, x + 10, cursorY, w - 20,
      pageText(i18n, "unsupported", "This flight controller firmware was built without GPS support."))
    return
  end

  if ui.featureEnabled == false then
    appendNotice(children, x + 10, cursorY, w - 20,
      pageText(i18n, "feature_off", "The GPS feature is off. Turn it on under Configuration."))
    cursorY = cursorY + (Controls.LABEL_H or 20) + 10
  end

  -- 1) Protocol
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "protocol", "Protocol"),
    getProviderOptions(),
    ui.config.provider,
    function(newVal)
      if ui.config.provider ~= newVal then
        ui.config.provider = newVal
        -- FBUS carries the position over the receiver's own link. There is no serial port for
        -- this driver to open, so neither the baud search nor the receiver configuration it
        -- would run has anything to act on.
        if newVal == PROVIDER_FBUS then
          ui.config.auto_baud = 0
          ui.config.auto_config = 0
        end
        markDirty()
        requestRebuild()
      end
    end
  )

  if ui.config.provider ~= PROVIDER_FBUS then
    -- 2) Auto-baud
    cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
      pageText(i18n, "auto_baud", "Auto-baud"),
      function() return (ui.config.auto_baud or 0) ~= 0 end,
      function(newVal)
        local nextVal = newVal and 1 or 0
        if ui.config.auto_baud ~= nextVal then
          ui.config.auto_baud = nextVal
          markDirty()
        end
      end
    )

    -- 3) Auto-config
    cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
      pageText(i18n, "auto_config", "Auto-config"),
      function() return (ui.config.auto_config or 0) ~= 0 end,
      function(newVal)
        local nextVal = newVal and 1 or 0
        if ui.config.auto_config ~= nextVal then
          ui.config.auto_config = nextVal
          markDirty()
          requestRebuild()
        end
      end
    )
  end

  -- The two fields below are only ever sent to the receiver by the auto-configuration
  -- sequence, and only the u-blox driver runs one.
  if ui.config.provider == PROVIDER_UBLOX and (ui.config.auto_config or 0) ~= 0 then
    -- 4) SBAS mode
    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      pageText(i18n, "sbas_mode", "SBAS mode"),
      getSbasOptions(i18n),
      ui.config.sbas_mode,
      function(newVal)
        if ui.config.sbas_mode ~= newVal then
          ui.config.sbas_mode = newVal
          markDirty()
        end
      end
    )

    -- 5) Galileo
    cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
      pageText(i18n, "use_galileo", "Use Galileo"),
      function() return (ui.config.ublox_use_galileo or 0) ~= 0 end,
      function(newVal)
        local nextVal = newVal and 1 or 0
        if ui.config.ublox_use_galileo ~= nextVal then
          ui.config.ublox_use_galileo = nextVal
          markDirty()
        end
      end
    )
  end

  -- 6) Set home point once
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "set_home_point_once", "Set home point once"),
    function() return (ui.config.set_home_point_once or 0) ~= 0 end,
    function(newVal)
      local nextVal = newVal and 1 or 0
      if ui.config.set_home_point_once ~= nextVal then
        ui.config.set_home_point_once = nextVal
        markDirty()
      end
    end
  )
end

function M.onSave(ctx)
  if ui.readFailed then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = pageText(ctx and ctx.i18n, "unsupported",
          "This flight controller firmware was built without GPS support.")
      })
    end
    return false
  end

  local ok, err = queueGpsWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- Nothing has reached EEPROM yet: the first step has only been queued. The outcome is
  -- reported once, from whichever step of the pipeline ends the chain.
  return true
end

function M.onReload()
  loadFromSession()
  ui.dirty = false
  queueGpsRead(false)
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/gps/help.lua")
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
  ui.readFailed = false
  ui.featureEnabled = nil
  Controls = nil
  Common = nil
  MspRuntime = nil
  GpsConfigApi = nil
  FeatureConfigApi = nil
  LoadingOverlay = nil
  SavePipeline = nil
  t = nil
end

return M
