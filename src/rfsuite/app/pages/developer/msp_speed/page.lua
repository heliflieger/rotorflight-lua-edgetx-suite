local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Common = nil
local Controls = nil
local MspRuntime = nil
local ApiVersionApi = nil
local FcVersionApi = nil
local UidApi = nil

local DURATION_OPTIONS = {
  { value = 600, label = "600s" },
  { value = 300, label = "300s" },
  { value = 120, label = "120s" },
  { value = 30, label = "30s" },
}

local DURATION_LABELS = { "600s", "300s", "120s", "30s" }

local ROW_ORDER = {
  "rf_protocol",
  "test_length",
  "status",
  "total_queries",
  "successful_queries",
  "timeouts",
  "retries",
  "checksum_errors",
  "min_query_time",
  "max_query_time",
  "avg_query_time",
  "last_error",
}

local ui = {
  selectedDuration = 120,
  loaded = false,
  rebuild = nil,
  lastAutoRefreshAt = 0,
  test = {
    active = false,
    durationSec = 120,
    startedAt = 0,
    endsAt = 0,
    lastEnqueueAt = 0,
    intervalSec = 0.25,
    nextApiIndex = 1,
    protocol = "-",
    total = 0,
    success = 0,
    retries = 0,
    timeouts = 0,
    checksum = 0,
    minTimeMs = 0,
    maxTimeMs = 0,
    avgTimeMs = 0,
    sumTimeMs = 0,
    runningForSec = 0,
    completed = false,
    lastError = nil,
  },
  msp = {
    available = false,
    protocol = nil,
    queue = nil,
    messages = nil,
  },
  handlers = {
    start = nil,
    stop = nil,
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

local function formatMs(value)
  local v = tonumber(value) or 0
  if v <= 0 then return "-" end
  return tostring(v) .. " ms"
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
    text = labelText,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE,
  }

  children[#children + 1] = {
    type = "label",
    x = x + labelW + 8,
    y = y + 8,
    w = valueW,
    text = valueText,
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

local function consumedRetries(message)
  local attempts = tonumber(message and message.__retryCount) or 1
  if attempts < 1 then attempts = 1 end
  return attempts - 1
end

local function durationIndexForValue(value)
  local v = tonumber(value) or 120
  for i = 1, #DURATION_OPTIONS do
    if DURATION_OPTIONS[i].value == v then
      return i
    end
  end
  return 3
end

local function resetStats(durationSec)
  local st = ui.test
  st.durationSec = tonumber(durationSec) or 120
  st.total = 0
  st.success = 0
  st.retries = 0
  st.timeouts = 0
  st.checksum = 0
  st.minTimeMs = 0
  st.maxTimeMs = 0
  st.avgTimeMs = 0
  st.sumTimeMs = 0
  st.runningForSec = 0
  st.completed = false
  st.lastError = nil
  st.nextApiIndex = 1
  st.lastEnqueueAt = 0
end

local function stopTest(completed, doRebuild)
  local st = ui.test
  local wasActive = st.active == true
  st.active = false
  st.completed = completed == true
  st.lastEnqueueAt = 0
  st.runningForSec = 0
  if ui.msp.queue and type(ui.msp.queue.clear) == "function" then
    ui.msp.queue:clear()
  end
  if doRebuild == true and wasActive then
    requestRebuild()
  end
end

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not MspRuntime then
    MspRuntime = loadModule("tasks/msp/runtime.lua")
  end
  if not ApiVersionApi then
    ApiVersionApi = loadModule("tasks/msp/api/api_version.lua")
  end
  if not FcVersionApi then
    FcVersionApi = loadModule("tasks/msp/api/fc_version.lua")
  end
  if not UidApi then
    UidApi = loadModule("tasks/msp/api/uid.lua")
  end
  if not t then
    t = Common.pageT("developer_msp_speed")
  end
end

local function ensureMspInitialized()
  local msp = ui.msp
  local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
  local runtimeQueue = runtimeState and runtimeState.queue or nil

  if not runtimeQueue then
    msp.available = false
    ui.test.protocol = "-"
    ui.test.lastError = "msp_unavailable"
    return false
  end

  msp.queue = runtimeQueue
  msp.protocol = runtimeState and runtimeState.protocol or nil

  local messagesValid = type(msp.messages) == "table" and msp.queueRef == runtimeQueue and msp.messagesProtocol == msp.protocol
  if messagesValid then
    msp.available = true
    ui.test.protocol = msp.protocol or ((runtimeState and runtimeState.isSimulator == true) and "simulator" or "none")
    return true
  end

  local isCrsf = msp.protocol == "crsf"
  -- Keep speed test timings close to production behavior.
  local msgRetryBackoff = isCrsf and 0.25 or 0.30
  local msgTimeout = isCrsf and 2.2 or 2.4

  msp.messages = {
    { command = ApiVersionApi and ApiVersionApi.command, simulatorResponse = ApiVersionApi and ApiVersionApi.simulatorResponse, retryBackoff = msgRetryBackoff, timeout = msgTimeout },
    { command = FcVersionApi and FcVersionApi.command, simulatorResponse = FcVersionApi and FcVersionApi.simulatorResponse, retryBackoff = msgRetryBackoff, timeout = msgTimeout },
    { command = UidApi and UidApi.command, simulatorResponse = UidApi and UidApi.simulatorResponse, retryBackoff = msgRetryBackoff, timeout = msgTimeout },
  }
  msp.queueRef = runtimeQueue
  msp.messagesProtocol = msp.protocol

  for i = 1, #msp.messages do
    local msg = msp.messages[i]
    msg.processReply = function(message)
      local st = ui.test
      st.total = st.total + 1
      st.success = st.success + 1
      st.retries = st.retries + consumedRetries(message)
      local startedAt = tonumber(message and message.__startedAt) or nowSeconds()
      local elapsedMs = math.floor(((nowSeconds() - startedAt) * 1000) + 0.5)
      if elapsedMs < 0 then elapsedMs = 0 end
      if st.minTimeMs == 0 or elapsedMs < st.minTimeMs then st.minTimeMs = elapsedMs end
      if elapsedMs > st.maxTimeMs then st.maxTimeMs = elapsedMs end
      st.sumTimeMs = st.sumTimeMs + elapsedMs
      if st.success > 0 then
        st.avgTimeMs = math.floor((st.sumTimeMs / st.success) + 0.5)
      end
    end
    msg.errorHandler = function(_, reason)
      ui.test.total = ui.test.total + 1
      ui.test.retries = ui.test.retries + consumedRetries(msg)
      if reason == "timeout" then
        ui.test.timeouts = ui.test.timeouts + 1
      end
      ui.test.lastError = tostring(reason or "error")
    end
  end

  msp.available = true
  ui.test.protocol = msp.protocol or ((runtimeState and runtimeState.isSimulator == true) and "simulator" or "none")
  return true
end

local function enqueueNextQuery(now)
  local st = ui.test
  local msp = ui.msp
  if not msp.queue or not msp.messages then return end
  if not msp.queue:isProcessed() then return end
  if st.lastEnqueueAt > 0 and (now - st.lastEnqueueAt) < st.intervalSec then return end

  local idx = st.nextApiIndex or 1
  local msg = msp.messages[idx]
  if not msg or type(msg.command) ~= "number" then
    st.lastError = "api_unavailable"
    stopTest(false)
    return
  end

  st.lastEnqueueAt = now
  msg.__startedAt = now
  msp.queue:add(msg)

  idx = idx + 1
  if idx > #msp.messages then idx = 1 end
  st.nextApiIndex = idx
end

local function wakeupTestLoop(now)
  local st = ui.test
  if st.active ~= true then
    return
  end

  st.runningForSec = math.max(0, math.floor((now - st.startedAt) + 0.5))
  if now >= st.endsAt then
    stopTest(true, true)
    return
  end

  if not ensureMspInitialized() then
    stopTest(false, true)
    return
  end

  if ui.msp.queue and type(ui.msp.queue.processQueue) == "function" then
    ui.msp.queue:processQueue(now)
  end
  enqueueNextQuery(now)
end

local function buildValues(i18n)
  local snapshot = ui.test
  local active = snapshot.active == true
  local status
  if active then
    local running = tonumber(snapshot.runningForSec) or 0
    local duration = tonumber(snapshot.durationSec) or ui.selectedDuration
    status = t(i18n, "running", "Running") .. " " .. tostring(running) .. "s / " .. tostring(duration) .. "s"
  elseif snapshot.completed == true then
    status = t(i18n, "completed", "Completed")
  else
    status = t(i18n, "not_running", "Not running")
  end

  return {
    active = active,
    rf_protocol = string.upper(tostring(snapshot.protocol or "-")),
    test_length = tostring(snapshot.durationSec or ui.selectedDuration) .. "s",
    status = status,
    total_queries = tostring(snapshot.total or 0),
    successful_queries = tostring(snapshot.success or 0),
    timeouts = tostring(snapshot.timeouts or 0),
    retries = tostring(snapshot.retries or 0),
    checksum_errors = tostring(snapshot.checksum or 0),
    min_query_time = formatMs(snapshot.minTimeMs),
    max_query_time = formatMs(snapshot.maxTimeMs),
    avg_query_time = formatMs(snapshot.avgTimeMs),
    last_error = (snapshot.lastError and snapshot.lastError ~= "") and tostring(snapshot.lastError) or "-",
  }
end

local function ensureHandlers()
  if not ui.handlers.start then
    ui.handlers.start = function()
      resetStats(ui.selectedDuration)
      if not ensureMspInitialized() then
        return
      end
      if ui.msp.queue and type(ui.msp.queue.clear) == "function" then
        ui.msp.queue:clear()
      end
      ui.test.active = true
      ui.test.startedAt = nowSeconds()
      ui.test.endsAt = ui.test.startedAt + ui.test.durationSec
      ui.test.intervalSec = ui.msp.protocol == "crsf" and 0.25 or 0.35
      ui.lastAutoRefreshAt = 0
      requestRebuild()
    end
  end
  if not ui.handlers.stop then
    ui.handlers.stop = function()
      stopTest(false)
      requestRebuild()
    end
  end
end

function M.getHeaderActions()
  ensureDeps()
  return { save = false, reload = true, help = true }
end


function M.onReload()
  ensureDeps()
  stopTest(false)
  resetStats(ui.selectedDuration)
  ui.lastAutoRefreshAt = 0
end

function M.onClose()
  stopTest(false)
  local msp = ui.msp
  if type(msp.messages) == "table" then
    for i = 1, #msp.messages do
      local msg = msp.messages[i]
      if type(msg) == "table" then
        msg.processReply = nil
        msg.errorHandler = nil
        msg.__startedAt = nil
        msg.__retryCount = nil
      end
    end
  end
  if msp.queue and type(msp.queue.clear) == "function" then
    msp.queue:clear()
  end
  msp.queue = nil
  msp.queueRef = nil
  msp.messages = nil
  msp.messagesProtocol = nil
  msp.available = false
  msp.protocol = nil

  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      clearRebuild = true,
      clearLastAutoRefresh = true,
      tablesToWipe = { "test" }
    })
    ui.selectedDuration = 120
    resetStats(ui.selectedDuration)
  else
    ui.loaded = false
    ui.rebuild = nil
    ui.handlers.start = nil
    ui.handlers.stop = nil
    ui.lastAutoRefreshAt = 0
  end

  Common = nil
  Controls = nil
  MspRuntime = nil
  ApiVersionApi = nil
  FcVersionApi = nil
  UidApi = nil
  t = nil
