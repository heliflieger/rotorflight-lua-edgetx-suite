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
local MixerInputPitchApi = nil
local MixerInputRollApi = nil
local MixerInputCollectiveApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local t = nil

local MIXER_OVERRIDE_OFF = 2501
local MIXER_OVERRIDE_ON = 0
local MIXER_OVERRIDE_PASSTHROUGH = 2502

local lastChangeTime = 0
local liveUpdateInterval = 0.20 -- 200 ms

local function u16_to_s16(u)
  if u >= 0x8000 then
    return u - 0x10000
  else
    return u
  end
end

local function s16_to_u16(s)
  if s < 0 then return s + 0x10000 end
  return s
end

local function rateToDir(u16rate)
  return (u16_to_s16(u16rate) < 0) and 0 or 1
end

local function dirSign(d)
  return (d == 0) and -1 or 1
end

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
    cyclic_calibration = 400,
    collective_calibration = 400,
    geo_correction = 0,
    cyclic_pitch_limit = 20,
    collective_pitch_limit = 20,
    swash_pitch_limit = 200,
    swash_phase = 0,
    collective_tilt_correction_pos = 0,
    collective_tilt_correction_neg = 0,
    ail_direction = 1,
    ele_direction = 1,
    col_direction = 1
  },
  apiData = {},
  -- What the board holds as far as this page knows: the geometry and its four records (mixer
  -- configuration, pitch, roll and collective inputs) of this visit's read, or of the last save
  -- that reached EEPROM. A value sent live in setup mode is a trial until Save, and this is what
  -- leaving without Save puts back.
  original = nil,
  -- Whether a live write was queued since the snapshot, and the geometry it last sent, so the live
  -- loop sends a change once rather than on every pass while the page is dirty.
  liveSent = false,
  liveConfig = nil,
  runtime = {
    readPending = false,
    requestRebuild = nil
  }
}

-- The four records, in the order the page writes them.
local RECORDS = { "MIXER_CONFIG", "GET_MIXER_INPUT_PITCH", "GET_MIXER_INPUT_ROLL", "GET_MIXER_INPUT_COLLECTIVE" }

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
  local snap = { config = copyFlat(ui.config) }
  for i = 1, #RECORDS do
    snap[RECORDS[i]] = copyFlat(ui.apiData[RECORDS[i]])
  end
  return snap
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
  if not MixerInputPitchApi then MixerInputPitchApi = loadModule("tasks/msp/api/get_mixer_input_pitch.lua") end
  if not MixerInputRollApi then MixerInputRollApi = loadModule("tasks/msp/api/get_mixer_input_roll.lua") end
  if not MixerInputCollectiveApi then MixerInputCollectiveApi = loadModule("tasks/msp/api/get_mixer_input_collective.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
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
  if type(session.setup_mixer_swashgeometry) ~= "table" then
    session.setup_mixer_swashgeometry = {}
  end
  return session.setup_mixer_swashgeometry
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.cyclic_calibration = rcConfig.cyclic_calibration or 400
  ui.config.collective_calibration = rcConfig.collective_calibration or 400
  ui.config.geo_correction = rcConfig.geo_correction or 0
  ui.config.cyclic_pitch_limit = rcConfig.cyclic_pitch_limit or 20
  ui.config.collective_pitch_limit = rcConfig.collective_pitch_limit or 20
  ui.config.swash_pitch_limit = rcConfig.swash_pitch_limit or 200
  ui.config.swash_phase = rcConfig.swash_phase or 0
  ui.config.collective_tilt_correction_pos = rcConfig.collective_tilt_correction_pos or 0
  ui.config.collective_tilt_correction_neg = rcConfig.collective_tilt_correction_neg or 0
  ui.config.ail_direction = rcConfig.ail_direction or 1
  ui.config.ele_direction = rcConfig.ele_direction or 1
  ui.config.col_direction = rcConfig.col_direction or 1

  if type(rcConfig.apiData) == "table" then
    ui.apiData = rcConfig.apiData
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  rcConfig.cyclic_calibration = ui.config.cyclic_calibration
  rcConfig.collective_calibration = ui.config.collective_calibration
  rcConfig.geo_correction = ui.config.geo_correction
  rcConfig.cyclic_pitch_limit = ui.config.cyclic_pitch_limit
  rcConfig.collective_pitch_limit = ui.config.collective_pitch_limit
  rcConfig.swash_pitch_limit = ui.config.swash_pitch_limit
  rcConfig.swash_phase = ui.config.swash_phase
  rcConfig.collective_tilt_correction_pos = ui.config.collective_tilt_correction_pos
  rcConfig.collective_tilt_correction_neg = ui.config.collective_tilt_correction_neg
  rcConfig.ail_direction = ui.config.ail_direction
  rcConfig.ele_direction = ui.config.ele_direction
  rcConfig.col_direction = ui.config.col_direction
  rcConfig.apiData = ui.apiData
end

local function isAtLeastVersion(req)
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  if not rawApiVersion or rawApiVersion == "" or tostring(rawApiVersion) == "0" then
    return false
  end
  return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, req)
