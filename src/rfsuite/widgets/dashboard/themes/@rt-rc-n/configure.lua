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
local THEME_PATH = "system/@rt-rc-n"
local THEME_DEFAULTS = {
    v_min = 7.0,
    v_max = 8.4,
}

local ui = {
    loaded = false,
    config = {
        v_min_tenths = 70,
        v_max_tenths = 84,
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
    local vMin = tonumber(cfg.v_min) or THEME_DEFAULTS.v_min
    local vMax = tonumber(cfg.v_max) or THEME_DEFAULTS.v_max

    vMin = clamp(vMin, 5.0, 64.9)
    vMax = clamp(vMax, vMin + 0.1, 65.0)

    ui.config.v_min_tenths = math.floor((vMin * 10) + 0.5)
    ui.config.v_max_tenths = math.floor((vMax * 10) + 0.5)
    ui.loaded = true
end

local function saveConfig(prefs)
    local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
    -- The per-model store can only be written once the flight controller's id is known, so
    -- a theme configured without one is stored globally instead.
    local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

    DashboardLib.setThemeConfig(prefs, THEME_PATH, {
        v_min = (tonumber(ui.config.v_min_tenths) or 70) / 10,
        v_max = (tonumber(ui.config.v_max_tenths) or 84) / 10,
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

local function getMin()
    local current = tonumber(ui.config.v_min_tenths) or 70
    local maxAllowed = (tonumber(ui.config.v_max_tenths) or 84) - 1
    return clamp(current, 50, maxAllowed)
end

local function setMin(value)
    local maxAllowed = (tonumber(ui.config.v_max_tenths) or 84) - 1
    local nextValue = clamp(tonumber(value) or 70, 50, maxAllowed)
    if ui.config.v_min_tenths ~= nextValue then
        ui.config.v_min_tenths = nextValue
    end
end

local function getMax()
    local current = tonumber(ui.config.v_max_tenths) or 84
    local minAllowed = (tonumber(ui.config.v_min_tenths) or 70) + 1
    return clamp(current, minAllowed, 650)
end

local function setMax(value)
    local minAllowed = (tonumber(ui.config.v_min_tenths) or 70) + 1
    local nextValue = clamp(tonumber(value) or 84, minAllowed, 650)
    if ui.config.v_max_tenths ~= nextValue then
        ui.config.v_max_tenths = nextValue
    end
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

    local sectionTitle = "@RT-RC Nitro Theme Voltage"
    if i18n and i18n.t then
        local translated = i18n.t("app.pages.settings_dashboard_settings.section_default_voltage")
        if translated and translated ~= "app.pages.settings_dashboard_settings.section_default_voltage" and translated ~= "" then
            sectionTitle = translated
        end
    end

    Controls.appendSectionHeader(children, x, cursorY, w, sectionTitle, true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    local minLabel = "Min"
    local maxLabel = "Max"
    if i18n and i18n.t then
        local minTranslated = i18n.t("app.pages.settings_dashboard_settings.min")
        local maxTranslated = i18n.t("app.pages.settings_dashboard_settings.max")
        if minTranslated and minTranslated ~= "app.pages.settings_dashboard_settings.min" and minTranslated ~= "" then
            minLabel = minTranslated
        end
        if maxTranslated and maxTranslated ~= "app.pages.settings_dashboard_settings.max" and maxTranslated ~= "" then
            maxLabel = maxTranslated
        end
    end

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, minLabel, {
        min = 50,
        max = 649,
        get = getMin,
        set = setMin,
        display = function(value)
            return string.format("%.1fV", (tonumber(value) or 70) / 10)
        end
    })

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, maxLabel, {
        min = 51,
        max = 650,
        get = getMax,
        set = setMax,
        display = function(value)
            return string.format("%.1fV", (tonumber(value) or 84) / 10)
        end
    })
end

return function(ctx)
    local theme = ctx and ctx.theme
    if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
        THEME_PATH = theme.path
    end
    return M
end
