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
local NameApi = nil
local AdvancedConfigApi = nil
local FeatureConfigApi = nil
local StatusApi = nil
local LoadingOverlay = nil
local SavePipeline = nil
local t = nil

local FEATURE_BIT_GPS = 7
local FEATURE_BIT_LED_STRIP = 16
local FEATURE_BIT_CMS = 19

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
    name = "",
    pid_process_denom = 1,
    gyro_sync_denom_compat = 1,
    enabledFeatures = 0,
    task_delta_time_gyro = 250
  },
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
  if not NameApi then NameApi = loadModule("tasks/msp/api/name.lua") end
  if not AdvancedConfigApi then AdvancedConfigApi = loadModule("tasks/msp/api/advanced_config.lua") end
  if not FeatureConfigApi then FeatureConfigApi = loadModule("tasks/msp/api/feature_config.lua") end
  if not StatusApi then StatusApi = loadModule("tasks/msp/api/status.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_configuration") or nil end

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

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_configuration) ~= "table" then
    session.setup_configuration = {}
  end
  return session.setup_configuration
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.name = rcConfig.name or ""
  ui.config.pid_process_denom = tonumber(rcConfig.pid_process_denom) or 1
  ui.config.gyro_sync_denom_compat = tonumber(rcConfig.gyro_sync_denom_compat) or 1
  ui.config.enabledFeatures = tonumber(rcConfig.enabledFeatures) or 0
  ui.config.task_delta_time_gyro = tonumber(rcConfig.task_delta_time_gyro) or 250
end

