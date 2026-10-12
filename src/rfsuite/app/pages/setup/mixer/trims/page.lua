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
local MixerConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

local MIXER_OVERRIDE_OFF = 2501
local MIXER_OVERRIDE_ON = 0

local lastChangeTime = 0
local liveUpdateInterval = 0.20 -- 200 ms

local function writeU16(val)
  local lo = val % 256
  local hi = math.floor(val / 256) % 256
  return lo, hi
end

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if os and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  inOverride = false,
  config = {
    tail_rotor_mode = 0,
    swash_trim_0 = 0,
    swash_trim_1 = 0,
    swash_trim_2 = 0,
    tail_center_trim = 0
  },
  apiData = {},
  -- What the board holds as far as this page knows: the trims and the MIXER_CONFIG record of
  -- this visit's read, or of the last save that reached EEPROM. A value sent live under the
  -- override is a trial until Save, and this is what leaving without Save puts back.
  original = nil,
  -- Whether a live write was queued since the snapshot, and the trims it last sent, so the live
  -- loop sends a change once rather than on every pass while the page is dirty.
  liveSent = false,
  liveConfig = nil,
  runtime = {
    readPending = false,
    requestRebuild = nil
  }
}

-- Every record here is a flat table of numbers, so a flat copy is a full copy.
local function copyFlat(src)
  if type(src) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(src) do out[k] = v end
  return out
end

local function sameFlat(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k, v in pairs(b) do
    if a[k] ~= v then return false end
  end
  return true
end

local function takeSnapshot()
  return {
    config = copyFlat(ui.config),
    MIXER_CONFIG = copyFlat(ui.apiData.MIXER_CONFIG)
  }
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not MixerConfigApi then MixerConfigApi = loadModule("tasks/msp/api/mixer_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_mixer") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil
    }
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
  if type(session.setup_mixer_trims) ~= "table" then
    session.setup_mixer_trims = {}
  end
  return session.setup_mixer_trims
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.tail_rotor_mode = rcConfig.tail_rotor_mode or 0
  ui.config.swash_trim_0 = rcConfig.swash_trim_0 or 0
  ui.config.swash_trim_1 = rcConfig.swash_trim_1 or 0
  ui.config.swash_trim_2 = rcConfig.swash_trim_2 or 0
  ui.config.tail_center_trim = rcConfig.tail_center_trim or 0

  if type(rcConfig.apiData) == "table" then
    ui.apiData = rcConfig.apiData
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  rcConfig.tail_rotor_mode = ui.config.tail_rotor_mode
  rcConfig.swash_trim_0 = ui.config.swash_trim_0
  rcConfig.swash_trim_1 = ui.config.swash_trim_1
  rcConfig.swash_trim_2 = ui.config.swash_trim_2
  rcConfig.tail_center_trim = ui.config.tail_center_trim
  rcConfig.apiData = ui.apiData
end

local function setOverride(enabled)
  if not MspRuntime then return end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return end

  local val = MIXER_OVERRIDE_OFF
  if enabled then
    val = MIXER_OVERRIDE_ON
  end

  local lo, hi = writeU16(val)
  for i = 1, 4 do
    queue:add({
      command = 191, -- MSP_SET_MIXER_OVERRIDE
      payload = { i, lo, hi },
      isWrite = true,
      processReply = function() end
    })
  end
end

local function triggerLiveWrite()
  if not MspRuntime or not MixerConfigApi or type(MspRuntime.getState) ~= "function" then return end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return end

  if not queue:isProcessed() then return end

  if not M.canSave() or not ui.apiData.MIXER_CONFIG then return end

  -- The board already has what is on screen.
  if ui.liveConfig and sameFlat(ui.liveConfig, ui.config) then return end

  ui.apiData.MIXER_CONFIG.swash_trim_0 = ui.config.swash_trim_0
  ui.apiData.MIXER_CONFIG.swash_trim_1 = ui.config.swash_trim_1
  ui.apiData.MIXER_CONFIG.swash_trim_2 = ui.config.swash_trim_2
  ui.apiData.MIXER_CONFIG.tail_center_trim = ui.config.tail_center_trim

  local mixerCfgPayload = MixerConfigApi.buildWritePayload(ui.apiData.MIXER_CONFIG)

  -- The acknowledgement leaves the page dirty: the value is in the board's RAM only, and it stays
  -- a trial until Save writes it to EEPROM. A write that went unanswered or was dropped is sent
  -- again on the next pass; one the board refused is not repeated until the value changes.
  queue:add({
    command = MixerConfigApi.writeCommand,
    payload = mixerCfgPayload,
    isWrite = true,
    processReply = function() end,
    errorHandler = function(_, reason) if reason ~= "refused" then ui.liveConfig = nil end end
  })
  ui.liveSent = true
  ui.liveConfig = copyFlat(ui.config)