end

local function mixerOverrideOnValue()
  if isAtLeastVersion({12, 0, 8}) then
    return MIXER_OVERRIDE_PASSTHROUGH
  end
  return MIXER_OVERRIDE_ON
end

local function setOverride(enabled)
  if not MspRuntime then return end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return end

  local val = MIXER_OVERRIDE_OFF
  if enabled then
    val = mixerOverrideOnValue()
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

local function copyConfigToApi()
  local config = ui.config
  local apiData = ui.apiData

  local pConfig = apiData.MIXER_CONFIG
  local pPitch = apiData.GET_MIXER_INPUT_PITCH
  local pRoll = apiData.GET_MIXER_INPUT_ROLL
  local pColl = apiData.GET_MIXER_INPUT_COLLECTIVE

  if not pConfig or not pPitch or not pRoll or not pColl then
    return false
  end

  local cyclicRate = math.floor(config.cyclic_calibration + 0.5)
  local collRate = math.floor(config.collective_calibration + 0.5)

  local cyclicMax_raw = math.floor((config.cyclic_pitch_limit or 0) * 100 / 12 + 0.5)
  local collMax_raw   = math.floor((config.collective_pitch_limit or 0) * 100 / 12 + 0.5)

  -- MIXER_CONFIG
  pConfig.swash_geo_correction = math.floor((config.geo_correction or 0) / 2 + 0.5)
  pConfig.swash_pitch_limit = math.floor((config.swash_pitch_limit or 0) * 100 / 12 + 0.5)
  pConfig.swash_phase = math.floor(config.swash_phase or 0)
  pConfig.collective_tilt_correction_pos = math.floor(config.collective_tilt_correction_pos or 0)
  pConfig.collective_tilt_correction_neg = math.floor(config.collective_tilt_correction_neg or 0)

  -- PITCH
  local pitchVal = cyclicRate * dirSign(ui.config.ele_direction)
  pPitch.rate_stabilized_pitch = s16_to_u16(pitchVal)
  pPitch.max_stabilized_pitch = s16_to_u16(math.abs(cyclicMax_raw))
  pPitch.min_stabilized_pitch = s16_to_u16(-math.abs(cyclicMax_raw))

  -- ROLL
  local rollVal = cyclicRate * dirSign(ui.config.ail_direction)
  pRoll.rate_stabilized_roll = s16_to_u16(rollVal)
  pRoll.max_stabilized_roll = s16_to_u16(math.abs(cyclicMax_raw))
  pRoll.min_stabilized_roll = s16_to_u16(-math.abs(cyclicMax_raw))

  -- COLLECTIVE
  local collVal = collRate * dirSign(ui.config.col_direction)
  pColl.rate_stabilized_collective = s16_to_u16(collVal)
  pColl.max_stabilized_collective = s16_to_u16(math.abs(collMax_raw))
  pColl.min_stabilized_collective = s16_to_u16(-math.abs(collMax_raw))

  return true
end

