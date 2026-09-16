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

local FIELD_COUNT = 9
local THROTTLE_STEPS = { "0%", "12%", "25%", "37%", "50%", "62%", "75%", "87%", "100%" }

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  config = {
    curve = { 0, 5, 10, 15, 25, 30, 35, 40, 50 }
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

local function clampPercent(v)
  v = tonumber(v or 0) or 0
  if v < 0 then return 0 end
  if v > 100 then return 100 end
  return math.floor(v + 0.5)
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.governor_config) ~= "table" then return end
  local cached = session.governor_config
  ui.config.curve = {}
  for i = 1, FIELD_COUNT do
    local raw = cached["gov_bypass_throttle_curve_" .. tostring(i)]
    ui.config.curve[i] = clampPercent((tonumber(raw) or 0) / 2)
  end
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
        ui.config.curve = {}
        for i = 1, FIELD_COUNT do
          local raw = parsed["gov_bypass_throttle_curve_" .. tostring(i)]
          ui.config.curve[i] = clampPercent((tonumber(raw) or 0) / 2)
        end
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

  for i = 1, FIELD_COUNT do
    writeData["gov_bypass_throttle_curve_" .. tostring(i)] = clampPercent(ui.config.curve[i]) * 2
  end

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
    curve = { 0, 5, 10, 15, 25, 30, 35, 40, 50 }
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
    local msgText = ui.loading and pageText(i18n, "loading_message", "Reading governor configuration...") or pageText(i18n, "saving_message", "Saving governor configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Bypass Curve"
  local title = pageText(i18n, "curves", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- ── 1. Curve Graph Visualization ──────────────────────────────────────────
  local graphMargin = 20
  local gx = x + graphMargin
  local gw = w - (graphMargin * 2)
  local gy = cursorY + 6
  local gh = 130

  -- Background box
  children[#children + 1] = {
    type = "rectangle",
    x = gx, y = gy,
    w = gw, h = gh,
    color = COLOR_THEME_SECONDARY2,
    filled = false
  }

  -- Horizontal grid lines (0%, 25%, 50%, 75%, 100%)
  for i = 0, 4 do
    local gridY = gy + math.floor((gh * i) / 4 + 0.5)
    children[#children + 1] = {
      type = "line",
      x = 0, y = 0, w = 0, h = 0,
      pts = { { gx, gridY }, { gx + gw, gridY } },
      color = COLOR_THEME_SECONDARY2,
      thickness = 1
    }
  end

  -- Vertical grid lines for each of the 9 points
  for i = 1, FIELD_COUNT do
    local gridX = gx + math.floor((gw * (i - 1)) / (FIELD_COUNT - 1) + 0.5)
    children[#children + 1] = {
      type = "line",
      x = 0, y = 0, w = 0, h = 0,
      pts = { { gridX, gy }, { gridX, gy + gh } },
      color = COLOR_THEME_SECONDARY2,
      thickness = 1
    }
  end

  -- Curve Line and Points
  local prevX, prevY
  for i = 1, FIELD_COUNT do
    local pct = clampPercent(ui.config.curve[i])
    local ptX = gx + math.floor((gw * (i - 1)) / (FIELD_COUNT - 1) + 0.5)
    local ptY = gy + gh - math.floor((gh * pct) / 100 + 0.5)

    if prevX and prevY then
      children[#children + 1] = {
        type = "line",
        x = 0, y = 0, w = 0, h = 0,
        pts = { { prevX, prevY }, { ptX, ptY } },
        color = COLOR_THEME_PRIMARY1 or WHITE,
        thickness = 2
      }
    end

    -- Marker dot
    children[#children + 1] = {
      type = "rectangle",
      x = ptX - 3, y = ptY - 3,
      w = 7, h = 7,
      color = COLOR_THEME_PRIMARY1 or WHITE,
      filled = true
    }

    prevX, prevY = ptX, ptY
  end

  cursorY = gy + gh + 10

  -- ── 2. Refresh Button ─────────────────────────────────────────────────────
  local btnW = math.min(260, w - 40)
  local btnH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or (Controls and Controls.CTRL_H) or 32
  local btnX = x + math.floor((w - btnW) / 2)
  children[#children + 1] = {
    type = "button",
    x = btnX,
    y = cursorY,
    w = btnW,
    text = pageText(i18n, "refresh_graph", "Refresh Graph"),
    press = function()
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  }

  cursorY = cursorY + btnH + 10

  -- ── 3. 9 Throttle Points Inputs ───────────────────────────────────────────
  local gap = 4
  local fieldW = math.floor((gw - (gap * (FIELD_COUNT - 1))) / FIELD_COUNT)
  local labelH = (Controls and Controls.LABEL_H) or (lvgl and lvgl.LCD_SCALE and math.floor(21 * lvgl.LCD_SCALE + 0.5)) or 21
  local editH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or (Controls and Controls.CTRL_H) or 32

  for i = 1, FIELD_COUNT do
    local cellX = gx + (i - 1) * (fieldW + gap)

    -- Step Label (e.g. 0%, 12%, 25%...)
    children[#children + 1] = {
      type = "label",
      x = cellX,
      y = cursorY,
      w = fieldW,
      text = THROTTLE_STEPS[i] or ("P" .. tostring(i)),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE,
      align = CENTER
    }

    -- Number Edit
    local pointIndex = i
    children[#children + 1] = {
      type = "numberEdit",
      x = cellX,
      y = cursorY + labelH + 6,
      w = fieldW,
      min = 0,
      max = 100,
      active = function() return true end,
      get = function()
        return ui.config.curve[pointIndex] or 0
      end,
      set = function(val)
        ui.config.curve[pointIndex] = clampPercent(val)
        ui.dirty = true
      end,
      display = function(val)
        return tostring(clampPercent(val)) .. "%"
      end
    }
  end

  cursorY = cursorY + labelH + 6 + editH + 14

  if ui.dirty then
    children[#children + 1] = {
      type = "label",
      x = x + 16, y = cursorY,
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
  local help = loadModule("app/pages/setup/governor/curves/help.lua")
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