local function queueRcRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or not StatusApi or not NameApi or not AdvancedConfigApi or not FeatureConfigApi or type(MspRuntime.getState) ~= "function" then
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

  -- Step 1: Read STATUS
  queue:add({
    command = StatusApi.command,
    simulatorResponse = StatusApi.simulatorResponse,
    processReply = function(self, buf)
      local parsedStatus = StatusApi.parse(buf)
      if parsedStatus then
        local delta = tonumber(parsedStatus.task_delta_time_gyro) or 0
        if delta > 0 then
          ui.config.task_delta_time_gyro = delta
        end
      end

      -- Step 2: Read NAME
      queue:add({
        command = NameApi.command,
        simulatorResponse = NameApi.simulatorResponse,
        processReply = function(self, buf)
          local parsedName = NameApi.parse(buf)
          if parsedName then
            ui.config.name = parsedName.name or ""
          end

          -- Step 3: Read ADVANCED_CONFIG
          queue:add({
            command = AdvancedConfigApi.command,
            simulatorResponse = AdvancedConfigApi.simulatorResponse,
            processReply = function(self, buf)
              local parsedAdv = AdvancedConfigApi.parse(buf)
              if parsedAdv then
                ui.config.pid_process_denom = parsedAdv.pid_process_denom or 1
                ui.config.gyro_sync_denom_compat = parsedAdv.gyro_sync_denom_compat or 1
              end

              -- Step 4: Read FEATURE_CONFIG
              queue:add({
                command = FeatureConfigApi.command,
                simulatorResponse = FeatureConfigApi.simulatorResponse,
                processReply = function(self, buf)
                  local parsedFeat = FeatureConfigApi.parse(buf)
                  if parsedFeat then
                    ui.config.enabledFeatures = parsedFeat.enabledFeatures or 0
                  end

                  -- Sync to session
                  local session = getSession()
                  if session then
                    local rcConfig = getRcConfig(session)
                    if rcConfig then
                      rcConfig.name = ui.config.name
                      rcConfig.pid_process_denom = ui.config.pid_process_denom
                      rcConfig.gyro_sync_denom_compat = ui.config.gyro_sync_denom_compat
                      rcConfig.enabledFeatures = ui.config.enabledFeatures
                      rcConfig.task_delta_time_gyro = ui.config.task_delta_time_gyro
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
            end,
            errorHandler = function()
              ui.runtime.readPending = false
              ui.loading = false
              if type(ui.runtime.requestRebuild) == "function" then
                ui.runtime.requestRebuild()
              end
            end
          })
        end,
        errorHandler = function()
          ui.runtime.readPending = false
          ui.loading = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    errorHandler = function()
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueRcWrite(_i18n)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not NameApi or not AdvancedConfigApi or not FeatureConfigApi then
    return false, "msp_runtime_unavailable"
  end

  -- The five nested queue:add calls that stood here queued NAME, ADVANCED_CONFIG,
  -- FEATURE_CONFIG, the EEPROM commit and the reboot, each from the previous step's
  -- processReply, and the reboot's processReply was empty: the chain ended the moment the
  -- restart was sent. What the page wanted is described here instead, and the pipeline owns the
  -- rest -- including the part that never existed, which is waiting for the board to come back
  -- and reading the settings again afterwards.
  return SavePipeline.start({
    pageId = "setup_configuration",
    steps = {
      {
        label = "MSP_SET_NAME",
        command = NameApi.writeCommand,
        payload = NameApi.buildWritePayload({ name = ui.config.name })
      },
      {
        label = "MSP_SET_ADVANCED_CONFIG",
        command = AdvancedConfigApi.writeCommand,
        payload = AdvancedConfigApi.buildWritePayload({
          gyro_sync_denom_compat = ui.config.gyro_sync_denom_compat or 1,
          pid_process_denom = ui.config.pid_process_denom
        })
      },
      {
        label = "MSP_SET_FEATURE_CONFIG",
        command = FeatureConfigApi.writeCommand,
        payload = FeatureConfigApi.buildWritePayload({
          enabledFeatures = ui.config.enabledFeatures
        })
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_configuration" },
    -- The settings are in EEPROM here, which is the moment the page stops being dirty. The
    -- dialog waits: raising a native modal now would suspend the tool's run() -- and with it the
    -- MSP tick the rest of this pipeline needs -- in the middle of the restart.
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      -- The outcome is drawn by the overlay that has been reporting this save all along. It
      -- used to be a native dialog raised from here -- which is inside the reply handler, so
      -- the overlay underneath could not be repainted away before it appeared, and while it
      -- stood the tool's run() did not run.
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
  return pageText(nil, "title", "Configuration")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueRcRead(false)
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

local function getBoolGetter(bit)
  return function()
    return bitIsSet(ui.config.enabledFeatures or 0, bit)
  end
end

local function getBoolSetter(bit)
  return function(nextBool)
    local oldVal = ui.config.enabledFeatures or 0
    local newVal = setBit(oldVal, bit, nextBool == true)
    if oldVal ~= newVal then
      ui.config.enabledFeatures = newVal
      ui.dirty = true
    end
  end
end

local function getPidLoopChoices(currentValue)
  local gyroDelta = ui.config.task_delta_time_gyro
  if not gyroDelta or gyroDelta <= 0 then gyroDelta = 250 end
  local rawGyroHz = 1000000 / gyroDelta
  local gyroHz = math.floor((rawGyroHz / 1000) + 0.5) * 1000

  local function formatPidLoopKhz(valueKhz)
    local rounded = math.floor((valueKhz * 100) + 0.5) / 100
    local text = string.format("%.2f", rounded)
    text = string.gsub(text, "0+$", "")
    text = string.gsub(text, "%.$", "")
    if not string.find(text, "%.") and rounded >= 2 then
      text = text .. ".0"
    end
    return text .. " kHz"
  end

  local options = {}
  local present = {}
  local PID_LOOP_DENOMS = {1, 2, 3, 4}

  for i = 1, #PID_LOOP_DENOMS do
    local denom = PID_LOOP_DENOMS[i]
    local pidKhz = (gyroHz / denom) / 1000
    local label = formatPidLoopKhz(pidKhz)
    options[#options + 1] = { value = denom, label = label }
    present[denom] = true
  end

  if currentValue and not present[currentValue] then
    local pidKhz = (gyroHz / currentValue) / 1000
    local label = formatPidLoopKhz(pidKhz)
    options[#options + 1] = { value = currentValue, label = label }
  end

  return options
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
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_configuration")
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
    queueRcRead(false)
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
      message = pageText(i18n, "loading_message", "Reading configuration"),
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

  -- 1) Craft Name
  cursorY = cursorY + Controls.appendTextField(children, x, cursorY, w,
    pageText(i18n, "craft_name", "Craft name"),
    {
      get = function()
        return ui.config.name or ""
      end,
      set = function(newVal)
        if ui.config.name ~= newVal then
          ui.config.name = newVal
          ui.dirty = true
        end
      end,
      length = 32
    }
  )

  -- 2) PID loop speed (ComboSelect)
  local pidOptions = getPidLoopChoices(ui.config.pid_process_denom)
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "pid_loop_speed", "PID loop speed"),
    pidOptions,
    ui.config.pid_process_denom,
    function(newVal)
      if ui.config.pid_process_denom ~= newVal then
        ui.config.pid_process_denom = newVal
        ui.dirty = true
      end
    end
  )

  -- 3) GPS switch
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "feature_gps", "GPS"),
    getBoolGetter(FEATURE_BIT_GPS),
    getBoolSetter(FEATURE_BIT_GPS)
  )

  -- 4) LED_STRIP switch
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "feature_led_strip", "LED_STRIP"),
    getBoolGetter(FEATURE_BIT_LED_STRIP),
    getBoolSetter(FEATURE_BIT_LED_STRIP)
  )

  -- 5) CMS switch
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "feature_cms", "CMS"),
    getBoolGetter(FEATURE_BIT_CMS),
    getBoolSetter(FEATURE_BIT_CMS)
  )
end

function M.onSave(ctx)
  local ok, err = queueRcWrite(ctx and ctx.i18n)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- Nothing has been written yet: queueRcWrite has QUEUED the first message and no reply has
  -- come back. Clearing the dirty flag and announcing success here says something this function
  -- cannot know -- and when a step fails it is never contradicted, so the page goes on looking
  -- saved while the flight controller holds the old values. Both are reported from the chain
  -- itself now, once, by whichever step reaches an end first.
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    queueRcRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/configuration/help.lua")
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
  NameApi = nil
  AdvancedConfigApi = nil
  FeatureConfigApi = nil
  StatusApi = nil
  LoadingOverlay = nil
  t = nil
end

return M