end

--- Leaving without Save, or Reload: a trim sent live under the override goes back to the
--- snapshot on the board, on screen and in the session copy. Nothing is sent when no live write
--- went out since the snapshot, or when what went out is the snapshot. The payload is built here,
--- not in a reply, because onClose drops this page's modules right after.
local function rollbackLiveChanges()
  local orig = ui.original
  local sent = ui.liveSent
  ui.liveSent = false
  ui.liveConfig = nil
  if not sent or type(orig) ~= "table" or type(orig.MIXER_CONFIG) ~= "table" then return false end
  if sameFlat(ui.apiData.MIXER_CONFIG, orig.MIXER_CONFIG) then return false end
  if not MspRuntime or not MixerConfigApi or type(MspRuntime.getState) ~= "function" then return false end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return false end

  queue:add({
    command = MixerConfigApi.writeCommand,
    payload = MixerConfigApi.buildWritePayload(orig.MIXER_CONFIG),
    isWrite = true,
    processReply = function() end
  })
  ui.apiData.MIXER_CONFIG = copyFlat(orig.MIXER_CONFIG)
  for k, v in pairs(orig.config) do ui.config[k] = v end
  saveToSession()
  return true
end

local function queueTrimsRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not MixerConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.runtime.readPending = true
  ui.original = nil
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.apiData.MIXER_CONFIG = parsed
        ui.config.tail_rotor_mode = parsed.tail_rotor_mode
        ui.config.swash_trim_0 = parsed.swash_trim_0
        ui.config.swash_trim_1 = parsed.swash_trim_1
        ui.config.swash_trim_2 = parsed.swash_trim_2
        ui.config.tail_center_trim = parsed.tail_center_trim
      end

      saveToSession()

      -- Taken here rather than at each field: nothing changes the record between the parse and
      -- this line, because the live write and Save wait for canSave(), false while readPending.
      ui.original = takeSnapshot()
      ui.liveSent = false
      ui.liveConfig = nil

      ui.runtime.readPending = false
      ui.runtime.readComplete = true
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

local function queueTrimsWrite()
  if not MspRuntime or not MixerConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  if not M.canSave() or not ui.apiData.MIXER_CONFIG then
    return false, "loaded_data_missing"
  end

  ui.apiData.MIXER_CONFIG.swash_trim_0 = ui.config.swash_trim_0
  ui.apiData.MIXER_CONFIG.swash_trim_1 = ui.config.swash_trim_1
  ui.apiData.MIXER_CONFIG.swash_trim_2 = ui.config.swash_trim_2
  ui.apiData.MIXER_CONFIG.tail_center_trim = ui.config.tail_center_trim

  local mixerCfgPayload = MixerConfigApi.buildWritePayload(ui.apiData.MIXER_CONFIG)
  local stored = takeSnapshot()
  -- The save sends what is on screen, so the live loop has nothing to send until it changes.
  ui.liveConfig = copyFlat(ui.config)

  queue:add({
    command = MixerConfigApi.writeCommand,
    payload = mixerCfgPayload,
    isWrite = true,
    processReply = function()
      local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
      if eepromApi then
        queue:add({
          command = eepromApi.writeCommand,
          payload = {},
          isWrite = true,
          -- Stored: from now on this is what leaving without Save puts back.
          processReply = function() ui.original = stored end,
          errorHandler = function() end
        })
      end
    end,
    errorHandler = function() end
  })

  return true, nil
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "trims", "Servo Trims")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.inOverride = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueTrimsRead(false)
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
    queueTrimsRead(false)
  end

  if ui.inOverride and ui.dirty then
    local now = nowSeconds()
    if (now - lastChangeTime) >= liveUpdateInterval then
      lastChangeTime = now
      triggerLiveWrite()
    end
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    -- Switching the override on waits for this visit's read, as Save does (M.canSave below):
    -- until then the live write sends nothing. Switching it off is always offered.
    star = ui.inOverride or M.canSave(),
    menu = true
  }
