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
local RxfailConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

local channelKeys = {
  "roll", "pitch", "yaw", "collective", "throttle",
  "aux1", "aux2", "aux3", "aux4", "aux5", "aux6", "aux7", "aux8", "aux9", "aux10", "aux11", "aux12", "aux13"
}
local channelDefaultNames = {
  "Roll", "Pitch", "Yaw", "Collective", "Throttle",
  "AUX 1", "AUX 2", "AUX 3", "AUX 4", "AUX 5", "AUX 6", "AUX 7", "AUX 8", "AUX 9", "AUX 10", "AUX 11", "AUX 12", "AUX 13"
}

local ui = {
  loaded = false,
  dirty = false,
  channels = {}, -- index 1..18, each { mode = 0, value = 1500 }
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil
  },
  loading = false,
  progress = 0,
  baseTitle = nil,
  dirtyChannels = {} -- maps channelIndex (1..18) -> true
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not RxfailConfigApi then RxfailConfigApi = loadModule("tasks/msp/api/rxfail_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_failsafe") or nil end
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
  if not session or type(session.setup_controls_failsafe) ~= "table" then return end
  for i = 1, 18 do
    local ch = session.setup_controls_failsafe[i]
    if ch then
      ui.channels[i] = {
        mode = tonumber(ch.mode) or 0,
        value = tonumber(ch.value) or 1500
      }
    end
  end
end

local function queueFailsafeRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not RxfailConfigApi or type(MspRuntime.getState) ~= "function" then
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
    command = RxfailConfigApi.command,
    simulatorResponse = RxfailConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = RxfailConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        for i = 1, 18 do
          ui.channels[i] = {
            mode = parsed["channel_" .. i .. "_mode"] or 0,
            value = parsed["channel_" .. i .. "_value"] or 1500
          }
        end
        -- Sync to session
        local session = getSession()
        if session then
          if type(session.setup_controls_failsafe) ~= "table" then
            session.setup_controls_failsafe = {}
          end
          for i = 1, 18 do
            session.setup_controls_failsafe[i] = {
              mode = ui.channels[i].mode,
              value = ui.channels[i].value
            }
          end
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

