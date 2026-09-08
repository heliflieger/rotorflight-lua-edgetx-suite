local Render = {}

-- Sensor-backed values come out of the derived snapshot, never from a probe: this runs
-- per frame in the reactive sweep, where a probe is forbidden (see GEMINI.md, "Dashboard
-- reactive closures").
local function readDerived(state, source)
  local derived = type(state) == "table" and state.derived or nil
  if derived == nil or source == nil then return nil end
  return derived[source]
end

local function resolveCellCount(state, themeCommon)
  local stateCells = tonumber(state and state.batteryCellCount)
  if stateCells and stateCells > 0 then
    return math.max(1, math.floor(stateCells + 0.5))
  end

  if themeCommon and type(themeCommon.estimateCellCount) == "function" then
    local estimated = tonumber(themeCommon.estimateCellCount(state))
    if estimated and estimated > 0 then
      return math.max(1, math.floor(estimated + 0.5))
    end
  end

  local cfg = state and state.themeConfig or nil
  local vMax = tonumber(cfg and cfg.v_max)
  if vMax and vMax > 0 then
    return math.max(1, math.floor((vMax / 4.2) + 0.5))
  end

  return 6
end

local function useFahrenheit()
  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local localizations = prefs and prefs.localizations or nil
  return tonumber(localizations and localizations.temperature_unit) == 1
end

function Render.render(nodes, rect, box, state, themeCommon, utils)
  local function formatWithUnit(value, src)
    local adjustedValue = value
    local unit = utils.resolveValue(box.unit, box, state)

    if src == "esc_temp" or src == "mcu_temp" then
      if useFahrenheit() and type(adjustedValue) == "number" then
        adjustedValue = (adjustedValue * 9 / 5) + 32
        unit = "°F"
      else
        unit = "°C"
      end
    end

    local transformed = utils.applyTransform(adjustedValue, utils.resolveValue(box.transform, box, state))
    local decimals = utils.resolveValue(box.decimals, box, state)
    return utils.appendUnit(utils.formatDisplayValue(transformed, decimals), unit)
  end

  local lastSource = nil
  local lastStattype = nil
  local lastStatInput = nil
  local cachedText = nil

  local textGetter = function()
    local source = utils.resolveValue(box.source, box, state)
    local raw = nil

    if source == "min_link" then
      local val = state and (state.currentFlightMinLq or state.lastMinLq)
      if source == lastSource and val == lastStatInput and cachedText ~= nil then
        return cachedText
      end
      lastSource = source
      lastStatInput = val
      if themeCommon and type(themeCommon.formatInteger) == "function" then
        local ok, res = pcall(themeCommon.formatInteger, val, "%")
        if ok and res ~= nil then raw = res end
      end
      if raw == nil then
        raw = (val ~= nil) and (tostring(math.floor(tonumber(val) or 0)) .. "%") or "--"
      end
    elseif source == "min_voltage_cell" then
      local val = state and (state.currentFlightMinVoltage or state.lastMinVoltage)
      if source == lastSource and val == lastStatInput and cachedText ~= nil then
        return cachedText
      end
      lastSource = source
      lastStatInput = val
      if themeCommon and type(themeCommon.formatCellVoltage) == "function" then
        local ok, res = pcall(themeCommon.formatCellVoltage, state, val)
        if ok and res ~= nil then raw = res end
      end
      if raw == nil then
        local num = tonumber(val)
        if num and num > 0 then
          raw = string.format("%.2fV/c", num / resolveCellCount(state, themeCommon))
        else
          raw = "--.-V/c"
        end
      end
    else
      local stattype = utils.resolveValue(box.stattype, box, state)

      local statValue = nil
      if stattype == "max" then
        if source == "throttle_percent" then
          statValue = state and (state.currentFlightMaxThrottlePercent or state.lastFlightMaxThrottlePercent)
        elseif source == "rpm" then
          statValue = state and (state.currentFlightMaxRpm or state.lastFlightMaxRpm)
        elseif source == "current" then
          statValue = state and (state.currentFlightMaxCurrent or state.lastFlightMaxCurrent)
        elseif source == "mcu_temp" then
          statValue = state and (state.currentFlightMaxMcuTemp or state.lastFlightMaxMcuTemp)
        elseif source == "watts" then
          statValue = state and (state.currentFlightMaxWatts or state.lastFlightMaxWatts)
        elseif source == "altitude" then
          statValue = state and (state.currentFlightMaxAltitude or state.lastFlightMaxAltitude)
        elseif source == "esc_temp" then
          statValue = state and (state.currentFlightMaxEscTemp or state.lastFlightMaxEscTemp)
        elseif source == "smartconsumption" then
          statValue = state and state.consumedMah
        elseif source == "voltage" then
          statValue = state and (state.currentFlightMaxVoltage or state.lastFlightMaxVoltage)
        elseif source == "link" then
          statValue = state and (state.currentFlightMaxLq or state.lastFlightMaxLq)
        end
      elseif stattype == "min" then
        if source == "fuel" or source == "smartfuel" then
          statValue = state and (state.currentFlightMinFuel or state.lastFlightMinFuel)
        elseif source == "rpm" then
          statValue = state and (state.currentFlightMinRpm or state.lastFlightMinRpm)
        elseif source == "current" then
          statValue = state and (state.currentFlightMinCurrent or state.lastFlightMinCurrent)
        elseif source == "voltage" then
          statValue = state and (state.currentFlightMinVoltage or state.lastMinVoltage)
        elseif source == "bec_voltage" then
          -- lastMinBecVoltage == lastFlightMinBecVoltage (same source in runtime.lua:1105-1106);
          -- the third term is unreachable but kept so user themes reading state directly do not break.
          statValue = state and (state.currentFlightMinBecVoltage or state.lastFlightMinBecVoltage or state.lastMinBecVoltage)
        elseif source == "link" then
          statValue = state and (state.currentFlightMinLq or state.lastMinLq)
        end
      elseif stattype == "last" then
        if source == "voltage" then
          statValue = state and state.lastFlightEndingVoltage
        end
      elseif stattype == "consumed" then
        if source == "current" then
          statValue = state and state.consumedMah
        end
      elseif stattype == "cell" then
        if source == "voltage" then
          local voltage = state and state.voltage
          local cellCount = resolveCellCount(state, themeCommon)
          if type(voltage) == "number" and cellCount > 0 then
            statValue = voltage / cellCount
          end
        end
      elseif stattype == "count" then
        statValue = readDerived(state, source)
      elseif stattype == "time" then
        statValue = readDerived(state, source)
      end

      -- Allow the derived-snapshot fallback for stattype-less tiles and for count/time,
      -- which already have a dedicated readDerived call above (harmless second read).
      -- For any other (stattype, source) pair that had no dedicated handler, render "--"
      -- so a missing handler is immediately visible instead of silently showing a live value.
      local allowsLiveFallback = stattype == "count" or stattype == "time" or
                                 stattype == nil or stattype == ""
      if statValue == nil and allowsLiveFallback and type(source) == "string" then
        statValue = readDerived(state, source)
      end

      if source == lastSource and stattype == lastStattype and statValue == lastStatInput and cachedText ~= nil then
        return cachedText
      end
      lastSource = source
      lastStattype = stattype
      lastStatInput = statValue

      if statValue ~= nil then
        raw = formatWithUnit(statValue, source)
      end
    end

    local valueText = raw and tostring(raw) or "--"
    valueText = utils.applyLowResMaxChars(valueText, box, state, "max_chars_lowres")
    cachedText = valueText or "--"
    return cachedText
  end

  local colorRef = utils.staticTextColor(box, state, WHITE)
  if colorRef == nil then
    colorRef = function()
      return utils.resolveTextColor(box, state, WHITE)
    end
  end

  local fontRef = utils.staticFont(box, state, MIDSIZE, "font", "font_lowres")
  if fontRef == nil then
    fontRef = function()
      return utils.resolveFont(box, state, MIDSIZE, "font", "font_lowres")
    end
  end

  utils.pushLabel(
    nodes,
    rect.x + 4,
    utils.defaultValueY(rect, box),
    rect.w - 8,
    textGetter,
    colorRef,
    box.valuealign or box.titlealign or CENTER,
    fontRef
  )
end

return Render
