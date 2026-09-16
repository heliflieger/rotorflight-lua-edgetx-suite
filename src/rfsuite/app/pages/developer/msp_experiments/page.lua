--[[
  Copyright (C) 2026 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]]--

-- MSP Experiments Page (EdgeTX)
-- Refactored: Bulletproof LVGL Focus Handling & Native Controls

local M = {}

-- Module locals
local function loadModule(path)
    local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
    local chunk = assert(loadScript(fullPath, "t"))
    return chunk()
end

local Common = nil
local Controls = nil
local MspRuntime = nil
local AsyncLoadUi = nil
local LoadingOverlay = nil
local ExperimentalApi = nil
local t = nil

local state = {
  started = false,
  attached = false,
  pendingStart = false,
  deferStartBuild = false,
  forceReload = false,
  loading = false,
  showLoadingOverlay = false,
  loadingStartedAt = 0,
  loadingTimeoutSec = 12,
  refreshIntervalSec = 45,
  lastFetchAt = 0,
  progress = 0,
  done = 0,
  total = 0,
  errorMessage = nil,
  errorDialogShown = nil,
  rebuild = nil,
  
  -- page specific state
  loaded = false,
  expBytes = 16,
  apidata = nil
}

local function requestRebuild()
    if type(state.rebuild) == "function" then
        state.rebuild()
    end
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then return ticks / 100 end
  end
  return (os and os.clock and os.clock()) or 0
end

local function generateMSPAPI(numLabels)
    if numLabels > 16 then numLabels = 16 end
    local apidata = {api = {'EXPERIMENTAL'}, formdata = {labels = {}, fields = {}}}
    for i = 1, numLabels do
        table.insert(apidata.formdata.labels, {t = tostring(i), inline_size = 17, label = i})
        table.insert(apidata.formdata.fields, {t = "UINT8", isUINT8 = true, label = i, inline = 2, mspapi = 1, apikey = "exp_uint" .. i, min = 0, max = 255})
    end
    return apidata
end

local function getExpBytes()
    if _G and _G.rfsuite and _G.rfsuite.preferences and _G.rfsuite.preferences.developer and _G.rfsuite.preferences.developer.mspexpbytes then
        return _G.rfsuite.preferences.developer.mspexpbytes
    end
    return 16
end

local function ensureDeps()
    if not Common then Common = loadModule("app/pages/settings/common.lua") end
    if not Controls then Controls = loadModule("ui/controls.lua") end
    if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
    if not ExperimentalApi then ExperimentalApi = loadModule("tasks/msp/api/experimental.lua") end
    if not AsyncLoadUi then AsyncLoadUi = loadModule("app/pages/lib/async_load_ui.lua") end
    if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
    if not t then t = Common.pageT("developer_msp_experiments") end
end

local function isFblConnected()
    ensureDeps()
    local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
    if type(runtimeState) ~= "table" then return false end
    if runtimeState.isSimulator == true then return true end
    return runtimeState.lastConnected == true
end

local function markStepDone()
    if AsyncLoadUi.stepDone(state) then
        state.lastFetchAt = nowSeconds()
    end
    requestRebuild()
end

local function abortLoading(i18n, reason)
    AsyncLoadUi.fail(state, i18n, t, reason)
    requestRebuild()
end

local function startLiveLoad()
    if not isFblConnected() then
        state.started = false
        state.forceReload = false
        return
    end
    ensureDeps()

    if state.started and not state.forceReload then
        return
    end
    state.started = true
    state.forceReload = false

    if MspRuntime and type(MspRuntime.attach) == "function" and not state.attached then
        MspRuntime.attach("exp-page")
        state.attached = true
    end

    local runtimeState = MspRuntime.getState()
    local queue = runtimeState and runtimeState.queue

    if type(queue) ~= "table" or type(queue.add) ~= "function" then
        state.started = false
        return
    end

    AsyncLoadUi.begin(state, nowSeconds(), 1, true)

    queue:add({
        client = "exp-page",
        command = ExperimentalApi.command,
        simulatorResponse = ExperimentalApi.simulatorResponse,
        retryDelay = 1.2,
        timeout = 3.5,
        processReply = function(_, buf)
            local parsed = ExperimentalApi.parse(buf)
            if parsed then
                for _, field in ipairs(state.apidata.formdata.fields) do
                    if field.isUINT8 and parsed[field.apikey] ~= nil then
                        field.value = parsed[field.apikey]
                    end
                end
                state.hasUnsavedChanges = false 
            end
            markStepDone()
        end,
        errorHandler = function() abortLoading(state.i18n, "MSP Fetch failed") end
    })

    requestRebuild()
end

local function queueLiveLoad(force)
    state.started = false
    state.forceReload = force == true
    state.deferStartBuild = true
    if force == true then
        state.lastFetchAt = 0
        state.errorMessage = nil
        state.errorDialogShown = nil
    end
    state.pendingStart = true
    requestRebuild()
end

function M.getHeaderActions()
    return {
        save = isFblConnected(),
        reload = isFblConnected(),
        help = true,
        menu = true
    }
end


function M.onReload()
    ensureDeps()
    state.expBytes = getExpBytes()
    state.apidata = generateMSPAPI(state.expBytes)
    state.loaded = true
    state.hasUnsavedChanges = false

    queueLiveLoad(true)
    return false
