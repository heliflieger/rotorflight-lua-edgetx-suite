--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html
]] --

local function loadModule(path)
    local chunk = assert(loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t"))
    return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")

-- The settings page loads this file for the theme it is configuring and hands that theme
-- to the factory below, so a copy of this theme under rfsuite.user/dashboard stores its
-- values under its own key prefix instead of this one's. The literal is the fallback for
-- a caller that passes no theme.
local THEME_PATH = "system/@aerc-n"
local THEME_DEFAULTS = {
    rpm_min = 0,
    rpm_max = 3000,
    bec_min = 3.0,
    bec_warn = 6.0,
    bec_max = 13.0,
    esctemp_warn = 90,
    esctemp_max = 140,
}

local ui = {
    loaded = false,
    config = {
        rpm_min = 0,
        rpm_max = 3000,
        bec_min_tenths = 30,
        bec_warn_tenths = 60,
        bec_max_tenths = 130,
        esctemp_warn = 90,
        esctemp_max = 140,
    }
}

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function loadConfig(prefs)
    if ui.loaded then return end

    local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
    -- The per-model store is only addressable once the flight controller's id is known, so
    -- the read is conditioned on it exactly as the save is.
    local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

    local cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, THEME_DEFAULTS, modelPrefs)
    
    ui.config.rpm_min = tonumber(cfg.rpm_min) or THEME_DEFAULTS.rpm_min
    ui.config.rpm_max = tonumber(cfg.rpm_max) or THEME_DEFAULTS.rpm_max
    ui.config.bec_min_tenths = math.floor(((tonumber(cfg.bec_min) or THEME_DEFAULTS.bec_min) * 10) + 0.5)
    ui.config.bec_warn_tenths = math.floor(((tonumber(cfg.bec_warn) or THEME_DEFAULTS.bec_warn) * 10) + 0.5)
    ui.config.bec_max_tenths = math.floor(((tonumber(cfg.bec_max) or THEME_DEFAULTS.bec_max) * 10) + 0.5)
    ui.config.esctemp_warn = tonumber(cfg.esctemp_warn) or THEME_DEFAULTS.esctemp_warn
    ui.config.esctemp_max = tonumber(cfg.esctemp_max) or THEME_DEFAULTS.esctemp_max
    
    ui.config.rpm_min = clamp(ui.config.rpm_min, 0, 20000)
    ui.config.rpm_max = clamp(ui.config.rpm_max, 1, 20000)
    ui.config.bec_min_tenths = clamp(ui.config.bec_min_tenths, 20, 150)
    ui.config.bec_warn_tenths = clamp(ui.config.bec_warn_tenths, 20, 150)
    ui.config.bec_max_tenths = clamp(ui.config.bec_max_tenths, 20, 150)
    ui.config.esctemp_warn = clamp(ui.config.esctemp_warn, 0, 200)
    ui.config.esctemp_max = clamp(ui.config.esctemp_max, 1, 200)
    
    ui.loaded = true
end

local function saveConfig(prefs)
    local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
    -- The per-model store can only be written once the flight controller's id is known, so
    -- a theme configured without one is stored globally instead.
    local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

    DashboardLib.setThemeConfig(prefs, THEME_PATH, {
        rpm_min = tonumber(ui.config.rpm_min) or THEME_DEFAULTS.rpm_min,
        rpm_max = tonumber(ui.config.rpm_max) or THEME_DEFAULTS.rpm_max,
        bec_min = (tonumber(ui.config.bec_min_tenths) or 30) / 10,
        bec_warn = (tonumber(ui.config.bec_warn_tenths) or 60) / 10,
        bec_max = (tonumber(ui.config.bec_max_tenths) or 130) / 10,
        esctemp_warn = tonumber(ui.config.esctemp_warn) or THEME_DEFAULTS.esctemp_warn,
        esctemp_max = tonumber(ui.config.esctemp_max) or THEME_DEFAULTS.esctemp_max,
    }, modelPrefs)

    if session and session.mcu_id and modelPrefs then
        local loadMod = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", "t")
        if type(loadMod) == "function" then
            local ok, MP = pcall(loadMod)
            if ok and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
                MP.saveByMcuId(session.mcu_id, modelPrefs)
            end
        end
    end
