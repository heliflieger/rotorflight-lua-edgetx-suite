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
local RcConfigApi = nil
local ApiVersion = nil
local LoadingOverlay = nil
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
    rc_center = 1500,
    rc_deflection = 510,
    rc_arm_throttle = 1000,
    rc_min_throttle = 1100,
    rc_max_throttle = 1900,
    rc_deadband = 4,
    rc_yaw_deadband = 4
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
  if not RcConfigApi then RcConfigApi = loadModule("tasks/msp/api/rc_config.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_radio_config") or nil end

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
  if type(session.setup_radio_config) ~= "table" then
    session.setup_radio_config = {}
  end
  return session.setup_radio_config
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.rc_center = tonumber(rcConfig.rc_center) or 1500
  ui.config.rc_deflection = tonumber(rcConfig.rc_deflection) or 510
  ui.config.rc_arm_throttle = tonumber(rcConfig.rc_arm_throttle) or 1000
  ui.config.rc_min_throttle = tonumber(rcConfig.rc_min_throttle) or 1100
  ui.config.rc_max_throttle = tonumber(rcConfig.rc_max_throttle) or 1900
  ui.config.rc_deadband = tonumber(rcConfig.rc_deadband) or 4
  ui.config.rc_yaw_deadband = tonumber(rcConfig.rc_yaw_deadband) or 4
end

local function validateThrottle()
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isAtLeast = rawApiVersion and ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, { 12, 0, 9 })
  if isAtLeast then
    return
  end
  local arm = tonumber(ui.config.rc_arm_throttle)
  local min = tonumber(ui.config.rc_min_throttle)
  if arm and min then
    if min < (arm + 10) then
      ui.config.rc_min_throttle = arm + 10
      ui.dirty = true
    end
  end
end

local function queueRcRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or not RcConfigApi or type(MspRuntime.getState) ~= "function" then
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
    command = RcConfigApi.command,
    simulatorResponse = RcConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = RcConfigApi.parse(buf)
      if parsed then
        ui.config.rc_center = parsed.rc_center
        ui.config.rc_deflection = parsed.rc_deflection
        ui.config.rc_arm_throttle = parsed.rc_arm_throttle
        ui.config.rc_min_throttle = parsed.rc_min_throttle
        ui.config.rc_max_throttle = parsed.rc_max_throttle
        ui.config.rc_deadband = parsed.rc_deadband
        ui.config.rc_yaw_deadband = parsed.rc_yaw_deadband
        
        -- Sync to session
        local session = getSession()
        if session then
          local rcConfig = getRcConfig(session)
          if rcConfig then
            rcConfig.rc_center = ui.config.rc_center
            rcConfig.rc_deflection = ui.config.rc_deflection
            rcConfig.rc_arm_throttle = ui.config.rc_arm_throttle
            rcConfig.rc_min_throttle = ui.config.rc_min_throttle
            rcConfig.rc_max_throttle = ui.config.rc_max_throttle
            rcConfig.rc_deadband = ui.config.rc_deadband
            rcConfig.rc_yaw_deadband = ui.config.rc_yaw_deadband
          end
        end
        validateThrottle()
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

