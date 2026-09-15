local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = nil
local MspRuntime = nil
local AsyncLoadUi = nil
local LoadingOverlay = nil
local Controls = nil
local t = nil

local state = {
  loaded = false,
  loading = false,
  showLoadingOverlay = false,
  progress = 0,
  done = 0,
  total = 3,
  rows = {},
  rowSignature = "",
  requestRebuild = nil,
  lastRefreshAt = 0,
  refreshIntervalSec = 5.0,
  i18n = nil,
  values = {
    date = nil,
    time = nil,
    arming_flags = nil,
    dataflash_free = nil,
    real_time_load = nil,
    cpu_load = nil
  }
}

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not AsyncLoadUi then AsyncLoadUi = loadModule("app/pages/lib/async_load_ui.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not t then t = Common and Common.pageT("diagnostics_fblstatus") or nil end
end

local function pageText(i18n, key, fallback)
  local obj = i18n or state.i18n
  if t then return t(obj, key, fallback) end
  return fallback
end

local function formatArmingFlags(flags)
  if not flags or flags == 0 then
    return "OK"
  end
  -- For now just show the number, or we could add a list of active flags.
  -- Rotorflight has a lot of them.
  return "0x" .. string.format("%08X", flags)
end

local function formatDataflash(summary)
  if not summary then return "-" end
  local free = (summary.total or 0) - (summary.used or 0)
  if free < 0 then free = 0 end
  
  if free > 1024 * 1024 then
    return string.format("%.1f MB", free / (1024 * 1024))
  elseif free > 1024 then
    return string.format("%.1f KB", free / 1024)
  else
    return tostring(free) .. " B"
  end
end

local function rebuildRows(i18n)
  local v = state.values
  local rows = {
    { label = pageText(i18n, "date", "Date"), value = v.date or "-" },
    { label = pageText(i18n, "time", "Time"), value = v.time or "-" },
    { label = pageText(i18n, "arming_flags", "Arming Flags"), value = formatArmingFlags(v.arming_flags) },
    { label = pageText(i18n, "dataflash_free", "Dataflash Free"), value = v.dataflash_free or "-" },
    { label = pageText(i18n, "real_time_load", "Real-time Load"), value = v.real_time_load or "-" },
    { label = pageText(i18n, "cpu_load", "CPU Load"), value = v.cpu_load or "-" },
  }

  local signatureParts = {}
  for i = 1, #rows do
    signatureParts[#signatureParts + 1] = tostring(rows[i].label) .. "|" .. tostring(rows[i].value)
  end
  local signature = table.concat(signatureParts, "|")
  if signature == state.rowSignature then
    return false
  end

  state.rows = rows
  state.rowSignature = signature
  return true
end

local function abortLoading(i18n, message)
  if AsyncLoadUi and type(AsyncLoadUi.fail) == "function" then
    AsyncLoadUi.fail(state, i18n, pageText, message)
  else
    state.loading = false
    state.showLoadingOverlay = false
    state.errorMessage = message or "Loading failed"
  end
  if type(state.requestRebuild) == "function" then
    state.requestRebuild()
  end
end

local function requestData(i18n)
  if state.loading then return end
  ensureDeps()

  AsyncLoadUi.begin(state, nowSeconds(), 3, true)
  state.startTime = state.loadingStartedAt

  local msp = MspRuntime
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    abortLoading(i18n, "MSP link unavailable")
    return
  end

  local function incrementProgress()
    if AsyncLoadUi and type(AsyncLoadUi.stepDone) == "function" then
      if AsyncLoadUi.stepDone(state) then
        state.loaded = true
      end
    else
      state.done = state.done + 1
      if state.total > 0 and state.done >= state.total then
        state.loading = false
        state.showLoadingOverlay = false
        state.loaded = true
      end
    end
    if type(state.requestRebuild) == "function" then
      state.requestRebuild()
    end
  end

  -- 1. MSP_RTC (247)
  local rtcApi = loadModule("tasks/msp/api/rtc.lua")
  mspState.queue:add({
    command = rtcApi.command,
    simulatorResponse = rtcApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.5,
    processReply = function(_, buf)
      local parsed = rtcApi.parse(buf)
      if parsed then
        state.values.date = string.format("%04d-%02d-%02d", parsed.year, parsed.month, parsed.day)
        state.values.time = string.format("%02d:%02d:%02d", parsed.hours, parsed.minutes, parsed.seconds)
      end
      incrementProgress()
    end,
    errorHandler = function() incrementProgress() end
  })

  -- 2. MSP_STATUS (101)
  local statusApi = loadModule("tasks/msp/api/status.lua")
  mspState.queue:add({
    command = statusApi.command,
    simulatorResponse = statusApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.5,
    processReply = function(_, buf)
      local parsed = statusApi.parse(buf)
      if parsed then
        state.values.arming_flags = parsed.arming_disable_flags
        state.values.real_time_load = string.format("%.1f%%", parsed.max_real_time_load / 10)
        state.values.cpu_load = string.format("%.1f%%", parsed.average_cpu_load / 10)
      end
      incrementProgress()
    end,
    errorHandler = function() incrementProgress() end
  })

  -- 3. MSP_DATAFLASH_SUMMARY (70)
  local dfApi = loadModule("tasks/msp/api/dataflash_summary.lua")
  mspState.queue:add({
    command = dfApi.command,
    simulatorResponse = dfApi.simulatorResponse,
    retryDelay = 1.2,
    timeout = 3.5,
    processReply = function(_, buf)
      local parsed = dfApi.parse(buf)
      if parsed then
        state.values.dataflash_free = formatDataflash(parsed)
      end
      incrementProgress()
    end,
    errorHandler = function() incrementProgress() end
  })

  if type(state.requestRebuild) == "function" then
    state.requestRebuild()
  end
end

function M.getModuleTitle()
  return "FBL Status"
end

function M.getHeaderActions()
  return { reload = true, save = false, help = false }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  requestData(state.i18n)
  return true
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild
  state.i18n = ctx.i18n

  local i18n = ctx.i18n
  
  if not state.loaded and not state.loading then
    requestData(i18n)
  end
  
  rebuildRows(i18n)

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local rowY = y + 6
  local rowH = 44
  local labelW = math.floor(w * 0.58)
  local valueX = x + labelW
  local valueW = w - labelW

  for i = 1, #state.rows do
    local row = state.rows[i]
    local thisY = rowY + (i - 1) * rowH

    children[#children + 1] = {
      type = "label",
      x = x,
      y = thisY + 8,
      w = labelW - 10,
      text = row.label,
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "label",
      x = valueX,
      y = thisY + 8,
      w = valueW - 6,
      text = tostring(row.value),
      color = COLOR_THEME_PRIMARY1,
      align = RIGHT,
      font = SMLSIZE
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = thisY + rowH - 2,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY1,
      filled = true
    }
  end

  if state.loading and state.showLoadingOverlay then
    if AsyncLoadUi and AsyncLoadUi.isTimedOut(state, nowSeconds()) then
      abortLoading(i18n, pageText(i18n, "loading_timeout", "Timeout"))
    end
    local title = pageText(i18n, "loading_title", "Loading")
    local message = pageText(i18n, "loading_message", "Reading FBL status...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = ctx.w, h = ctx.h,
      title = title, message = message, progress = state.progress
    })
  elseif state.errorMessage and state.errorMessage ~= "" then
    AsyncLoadUi.appendErrorNotice(children, {
      x = x,
      y = y,
      w = ctx.w,
      h = ctx.h,
      overlay = LoadingOverlay,
      requestRebuild = ctx and ctx.requestRebuild
    }, state, i18n, pageText)
  end
end

function M.wakeup()
  local now = nowSeconds()
  if state.loading and AsyncLoadUi and type(AsyncLoadUi.isTimedOut) == "function" and AsyncLoadUi.isTimedOut(state, now) then
    abortLoading(state.i18n, pageText(state.i18n, "loading_timeout", "Timeout while reading from FBL"))
  end
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.loaded = false
  state.loading = false
  state.showLoadingOverlay = false
  state.rows = {}
  state.rowSignature = ""
  state.requestRebuild = nil
  state.lastRefreshAt = 0
  state.i18n = nil
  if AsyncLoadUi and type(AsyncLoadUi.reset) == "function" then
    AsyncLoadUi.reset(state)
  end
  Common = nil
  MspRuntime = nil
  AsyncLoadUi = nil
  LoadingOverlay = nil
  Controls = nil
  t = nil
end

return M