end

local function getRpmMin()
    return tonumber(ui.config.rpm_min) or 0
end

local function setRpmMin(value)
    ui.config.rpm_min = clamp(tonumber(value) or 0, 0, 20000)
end

local function getRpmMax()
    return tonumber(ui.config.rpm_max) or 3000
end

local function setRpmMax(value)
    ui.config.rpm_max = clamp(tonumber(value) or 3000, 1, 20000)
end

local function getBecMin()
    return tonumber(ui.config.bec_min_tenths) or 30
end

local function setBecMin(value)
    ui.config.bec_min_tenths = clamp(tonumber(value) or 30, 20, 150)
end

local function getBecWarn()
    return tonumber(ui.config.bec_warn_tenths) or 60
end

local function setBecWarn(value)
    ui.config.bec_warn_tenths = clamp(tonumber(value) or 60, 20, 150)
end

local function getBecMax()
    return tonumber(ui.config.bec_max_tenths) or 130
end

local function setBecMax(value)
    ui.config.bec_max_tenths = clamp(tonumber(value) or 130, 20, 150)
end

local function getEscWarn()
    return tonumber(ui.config.esctemp_warn) or 90
end

local function setEscWarn(value)
    ui.config.esctemp_warn = clamp(tonumber(value) or 90, 0, 200)
end

local function getEscMax()
    return tonumber(ui.config.esctemp_max) or 140
end

local function setEscMax(value)
    ui.config.esctemp_max = clamp(tonumber(value) or 140, 1, 200)
end

local M = {}

function M.getHeaderActions()
    return { save = true, help = false }
end


function M.onReload(ctx)
    ui.loaded = false
    loadConfig(ctx.preferences)
    return true
end

function M.onSave(ctx)
    saveConfig(ctx.preferences)
    local ok, err = ctx.savePreferences()
    if ok then
        ui.dirty = false
        if ctx and type(ctx.reportSave) == "function" then
            local i18n = ctx.i18n
            local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_title") or "Saved"
            local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_message") or "Theme settings saved"
            ctx.reportSave({ ok = true, title = title, message = message })
        end
    else
        if ctx and type(ctx.reportSave) == "function" then
            local i18n = ctx.i18n
            local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_title") or "Error"
            local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_message") or "Save failed"
            ctx.reportSave({ title = title, message = message .. ": " .. tostring(err or "io") })
        end
    end
    return true
end