end

function M.wakeup()
  ensureDeps()
  local now = nowSeconds()
  wakeupTestLoop(now)
  if ui.test.active then
    if (now - (ui.lastAutoRefreshAt or 0)) >= 1.0 then
      ui.lastAutoRefreshAt = now
      requestRebuild()
    end
  else
    ui.lastAutoRefreshAt = 0
  end
end

function M.build(ctx)
  ensureDeps()
  ensureHandlers()

  if not ui.loaded then
    ui.loaded = true
    ui.selectedDuration = 120
    resetStats(ui.selectedDuration)
  end

  ui.rebuild = ctx.requestRebuild

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local i18n = ctx.i18n
  local values = buildValues(i18n)

  Controls.appendStaticSectionHeader(children, x, y, w, t(i18n, "section_test", "MSP Speed Test"))

  local cursorY = y + Controls.STATIC_SECTION_H
  local rowH = (Controls and Controls.ROW_H) or 64
  local buttonW = 130
  local comboW = 130
  local ctrlY = (Controls and Controls.controlY and Controls.controlY(cursorY, rowH)) or (cursorY + math.floor((rowH - 32) / 2))
  local labelY = (Controls and Controls.labelY and Controls.labelY(cursorY, rowH)) or (cursorY + math.floor((rowH - 21) / 2))

  children[#children + 1] = {
    type = "label",
    x = x,
    y = labelY,
    w = labelW,
    text = t(i18n, "duration", "Duration"),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE,
  }

  local selectedDurationIndex = durationIndexForValue(ui.selectedDuration)
  children[#children + 1] = {
    type = "choice",
    x = comboX,
    y = ctrlY,
    w = comboW,
    title = tostring(t(i18n, "duration", "Duration")),
    values = DURATION_LABELS,
    get = function()
      return durationIndexForValue(ui.selectedDuration)
    end,
    set = function(nextIndex)
      local idx = tonumber(nextIndex) or selectedDurationIndex
      if idx < 1 then idx = 1 end
      if idx > #DURATION_OPTIONS then idx = #DURATION_OPTIONS end
      selectedDurationIndex = idx
      local nextDuration = DURATION_OPTIONS[idx].value
      if ui.selectedDuration ~= nextDuration then
        ui.selectedDuration = nextDuration
        if not ui.test.active then
          ui.test.durationSec = nextDuration
        end
      end
    end
  }

  local buttonText = values.active and t(i18n, "stop", "Stop") or t(i18n, "start", "Start")

  children[#children + 1] = {
    type = "button",
    x = buttonX,
    y = ctrlY,
    w = buttonW,
    text = buttonText,
    press = values.active and ui.handlers.stop or ui.handlers.start,
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

  for i = 1, #ROW_ORDER do
    local key = ROW_ORDER[i]
    cursorY = cursorY + appendDataRow(children, x, cursorY, w, t(i18n, key, key), values[key] or "-")
  end

  if ui.test.active then
    local done = tonumber(ui.test.runningForSec) or 0
    local total = tonumber(ui.test.durationSec) or 1
    if total < 1 then total = 1 end
    if done < 0 then done = 0 end
    if done > total then done = total end
    local ratio = done / total
    local barW = w
    local fillW = math.floor((barW - 2) * ratio + 0.5)
    if fillW < 0 then fillW = 0 end
    if fillW > (barW - 2) then fillW = barW - 2 end

    cursorY = cursorY + 8
    children[#children + 1] = {
      type = "label",
      x = x,
      y = cursorY,
      w = w,
      text = t(i18n, "running", "Running") .. " " .. tostring(done) .. "s/" .. tostring(total) .. "s",
      color = COLOR_THEME_PRIMARY1,
      font = XXSMLSIZE
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY + 14,
      w = barW,
      h = 8,
      color = GREY_DARK,
      filled = true
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x + 1,
      y = cursorY + 15,
      w = fillW,
      h = 6,
      color = COLOR_THEME_SECONDARY1,
      filled = true
    }
  end
end

return M