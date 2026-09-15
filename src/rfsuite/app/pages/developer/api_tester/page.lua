local Log = nil
local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

-- Log laden
if not Log then
  Log = loadModule("lib/log.lua")
end

local Common = nil
local Controls = nil
local MspRuntime = nil
local LoadingOverlay = nil
local AsyncLoadUi = nil

local API_DIR_CANDIDATES = {
  "/SCRIPTS/TOOLS/rfsuite-core/tasks/msp/api/",
  "/SCRIPTS/TOOLS/rfsuite/tasks/msp/api/",
}

local ROW_ORDER_KEYS = { "status", "info", "error", "value" }

local ui = {
  loaded = false,
  rebuild = nil,
  i18n = nil,
  selectedIndex = 1,
  status = "-",
  fieldCount = 0,
  rows = {},
  activeRequest = nil,
  requestSeq = 0,
  pendingDiscover = false,
  apiNames = {},
  choices = {},
  choiceLabels = {},
  sections = {
    read_result = true,
  },
  loading = false,
  showLoadingOverlay = false,
  loadingStartedAt = 0,
  loadingTimeoutSec = 8,
  progress = 0,
  done = 0,
  total = 0,
  loadingOperation = "read",
  errorMessage = nil,
  errorDialogShown = nil,
  handlers = {
    test = nil,
    toggle_read_result = nil,
  }
}

local t = nil

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then
      return ticks / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function requestRebuild()
  if type(ui.rebuild) == "function" then
    ui.rebuild()
  end
end

local function appendDataRow(children, x, y, w, labelText, valueText)
  local rowH = 34
  local valueW = math.floor(w * 0.44)
  local labelW = w - valueW - 8

  children[#children + 1] = {
    type = "label",
    x = x,
    y = y + 8,
    w = labelW,
    text = tostring(labelText or ""),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE,
  }

  children[#children + 1] = {
    type = "label",
    x = x + labelW + 8,
    y = y + 8,
    w = valueW,
    text = tostring(valueText or "-"),
    color = COLOR_THEME_PRIMARY1,
    align = RIGHT,
    font = SMLSIZE,
  }

  children[#children + 1] = {
    type = "rectangle",
    x = x,
    y = y + rowH,
    w = w,
    h = 1,
    color = COLOR_THEME_SECONDARY2,
    filled = true,
  }

  return rowH + 1
end

local function sortedKeys(tbl)
  local keys = {}
  for k in pairs(tbl or {}) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys, function(a, b)
    local rankA = #ROW_ORDER_KEYS + 1
    local rankB = #ROW_ORDER_KEYS + 1
    for i = 1, #ROW_ORDER_KEYS do
      if ROW_ORDER_KEYS[i] == a then rankA = i end
      if ROW_ORDER_KEYS[i] == b then rankB = i end
    end
    if rankA ~= rankB then return rankA < rankB end
    return a < b
  end)
  return keys
end

local function ensureUiDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not t then
    t = Common.pageT("developer_api_tester")
  end
end

local function ensureMspDeps()
  if not MspRuntime then
    MspRuntime = loadModule("tasks/msp/runtime.lua")
  end
end

local function ensureOverlayDeps()
  if not LoadingOverlay then
    LoadingOverlay = loadModule("ui/loading_overlay.lua")
  end
  if not AsyncLoadUi then
    AsyncLoadUi = loadModule("app/pages/lib/async_load_ui.lua")
  end
end

local function setStatus(text)
  ui.status = tostring(text or "-")
end

local function tr(key, fallback)
  return t(ui.i18n, key, fallback)
end

local function setInfoRows(rows, fieldCount)
  ui.rows = rows or {}
  ui.fieldCount = tonumber(fieldCount) or 0
end

local function abortLoading(i18n, reason)
  ensureOverlayDeps()
  if AsyncLoadUi and type(AsyncLoadUi.fail) == "function" then
    AsyncLoadUi.fail(ui, i18n, t, reason)
  end
