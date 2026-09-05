local Wrapper = {}

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    return _G.rfsuite.require(path)
  end
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local function getUtils()
  return requireModule("widgets/dashboard/objects/common.lua")
end

local function getThemeCommon()
  return requireModule("widgets/dashboard/themes/default/common.lua")
end

local function rgb(hex, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local r = math.floor(hex / 65536) % 256
    local g = math.floor(hex / 256) % 256
    local b = hex % 256
    local ok, col = pcall(lcd.RGB, r, g, b)
    if ok and col then return col end
  end
  return fallback
end

local ARC_BG_COLOR = rgb(0x444444, COLOR_THEME_SECONDARY2)
local ARC_OK_COLOR = rgb(0x00FF00, GREEN or 0x00FF00)
local ARC_WARN_COLOR = rgb(0xFF8000, 0xFF8000)
local ARC_ALERT_COLOR = rgb(0xFF0000, 0xFF0000)
local BAR_BG_COLOR = rgb(0x1a1a1a, BLACK)
local BAR_OK_COLOR = rgb(0x00FF00, GREEN or 0x00FF00)
local BAR_WARN_COLOR = rgb(0xFF8000, 0xFF8000)
local BAR_ALERT_COLOR = rgb(0xFF0000, 0xFF0000)

local function useFahrenheit()
  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local localizations = prefs and prefs.localizations or nil
  return tonumber(localizations and localizations.temperature_unit) == 1
end

local function isTempSource(source)
  return source == "esc_temp" or source == "mcu_temp" or source == "temp_esc" or source == "temp_mcu"
end

local function cToF(c)
  if type(c) == "number" then
    return (c * 9 / 5) + 32
  end
  return c
end

-- The value a reactive closure renders comes out of the derived snapshot, never from a
-- probe: the sweep runs per frame on the refresh's leftover budget, outside any pcall,
-- so its per-object cost has to be a constant (see GEMINI.md, "Dashboard reactive
-- closures"). The snapshot is rebuilt on the telemetry-read cadence.
local function readDerived(state, source)
  local derived = type(state) == "table" and state.derived or nil
  if derived == nil or source == nil then return nil end
  return derived[source]
end

-- Compiled once per box and kept on a weak-keyed cache (a theme whose `boxes` is a
-- function hands out fresh box tables per resolve; a strong key would leak one compiled
-- list per resolve): the comparison values with their unit conversion already applied and
-- the fill color picked, in the theme's own order. The per-frame pick is then a walk over
-- a list whose length is a build-time constant.
local thresholdCache = setmetatable({}, { __mode = "k" })

local function compiledThresholds(box, thresholds, isFahrenheit)
  local cached = box and thresholdCache[box] or nil
  if cached and cached.src == thresholds and cached.fahrenheit == isFahrenheit then
    return cached.list
  end
  local list = {}
  for i = 1, #thresholds do
    local threshold = thresholds[i]
    if type(threshold) == "table" and type(threshold.value) == "number" then
      list[#list + 1] = {
        value = isFahrenheit and cToF(threshold.value) or threshold.value,
        color = threshold.fillcolor or threshold.color
      }
    end
  end
  if box then
    thresholdCache[box] = { src = thresholds, fahrenheit = isFahrenheit, list = list }
  end
  return list
end

local function resolveThresholdColor(value, thresholds, defaultColor, isFahrenheit, box)
  if type(value) ~= "number" or type(thresholds) ~= "table" or #thresholds == 0 then
    return defaultColor
  end

  local list = compiledThresholds(box, thresholds, isFahrenheit == true)
  for i = 1, #list do
    if value <= list[i].value then
      return list[i].color or defaultColor
    end
  end

  return defaultColor
end

local function getArcValueColor(value, state, box, themeCommon, utils, isTemp, fahrenheit, curHasValue, gaugeMax, unit)
  if type(value) ~= "number" then
    return ARC_BG_COLOR
  end

  if unit == "%" then
    local alertPct = tonumber(box and box.alertpct) or 15
    local warnPct = tonumber(box and box.warnpct) or 30
    if value <= alertPct then return ARC_ALERT_COLOR end
    if value <= warnPct then return ARC_WARN_COLOR end
    return ARC_OK_COLOR
  end

  -- Temperature sources: inverted threshold logic (high = warning/critical).
  -- No division by battery cell count; raw value is evaluated directly.
  if isTemp then
    -- When telemetry has no reading, use background color.
    -- Legitimate low/negative temperatures (<= 0 °C) remain valid (green).
    if curHasValue == false then
      return ARC_BG_COLOR
    end

    -- Resolve warn threshold (°C): box property -> theme config -> default 90.
    local warnTemp = tonumber(box and (box.warntemp or box.warn))
    if not warnTemp then
      local cfg = state and state.themeConfig
      warnTemp = tonumber(cfg and cfg.esctemp_warn)
    end
    warnTemp = warnTemp or 90

    -- Resolve alert threshold (°C): box property -> theme config -> default max(warn+15, 105).
    local isDefaultAlert = false
    local alertTemp = tonumber(box and (box.alerttemp or box.alert))
    if not alertTemp then
      local cfg = state and state.themeConfig
      alertTemp = tonumber(cfg and cfg.esctemp_alert)
    end
    if not alertTemp then
      alertTemp = math.max(warnTemp + 15, 105)
      isDefaultAlert = true
    end

    -- Ensure warn < alert.
    if warnTemp > alertTemp then
      local tmp = warnTemp
      warnTemp = alertTemp
      alertTemp = tmp
    end

    -- When Fahrenheit display is active, renderArc already converts curVal to °F
    -- before calling this function, so the thresholds must be converted as well.
    if fahrenheit then
      warnTemp = cToF(warnTemp)
      alertTemp = cToF(alertTemp)
    end

    -- Cap defaulted alert threshold at gaugeMax so alert color remains reachable even if
    -- user or theme increases warnTemp beyond standard scale limits.
    if isDefaultAlert and type(gaugeMax) == "number" and gaugeMax > warnTemp then
      alertTemp = math.min(alertTemp, gaugeMax)
    end

    if value >= alertTemp then return ARC_ALERT_COLOR end
    if value >= warnTemp then return ARC_WARN_COLOR end
    return ARC_OK_COLOR
  end

  -- Default: battery cell voltage handling (ascending thresholds, low = bad).
  if value <= 0 or curHasValue == false then
    return ARC_BG_COLOR
  end

  local cells = 1
  if themeCommon and type(themeCommon.estimateCellCount) == "function" then
    cells = math.max(1, themeCommon.estimateCellCount(state))
  elseif utils then
    local maxValue = utils.toNumber(utils.resolveValue(box.max, box, state), 25.2)
    if type(maxValue) == "number" and maxValue > 0 then
      cells = math.max(1, math.floor((maxValue / 4.2) + 0.5))
    end
  end

  local cellValue = value / cells
  local alertCell = tonumber(box and box.alertcell) or 3.50
  local warnCell = tonumber(box and box.warncell) or 3.70

  if alertCell > warnCell then
    local tmp = alertCell
    alertCell = warnCell
    warnCell = tmp
  end

  if cellValue <= alertCell then return ARC_ALERT_COLOR end
  if cellValue <= warnCell then return ARC_WARN_COLOR end
  return ARC_OK_COLOR
end

local function getMaxValue(source, state, box, utils)
  if source == "throttle_percent" then
    return state.currentFlightMaxThrottlePercent or state.lastFlightMaxThrottlePercent
  elseif source == "rpm" then
    return state.currentFlightMaxRpm or state.lastFlightMaxRpm
  elseif source == "temp_esc" or source == "esc_temp" then
    return state.currentFlightMaxEscTemp or state.lastFlightMaxEscTemp
  elseif source == "temp_mcu" or source == "mcu_temp" then
    return state.currentFlightMaxMcuTemp or state.lastFlightMaxMcuTemp
  elseif source == "current" then
    return state.currentFlightMaxCurrent or state.lastFlightMaxCurrent
  elseif source == "watts" then
    return state.currentFlightMaxWatts or state.lastFlightMaxWatts
  end
  return nil
end

local function resolveGaugeBounds(box, state, utils, defaultMin, defaultMax, isTemp)
  local fallbackMin = utils.toNumber(
    state and state.themeConfig and state.themeConfig.v_min,
    utils.toNumber(defaultMin, 0)
  )
  local fallbackMax = utils.toNumber(
    state and state.themeConfig and state.themeConfig.v_max,
    utils.toNumber(defaultMax, 100)
  )

  local minValue, maxValue
  if type(box.min) == "number" and type(box.max) == "number" then
    box._gaugeMin = box._gaugeMin or box.min
    box._gaugeMax = box._gaugeMax or box.max
    minValue = utils.toNumber(box._gaugeMin, fallbackMin)
    maxValue = utils.toNumber(box._gaugeMax, fallbackMax)
  else
    minValue = utils.toNumber(utils.resolveValue(box.min, box, state), fallbackMin)
    maxValue = utils.toNumber(utils.resolveValue(box.max, box, state), fallbackMax)
  end

  if isTemp and useFahrenheit() then
    minValue = cToF(minValue)
    maxValue = cToF(maxValue)
  end

  return minValue, maxValue
end

local function renderBar(nodes, rect, box, state, themeCommon, utils)
  local source = utils.resolveValue(box.source, box, state)
  local isTemp = isTempSource(source)
  local fahrenheit = isTemp and useFahrenheit()
  local rawValue = readDerived(state, source)
  local hasValue = type(rawValue) == "number"
  local gaugeValue = utils.toNumber(rawValue, 0)
  if fahrenheit and hasValue then
    gaugeValue = cToF(gaugeValue)
  end

  local gaugeMin, gaugeMax = resolveGaugeBounds(box, state, utils, isTemp and 20 or 0, isTemp and 140 or 100, isTemp)
  
  if gaugeMax <= gaugeMin then gaugeMax = 100 end
  
  local ratio = 0
  if gaugeMax > gaugeMin then
    ratio = utils.clamp((gaugeValue - gaugeMin) / (gaugeMax - gaugeMin), 0, 1)
  end
  
  local gaugeOrientation = utils.resolveValue(box.gaugeorientation, box, state) or "horizontal"
  
  -- VERTICAL GAUGE
  if gaugeOrientation == "vertical" then
    local gaugePaddingTop = utils.toNumber(utils.resolveValue(box.gaugepaddingtop, box, state), 2)
    local gaugePaddingBottom = utils.toNumber(utils.resolveValue(box.gaugepaddingbottom, box, state), 0)
    local gaugePaddingLeft = utils.toNumber(utils.resolveValue(box.gaugepaddingleft, box, state), 4)
    local gaugePaddingRight = utils.toNumber(utils.resolveValue(box.gaugepaddingright, box, state), 4)
    local titleReserved = (box and box.titlepos == "bottom") and 20 or 0
    local panelH = math.max(24, rect.h - titleReserved - gaugePaddingTop - gaugePaddingBottom - 2)
    local barWidth = math.max(10, math.floor(rect.w - gaugePaddingLeft - gaugePaddingRight))
    local barX = rect.x + gaugePaddingLeft
    local panelY = rect.y + gaugePaddingTop
    local barY = panelY
    local barH = panelH
    
    local thresholds = box.thresholds or {}
    local barColor = box.fillcolor or BAR_OK_COLOR
    if hasValue then
      barColor = resolveThresholdColor(gaugeValue, thresholds, barColor, fahrenheit, box)
    end
    
    -- Background bar (vertical)
    nodes[#nodes + 1] = {
      type = "rectangle",
      x = barX,
      y = barY,
      w = barWidth,
      h = barH,
      color = box.fillbgcolor or BAR_BG_COLOR,
      filled = true
    }
    
    -- Filled bar (from bottom, grows upward)
    if ratio > 0 then
      nodes[#nodes + 1] = {
        type = "rectangle",
        x = barX,
        y = barY + (barH - math.max(1, math.floor(barH * ratio))),
        w = barWidth,
        h = math.max(1, math.floor(barH * ratio)),
        color = barColor,
        filled = true
      }
    end

    -- Optional segmented battery look for vertical bars.
    if box.battery then
      local segmentCount = utils.toNumber(utils.resolveValue(box.batterysegments, box, state), 5)
      segmentCount = utils.clamp(math.floor(segmentCount + 0.5), 2, 10)
      local separatorColor = box.bgcolor or BLACK
      for i = 1, segmentCount - 1 do
        local sepY = barY + math.floor((barH * i) / segmentCount)
        nodes[#nodes + 1] = {
          type = "rectangle",
          x = barX,
          y = sepY,
          w = barWidth,
          h = 1,
          color = separatorColor,
          filled = true
        }
      end
    end
    
    local unit = utils.resolveValue(box.unit, box, state)
    if fahrenheit then
      unit = "°F"
    elseif isTemp and (unit == nil or unit == "") then
      unit = "°C"
    end
    local decimals = utils.resolveValue(box.decimals, box, state)

    local lastBarVal = nil
    local cachedBarText = nil
    local valueTextGetter = function()
      local curRaw = readDerived(state, source)
      if curRaw == lastBarVal and cachedBarText ~= nil then
        return cachedBarText
      end
      lastBarVal = curRaw
      local curHasValue = type(curRaw) == "number"
      local curVal = utils.toNumber(curRaw, 0)
      if not curHasValue then
        if unit ~= nil and unit ~= "" then
          cachedBarText = "-- " .. tostring(unit)
        else
          cachedBarText = "--"
        end
      else
        cachedBarText = utils.appendUnit(utils.formatDisplayValue(curVal, decimals), unit)
      end
      return cachedBarText
    end
    
    local textFontRef = nil
    if type(box.valuefont) ~= "function" and type(box.font) ~= "function" then
      textFontRef = box.valuefont or box.font or DBLSIZE
    end
    if textFontRef == nil then
      textFontRef = function()
        return utils.resolveValue(box.valuefont, box, state) or utils.resolveValue(box.font, box, state) or DBLSIZE
      end
    end
    local valuePaddingTop = utils.toNumber(utils.resolveValue(box.valuepaddingtop, box, state), 0)
    local valuePosition = utils.resolveValue(box.valueposition, box, state) or "inside"
    local valueAlign = utils.resolveValue(box.valuealign, box, state) or CENTER
    local valueY = barY + math.floor((barH - 12) / 2) + valuePaddingTop

    if valuePosition == "top" then
      valueY = barY + valuePaddingTop
    elseif valuePosition == "bottom" then
      valueY = barY + barH - 12 + valuePaddingTop
    end
    
    local colorRef = utils.staticTextColor(box, state, WHITE)
    if colorRef == nil then
      colorRef = function()
        return utils.resolveTextColor(box, state, WHITE)
      end
    end

    utils.pushLabel(
      nodes,
      barX,
      valueY,
      barWidth,
      valueTextGetter,
      colorRef,
      valueAlign,
      textFontRef
    )
  
  -- HORIZONTAL GAUGE (default)
  else
    local titleReserved = (box and box.titlepos == "top") and 18 or 0
    local panelY = rect.y + titleReserved + 2
    local panelH = math.max(20, rect.h - titleReserved - 4)
    local barHeight = math.max(12, math.floor(panelH * 0.5))
    local barX = rect.x + 4
    local barW = rect.w - 8
    local barY = panelY + math.floor((panelH - barHeight) / 2)
    
    local thresholds = box.thresholds or {}
    local barColor = box.fillcolor or BAR_OK_COLOR
    if hasValue then
      barColor = resolveThresholdColor(gaugeValue, thresholds, barColor, fahrenheit, box)
    end
    
    -- Background bar
    nodes[#nodes + 1] = {
      type = "rectangle",
      x = barX,
      y = barY,
      w = barW,
      h = barHeight,
      color = box.fillbgcolor or BAR_BG_COLOR,
      filled = true
    }
    
    -- Filled bar
    if ratio > 0 then
      nodes[#nodes + 1] = {
        type = "rectangle",
        x = barX,
        y = barY,
        w = math.max(1, math.floor(barW * ratio)),
        h = barHeight,
        color = barColor,
        filled = true
      }
    end
    
    local unit = utils.resolveValue(box.unit, box, state)
    if fahrenheit then
      unit = "°F"
    elseif isTemp and (unit == nil or unit == "") then
      unit = "°C"
    end
    local decimals = utils.resolveValue(box.decimals, box, state)

    local lastBarVal = nil
    local cachedBarText = nil
    local valueTextGetter = function()
      local curRaw = readDerived(state, source)
      if curRaw == lastBarVal and cachedBarText ~= nil then
        return cachedBarText
      end
      lastBarVal = curRaw
      local curHasValue = type(curRaw) == "number"
      local curVal = utils.toNumber(curRaw, 0)
      if not curHasValue then
        if unit ~= nil and unit ~= "" then
          cachedBarText = "-- " .. tostring(unit)
        else
          cachedBarText = "--"
        end
      else
        cachedBarText = utils.appendUnit(utils.formatDisplayValue(curVal, decimals), unit)
      end
      return cachedBarText
    end
    
    local textFontRef = nil
    if type(box.valuefont) ~= "function" and type(box.font) ~= "function" then
      textFontRef = box.valuefont or box.font or DBLSIZE
    end
    if textFontRef == nil then
      textFontRef = function()
        return utils.resolveValue(box.valuefont, box, state) or utils.resolveValue(box.font, box, state) or DBLSIZE
      end
    end
    local valuePaddingLeft = utils.toNumber(utils.resolveValue(box.valuepaddingleft, box, state), 8)
    local valuePaddingTop = utils.toNumber(utils.resolveValue(box.valuepaddingtop, box, state), 0)
    local valueAlign = utils.resolveValue(box.valuealign, box, state) or LEFT
    
    local colorRef = utils.staticTextColor(box, state, WHITE)
    if colorRef == nil then
      colorRef = function()
        return utils.resolveTextColor(box, state, WHITE)
      end
    end

    utils.pushLabel(
      nodes,
      barX + valuePaddingLeft,
      barY + math.floor((barHeight - 8) / 2) + valuePaddingTop,
      barW - valuePaddingLeft - 4,
      valueTextGetter,
      colorRef,
      valueAlign,
      textFontRef
    )
  
    -- Battery advanced info (like capacity) - only for horizontal
    if box.battadv then
      local lastBattAdvVoltage = nil
      local lastBattAdvCells = nil
      local lastBattAdvMah = nil
      local cachedBattAdvText = nil
      local battAdvTextGetter = function()
        local curVoltage = state and state.voltage
        local curCells = state and state.batteryCellCount
        local curMah = state and state.consumedMah
        if curVoltage == lastBattAdvVoltage and curCells == lastBattAdvCells and curMah == lastBattAdvMah and cachedBattAdvText ~= nil then
          return cachedBattAdvText
        end
        lastBattAdvVoltage = curVoltage
        lastBattAdvCells = curCells
        lastBattAdvMah = curMah

        local battAdvText = ""
        if source == "smartfuel" or source == "fuel" then
          local voltageText = nil
          if themeCommon and type(themeCommon.formatVoltage) == "function" and type(curVoltage) == "number" and curVoltage > 0 then
            local cellText = nil
            local cells = nil
            if type(curCells) == "number" and curCells > 0 then
              cells = curCells
            elseif type(themeCommon.estimateCellCount) == "function" then
              local ok, c = pcall(themeCommon.estimateCellCount, state)
              if ok and c ~= nil then cells = c end
            end

            if type(cells) == "number" and cells > 0 then
              cellText = string.format("%.2fV (%dS)", curVoltage / cells, cells)
            elseif type(themeCommon.formatCellVoltage) == "function" then
              local ok, cv = pcall(themeCommon.formatCellVoltage, state, curVoltage)
              if ok and cv ~= nil then cellText = cv end
            end

            local okFmt, fmtV = pcall(themeCommon.formatVoltage, curVoltage)
            local baseV = (okFmt and fmtV) or string.format("%.1fV", curVoltage)
            if cellText and cellText ~= "" then
              voltageText = baseV .. " / " .. cellText
            else
              voltageText = baseV
            end
          end

          local consumptionText = nil
          local consumedMah = tonumber(curMah)
          if consumedMah and consumedMah >= 0 then
            consumptionText = string.format("%d mah", math.floor(consumedMah + 0.5))
          end

          local singleLineDetails = utils.resolveValue(box.battadvsingleline, box, state)

          if voltageText and consumptionText then
            if singleLineDetails then
              battAdvText = voltageText .. " " .. consumptionText
            else
              battAdvText = voltageText .. "\n" .. consumptionText
            end
          else
            battAdvText = voltageText or consumptionText or ""
          end
        end
        cachedBattAdvText = battAdvText
        return cachedBattAdvText
      end
      
      local battAdvFontRef = nil
      if type(box.battadvfont) ~= "function" then
        battAdvFontRef = box.battadvfont or 0
      end
      if battAdvFontRef == nil then
        battAdvFontRef = function()
          return utils.resolveValue(box.battadvfont, box, state) or 0
        end
      end
      local battAdvPaddingTop = utils.toNumber(utils.resolveValue(box.battadvpaddingtop, box, state), math.floor((barHeight - 8) / 2))
      local battAdvPaddingRight = utils.toNumber(utils.resolveValue(box.battadvpaddingright, box, state), 6)
      local battAdvAlign = utils.resolveValue(box.battadvvaluealign, box, state) or RIGHT
      
      utils.pushLabel(
        nodes,
        rect.x + 4,
        barY + battAdvPaddingTop,
        barW - battAdvPaddingRight - 4,
        battAdvTextGetter,
        box.battadvtextcolor or WHITE,
        battAdvAlign,
        battAdvFontRef
      )
    end
  end
end

local function renderArc(nodes, rect, box, state, themeCommon, utils)
  local source = utils.resolveValue(box.source, box, state)
  local unit = utils.resolveValue(box.unit, box, state)
  local isTemp = isTempSource(source) or unit == "°C" or unit == "°F"
  local fahrenheit = isTemp and useFahrenheit()

  local defaultMin = isTemp and 20 or 18.0
  local defaultMax = isTemp and 140 or 25.2
  local gaugeMin, gaugeMax = resolveGaugeBounds(box, state, utils, defaultMin, defaultMax, isTemp)

  -- Schutz gegen extreme Werte
  if gaugeMin == gaugeMax or gaugeMax - gaugeMin < 0.1 then return end

  local titleReserved = (box and box.titlepos == "bottom") and 22 or 0
  local panelY = rect.y + 4
  local panelH = math.max(40, rect.h - 8 - titleReserved)
  local cx = rect.x + math.floor(rect.w / 2)
  local cy = panelY + math.floor(panelH * 0.52)
  local radius = math.max(18, math.floor(math.min(rect.w - 14, panelH - 10) / 2))
  local thickness = math.max(5, math.floor(radius * 0.18))
  local startAngle = utils.toNumber(utils.resolveValue(box.arcstart, box, state), 135)
  local endAngle = utils.toNumber(utils.resolveValue(box.arcend, box, state), 405)
  
  if endAngle <= startAngle then endAngle = startAngle + 250 end
  local sweep = endAngle - startAngle

  local arcBgColor = box.fillbgcolor or ARC_BG_COLOR

  -- Background arc
  nodes[#nodes + 1] = {
    type = "arc",
    x = cx,
    y = cy,
    radius = radius,
    thickness = thickness,
    startAngle = startAngle,
    endAngle = endAngle,
    rounded = true,
    color = arcBgColor
  }

  -- Dynamic Value Arc with reactive endAngle and color getters
  local lastRawAngle = nil
  local cachedEndAngle = nil
  local valueEndAngleGetter = function()
    local curRaw = readDerived(state, source)
    if curRaw == lastRawAngle and cachedEndAngle ~= nil then
      return cachedEndAngle
    end
    lastRawAngle = curRaw
    local curVal = utils.toNumber(curRaw, 0)
    if fahrenheit and type(curRaw) == "number" then
      curVal = cToF(curVal)
    end
    local curRatio = 0
    if gaugeMax > gaugeMin then
      curRatio = utils.clamp((curVal - gaugeMin) / (gaugeMax - gaugeMin), 0, 1)
    end
    cachedEndAngle = startAngle + math.floor(sweep * curRatio + 0.5)
    return cachedEndAngle
  end

  local lastRawArcColor = nil
  local cachedArcColor = nil
  local valueArcColorGetter = function()
    local curRaw = readDerived(state, source)
    if curRaw == lastRawArcColor and cachedArcColor ~= nil then
      return cachedArcColor
    end
    lastRawArcColor = curRaw
    local curHasValue = type(curRaw) == "number"
    local curVal = utils.toNumber(curRaw, 0)
    if fahrenheit and curHasValue then
      curVal = cToF(curVal)
    end
    local arcValueColor = box.fillcolor
    if not arcValueColor then
      if type(box.thresholds) == "table" and #box.thresholds > 0 and curHasValue then
        arcValueColor = resolveThresholdColor(curVal, box.thresholds, ARC_OK_COLOR, fahrenheit, box)
      else
        arcValueColor = getArcValueColor(curVal, state, box, themeCommon, utils, isTemp, fahrenheit, curHasValue, gaugeMax, unit)
      end
    end
    cachedArcColor = arcValueColor or ARC_OK_COLOR
    return cachedArcColor
  end

  nodes[#nodes + 1] = {
    type = "arc",
    x = cx,
    y = cy,
    radius = radius,
    thickness = thickness,
    startAngle = startAngle,
    endAngle = valueEndAngleGetter,
    rounded = true,
    color = valueArcColorGetter
  }

  local valueYOffset = utils.toNumber(utils.resolveValue(box.value_offset_y, box, state), 0)
  local displayH = tonumber(state and state.zoneH) or tonumber(LCD_H) or 0
  local defaultCenterLift = (displayH >= 400) and 8 or 0
  local valueCenterLift = utils.toNumber(utils.resolveValue(box.value_center_lift, box, state), defaultCenterLift)
  local valueY = cy - math.floor(thickness * 1.3) - valueCenterLift + valueYOffset
  if valueY < rect.y + 10 then valueY = rect.y + 10 end

  if fahrenheit then
    unit = "°F"
  elseif isTemp and (unit == nil or unit == "") then
    unit = "°C"
  end
  local decimals = utils.resolveValue(box.decimals, box, state)

  local lastRawText = nil
  local cachedValueText = nil
  local valueTextGetter = function()
    local curRaw = readDerived(state, source)
    if curRaw == lastRawText and cachedValueText ~= nil then
      return cachedValueText
    end
    lastRawText = curRaw
    local curHasValue = type(curRaw) == "number"
    local curVal = utils.toNumber(curRaw, 0)
    if fahrenheit and curHasValue then
      curVal = cToF(curVal)
    end
    local valueText = nil
    if source == "voltage" and themeCommon and type(themeCommon.formatVoltage) == "function" then
      local ok, res = pcall(themeCommon.formatVoltage, curVal)
      if ok and res ~= nil then valueText = res end
    end
    if valueText == nil then
      if not curHasValue then
        if unit ~= nil and unit ~= "" then
          valueText = "-- " .. tostring(unit)
        else
          valueText = "--"
        end
      else
        valueText = utils.appendUnit(utils.formatDisplayValue(curVal, decimals), unit)
      end
    end
    cachedValueText = valueText or "--"
    return cachedValueText
  end


  -- Only a percentage arc colours its own reading by the value. On every other unit this getter
  -- reduces to resolveTextColor, and reads the telemetry source once per pass to answer with the
  -- number the box already carries.
  local valueColorRef = nil
  if unit ~= "%" then
    valueColorRef = utils.staticTextColor(box, state, WHITE)
  end
  if valueColorRef == nil then
    local lastRawValColor = nil
    local cachedValColor = nil
    valueColorRef = function()
      local curRaw = readDerived(state, source)
      if curRaw == lastRawValColor and cachedValColor ~= nil then
        return cachedValColor
      end
      lastRawValColor = curRaw
      local curHasValue = type(curRaw) == "number"
      local curVal = utils.toNumber(curRaw, 0)
      if fahrenheit and curHasValue then
        curVal = cToF(curVal)
      end
      local valueColor = utils.resolveTextColor(box, state, WHITE)
      if unit == "%" and curHasValue then
        valueColor = getArcValueColor(curVal, state, box, themeCommon, utils)
      end
      cachedValColor = valueColor
      return cachedValColor
    end
  end

  local fontRef = utils.staticFont(box, state, DBLSIZE, "value_font", "value_font_lowres")
  if fontRef == nil then
    fontRef = function()
      return utils.resolveFont(box, state, DBLSIZE, "value_font", "value_font_lowres")
    end
  end

  utils.pushLabel(
    nodes,
    rect.x + 4,
    valueY,
    rect.w - 8,
    valueTextGetter,
    valueColorRef,
    box.valuealign or box.titlealign or CENTER,
    fontRef
  )
  
  -- MAX value display
  if box.arcmax then
    local maxPrefix = utils.resolveValue(box.maxprefix, box, state) or "Max: "
    local maxDecimals = utils.resolveValue(box.maxdecimals, box, state)
    local maxUnit = utils.resolveValue(box.maxunit, box, state) or unit or ""
    local maxFont = utils.resolveValue(box.maxfont, box, state) or 0
    local maxTextColor = utils.resolveValue(box.maxtextcolor, box, state) or "orange"
    local maxPosition = utils.resolveValue(box.maxposition, box, state)
    local maxAlign = utils.resolveValue(box.maxalign, box, state) or LEFT
    local maxPaddingTop = utils.toNumber(utils.resolveValue(box.maxpaddingtop, box, state), 30)
    local maxPaddingLeft = utils.toNumber(utils.resolveValue(box.maxpaddingleft, box, state), 20)
    local maxPaddingRight = utils.toNumber(utils.resolveValue(box.maxpaddingright, box, state), 4)
    local maxPaddingBottom = utils.toNumber(utils.resolveValue(box.maxpaddingbottom, box, state), 26)

    local maxX = rect.x + maxPaddingLeft
    local maxY = rect.y + maxPaddingTop
    local maxW = rect.w - maxPaddingLeft - maxPaddingRight

    if maxPosition == "bottom" then
      maxAlign = utils.resolveValue(box.maxalign, box, state) or CENTER
      maxY = rect.y + rect.h - titleReserved - maxPaddingBottom
      if maxY < rect.y + 6 then
        maxY = rect.y + 6
      end
    end
    
    local lastRawMax = nil
    local cachedMaxText = nil
    local maxTextGetter = function()
      local maxValue = getMaxValue(source, state, box, utils)
      if maxValue == lastRawMax and cachedMaxText ~= nil then
        return cachedMaxText
      end
      lastRawMax = maxValue
      if maxValue and type(maxValue) == "number" and maxValue > 0 then
        if fahrenheit then
          maxValue = cToF(maxValue)
        end
        cachedMaxText = maxPrefix .. utils.formatDisplayValue(maxValue, maxDecimals) .. maxUnit
        return cachedMaxText
      end
      cachedMaxText = ""
      return cachedMaxText
    end

    utils.pushLabel(
      nodes,
      maxX,
      maxY,
      maxW,
      maxTextGetter,
      maxTextColor,
      maxAlign,
      maxFont
    )
  end
end

function Wrapper.render(nodes, rect, box, state)
  local utils = getUtils()
  local themeCommon = getThemeCommon()
  if not utils then return end

  utils.drawContainer(nodes, rect, box, state)
  
  local subtype = utils.resolveValue(box.subtype, box, state) or "arc"
  
  if subtype == "bar" then
    renderBar(nodes, rect, box or {}, state, themeCommon, utils)
  else
    renderArc(nodes, rect, box or {}, state, themeCommon, utils)
  end
end

return Wrapper