end

-- The page is kept between visits and loadFromSession() puts the last record read back into
-- ui.apiData before this visit's read is even queued, so "a MIXER_CONFIG is there" says nothing
-- about this visit. ui.runtime is dropped by resetPageState() on close, which makes this flag
-- the visit's own: set only by a read that parsed, cleared when a read starts.
-- The live write while the override is on is held back by it too: it sends the same whole record.
function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
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
      message = pageText(i18n, "loading_trims", "Reading trims configuration..."),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()
  if ui.inOverride then
    displayTitle = displayTitle .. " *"
  end

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  -- 1) Roll Trim
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "roll_trim", "Roll trim"),
    {
      min = -1000,
      max = 1000,
      step = 1,
      get = function() return ui.config.swash_trim_0 or 0 end,
      set = function(val)
        if ui.config.swash_trim_0 ~= val then
          ui.config.swash_trim_0 = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%"
    }
  )

  -- 2) Pitch Trim
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "pitch_trim", "Pitch trim"),
    {
      min = -1000,
      max = 1000,
      step = 1,
      get = function() return ui.config.swash_trim_1 or 0 end,
      set = function(val)
        if ui.config.swash_trim_1 ~= val then
          ui.config.swash_trim_1 = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%"
    }
  )

  -- 3) Collective Trim
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_trim", "Col. trim"),
    {
      min = -1000,
      max = 1000,
      step = 1,
      get = function() return ui.config.swash_trim_2 or 0 end,
      set = function(val)
        if ui.config.swash_trim_2 ~= val then
          ui.config.swash_trim_2 = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%"
    }
  )

  -- 4) Yaw Trim (only shown if tail_rotor_mode == 0)
  if ui.config.tail_rotor_mode == 0 then
    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
      pageText(i18n, "yaw_trim", "Yaw. trim"),
      {
        min = -500,
        max = 500,
        step = 1,
        get = function() return ui.config.tail_center_trim or 0 end,
        set = function(val)
          if ui.config.tail_center_trim ~= val then
            ui.config.tail_center_trim = val
            ui.dirty = true
          end
        end,
        display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
        suffix = "%"
      }
    )
  end
end

function M.onSave(ctx)
  local ok, err = queueTrimsWrite()
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
      message = pageText(ctx and ctx.i18n, "saved_message_trims", "Servo trims saved")
    })
  end
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    -- Before the read, so the read is queued behind the rollback and shows the board's value.
    if ui.dirty then rollbackLiveChanges() end
    loadFromSession()
    ui.dirty = false
    queueTrimsRead(false)
  end
  return true
end

function M.onStar(ctx)
  if not ConfirmDialog then return false end
  if not ui.inOverride and not M.canSave() then return false end

  local i18n = ctx and ctx.i18n
  local title
  local message

  if not ui.inOverride then
    title = pageText(i18n, "enable_mixer_override", "Enable swash override")
    message = pageText(i18n, "enable_mixer_message", "Enable swash override so the flight controller centers the servos while adjusting trims. \n\nLive changes from this page are sent to the flight controller.")
  else
    title = pageText(i18n, "disable_mixer_override", "Disable swash override")
    message = pageText(i18n, "disable_mixer_message", "Disable swash override and return mixer control to the flight controller.")
  end

  ConfirmDialog.show({
    title = title,
    message = message,
    onConfirm = function()
      if not ui.inOverride then
        -- Checked again: Yes comes later than the press, and the page may have closed since.
        if not M.canSave() then return end
        setOverride(true)
        ui.inOverride = true
      else
        setOverride(false)
        ui.inOverride = false
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true
end


function M.onClose()
  -- An unsaved trim sent live is taken back first, while the override still holds the servos.
  -- Queued ahead of the override writes on purpose: should the close end before every write is
  -- out, a lost override write leaves a board that refuses to arm, a lost rollback a trial trim
  -- the model would fly with. Save clears dirty, so a save still on its way is not undone here.
  if ui.dirty then rollbackLiveChanges() end
  if ui.inOverride then
    setOverride(false)
    ui.inOverride = false
  end
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  MixerConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

return M