end

function M.onSave()
    ensureDeps()
    
    -- Wenn nichts geändert wurde, brechen wir geräuschlos ab.
    if not state.hasUnsavedChanges then
        return false 
    end
    
    -- HIER kommt später dein queue:add() Aufruf rein, um die Werte an den FC zu senden.
    
    state.hasUnsavedChanges = false
    return true 
end

function M.onClose()
    ensureDeps()
    if state.attached and MspRuntime and type(MspRuntime.detach) == "function" then
        MspRuntime.detach("exp-page")
    end
    local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
    local queue = runtimeState and runtimeState.queue
    if queue and type(queue.clear) == "function" then
        queue:clear()
    end

    state.loaded = false
    state.rebuild = nil
    state.apidata = nil
    state.hasUnsavedChanges = false

    state.started = false
    state.attached = false
    state.pendingStart = false
    state.deferStartBuild = false
    state.forceReload = false
    if AsyncLoadUi then AsyncLoadUi.reset(state) end

    Common = nil
    Controls = nil
    t = nil
end

function M.build(ctx)
    ensureDeps()
    if not state.loaded then
        M.onReload()
    end
    local i18n = ctx.i18n
    state.i18n = i18n
    state.rebuild = ctx.requestRebuild

    if not isFblConnected() then
        state.pendingStart = false
        state.deferStartBuild = false
    elseif not state.started and not state.pendingStart then
        state.pendingStart = true
        state.deferStartBuild = true
    end

    if state.pendingStart and state.deferStartBuild then
        state.deferStartBuild = false
        requestRebuild()
    elseif state.pendingStart and not state.loading then
        state.pendingStart = false
        startLiveLoad()
    end

    local children = ctx.children
    local x, y, w = ctx.x, ctx.y, ctx.w

    Controls.appendStaticSectionHeader(children, x, y, w, t(i18n, "section_experiments", "MSP Experiments"))

    local cursorY = y + Controls.STATIC_SECTION_H
    cursorY = cursorY + 4

    local fieldW = 172
    local fieldX = x + w - fieldW - 10
    
    children[#children + 1] = {
        type = "label",
        x = fieldX,
        y = cursorY,
        w = fieldW - 8, 
        text = "UINT8 (0-255)",
        color = COLOR_THEME_PRIMARY1,
        font = SMLSIZE,
        align = RIGHT,
    }
    
    children[#children + 1] = {
        type = "rectangle",
        x = x,
        y = cursorY + 24,
        w = w,
        h = 2,
        color = COLOR_THEME_PRIMARY1,
        filled = true,
    }
    cursorY = cursorY + 34

    local fieldsByLabel = {}
    for _, field in ipairs(state.apidata.formdata.fields or {}) do
        if field.isUINT8 and field.label ~= nil then
            fieldsByLabel[field.label] = field
        end
    end

    for i = 1, state.expBytes do
        local label = "Byte " .. tostring(i)
        local uint8Field = fieldsByLabel[i]

        cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, label, {
            min = 0,
            max = 255,
            get = function() return uint8Field and uint8Field.value or 0 end,
            set = function(val)
                if uint8Field then
                    local v = tonumber(val) or 0
                    if v < 0 then v = 0 end
                    if v > 255 then v = 255 end
                    if uint8Field.value ~= v then
                        uint8Field.value = v
                    end
                end
            end,
            enabled = true,
        })
    end

    if state.loading and state.showLoadingOverlay then
        if AsyncLoadUi.isTimedOut(state, nowSeconds()) then
            abortLoading(i18n, t(i18n, "loading_timeout", "Timeout"))
        end
        local title = t(i18n, "loading_title", "Loading")
        local message = string.format("%s %d/%d", t(i18n, "loading_message", "Reading live data"), state.done, state.total)
        LoadingOverlay.append(children, {
            x = x, y = y, w = ctx.w, h = ctx.h,
            title = title, message = message, progress = state.progress
        })
    elseif state.errorMessage and state.errorMessage ~= "" then
        AsyncLoadUi.appendErrorNotice(children, {
            x = x, y = y, w = ctx.w, h = ctx.h,
            overlay = LoadingOverlay,
            requestRebuild = ctx and ctx.requestRebuild
        }, state, i18n, t)
    end
end

function M.wakeup()
    local now = nowSeconds()
    if state.loading and AsyncLoadUi and type(AsyncLoadUi.isTimedOut) == "function" and AsyncLoadUi.isTimedOut(state, now) then
        abortLoading(state.i18n, t(state.i18n, "loading_timeout", "Timeout"))
    end
end

function M.closePage()
    if state.attached and MspRuntime and type(MspRuntime.detach) == "function" then
        MspRuntime.detach("exp-page")
    end
    local runtimeState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
    local queue = runtimeState and runtimeState.queue
    if queue and type(queue.clear) == "function" then
        queue:clear("exp-page")
    end
    state.started = false
    state.attached = false
    state.pendingStart = false
    state.deferStartBuild = false
    state.forceReload = false
    state.i18n = nil
    if AsyncLoadUi and type(AsyncLoadUi.reset) == "function" then
        AsyncLoadUi.reset(state)
    end
    state.rebuild = nil
    state.loaded = false
end

return M