local function triggerLiveWrite()
  if not MspRuntime then return end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return end

  if not queue:isProcessed() then return end

  if not M.canSave() then return end
  -- The board already has what is on screen.
  if ui.liveConfig and sameFlat(ui.liveConfig, ui.config) then return end
  if not copyConfigToApi() then return end

  local mixerCfgPayload = MixerConfigApi.buildWritePayload(ui.apiData.MIXER_CONFIG)
  local pitchPayload = MixerInputPitchApi.buildWritePayload(ui.apiData.GET_MIXER_INPUT_PITCH)
  local rollPayload = MixerInputRollApi.buildWritePayload(ui.apiData.GET_MIXER_INPUT_ROLL)
  local collectivePayload = MixerInputCollectiveApi.buildWritePayload(ui.apiData.GET_MIXER_INPUT_COLLECTIVE)

  ui.liveSent = true
  ui.liveConfig = copyFlat(ui.config)

  -- All four queued at once rather than each from the reply before it: a rollback or a read
  -- queued while a chain was still running would otherwise land between its links, and the
  -- rest of the trial would reach the board after it. The acknowledgements leave the page
  -- dirty: the values are in the board's RAM only, and they stay a trial until Save writes them
  -- to EEPROM. A write that went unanswered or was dropped is sent again on the next pass; one
  -- the board refused is not repeated until the value changes.
  local writes = {
    { MixerConfigApi.writeCommand, mixerCfgPayload },
    { MixerInputPitchApi.writeCommand, pitchPayload },
    { MixerInputRollApi.writeCommand, rollPayload },
    { MixerInputCollectiveApi.writeCommand, collectivePayload }
  }
  for i = 1, #writes do
    queue:add({
      command = writes[i][1],
      payload = writes[i][2],
      isWrite = true,
      processReply = function() end,
      errorHandler = function(_, reason) if reason ~= "refused" then ui.liveConfig = nil end end
    })
  end
end

--- Leaving without Save, or Reload: geometry sent live in setup mode goes back to the snapshot on
--- the board, on screen and in the session copy. Only a record that differs from the snapshot is
--- written, all of them queued at once, so they are ahead of whatever is queued after this call.
--- Nothing is sent when no live write went out since the snapshot. The payloads are built here,
--- not in a reply, because onClose drops this page's modules right after.
local function rollbackLiveChanges()
  local orig = ui.original
  local sent = ui.liveSent
  ui.liveSent = false
  ui.liveConfig = nil
  if not sent or type(orig) ~= "table" then return false end
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return false end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return false end

  local apis = { MixerConfigApi, MixerInputPitchApi, MixerInputRollApi, MixerInputCollectiveApi }
  local changed = false
  for i = 1, #RECORDS do
    local key = RECORDS[i]
    local api = apis[i]
    local rec = orig[key]
    if api and type(rec) == "table" and not sameFlat(ui.apiData[key], rec) then
      queue:add({
        command = api.writeCommand,
        payload = api.buildWritePayload(rec),
        isWrite = true,
        processReply = function() end
      })
      ui.apiData[key] = copyFlat(rec)
      changed = true
    end
  end
  if not changed then return false end

  for k, v in pairs(orig.config) do ui.config[k] = v end
  saveToSession()
  return true
end