local function queueRcWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not RcConfigApi then
    return false, "msp_runtime_unavailable"
  end

  validateThrottle()

  -- The three nested queue:add calls that stood here wrote the configuration, committed it and
  -- sent the reboot, and the reboot's processReply was empty: nothing waited for the flight
  -- controller to come back, and every errorHandler in the chain was empty too, so a failed
  -- write was silent. The pipeline owns the process and reports its outcome.
  return SavePipeline.start({
    pageId = "setup_radio_config",
    steps = {
      {
        label = "MSP_SET_RC_CONFIG",
        command = RcConfigApi.writeCommand,
        payload = RcConfigApi.buildWritePayload({
          rc_center = ui.config.rc_center,
          rc_deflection = ui.config.rc_deflection,
          rc_arm_throttle = ui.config.rc_arm_throttle,
          rc_min_throttle = ui.config.rc_min_throttle,
          rc_max_throttle = ui.config.rc_max_throttle,
          rc_deadband = ui.config.rc_deadband,
          rc_yaw_deadband = ui.config.rc_yaw_deadband
        })
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_radio_config" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then
        ui.dirty = true
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function buildSessionSignature()
  return "1" -- static, global page
end

local function getBaseTitle()
  return pageText(nil, "title", "Radio Config")
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

local function appendDoubleFieldRow(children, x, y, w, rowLabelText, field1, field2)
  local rowH = (Controls and Controls.ROW_H) or 40
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))
  local dividerY = y + rowH

  local mainW    = math.floor(w * 0.18)
  local labelW1  = math.floor(w * 0.14)
  local editW1   = math.floor(w * 0.24)
  local gap      = 8
  local labelGap = 4

  -- Left row label
  if rowLabelText and rowLabelText ~= "" then
    children[#children + 1] = {
      type  = "label",
      x = x, y = labelY,
      w = mainW,
      text  = rowLabelText,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE
    }
  end

  -- Column 1
  local xLabel1 = x + mainW
  local xEdit1  = xLabel1 + labelW1

  if field1 then
    children[#children + 1] = {
      type  = "label",
      x = xLabel1, y = labelY,
      w = labelW1 - labelGap,
      text  = field1.label,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE,
      align = RIGHT
    }

    children[#children + 1] = {
      type = "numberEdit",
      x = xEdit1,
      y = cellTop,
      w = editW1,
      min = field1.min,
      max = field1.max,
      active = function() return field1.active ~= false end,
      get = field1.get,
      set = field1.set,
      display = function(val)
        return tostring(val) .. "us"
      end
    }
  end

  -- Column 2
  if field2 then
    local labelW2 = math.floor(w * 0.14)
    local editW2  = math.floor(w * 0.24)
    local xLabel2 = xEdit1 + editW1 + gap
    local xEdit2  = xLabel2 + labelW2

    children[#children + 1] = {
      type  = "label",
      x = xLabel2, y = labelY,
      w = labelW2 - labelGap,
      text  = field2.label,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE,
      align = RIGHT
    }

    children[#children + 1] = {
      type = "numberEdit",
      x = xEdit2,
      y = cellTop,
      w = editW2,
      min = field2.min,
      max = field2.max,
      active = function() return field2.active ~= false end,
      get = field2.get,
      set = field2.set,
      display = function(val)
        return tostring(val) .. "us"
      end
    }
  end

  -- Divider
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = dividerY,
    w = w, h = 1,
    color  = COLOR_THEME_SECONDARY2, filled = true
  }

  return rowH + 1
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
    SavePipeline.takeResult("setup_radio_config")
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
      message = pageText(i18n, "loading_message", "Reading radio configuration"),
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
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
  end

  -- Stick row
  cursorY = cursorY + appendDoubleFieldRow(children, x, cursorY, w,
    pageText(i18n, "stick", "Stick"),
    {
      label = pageText(i18n, "center", "Center"),
      min = 1400,
      max = 1600,
      get = function() return ui.config.rc_center or 1500 end,
      set = function(val)
        if ui.config.rc_center ~= val then
          ui.config.rc_center = val
          ui.dirty = true
        end
      end
    },
    {
      label = pageText(i18n, "deflection", "Deflection"),
      min = 200,
      max = 700,
      get = function() return ui.config.rc_deflection or 510 end,
      set = function(val)
        if ui.config.rc_deflection ~= val then
          ui.config.rc_deflection = val
          ui.dirty = true
        end
      end
    }
  )

  -- Deadband row
  cursorY = cursorY + appendDoubleFieldRow(children, x, cursorY, w,
    pageText(i18n, "deadband", "Deadband"),
    {
      label = pageText(i18n, "cyclic", "Cyclic"),
      min = 0,
      max = 100,
      get = function() return ui.config.rc_deadband or 4 end,
      set = function(val)
        if ui.config.rc_deadband ~= val then
          ui.config.rc_deadband = val
          ui.dirty = true
        end
      end
    },
    {
      label = pageText(i18n, "yaw_deadband", "Yaw"),
      min = 0,
      max = 100,
      get = function() return ui.config.rc_yaw_deadband or 4 end,
      set = function(val)
        if ui.config.rc_yaw_deadband ~= val then
          ui.config.rc_yaw_deadband = val
          ui.dirty = true
        end
      end
    }
  )

  -- Throttle row(s) - dynamically drawn based on API version
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isAtLeast = rawApiVersion and ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, { 12, 0, 9 })

  if isAtLeast then
    -- API >= 12.0.9 has no rc_arm_throttle: only Min & Max
    cursorY = cursorY + appendDoubleFieldRow(children, x, cursorY, w,
      pageText(i18n, "throttle", "Throttle"),
      {
        label = pageText(i18n, "min_throttle", "Min"),
        min = 860,
        max = 1500,
        get = function() return ui.config.rc_min_throttle or 1100 end,
        set = function(val)
          if ui.config.rc_min_throttle ~= val then
            ui.config.rc_min_throttle = val
            ui.dirty = true
          end
        end
      },
      {
        label = pageText(i18n, "max_throttle", "Max"),
        min = 1510,
        max = 2150,
        get = function() return ui.config.rc_max_throttle or 1900 end,
        set = function(val)
          if ui.config.rc_max_throttle ~= val then
            ui.config.rc_max_throttle = val
            ui.dirty = true
          end
        end
      }
    )
  else
    -- API < 12.0.9 has Arming, Min, and Max
    cursorY = cursorY + appendDoubleFieldRow(children, x, cursorY, w,
      pageText(i18n, "throttle", "Throttle"),
      {
        label = pageText(i18n, "arming", "Arming"),
        min = 850,
        max = 1500,
        get = function() return ui.config.rc_arm_throttle or 1000 end,
        set = function(val)
          if ui.config.rc_arm_throttle ~= val then
            ui.config.rc_arm_throttle = val
            ui.dirty = true
            validateThrottle()
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end
        end
      },
      {
        label = pageText(i18n, "min_throttle", "Min"),
        min = (ui.config.rc_arm_throttle or 1000) + 10,
        max = 1500,
        get = function() return ui.config.rc_min_throttle or 1100 end,
        set = function(val)
          if ui.config.rc_min_throttle ~= val then
            ui.config.rc_min_throttle = val
            ui.dirty = true
          end
        end
      }
    )

    -- Max Throttle goes on its own row in Column 1
    cursorY = cursorY + appendDoubleFieldRow(children, x, cursorY, w,
      "",
      {
        label = pageText(i18n, "max_throttle", "Max"),
        min = 1510,
        max = 2150,
        get = function() return ui.config.rc_max_throttle or 1900 end,
        set = function(val)
          if ui.config.rc_max_throttle ~= val then
            ui.config.rc_max_throttle = val
            ui.dirty = true
          end
        end
      },
      nil
    )
  end
end

function M.onSave(ctx)
  local ok, err = queueRcWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- Nothing is announced here. This function has only QUEUED the save: the writes, the commit
  -- and -- on this page -- the restart are all still ahead of it, and a dialog saying the
  -- settings are saved would be a claim it cannot make. It was also drawn on TOP of the
  -- overlay that reports the save, from a place where that overlay could not be repainted away
  -- first, and while a native dialog stands the tool's run() does not run at all. The pipeline
  -- reports the outcome in the overlay, once, when it knows it.
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
  local help = loadModule("app/pages/setup/radio_config/help.lua")
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
  RcConfigApi = nil
  ApiVersion = nil
  LoadingOverlay = nil
  t = nil
end

return M