end

local function beginLoading(operation, totalSteps, showOverlay)
  ensureOverlayDeps()
  if AsyncLoadUi and type(AsyncLoadUi.begin) == "function" then
    ui.loadingOperation = tostring(operation or "read")
    AsyncLoadUi.begin(ui, nowSeconds(), totalSteps or 1, showOverlay == true)
  end
end

local function getLoadingMessage(i18n)
  local op = tostring(ui.loadingOperation or "read")
  if op == "write" then
    return t(i18n, "loading_message_write", "Writing live data")
  elseif op == "save" then
    return t(i18n, "loading_message_save", "Saving data")
  end
  return t(i18n, "loading_message_read", "Reading live data")
end

local function selectedApiName()
  local idx = tonumber(ui.selectedIndex) or 1
  return ui.apiNames[idx]
end

local function addApiName(name, names, seen)
  if type(name) ~= "string" or name == "" then
    return
  end
  if name == "api_template" then
    return
  end
  if seen[name] then
    return
  end
  seen[name] = true
  names[#names + 1] = name
end

local function listApiDir(path, names, seen)
  Log.emit("api_tester", "listApiDir: trying path " .. tostring(path), "debug")

  -- Prefer EdgeTX/Ethos native dir() if available
  if type(dir) == "function" then
    Log.emit("api_tester", "listApiDir: using dir() for " .. tostring(path), "debug")
    
    -- WICHTIG: Das Ausführen von dir() absichern und die Rückgabe speichern
    local okDir, iterator = pcall(dir, path)
    
    -- Nur in die Schleife gehen, wenn wirklich ein Iterator (Funktion) zurückkam
    if okDir and type(iterator) == "function" then
      for fname in iterator do
        local ok, err = pcall(function()
          Log.emit("api_tester", "listApiDir: processing entry: '" .. tostring(fname) .. "' (type=" .. type(fname) .. ")", "debug")
          
          local clean = ""
          if type(fname) == "string" then
            clean = string.gsub(fname, "^/*", "")
            clean = string.gsub(clean, "/*$", "")
            clean = string.gsub(clean, "%s+$", "")
          end
          
          Log.emit("api_tester", "listApiDir: clean='" .. tostring(clean) .. "'", "debug")
          
          if type(clean) == "string" and clean ~= "" then
            local apiName = string.match(clean, "([%w_%-]+)%.lua$")
            
            if apiName then
              Log.emit("api_tester", "listApiDir: calling addApiName with apiName='" .. tostring(apiName) .. "'", "debug")
              addApiName(apiName, names, seen)
            end
          end
        end)
        if not ok then
          Log.emit("api_tester", "listApiDir: error processing '" .. tostring(fname) .. "': " .. tostring(err), "error")
        end
      end
    else
      -- folder missing or empty
      Log.emit("api_tester", "listApiDir: folder not found or empty for " .. tostring(path), "warn")
    end

    local namesStr = (names and #names > 0) and table.concat(names, ", ") or "<leer>"
    Log.emit("api_tester", "listApiDir: final names for path '" .. tostring(path) .. "': [" .. namesStr .. "]", "debug")
  else
    Log.emit("api_tester", "listApiDir: no dir() available for " .. tostring(path), "error")
  end
end


local function enqueueApiRead(apiName)
  ensureMspDeps()
  local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
  local queue = runtimeState and runtimeState.queue or nil
  if not queue then
    setStatus(tr("status_load_failed", "Load failed"))
    setInfoRows({
      { label = tr("label_error", "Error"), value = tr("msp_unavailable", "MSP unavailable") }
    }, 0)
    return false
  end

  local loaderPath = "tasks/msp/api/" .. tostring(apiName) .. ".lua"
  local okLoad, api = pcall(loadModule, loaderPath)
  local command = (type(api) == "table") and (tonumber(api.command)) or nil
  if not okLoad or type(api) ~= "table" or type(command) ~= "number" then
    setStatus(tr("status_load_failed", "Load failed"))
    setInfoRows({
      { label = tr("label_error", "Error"), value = tr("msg_unable_to_load", "Unable to load API") .. ": " .. tostring(apiName) }
    }, 0)
    return false
  end

  local isEsc = (command == 217 or string.sub(apiName, 1, 15) == "esc_parameters_")

  if (not isEsc or not ui.connState or ui.connState == 0) and type(queue.clear) == "function" then
    queue:clear()
  end

  ui.requestSeq = (tonumber(ui.requestSeq) or 0) + 1
  local requestId = ui.requestSeq
  ui.activeRequest = {
    id = requestId,
    apiName = apiName,
    startedAt = nowSeconds(),
  }

  local FwdProgApi = loadModule("tasks/msp/api/4wif_esc_fwd_prog.lua")
  if FwdProgApi and isEsc then
    if not ui.connState or ui.connState == 0 then
      ui.connState = 1
      setStatus("Resetting 4WIF link (target 100)...")
      setInfoRows({
        { label = tr("label_status", "Status"), value = "Sending reset target..." }
      }, 0)
      beginLoading("read", 1, true)
      queue:add({
        command = FwdProgApi.writeCommand,
        payload = FwdProgApi.buildWritePayload({ target = 100 }),
        isWrite = true,
        processReply = function()
          ui.connState = 2
          ui.connTimer = nowSeconds()
          ui.activeRequest = nil
          requestRebuild()
        end,
        errorHandler = function(_, err)
          ui.connState = 0
          ui.activeRequest = nil
          abortLoading(ui.i18n, tostring(err or "Reset failed"))
          setStatus(tr("label_error", "Error"))
          setInfoRows({
            { label = tr("label_status", "Status"), value = "Reset failed" },
            { label = tr("label_error", "Error"), value = tostring(err) }
          }, 0)
          requestRebuild()
        end
      })
      return true
    elseif ui.connState == 3 then
      ui.connState = 4
      setStatus("Selecting ESC 1 (target 0)...")
      setInfoRows({
        { label = tr("label_status", "Status"), value = "Sending select target..." }
      }, 0)
      beginLoading("read", 1, true)
      queue:add({
        command = FwdProgApi.writeCommand,
        payload = FwdProgApi.buildWritePayload({ target = 0 }),
        isWrite = true,
        processReply = function()
          ui.connState = 5
          ui.connTimer = nowSeconds()
          ui.activeRequest = nil
          requestRebuild()
        end,
        errorHandler = function(_, err)
          ui.connState = 0
          ui.activeRequest = nil
          abortLoading(ui.i18n, tostring(err or "Selection failed"))
          setStatus(tr("label_error", "Error"))
          setInfoRows({
            { label = tr("label_status", "Status"), value = "Selection failed" },
            { label = tr("label_error", "Error"), value = tostring(err) }
          }, 0)
          requestRebuild()
        end
      })
      return true
    end
  end

  setStatus(tr("status_reading", "Reading") .. " " .. tostring(apiName) .. "...")
  setInfoRows({
    { label = tr("label_status", "Status"), value = tr("msg_waiting_response", "Waiting for response") }
  }, 0)
  beginLoading("read", 1, true)

  local function onComplete(message, buf)
    if not ui.activeRequest or ui.activeRequest.id ~= requestId then
      return
    end
    if AsyncLoadUi and type(AsyncLoadUi.stepDone) == "function" then
      AsyncLoadUi.stepDone(ui)
    end
    local parsed = type(api.parse) == "function" and api.parse(buf) or nil
    local rows = {}

    if type(parsed) ~= "table" then
      rows[1] = { label = tr("label_info", "Info"), value = tr("msg_no_parsed_result", "No parsed result") }
      setInfoRows(rows, 0)
      setStatus(tr("status_ok", "OK") .. ": 0 " .. tr("label_fields", "fields"))
      ui.activeRequest = nil
      requestRebuild()
      return
    end

    local keys = sortedKeys(parsed)
    for i = 1, #keys do
      local key = keys[i]
      if key ~= "buffer" then
      local value = parsed[key]
      if type(value) == "table" then
        value = "<table>"
      elseif type(value) == "boolean" then
        value = value and "true" or "false"
      elseif value == nil then
        value = "nil"
      else
        value = tostring(value)
      end
      rows[#rows + 1] = { label = key, value = value }
      end
    end

    local displayFieldCount = #rows
    if #rows == 0 then
      rows[1] = { label = tr("label_info", "Info"), value = tr("msg_read_completed_zero", "Read completed with 0 fields") }
    end

    setInfoRows(rows, displayFieldCount)
    setStatus(tr("status_ok", "OK") .. ": " .. tostring(displayFieldCount) .. " " .. tr("label_fields", "fields"))
    ui.activeRequest = nil
    requestRebuild()
  end

  local function onError(_, reason)
    if not ui.activeRequest or ui.activeRequest.id ~= requestId then
      return
    end
    local err = tostring(reason or "read_error")
    abortLoading(ui.i18n, err)
    setStatus(tr("label_error", "Error"))
    setInfoRows({
      { label = tr("label_status", "Status"), value = tr("msg_read_failed", "Read failed") },
      { label = tr("label_error", "Error"), value = err },
    }, 0)
    ui.activeRequest = nil
    requestRebuild()
  end

  local retryBackoff = 0.20
  local timeout = isEsc and 15.0 or 5.0
  queue:add({
    command = command,
    simulatorResponse = api.simulatorResponse,
    timeout = timeout,
    retryBackoff = retryBackoff,
    processReply = onComplete,
    errorHandler = onError,
  })

  return true
end

local function ensureHandlers()
  if not ui.handlers.test then
    ui.handlers.test = function()
      if ui.activeRequest then
        return
      end

      local apiName = selectedApiName()
      if not apiName then
        setStatus(t(nil, "label_error", "Error"))
        setInfoRows({
          { label = t(nil, "label_info", "Info"), value = t(nil, "msg_no_api_selected", "No API selected") }
        }, 0)
        requestRebuild()
        return
      end

      enqueueApiRead(apiName)
      requestRebuild()
    end
  end
  if not ui.handlers.toggle_read_result then
    ui.handlers.toggle_read_result = function()
      ui.sections.read_result = not ui.sections.read_result
      requestRebuild()
    end
  end
end

function M.getHeaderActions()
  ensureUiDeps()
  return { save = false, reload = false, help = true }
end


local function discoverApis()
  Log.emit("api_tester", "discoverApis: starting", "debug")
  
  local names = {}
  local seen = {}

  -- Durchsuche alle konfigurierten Ordner
  for i = 1, #API_DIR_CANDIDATES do
    local path = API_DIR_CANDIDATES[i]
    Log.emit("api_tester", "discoverApis: checking candidate " .. tostring(path), "debug")
    listApiDir(path, names, seen)
  end

  table.sort(names)

  -- Filter: nur APIs anzeigen, die ein numerisches `command` besitzen.
  local filtered = {}
  for i = 1, #names do
    local apiName = names[i]
    local loaderPath = "tasks/msp/api/" .. tostring(apiName) .. ".lua"
    local ok, api = pcall(loadModule, loaderPath)
    if ok and type(api) == "table" and api.command ~= nil then
      filtered[#filtered + 1] = apiName
    else
      Log.emit("api_tester", "discoverApis: skipping '" .. tostring(apiName) .. "' (no command or load failed)", "debug")
    end
  end

  -- UI Daten vorbereiten
  ui.apiNames = filtered
  ui.choices = {}
  ui.choiceLabels = {}

  for i = 1, #filtered do
    ui.choices[i] = i
    ui.choiceLabels[i] = filtered[i]
  end

  ui.selectedIndex = 1
  Log.emit("api_tester", "discoverApis: finished. Found " .. tostring(#names) .. " APIs.", "debug")
end

function M.onReload()
  ensureUiDeps()
  if ui.i18n == nil and type(_G) == "table" and type(_G.rfsuite) == "table" then
    ui.i18n = _G.rfsuite.i18n
  end
  ui.pendingDiscover = true
  ui.apiNames = {}
  ui.choices = {}
  ui.choiceLabels = {}
  ui.activeRequest = nil
  ui.requestSeq = (tonumber(ui.requestSeq) or 0) + 1
  ui.connState = 0
  ui.connTimer = nil
  setStatus(tr("status_idle", "Idle"))
  setInfoRows({
    { label = tr("label_info", "Info"), value = tr("msg_choose_api", "Choose an API and press Test") }
  }, 0)
  if AsyncLoadUi and type(AsyncLoadUi.reset) == "function" then
    AsyncLoadUi.reset(ui)
  end
  ui.loadingOperation = "read"
end

function M.wakeup()
  if ui.pendingDiscover == true then
    ui.pendingDiscover = false
    discoverApis()
    requestRebuild()
  end

  if ui.connState == 2 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 2.5 then
      ui.connState = 3
      local apiName = selectedApiName()
      if apiName then enqueueApiRead(apiName) end
    end
  elseif ui.connState == 5 and ui.connTimer then
    if nowSeconds() - ui.connTimer >= 5.0 then
      ui.connState = 6
      local apiName = selectedApiName()
      if apiName then enqueueApiRead(apiName) end
    end
  end
end

function M.onClose()
  ui.requestSeq = (tonumber(ui.requestSeq) or 0) + 1
  ui.activeRequest = nil
  ui.connState = nil
  ui.connTimer = nil
  local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
  local queue = runtimeState and runtimeState.queue or nil
  if queue and type(queue.clear) == "function" then
    queue:clear()
  end
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      clearRebuild = true,
      tablesToWipe = { "apiNames", "choices", "choiceLabels", "rows", "sections" }
    })
    ui.selectedIndex = 1
    ui.status = "-"
    ui.fieldCount = 0
    ui.sections.read_result = true
    if AsyncLoadUi and type(AsyncLoadUi.reset) == "function" then
      AsyncLoadUi.reset(ui)
    end
    ui.loadingOperation = "read"
  else
    ui.loaded = false
    ui.rebuild = nil
    ui.handlers.test = nil
    ui.handlers.toggle_read_result = nil
  end

  Common = nil
  Controls = nil
  MspRuntime = nil
  LoadingOverlay = nil
  AsyncLoadUi = nil
  t = nil
end

function M.build(ctx)
  ensureUiDeps()
  ensureHandlers()

  if not ui.loaded then
    ui.loaded = true
    ui.pendingDiscover = true
    setStatus(t(ctx.i18n, "status_idle", "Idle"))
    setInfoRows({
      { label = t(ctx.i18n, "label_info", "Info"), value = t(ctx.i18n, "msg_choose_api", "Choose an API and press Test") }
    }, 0)
  end

  ui.rebuild = ctx.requestRebuild

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local i18n = ctx.i18n
  ui.i18n = i18n

  Controls.appendStaticSectionHeader(children, x, y, w, t(i18n, "section_test", "API Tester"))

  local cursorY = y + Controls.STATIC_SECTION_H
  local rowH = (Controls and Controls.ROW_H) or 64
  local buttonW = 130
  local comboW = 220
  local rightPad = 10
  local gap = 8
  local buttonX = x + w - buttonW - rightPad
  local comboX = buttonX - gap - comboW
  if comboX < x then
    comboX = x
    comboW = buttonX - gap - x
  end
  if comboW < 120 then comboW = 120 end
  local labelW = comboX - x - 8
  local ctrlY = (Controls and Controls.controlY and Controls.controlY(cursorY, rowH)) or (cursorY + math.floor((rowH - 32) / 2))
  local labelY = (Controls and Controls.labelY and Controls.labelY(cursorY, rowH)) or (cursorY + math.floor((rowH - 21) / 2))

  children[#children + 1] = {
    type = "label",
    x = x,
    y = labelY,
    w = labelW,
    text = t(i18n, "label_api", "API"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE,
  }

  children[#children + 1] = {
    type = "choice",
    x = comboX,
    y = ctrlY,
    w = comboW,
    title = tostring(t(i18n, "label_api", "API")),
    values = (#ui.choiceLabels > 0) and ui.choiceLabels or { "" },
    get = function()
      local idx = tonumber(ui.selectedIndex) or 1
      if idx < 1 then idx = 1 end
      if idx > #ui.choices then idx = #ui.choices end
      if idx < 1 then idx = 1 end
      return idx
    end,
    set = function(nextIndex)
      local idx = tonumber(nextIndex) or 1
      if idx < 1 then idx = 1 end
      if idx > #ui.choices then idx = #ui.choices end
      ui.selectedIndex = idx
    end
  }

  children[#children + 1] = {
    type = "button",
    x = buttonX,
    y = ctrlY,
    w = buttonW,
    text = "",
    color = COLOR_THEME_SECONDARY1,
    press = ui.handlers.test,
  }

  children[#children + 1] = {
    type = "label",
    x = buttonX,
    y = Controls.labelY(ctrlY, Controls.CTRL_H),
    w = buttonW,
    text = t(i18n, "btn_test", "Test"),
    color = WHITE,
    align = CENTER,
    font = SMLSIZE,
  }

  children[#children + 1] = {
    type = "rectangle",
    x = x,
    y = cursorY + rowH,
    w = w,
    h = 1,
    color = COLOR_THEME_SECONDARY2,
    filled = true,
  }

  cursorY = cursorY + rowH + 1
  cursorY = cursorY + appendDataRow(children, x, cursorY, w, t(i18n, "label_status", "Status"), ui.status)

  cursorY = cursorY + 8
  Controls.appendSectionHeader(
    children,
    x,
    cursorY,
    w,
    t(i18n, "panel_read_result", "Read Result"),
    ui.sections.read_result,
    ui.handlers.toggle_read_result
  )
  cursorY = cursorY + Controls.SECTION_H

  if ui.sections.read_result then
    for i = 1, #ui.rows do
      local row = ui.rows[i]
      cursorY = cursorY + appendDataRow(children, x, cursorY, w, row.label, row.value)
    end
  end

  if ui.loading and ui.showLoadingOverlay then
    ensureOverlayDeps()
  end

  if ui.loading and ui.showLoadingOverlay and LoadingOverlay then
    if AsyncLoadUi and type(AsyncLoadUi.isTimedOut) == "function" and AsyncLoadUi.isTimedOut(ui, nowSeconds()) then
      abortLoading(i18n, tr("loading_timeout", "Timeout"))
    end
    local title = t(i18n, "loading_title", "Loading")
    local message = string.format("%s %d/%d", getLoadingMessage(i18n), ui.done or 0, ui.total or 0)
    LoadingOverlay.append(children, {
      x = x,
      y = y,
      w = w,
      h = ctx.h,
      title = title,
      message = message,
      progress = ui.progress
    })
  elseif ui.errorMessage and ui.errorMessage ~= "" and AsyncLoadUi and type(AsyncLoadUi.appendErrorNotice) == "function" then
    AsyncLoadUi.appendErrorNotice(children, {
      x = x,
      y = y,
      w = w,
      h = ctx.h,
      overlay = LoadingOverlay,
      requestRebuild = ctx and ctx.requestRebuild
    }, ui, i18n, t)
  end
end

function M.wakeup()
  local now = nowSeconds()
  if ui.loading and AsyncLoadUi and type(AsyncLoadUi.isTimedOut) == "function" and AsyncLoadUi.isTimedOut(ui, now) then
    abortLoading(ui.i18n, tr("loading_timeout", "Timeout"))
  end
end

return M