function M.build(ctx)
    loadConfig(ctx.preferences)

    local children = ctx.children
    local x, y, w = ctx.x, ctx.y, ctx.w
    local i18n = ctx.i18n
    local cursorY = y

    -- RPM Section
    local rpmSectionTitle = "@AERC Nitro Headspeed"
    if i18n and i18n.t then
        local translated = i18n.t("widgets.dashboard.headspeed")
        if translated and translated ~= "widgets.dashboard.headspeed" and translated ~= "" then
            rpmSectionTitle = translated
        end
    end

    Controls.appendSectionHeader(children, x, cursorY, w, rpmSectionTitle, true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    local rpmMinLabel = "Min RPM"
    local rpmMaxLabel = "Max RPM"
    if i18n and i18n.t then
        local minTranslated = i18n.t("widgets.dashboard.min")
        if minTranslated and minTranslated ~= "widgets.dashboard.min" and minTranslated ~= "" then
            rpmMinLabel = minTranslated .. " RPM"
        end
        local maxTranslated = i18n.t("widgets.dashboard.max")
        if maxTranslated and maxTranslated ~= "widgets.dashboard.max" and maxTranslated ~= "" then
            rpmMaxLabel = maxTranslated .. " RPM"
        end
    end

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, rpmMinLabel, {
        min = 0,
        max = 20000,
        get = getRpmMin,
        set = setRpmMin,
        display = function(value)
            return tostring(tonumber(value) or 0)
        end
    })

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, rpmMaxLabel, {
        min = 1,
        max = 20000,
        get = getRpmMax,
        set = setRpmMax,
        display = function(value)
            return tostring(tonumber(value) or 3000)
        end
    })

    -- BEC Section
    local becSectionTitle = "@AERC Nitro BEC Voltage"
    if i18n and i18n.t then
        local translated = i18n.t("widgets.dashboard.bec_voltage")
        if translated and translated ~= "widgets.dashboard.bec_voltage" and translated ~= "" then
            becSectionTitle = translated
        end
    end

    Controls.appendSectionHeader(children, x, cursorY, w, becSectionTitle, true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    local becMinLabel = "Min"
    local becWarnLabel = "Warning"
    local becMaxLabel = "Max"
    if i18n and i18n.t then
        local minTranslated = i18n.t("widgets.dashboard.min")
        if minTranslated and minTranslated ~= "widgets.dashboard.min" and minTranslated ~= "" then
            becMinLabel = minTranslated
        end
        local warnTranslated = i18n.t("widgets.dashboard.warning")
        if warnTranslated and warnTranslated ~= "widgets.dashboard.warning" and warnTranslated ~= "" then
            becWarnLabel = warnTranslated
        end
        local maxTranslated = i18n.t("widgets.dashboard.max")
        if maxTranslated and maxTranslated ~= "widgets.dashboard.max" and maxTranslated ~= "" then
            becMaxLabel = maxTranslated
        end
    end

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, becMinLabel, {
        min = 20,
        max = 150,
        get = getBecMin,
        set = setBecMin,
        display = function(value)
            return string.format("%.1fV", (tonumber(value) or 30) / 10)
        end
    })

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, becWarnLabel, {
        min = 20,
        max = 150,
        get = getBecWarn,
        set = setBecWarn,
        display = function(value)
            return string.format("%.1fV", (tonumber(value) or 60) / 10)
        end
    })

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, becMaxLabel, {
        min = 20,
        max = 150,
        get = getBecMax,
        set = setBecMax,
        display = function(value)
            return string.format("%.1fV", (tonumber(value) or 130) / 10)
        end
    })

    -- ESC Temp Section
    local escSectionTitle = "@AERC Nitro ESC Temperature"
    if i18n and i18n.t then
        local translated = i18n.t("widgets.dashboard.esc_temp")
        if translated and translated ~= "widgets.dashboard.esc_temp" and translated ~= "" then
            escSectionTitle = translated
        end
    end

    Controls.appendSectionHeader(children, x, cursorY, w, escSectionTitle, true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    local escWarnLabel = "Warning"
    local escMaxLabel = "Max"
    if i18n and i18n.t then
        local warnTranslated = i18n.t("widgets.dashboard.warning")
        if warnTranslated and warnTranslated ~= "widgets.dashboard.warning" and warnTranslated ~= "" then
            escWarnLabel = warnTranslated
        end
        local maxTranslated = i18n.t("widgets.dashboard.max")
        if maxTranslated and maxTranslated ~= "widgets.dashboard.max" and maxTranslated ~= "" then
            escMaxLabel = maxTranslated
        end
    end

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, escWarnLabel, {
        min = 0,
        max = 200,
        get = getEscWarn,
        set = setEscWarn,
        display = function(value)
            return tostring(tonumber(value) or 90) .. "°C"
        end
    })

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, escMaxLabel, {
        min = 1,
        max = 200,
        get = getEscMax,
        set = setEscMax,
        display = function(value)
            return tostring(tonumber(value) or 140) .. "°C"
        end
    })

    return cursorY
end

return function(ctx)
    local theme = ctx and ctx.theme
    if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
        THEME_PATH = theme.path
    end
    return M
end