local function queueFailsafeWrite(requestRebuild)
  if not MspRuntime or not RxfailConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  -- collect all dirty channels
  local dirtyIdxs = {}
  for i = 1, 18 do
    if ui.dirtyChannels[i] then
      dirtyIdxs[#dirtyIdxs + 1] = i
    end
  end

  if #dirtyIdxs == 0 then
    -- nothing to write
    return true
  end

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end

  local function writeNext(indexInDirty)
    if indexInDirty > #dirtyIdxs then
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
            ui.dirtyChannels = {}
            ui.dirty = false
            ui.saving = false
            queueFailsafeRead(true)
          end,
          errorHandler = function()
            ui.saving = false
            if type(requestRebuild) == "function" then
              requestRebuild()
            end
          end
        })
      else
        ui.saving = false
        if type(requestRebuild) == "function" then
          requestRebuild()
        end
      end
      return
    end

    local chIdx = dirtyIdxs[indexInDirty]
    local ch = ui.channels[chIdx]
    local payload = RxfailConfigApi.buildWritePayload({
      index = chIdx - 1,
      mode = ch.mode,
      value = ch.value
    })

    ui.progress = math.floor((indexInDirty - 1) / #dirtyIdxs * 90)
    if type(requestRebuild) == "function" then
      requestRebuild()
    end

    queue:add({
      command = RxfailConfigApi.writeCommand,
      payload = payload,
      isWrite = true,
      simulatorResponse = {},
      processReply = function()
        writeNext(indexInDirty + 1)
      end,
      errorHandler = function()
        ui.saving = false
        if type(requestRebuild) == "function" then
          requestRebuild()
        end
      end
    })
  end

  writeNext(1)
  return true
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

  ui.channels = {}
  for i = 1, 18 do
    ui.channels[i] = { mode = 0, value = 1500 }
  end
  ui.dirtyChannels = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  queueFailsafeRead(false)
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
    local msgText = ui.loading and pageText(i18n, "loading", "Loading failsafe configuration...") or pageText(i18n, "saving", "Saving failsafe configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Failsafe"
  local title = pageText(i18n, "title", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
  end

  local rightMargin = 10
  local leftMargin = 10
  local gap = 8
  local modeW = math.floor(w * 0.32)
  local valueW = math.floor(w * 0.24)
  local rowH = (Controls and Controls.ROW_H) or 40
  local valueX = w - rightMargin - valueW
  local modeX = valueX - gap - modeW
  local titleW = modeX - leftMargin - gap

  local labelYOffset = (Controls and Controls.labelY and Controls.labelY(0, rowH)) or math.floor((rowH - 21) / 2)
  local controlYOffset = (Controls and Controls.controlY and Controls.controlY(0, rowH)) or math.floor((rowH - 32) / 2)

  local modeOptions = {
    { label = pageText(i18n, "mode_auto", "Auto"), value = 0 },
    { label = pageText(i18n, "mode_hold", "Hold"), value = 1 },
    { label = pageText(i18n, "mode_set", "Set"), value = 2 }
  }

  for i = 1, 18 do
    local chKey = channelKeys[i]
    local chDefName = channelDefaultNames[i]
    local chName = pageText(i18n, chKey, chDefName)
    local ch = ui.channels[i] or { mode = 0, value = 1500 }

    -- 1. Left Label
    children[#children + 1] = {
      type  = "label",
      x = x + leftMargin, y = cursorY + labelYOffset,
      w = titleW,
      text  = chName,
      color = COLOR_THEME_PRIMARY1,
      font  = SMLSIZE
    }

    -- 2. Choice field for mode
    local values = {}
    local selectedIndex = 1
    for mIdx, opt in ipairs(modeOptions) do
      values[mIdx] = tostring(opt.label or "")
      if opt.value == ch.mode then
        selectedIndex = mIdx
      end
    end

    children[#children + 1] = {
      type  = "choice",
      x = x + modeX, y = cursorY + controlYOffset,
      w = modeW,
      title = chName,
      values = values,
      get = function()
        return selectedIndex
      end,
      set = function(nextIndex)
        local idx = tonumber(nextIndex) or selectedIndex
        if idx < 1 then idx = 1 end
        if idx > #modeOptions then idx = #modeOptions end
        selectedIndex = idx
        local opt = modeOptions[idx]
        if opt then
          local oldMode = ch.mode
          ch.mode = opt.value
          if oldMode ~= ch.mode then
            ui.dirtyChannels[i] = true
            ui.dirty = true
            -- Request rebuild to show/hide/enable/disable the value field
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end
        end
      end
    }

    -- 3. NumberEdit field for value
    local isEnabled = (ch.mode == 2) -- Active only when Set (2)
    children[#children + 1] = {
      type = "numberEdit",
      x = x + valueX, y = cursorY + controlYOffset,
      w = valueW,
      min = math.floor(875 / 5),
      max = math.ceil(2125 / 5),
      active = function()
        return isEnabled
      end,
      get = function()
        local current = tonumber(ch.value) or 1500
        if current < 875 then current = 875 end
        if current > 2125 then current = 2125 end
        return math.floor(current / 5)
      end,
      set = function(val)
        local nextVal = (tonumber(val) or 300) * 5
        if nextVal < 875 then nextVal = 875 end
        if nextVal > 2125 then nextVal = 2125 end
        local oldVal = ch.value
        ch.value = nextVal
        if oldVal ~= ch.value then
          ui.dirtyChannels[i] = true
          ui.dirty = true
        end
      end,
      display = function(val)
        local shown = (tonumber(val) or 300) * 5
        return tostring(shown) .. "us"
      end
    }

    -- 4. Separator Line
    children[#children + 1] = {
      type   = "rectangle",
      x = x, y = cursorY + rowH,
      w = w, h = 1,
      color  = COLOR_THEME_SECONDARY2, filled = true
    }

    cursorY = cursorY + rowH + 1
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
  local ok, err = queueFailsafeWrite(ctx and ctx.requestRebuild)
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
    ui.dirtyChannels = {}
    loadFromSession()
    ui.dirty = false
    queueFailsafeRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/failsafe/help.lua")
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
  RxfailConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

return M