local function queueGeometryRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not MixerConfigApi or not MixerInputPitchApi or not MixerInputRollApi or not MixerInputCollectiveApi or type(MspRuntime.getState) ~= "function" then
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

  -- Step 1: Read MIXER_CONFIG
  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.apiData.MIXER_CONFIG = parsed
        ui.config.geo_correction = parsed.swash_geo_correction * 2
        ui.config.swash_pitch_limit = math.floor(parsed.swash_pitch_limit * 12 / 100 + 0.5)
        ui.config.swash_phase = parsed.swash_phase
        ui.config.collective_tilt_correction_pos = parsed.collective_tilt_correction_pos
        ui.config.collective_tilt_correction_neg = parsed.collective_tilt_correction_neg
      end

      ui.progress = 25
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      -- Step 2: Read GET_MIXER_INPUT_PITCH
      queue:add({
        command = MixerInputPitchApi.command,
        payload = { 2 },
        simulatorResponse = MixerInputPitchApi.simulatorResponse,
        processReply = function(self, buf)
          local parsed = MixerInputPitchApi.parse(buf)
          if type(parsed) ~= "table" then return Common.failPageRead(ui) end
          if parsed then
            ui.apiData.GET_MIXER_INPUT_PITCH = parsed
            ui.config.ele_direction = rateToDir(parsed.rate_stabilized_pitch)
            local cyclic_cal = u16_to_s16(parsed.rate_stabilized_pitch)
            ui.config.cyclic_calibration = math.abs(cyclic_cal)
            local cyclic_lim = u16_to_s16(parsed.max_stabilized_pitch)
            ui.config.cyclic_pitch_limit = math.floor(math.abs(cyclic_lim) * 12 / 100 + 0.5)
          end

          ui.progress = 50
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end

          -- Step 3: Read GET_MIXER_INPUT_ROLL
          queue:add({
            command = MixerInputRollApi.command,
            payload = { 1 },
            simulatorResponse = MixerInputRollApi.simulatorResponse,
            processReply = function(self, buf)
              local parsed = MixerInputRollApi.parse(buf)
              if type(parsed) ~= "table" then return Common.failPageRead(ui) end
              if parsed then
                ui.apiData.GET_MIXER_INPUT_ROLL = parsed
                ui.config.ail_direction = rateToDir(parsed.rate_stabilized_roll)
              end

              ui.progress = 75
              if type(ui.runtime.requestRebuild) == "function" then
                ui.runtime.requestRebuild()
              end

              -- Step 4: Read GET_MIXER_INPUT_COLLECTIVE
              queue:add({
                command = MixerInputCollectiveApi.command,
                payload = { 4 },
                simulatorResponse = MixerInputCollectiveApi.simulatorResponse,
                processReply = function(self, buf)
                  local parsed = MixerInputCollectiveApi.parse(buf)
                  if type(parsed) ~= "table" then return Common.failPageRead(ui) end
                  if parsed then
                    ui.apiData.GET_MIXER_INPUT_COLLECTIVE = parsed
                    ui.config.col_direction = rateToDir(parsed.rate_stabilized_collective)
                    local coll_cal = u16_to_s16(parsed.rate_stabilized_collective)
                    ui.config.collective_calibration = math.abs(coll_cal)
                    local coll_lim = u16_to_s16(parsed.max_stabilized_collective)
                    ui.config.collective_pitch_limit = math.floor(math.abs(coll_lim) * 12 / 100 + 0.5)
                  end

                  saveToSession()

                  -- Taken here rather than at each parse: nothing changes the four records
                  -- between their parse and this line, because the live write and Save wait for
                  -- canSave(), false while readPending.
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

local function queueGeometryWrite()
  if not MspRuntime or not MixerConfigApi or not MixerInputPitchApi or not MixerInputRollApi or not MixerInputCollectiveApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  if not M.canSave() or not copyConfigToApi() then
    return false, "loaded_data_missing"
  end

  local mixerCfgPayload = MixerConfigApi.buildWritePayload(ui.apiData.MIXER_CONFIG)
  local pitchPayload = MixerInputPitchApi.buildWritePayload(ui.apiData.GET_MIXER_INPUT_PITCH)
  local rollPayload = MixerInputRollApi.buildWritePayload(ui.apiData.GET_MIXER_INPUT_ROLL)
  local collectivePayload = MixerInputCollectiveApi.buildWritePayload(ui.apiData.GET_MIXER_INPUT_COLLECTIVE)
  local stored = takeSnapshot()
  -- The save sends what is on screen, so the live loop has nothing to send until it changes.
  ui.liveConfig = copyFlat(ui.config)

  queue:add({
    command = MixerConfigApi.writeCommand,
    payload = mixerCfgPayload,
    isWrite = true,
    processReply = function()
      queue:add({
        command = MixerInputPitchApi.writeCommand,
        payload = pitchPayload,
        isWrite = true,
        processReply = function()
          queue:add({
            command = MixerInputRollApi.writeCommand,
            payload = rollPayload,
            isWrite = true,
            processReply = function()
              queue:add({
                command = MixerInputCollectiveApi.writeCommand,
                payload = collectivePayload,
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
            end,
            errorHandler = function() end
          })
        end,
        errorHandler = function() end
      })
    end,
    errorHandler = function() end
  })

  return true, nil
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "geometry", "Swashplate Geometry")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.inOverride = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueGeometryRead(false)
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
    queueGeometryRead(false)
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
    -- Switching setup mode on waits for this visit's read, as Save does (M.canSave below):
    -- until then the live write sends nothing. Switching it off is always offered.
    star = ui.inOverride or M.canSave(),
    menu = true
  }
end

-- The page is kept between visits and loadFromSession() puts the last records read back into
-- ui.apiData before this visit's read is even queued, so "the records are there" says nothing
-- about this visit. ui.runtime is dropped by resetPageState() on close, which makes this flag
-- the visit's own: set only when every read of the chain parsed, cleared when a read starts.
-- The live write in setup mode is held back by it too: it sends the same whole records.
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
      message = pageText(i18n, "loading_geometry", "Reading swashplate geometry configuration..."),
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

  -- 1) Cyclic Calibration
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "cyclic_calibration", "Cyclic Calibration"),
    {
      min = 200,
      max = 2000,
      step = 1,
      get = function() return ui.config.cyclic_calibration or 400 end,
      set = function(val)
        if ui.config.cyclic_calibration ~= val then
          ui.config.cyclic_calibration = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%"
    }
  )

  -- 2) Collective Calibration
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_calibration", "Collective Calibration"),
    {
      min = 200,
      max = 2000,
      step = 1,
      get = function() return ui.config.collective_calibration or 400 end,
      set = function(val)
        if ui.config.collective_calibration ~= val then
          ui.config.collective_calibration = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%"
    }
  )

  -- 3) Geo Correction
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "geo_correction", "Geo Correction"),
    {
      min = -250,
      max = 250,
      step = 2,
      get = function() return ui.config.geo_correction or 0 end,
      set = function(val)
        if ui.config.geo_correction ~= val then
          ui.config.geo_correction = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%"
    }
  )

  -- 4) Cyclic Pitch Limit
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "cyclic_pitch_limit", "Cyclic Pitch Limit"),
    {
      min = 0,
      max = 200,
      step = 1,
      get = function() return ui.config.cyclic_pitch_limit or 20 end,
      set = function(val)
        if ui.config.cyclic_pitch_limit ~= val then
          ui.config.cyclic_pitch_limit = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°"
    }
  )

  -- 5) Collective Pitch Limit
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_pitch_limit", "Collective Pitch Limit"),
    {
      min = 0,
      max = 200,
      step = 1,
      get = function() return ui.config.collective_pitch_limit or 20 end,
      set = function(val)
        if ui.config.collective_pitch_limit ~= val then
          ui.config.collective_pitch_limit = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°"
    }
  )

  -- 6) Total Pitch Limit
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "swash_pitch_limit", "Total Pitch Limit"),
    {
      min = 0,
      max = 360,
      step = 1,
      get = function() return ui.config.swash_pitch_limit or 200 end,
      set = function(val)
        if ui.config.swash_pitch_limit ~= val then
          ui.config.swash_pitch_limit = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°"
    }
  )

  -- 7) Phase Angle
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "swash_phase", "Phase Angle"),
    {
      min = -1800,
      max = 1800,
      step = 1,
      get = function() return ui.config.swash_phase or 0 end,
      set = function(val)
        if ui.config.swash_phase ~= val then
          ui.config.swash_phase = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°"
    }
  )

  -- 8) Collective Tilt Correction +
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_tilt_correction_pos", "Collective Tilt Correction +"),
    {
      min = -100,
      max = 100,
      step = 1,
      get = function() return ui.config.collective_tilt_correction_pos or 0 end,
      set = function(val)
        if ui.config.collective_tilt_correction_pos ~= val then
          ui.config.collective_tilt_correction_pos = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v or 0) .. "%" end,
      suffix = "%"
    }
  )

  -- 9) Collective Tilt Correction -
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_tilt_correction_neg", "Collective Tilt Correction -"),
    {
      min = -100,
      max = 100,
      step = 1,
      get = function() return ui.config.collective_tilt_correction_neg or 0 end,
      set = function(val)
        if ui.config.collective_tilt_correction_neg ~= val then
          ui.config.collective_tilt_correction_neg = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v or 0) .. "%" end,
      suffix = "%"
    }
  )
