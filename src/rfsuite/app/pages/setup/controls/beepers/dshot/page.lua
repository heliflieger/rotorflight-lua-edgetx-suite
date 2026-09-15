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
local BeeperConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

local DSHOT_FIELDS = {
  { bit = 1, key = "field_rx_lost", default = "RX lost" },
  { bit = 9, key = "field_rx_set", default = "RX set" }
}

local ui = {
  loaded = false,
  dirty = false,
  config = {
    beeper_off_flags = 0,
    dshotBeaconTone = 1,
    dshotBeaconOffFlags = 0
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
  if not BeeperConfigApi then BeeperConfigApi = loadModule("tasks/msp/api/beeper_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_beepers") or nil end
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

local function isBitSet(mask, bit)
  local m = tonumber(mask or 0) or 0
  return (m & (1 << bit)) ~= 0
end

local function setBit(mask, bit, set)
  local m = tonumber(mask or 0) or 0
  local f = (1 << bit)
  if set then
    return (m | f)
  end
  return (m & (~f))
end

local function isDshotConditionEnabled(bit)
  local offMask = tonumber(ui.config.dshotBeaconOffFlags or 0) or 0
  return not isBitSet(offMask, bit)
end

local function setDshotConditionEnabled(bit, enabled)
  ui.config.dshotBeaconOffFlags = setBit(ui.config.dshotBeaconOffFlags, bit, not enabled)
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_beepers) ~= "table" then return end
  ui.config.beeper_off_flags = tonumber(session.setup_beepers.beeper_off_flags) or 0
  ui.config.dshotBeaconTone = tonumber(session.setup_beepers.dshotBeaconTone) or 1
  ui.config.dshotBeaconOffFlags = tonumber(session.setup_beepers.dshotBeaconOffFlags) or 0
end

local function queueBeeperConfigRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not BeeperConfigApi or type(MspRuntime.getState) ~= "function" then
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

  queue:add({
    command = BeeperConfigApi.command,
    simulatorResponse = BeeperConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = BeeperConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.beeper_off_flags = parsed.beeper_off_flags or 0
        ui.config.dshotBeaconTone = parsed.dshotBeaconTone or 1
        ui.config.dshotBeaconOffFlags = parsed.dshotBeaconOffFlags or 0
        
        -- Sync to session
        local session = getSession()
        if session then
          if type(session.setup_beepers) ~= "table" then
            session.setup_beepers = {}
          end
          session.setup_beepers.beeper_off_flags = ui.config.beeper_off_flags
          session.setup_beepers.dshotBeaconTone = ui.config.dshotBeaconTone
          session.setup_beepers.dshotBeaconOffFlags = ui.config.dshotBeaconOffFlags
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

local function queueBeeperConfigWrite(requestRebuild)
  if not MspRuntime or not BeeperConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local payload = BeeperConfigApi.buildWritePayload({
    beeper_off_flags = ui.config.beeper_off_flags,
    dshotBeaconTone = ui.config.dshotBeaconTone,
    dshotBeaconOffFlags = ui.config.dshotBeaconOffFlags
  })

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end

  queue:add({
    command = BeeperConfigApi.writeCommand,
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
            ui.dirty = false
            ui.saving = false
            queueBeeperConfigRead(true)
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

  ui.config = {
    beeper_off_flags = 0,
    dshotBeaconTone = 1,
    dshotBeaconOffFlags = 0
  }

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  queueBeeperConfigRead(false)
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
    local msgText = ui.loading and pageText(i18n, "loading", "Loading beeper configuration...") or pageText(i18n, "saving", "Saving beeper configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "ESC Beacon"
  local title = pageText(i18n, "title_dshot", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- Tone options dropdown (choices 1 to 5)
  local toneOptions = {
    { label = "1", value = 1 },
    { label = "2", value = 2 },
    { label = "3", value = 3 },
    { label = "4", value = 4 },
    { label = "5", value = 5 }
  }

  cursorY = cursorY + Controls.appendComboSelect(
    children,
    x, cursorY, w,
    pageText(i18n, "dshot_tone", "ESC beacon tone"),
    toneOptions,
    ui.config.dshotBeaconTone,
    function(val)
      ui.config.dshotBeaconTone = val
      ui.dirty = true
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  )

  -- Condition switches
  for i = 1, #DSHOT_FIELDS do
    local def = DSHOT_FIELDS[i]
    local label = pageText(i18n, def.key, def.default)
    
    cursorY = cursorY + Controls.appendRadioSwitch(
      children,
      x, cursorY, w,
      label,
      function()
        return isDshotConditionEnabled(def.bit)
      end,
      function(v)
        setDshotConditionEnabled(def.bit, v)
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    )
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
  local ok, err = queueBeeperConfigWrite(ctx and ctx.requestRebuild)
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
    queueBeeperConfigRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/beepers/dshot/help.lua")
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
  BeeperConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

return M
