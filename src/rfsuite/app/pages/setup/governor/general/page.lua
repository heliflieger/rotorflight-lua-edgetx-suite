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
local GovernorConfigApi = nil
local LoadingOverlay = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  config = {
    gov_mode = 0,
    gov_throttle_type = 0,
    governor_idle_throttle = 10,
    governor_auto_throttle = 10,
    gov_handover_throttle = 20,
    gov_throttle_hold_timeout = 50
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
  if not GovernorConfigApi then GovernorConfigApi = loadModule("tasks/msp/api/governor_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_governor") or nil end
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
  if not session or type(session.governor_config) ~= "table" then return end
  local cached = session.governor_config
  ui.config.gov_mode = tonumber(cached.gov_mode) or 0
  ui.config.gov_throttle_type = tonumber(cached.gov_throttle_type) or 0
  ui.config.governor_idle_throttle = tonumber(cached.governor_idle_throttle) or 10
  ui.config.governor_auto_throttle = tonumber(cached.governor_auto_throttle) or 10
  ui.config.gov_handover_throttle = tonumber(cached.gov_handover_throttle) or 20
  ui.config.gov_throttle_hold_timeout = tonumber(cached.gov_throttle_hold_timeout) or 50
  ui.parsedCache = cached
end

local function queueGovRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not GovernorConfigApi or type(MspRuntime.getState) ~= "function" then
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
    command = GovernorConfigApi.command,
    simulatorResponse = GovernorConfigApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(self, buf)
      local parsed = GovernorConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.gov_mode = parsed.gov_mode or 0
        ui.config.gov_throttle_type = parsed.gov_throttle_type or 0
        ui.config.governor_idle_throttle = parsed.governor_idle_throttle or 10
        ui.config.governor_auto_throttle = parsed.governor_auto_throttle or 10
        ui.config.gov_handover_throttle = parsed.gov_handover_throttle or 20
        ui.config.gov_throttle_hold_timeout = parsed.gov_throttle_hold_timeout or 50
        ui.parsedCache = parsed

        local session = getSession()
        if session then
          session.governor_config = parsed
          session.governorMode = parsed.gov_mode
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

local function queueGovWrite(requestRebuild, ctx)
  if not MspRuntime or not GovernorConfigApi or type(MspRuntime.getState) ~= "function" then
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

  writeData.gov_mode = ui.config.gov_mode
  writeData.gov_throttle_type = ui.config.gov_throttle_type
  writeData.governor_idle_throttle = ui.config.governor_idle_throttle
  writeData.governor_auto_throttle = ui.config.governor_auto_throttle
  writeData.gov_handover_throttle = ui.config.gov_handover_throttle
  writeData.gov_throttle_hold_timeout = ui.config.gov_throttle_hold_timeout

  local payload = GovernorConfigApi.buildWritePayload(writeData)

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end

  queue:add({
    command = GovernorConfigApi.writeCommand,
    payload = payload,
    isWrite = true,
    simulatorResponse = {},
    processReply = function()
      -- Write EEPROM
      local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
      if eepromApi then
        queue:add({
          command = eepromApi.writeCommand,
          payload = {},
          isWrite = true,
          simulatorResponse = {},
          processReply = function()
            ui.dirty = false
            ui.saving = false
            ui.parsedCache = writeData
            local session = getSession()
            if session then
              session.governor_config = writeData
              session.governorMode = writeData.gov_mode
            end
            if ctx and type(ctx.reportSave) == "function" then
              ctx.reportSave({
                ok = true,
                title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
                message = pageText(ctx and ctx.i18n, "saved_message", "Governor settings saved")
              })
            end
            if type(requestRebuild) == "function" then
              requestRebuild()
            end
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
        ui.parsedCache = writeData
        local session = getSession()
        if session then
          session.governor_config = writeData
          session.governorMode = writeData.gov_mode
        end
        if ctx and type(ctx.reportSave) == "function" then
          ctx.reportSave({
            ok = true,
            title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
            message = pageText(ctx and ctx.i18n, "saved_message", "Governor settings saved")
          })
        end
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

  ui.config = {
    gov_mode = 0,
    gov_throttle_type = 0,
    governor_idle_throttle = 10,
    governor_auto_throttle = 10,
    gov_handover_throttle = 20,
    gov_throttle_hold_timeout = 50
  }
  ui.parsedCache = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  queueGovRead(false)
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
    local titleText = ui.loading and pageText(i18n, "loading_title", "Loading") or pageText(i18n, "saving_title", "Saving")
    local msgText = ui.loading and pageText(i18n, "loading", "Loading governor configuration...") or pageText(i18n, "saving", "Saving governor configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "General"
  local title = pageText(i18n, "general", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- Mode Options
  local modeOptions = {
    { value = 0, label = pageText(i18n, "mode_off", "OFF") },
    { value = 1, label = pageText(i18n, "mode_limit", "LIMIT") },
    { value = 2, label = pageText(i18n, "mode_direct", "DIRECT") },
    { value = 3, label = pageText(i18n, "mode_electric", "ELECTRIC") },
    { value = 4, label = pageText(i18n, "mode_nitro", "NITRO") }
  }

  -- Throttle Type Options
  local throttleTypeOptions = {
    { value = 0, label = pageText(i18n, "throttle_type_normal", "NORMAL") },
    { value = 1, label = pageText(i18n, "throttle_type_switch", "SWITCH") },
    { value = 2, label = pageText(i18n, "throttle_type_function", "FUNCTION") }
  }

  -- 1. Mode
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "mode", "Mode"),
    modeOptions,
    ui.config.gov_mode,
    function(newVal)
      local val = tonumber(newVal) or 0
      if ui.config.gov_mode ~= val then
        ui.config.gov_mode = val
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  )

  -- 2. Throttle type
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "throttle_type", "Throttle type"),
    throttleTypeOptions,
    ui.config.gov_throttle_type,
    function(newVal)
      local val = tonumber(newVal) or 0
      if ui.config.gov_throttle_type ~= val then
        ui.config.gov_throttle_type = val
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  )

  -- 3. Idle throttle (stored in 0.1%, e.g. 10 = 1.0%)
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "idle_throttle", "Idle throttle"),
    {
      min = 0,
      max = 250,
      step = 1,
      get = function() return ui.config.governor_idle_throttle end,
      set = function(v)
        ui.config.governor_idle_throttle = tonumber(v) or 0
        ui.dirty = true
      end,
      display = function(v)
        return string.format("%.1f%%", (tonumber(v) or 0) / 10)
      end
    }
  )

  -- 4. Auto throttle (stored in 0.1%, e.g. 10 = 1.0%)
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "auto_throttle", "Auto throttle"),
    {
      min = 0,
      max = 250,
      step = 1,
      get = function() return ui.config.governor_auto_throttle end,
      set = function(v)
        ui.config.governor_auto_throttle = tonumber(v) or 0
        ui.dirty = true
      end,
      display = function(v)
        return string.format("%.1f%%", (tonumber(v) or 0) / 10)
      end
    }
  )

  -- 5. Handover throttle%
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "handover_throttle", "Handover throttle%"),
    {
      min = 0,
      max = 100,
      step = 1,
      suffix = "%",
      get = function() return ui.config.gov_handover_throttle end,
      set = function(v)
        ui.config.gov_handover_throttle = tonumber(v) or 20
        ui.dirty = true
      end,
      display = function(v)
        return tostring(tonumber(v) or 0) .. "%"
      end
    }
  )

  -- 6. Throttle hold timeout (stored in 0.1s, e.g. 50 = 5.0s)
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "throttle_hold_timeout", "Throttle hold timeout"),
    {
      min = 0,
      max = 250,
      step = 1,
      get = function() return ui.config.gov_throttle_hold_timeout end,
      set = function(v)
        ui.config.gov_throttle_hold_timeout = tonumber(v) or 50
        ui.dirty = true
      end,
      display = function(v)
        return string.format("%.1fs", (tonumber(v) or 0) / 10)
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
  local ok, err = queueGovWrite(ctx and ctx.requestRebuild, ctx)
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
    queueGovRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/governor/general/help.lua")
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
  GovernorConfigApi = nil
  LoadingOverlay = nil
  t = nil
end

return M
