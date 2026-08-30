if type(_G) == "table" and type(_G.__rfsuiteThemeDefaultCommonModule) == "table" then
  return _G.__rfsuiteThemeDefaultCommonModule
end

local Common = {}

local LOGO_FILE = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/gfx/logo.png"

local i18nModule = nil
local i18nContext = nil
local i18nLocale = nil
local localeModule = nil

local function getLocaleModule()
  if localeModule then
    return localeModule
  end

  if type(_G) == "table" and type(_G.__rfsuite_system_locale_module) == "table" then
    localeModule = _G.__rfsuite_system_locale_module
    return localeModule
  end

  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("lib/system_locale.lua")
    if mod and type(mod) == "table" then
      localeModule = mod
      return localeModule
    end
  end

  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then
      localeModule = mod
      if type(_G) == "table" then
        _G.__rfsuite_system_locale_module = mod
      end
    end
  end

  return localeModule
end

local function resolveLocale()
  local mod = getLocaleModule()
  if mod and type(mod.resolveSystemLanguage) == "function" then
    local ok, locale = pcall(mod.resolveSystemLanguage, "en")
    if ok and type(locale) == "string" and locale ~= "" then
      return locale
    end
  end

  return "en"
end

local function getI18nContext()
  local locale = resolveLocale()
  if i18nContext and i18nLocale == locale then
    return i18nContext
  end

  if not i18nModule then
    if _G.rfsuite and type(_G.rfsuite.require) == "function" then
      local mod = _G.rfsuite.require("i18n/init.lua")
      if mod and type(mod) == "table" and type(mod.new) == "function" then
        i18nModule = mod
      end
    end
    if not i18nModule then
      local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/i18n/init.lua", mode)
      if chunk then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" and type(mod.new) == "function" then
          i18nModule = mod
        end
      end
    end
  end

  if i18nModule and type(i18nModule.new) == "function" then
    local ok, ctx = pcall(i18nModule.new, locale)
    if ok and type(ctx) == "table" then
      i18nContext = ctx
      i18nLocale = locale
      return i18nContext
    end
  end

  return nil
end

local function t(key, fallback)
  local ctx = getI18nContext()
  if ctx and type(ctx.t) == "function" then
    local ok, translated = pcall(ctx.t, key)
    if ok and type(translated) == "string" and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback or key
end