end

function M.onSave(ctx)
  local ok, err = queueGeometryWrite()
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
      message = pageText(ctx and ctx.i18n, "saved_message_geometry", "Swashplate geometry settings saved")
    })
  end
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    -- Before the read, so the read is queued behind the rollback and shows the board's values.
    if ui.dirty then rollbackLiveChanges() end
    loadFromSession()
    ui.dirty = false
    queueGeometryRead(false)
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
    title = pageText(i18n, "enable_swash_override", "Enable swash setup mode")
    message = pageText(i18n, "enable_swash_override_message", "Enable passthrough mixer override so you can move the sticks while adjusting swash geometry. \n\nLive changes from this page are sent to the flight controller.")
  else
    title = pageText(i18n, "disable_swash_override", "Disable swash setup mode")
    message = pageText(i18n, "disable_swash_override_message", "Disable swash setup mode and return mixer control to the flight controller.")
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
  -- Unsaved geometry sent live is taken back first, while setup mode is still on. Queued ahead of
  -- the override writes on purpose: should the close end before every write is out, a lost
  -- override write leaves a board that refuses to arm, a lost rollback a trial geometry the model
  -- would fly with. Save clears dirty, so a save still on its way is not undone here.
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
  MixerInputPitchApi = nil
  MixerInputRollApi = nil
  MixerInputCollectiveApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

return M
