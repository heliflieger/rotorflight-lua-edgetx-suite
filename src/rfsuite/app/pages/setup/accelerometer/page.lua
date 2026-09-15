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
local AccTrimApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

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
    roll = 0,
    pitch = 0
  },
  runtime = newRuntime(),
  loading = false,
  progress = 0,
  baseTitle = nil,
  calibrating = false
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not AccTrimApi then AccTrimApi = loadModule("tasks/msp/api/acc_trim.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_accelerometer") or nil end

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

local function getAccConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_accelerometer) ~= "table" then
    session.setup_accelerometer = {}
  end
  return session.setup_accelerometer
end

local function loadFromSession()
  local session = getSession()
  local accConfig = getAccConfig(session)
  if not accConfig then return end
  ui.config.roll = tonumber(accConfig.roll) or 0
  ui.config.pitch = tonumber(accConfig.pitch) or 0
end

local function queueAccRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or not AccTrimApi or type(MspRuntime.getState) ~= "function" then
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

  queue:add({
    command = AccTrimApi.command,
    simulatorResponse = AccTrimApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = AccTrimApi.parse(buf)
      if parsed then
        ui.config.roll = parsed.roll
        ui.config.pitch = parsed.pitch
        
        -- Sync to session
        local session = getSession()
        if session then
          local accConfig = getAccConfig(session)
          if accConfig then
            accConfig.roll = ui.config.roll
            accConfig.pitch = ui.config.pitch
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

  return true, nil
end

local function queueAccWrite()
  if not MspRuntime or not AccTrimApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local payload = AccTrimApi.buildWritePayload({
    roll = ui.config.roll,
    pitch = ui.config.pitch
  })

  queue:add({
    command = AccTrimApi.writeCommand,
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
            -- Success! Reload values
            queueAccRead(true)
          end,
          errorHandler = function() end
        })
      end
    end,
    errorHandler = function() end
  })

  return true, nil
end

local function buildSessionSignature()
  return "1" -- static page
end

local function getBaseTitle()
  return pageText(nil, "title", "Accelerometer")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueAccRead(false)
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
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    queueAccRead(false)
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    star = true,
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
      message = pageText(i18n, "loading_message", "Reading accelerometer trims"),
      progress = ui.progress / 100
    })
    return
  end

  if ui.calibrating then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "calibrating_title", "Calibrating"),
      message = pageText(i18n, "calibrating_message", "Calibrating accelerometer. Please keep the model level and still."),
      progress = 0
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

  -- 1) Roll
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "roll", "Roll"),
    {
      min = -300,
      max = 300,
      get = function() return ui.config.roll or 0 end,
      set = function(val)
        if ui.config.roll ~= val then
          ui.config.roll = val
          ui.dirty = true
        end
      end,
      suffix = "°"
    }
  )

  -- 2) Pitch
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "pitch", "Pitch"),
    {
      min = -300,
      max = 300,
      get = function() return ui.config.pitch or 0 end,
      set = function(val)
        if ui.config.pitch ~= val then
          ui.config.pitch = val
          ui.dirty = true
        end
      end,
      suffix = "°"
    }
  )
end

function M.onSave(ctx)
  local ok, err = queueAccWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  ui.dirty = false
  if ctx and type(ctx.reportSave) == "function" then
    ctx.reportSave({
      ok = true,
      title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
      message = pageText(ctx and ctx.i18n, "saved_message", "Accelerometer trims saved")
    })
  end
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    queueAccRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/accelerometer/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end

function M.onStar(ctx)
  if not ConfirmDialog then return false end
  
  local i18n = ctx and ctx.i18n
  local title = pageText(i18n, "msg_calibrate", "Calibrate the accelerometer?")
  local message = pageText(i18n, "help_p1", "The accelerometer is used to measure the angle of the flight controller in relation to the horizon. This data is used to stabilize the aircraft and provide self-leveling functionality.")
  
  ConfirmDialog.show({
    title = title,
    message = message,
    onConfirm = function()
      -- Trigger calibration!
      if not MspRuntime or type(MspRuntime.getState) ~= "function" then
        return
      end
      local mspState = MspRuntime.getState()
      local queue = mspState and mspState.queue
      if not queue or type(queue.add) ~= "function" then
        return
      end
      
      ui.calibrating = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
      
      queue:add({
        command = 205, -- MSP_ACC_CALIBRATION
        payload = {},
        isWrite = true,
        simulatorResponse = {},
        processReply = function(self, buf)
          -- Calibration finished, write EEPROM
          local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
          if eepromApi then
            queue:add({
              command = eepromApi.writeCommand,
              payload = {},
              isWrite = true,
              simulatorResponse = {},
              processReply = function()
                ui.calibrating = false
                if type(playFile) == "function" then
                  pcall(playFile, "/SOUNDS/rf/beep.wav")
                end
                
                -- Show calibrated alert
                if ctx and type(ctx.reportSave) == "function" then
                  ctx.reportSave({
                    ok = true,
                    title = pageText(i18n, "calibrated_title", "Calibrated"),
                    message = pageText(i18n, "calibrated_message", "Accelerometer calibrated successfully and saved to EEPROM.")
                  })
                end
                
                -- Read new trims
                queueAccRead(true)
              end,
              errorHandler = function()
                ui.calibrating = false
                if type(ui.runtime.requestRebuild) == "function" then
                  ui.runtime.requestRebuild()
                end
              end
            })
          else
            ui.calibrating = false
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end
        end,
        errorHandler = function()
          ui.calibrating = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    onCancel = function()
      -- Do nothing
    end
  })
  return true
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
  AccTrimApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

return M