local function append(nodes, extra)
  for index = 1, #extra do
    nodes[#nodes + 1] = extra[index]
  end
end

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function asNumber(value, fallback)
  if type(value) == "number" then
    return value
  end
  return fallback
end

function Common.getVoltageColor(state)
  local cfg = state and state.themeConfig or nil
  local vMin = tonumber(cfg and cfg.v_min) or 18.0
  local vMax = tonumber(cfg and cfg.v_max) or 25.2
  local value = tonumber(state and state.voltage) or 0
  if value <= 0 then return BLACK end
  if value < vMin or value > vMax then return COLOR_THEME_WARNING end
  return COLOR_THEME_PRIMARY1
end

function Common.estimateCellCount(state)
  local stateCells = tonumber(state and state.batteryCellCount)
  if stateCells and stateCells > 0 then
    return clamp(math.floor(stateCells + 0.5), 1, 14)
  end

  local cfg = state and state.themeConfig or nil
  local vMax = tonumber(cfg and cfg.v_max) or 25.2
  local cells = math.floor((vMax / 4.2) + 0.5)
  return clamp(cells, 1, 14)
end

function Common.formatDuration(seconds)
  local value = math.max(0, math.floor(asNumber(seconds, 0) + 0.5))
  local hours = math.floor(value / 3600)
  local minutes = math.floor((value % 3600) / 60)
  local secs = value % 60
  if hours > 0 then
    return string.format("%d:%02d", hours, minutes)
  end
  return string.format("%02d:%02d", minutes, secs)
end

function Common.formatVoltage(value)
  local numeric = asNumber(value, 0)
  if numeric <= 0 then
    return "--.-V"
  end
  return string.format("%.1fV", numeric)
end

function Common.formatCellVoltage(state, value)
  local numeric = asNumber(value, 0)
  if numeric <= 0 then
    return "--.-V/c"
  end
  return string.format("%.2fV/c", numeric / Common.estimateCellCount(state))
end

function Common.formatInteger(value, suffix)
  if type(value) ~= "number" then
    return "--"
  end
  local text = tostring(math.floor(value + 0.5))
  if suffix and suffix ~= "" then
    text = text .. suffix
  end
  return text
end

function Common.blackboxLabel(state)
  if state and state.armed then return t("widgets.dashboard.bb_rec", "REC") end

  if state and state.dataflash and type(state.dataflash.total) == "number" and state.dataflash.total > 0 then
    -- Convert bytes to MB (using 1048576 = 1024 * 1024)
    local usedMB = (state.dataflash.used or 0) / 1048576
    local totalMB = state.dataflash.total / 1048576
    return string.format("%.1f/%.0fMB", usedMB, totalMB)
  end

  if state and state.hadArmedFlight then return t("widgets.dashboard.bb_logged", "LOGGED") end
  return t("widgets.dashboard.bb_ready", "READY")
end

function Common.statusLabel(state)
  if state and state.armed then return t("widgets.dashboard.status_armed", "ARMED") end
  return t("widgets.dashboard.status_disarmed", "DISARMED")
end

function Common.statusColor(state)
  if state and state.armed then return COLOR_THEME_WARNING end
  return COLOR_THEME_SECONDARY1
end

function Common.buildHeader(zone, state, title)
  return {
    {
      type = "rectangle",
      x = zone.x,
      y = zone.y,
      w = zone.w,
      h = zone.h,
      color = COLOR_THEME_PRIMARY2,
      filled = true
    },
    {
      type = "rectangle",
      x = zone.x,
      y = zone.y,
      w = zone.w,
      h = 28,
      color = COLOR_THEME_PRIMARY1,
      filled = true
    },
    {
      type = "image",
      x = zone.x + 4,
      y = zone.y + 1,
      w = 26,
      h = 26,
      file = LOGO_FILE
    },
    {
      type = "label",
      x = zone.x + 36,
      y = zone.y + 6,
      w = math.max(70, zone.w - 150),
      text = title,
      color = WHITE,
      font = MIDSIZE
    },
    {
      type = "label",
      x = zone.x + zone.w - 110,
      y = zone.y + 6,
      w = 100,
      text = function() return Common.statusLabel(state) end,
      color = function() return Common.statusColor(state) end,
      align = RIGHT,
      font = SMLSIZE
    }
  }
end

function Common.addCard(nodes, x, y, w, h, color)
  nodes[#nodes + 1] = {
    type = "rectangle",
    x = x,
    y = y,
    w = w,
    h = h,
    color = color or WHITE,
    filled = true
  }
end

function Common.addMetricCard(nodes, spec)
  Common.addCard(nodes, spec.x, spec.y, spec.w, spec.h, spec.bgcolor or WHITE)

  nodes[#nodes + 1] = {
    type = "label",
    x = spec.x + 6,
    y = spec.y + 5,
    w = spec.w - 12,
    text = spec.title,
    color = spec.titleColor or COLOR_THEME_DISABLED,
    font = SMLSIZE
  }

  local valFont = spec.font or MIDSIZE
  if spec.autoSizeChars then
    valFont = function()
      local txt = type(spec.value) == "function" and spec.value() or tostring(spec.value)
      if #txt > spec.autoSizeChars then
        return spec.autoSizeFont or SMLSIZE
      end
      return type(spec.font) == "function" and spec.font() or (spec.font or MIDSIZE)
    end
  end

  nodes[#nodes + 1] = {
    type = "label",
    x = spec.x + 6,
    y = spec.y + math.max(18, math.floor((spec.h - 26) * 0.45)),
    w = spec.w - 12,
    text = spec.value,
    color = spec.valueColor or BLACK,
    align = spec.align or CENTER,
    font = valFont
  }

  if spec.note then
    nodes[#nodes + 1] = {
      type = "label",
      x = spec.x + 6,
      y = spec.y + spec.h - 18,
      w = spec.w - 12,
      text = spec.note,
      color = spec.noteColor or COLOR_THEME_DISABLED,
      align = spec.noteAlign or CENTER,
      font = SMLSIZE
    }
  end
end

function Common.buildPreflight(zone, state)
  local nodes = Common.buildHeader(zone, state, "DEFAULT / PREFLIGHT")
  local gap = 6
  local contentY = zone.y + 34
  local contentH = zone.h - 40
  local leftW = math.max(110, math.floor(zone.w * 0.58))
  local rightX = zone.x + leftW + gap
  local rightW = zone.w - leftW - gap
  local topH = 36
  local smallH = 34
  local boxGap = 4
  local smallW = math.floor((leftW - boxGap) / 2)
  local modelY = contentY + topH + gap
  local modelH = math.max(56, contentH - topH - gap - smallH * 2 - boxGap)
  local bottomRowY = modelY + modelH + gap

  Common.addMetricCard(nodes, {
    x = zone.x,
    y = contentY,
    w = smallW,
    h = topH,
    title = "FLIGHT TIME",
    value = function() return Common.formatDuration(state.flightSeconds) end,
    font = MIDSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x + smallW + boxGap,
    y = contentY,
    w = leftW - smallW - boxGap,
    h = topH,
    title = "FLIGHTS",
    value = function() return Common.formatInteger(state.flights, "") end,
    font = MIDSIZE
  })

  Common.addModelCard(nodes, zone.x, modelY, leftW, modelH)

  Common.addMetricCard(nodes, {
    x = zone.x,
    y = bottomRowY,
    w = smallW,
    h = smallH,
    title = "BLACKBOX",
    value = function() return Common.blackboxLabel(state) end,
    font = MIDSIZE,
    autoSizeChars = 12
  })
  Common.addMetricCard(nodes, {
    x = zone.x + smallW + boxGap,
    y = bottomRowY,
    w = leftW - smallW - boxGap,
    h = smallH,
    title = "PID PROFILE",
    value = function() return Common.formatInteger(state.profile, "") end,
    font = MIDSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x,
    y = bottomRowY + smallH + boxGap,
    w = smallW,
    h = smallH,
    title = "RATE PROFILE",
    value = function() return Common.formatInteger(state.rateProfile, "") end,
    font = MIDSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x + smallW + boxGap,
    y = bottomRowY + smallH + boxGap,
    w = leftW - smallW - boxGap,
    h = smallH,
    title = "LINK QUALITY",
    value = function() return Common.formatInteger(state.lq, "%") end,
    font = MIDSIZE
  })

  Common.addGaugeCard(nodes, rightX, contentY, rightW, contentH, state)
  return nodes
end

function Common.buildInflight(zone, state)
  local nodes = Common.buildHeader(zone, state, "DEFAULT / INFLIGHT")
  local gap = 6
  local contentY = zone.y + 34
  local footerH = 28
  local bodyH = zone.h - 40 - footerH - gap
  local leftW = math.max(92, math.floor(zone.w * 0.38))
  local rightX = zone.x + leftW + gap
  local rightW = zone.w - leftW - gap
  local cardH = math.floor((bodyH - gap) / 2)
  local footerY = contentY + bodyH + gap
  local footerColW = math.floor(zone.w / 3)

  Common.addMetricCard(nodes, {
    x = zone.x,
    y = contentY,
    w = leftW,
    h = cardH,
    title = "FLIGHT TIME",
    value = function() return Common.formatDuration(state.flightSeconds) end,
    font = DBLSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x,
    y = contentY + cardH + gap,
    w = leftW,
    h = bodyH - cardH - gap,
    title = "LINK QUALITY",
    value = function() return Common.formatInteger(state.lq, "%") end,
    note = function() return "FUEL " .. Common.formatInteger(state.fuel, "%") end,
    font = DBLSIZE
  })
  Common.addGaugeCard(nodes, rightX, contentY, rightW, bodyH, state)

  Common.addCard(nodes, zone.x, footerY, zone.w, footerH, COLOR_THEME_PRIMARY1)
  Common.addMetricCard(nodes, {
    x = zone.x,
    y = footerY,
    w = footerColW,
    h = footerH,
    title = "RPM",
    value = function() return Common.formatInteger(state.rpm, "") end,
    bgcolor = COLOR_THEME_PRIMARY1,
    titleColor = WHITE,
    valueColor = WHITE,
    font = SMLSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x + footerColW,
    y = footerY,
    w = footerColW,
    h = footerH,
    title = "FLIGHTS",
    value = function() return Common.formatInteger(state.flights, "") end,
    bgcolor = COLOR_THEME_PRIMARY1,
    titleColor = WHITE,
    valueColor = WHITE,
    font = SMLSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x + footerColW * 2,
    y = footerY,
    w = zone.w - footerColW * 2,
    h = footerH,
    title = "TOTAL",
    value = function() return Common.formatDuration(state.totalFlightSeconds) end,
    bgcolor = COLOR_THEME_PRIMARY1,
    titleColor = WHITE,
    valueColor = WHITE,
    font = SMLSIZE
  })
  return nodes
end

function Common.buildPostflight(zone, state)
  local nodes = Common.buildHeader(zone, state, "DEFAULT / POSTFLIGHT")
  local gap = 6
  local contentY = zone.y + 34
  local contentH = zone.h - 40
  local colW = math.floor((zone.w - gap) / 2)
  local rowH = math.floor((contentH - gap - 24) / 2)
  local footerY = contentY + rowH * 2 + gap

  Common.addMetricCard(nodes, {
    x = zone.x,
    y = contentY,
    w = colW,
    h = rowH,
    title = "LAST FLIGHT",
    value = function() return Common.formatDuration(state.lastFlightSeconds) end,
    font = DBLSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x + colW + gap,
    y = contentY,
    w = zone.w - colW - gap,
    h = rowH,
    title = "TOTAL TIME",
    value = function() return Common.formatDuration(state.totalFlightSeconds) end,
    font = DBLSIZE
  })
  Common.addMetricCard(nodes, {
    x = zone.x,
    y = contentY + rowH + gap,
    w = colW,
    h = rowH,
    title = "MIN V/CELL",
    value = function() return Common.formatCellVoltage(state, state.lastMinVoltage) end,
    font = MIDSIZE,
    valueColor = function()
      if type(state.lastMinVoltage) == "number" then
        return Common.getVoltageColor({ voltage = state.lastMinVoltage, themeConfig = state.themeConfig })
      end
      return BLACK
    end
  })
  Common.addMetricCard(nodes, {
    x = zone.x + colW + gap,
    y = contentY + rowH + gap,
    w = zone.w - colW - gap,
    h = rowH,
    title = "MIN LINK",
    value = function() return Common.formatInteger(state.lastMinLq, "%") end,
    font = DBLSIZE
  })

  Common.addCard(nodes, zone.x, footerY, zone.w, 24, COLOR_THEME_PRIMARY1)
  nodes[#nodes + 1] = {
    type = "label",
    x = zone.x + 8,
    y = footerY + 5,
    w = zone.w - 16,
    text = function() return "BLACKBOX " .. Common.blackboxLabel(state) .. "  |  FLIGHTS " .. Common.formatInteger(state.flights, "") end,
    color = WHITE,
    align = CENTER,
    font = SMLSIZE
  }
  return nodes
end

if type(_G) == "table" then _G.__rfsuiteThemeDefaultCommonModule = Common end
return Common