local Render = {}

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
      local val = state and state.lastMinLq
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
      local val = state and state.lastMinVoltage
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
      local statSource = nil
      if type(source) == "string" and source ~= "" then
        if stattype == "max" then
          statSource = source .. "+"
        elseif stattype == "min" then
          statSource = source .. "-"
        end
      end

      local statValue = nil
      if stattype == "max" then
        if source == "throttle_percent" then
          statValue = state and (state.lastFlightMaxThrottlePercent or state.currentFlightMaxThrottlePercent or state.throttlePercent)
        elseif source == "rpm" then
          statValue = state and (state.lastFlightMaxRpm or state.currentFlightMaxRpm or state.rpm)
        elseif source == "current" then
          statValue = state and (state.lastFlightMaxCurrent or state.currentFlightMaxCurrent or state.current)
          if statValue == nil and statSource then
            statValue = utils.mapTelemetrySource(statSource, state)
          end
        elseif source == "mcu_temp" then
          statValue = state and (state.lastFlightMaxMcuTemp or state.currentFlightMaxMcuTemp or state.mcuTemp)
        elseif source == "watts" then
          statValue = state and (state.lastFlightMaxWatts or state.currentFlightMaxWatts or state.watts)
        elseif source == "altitude" then
          statValue = state and (state.lastFlightMaxAltitude or state.currentFlightMaxAltitude or state.altitude)
        elseif source == "esc_temp" then
          statValue = state and (state.lastFlightMaxEscTemp or state.currentFlightMaxEscTemp or state.escTemp)
        elseif source == "smartconsumption" then
          statValue = state and state.consumedMah
        end
      elseif stattype == "min" then
        if source == "fuel" or source == "smartfuel" then
          statValue = state and (state.lastFlightMinFuel or state.currentFlightMinFuel or state.fuel)
        elseif source == "rpm" then
          statValue = state and (state.lastFlightMinRpm or state.currentFlightMinRpm or state.rpm)
        elseif source == "current" then
          statValue = state and (state.lastFlightMinCurrent or state.currentFlightMinCurrent or state.current)
        elseif source == "voltage" then
          statValue = state and (state.lastMinVoltage or state.currentFlightMinVoltage or state.voltage)
        elseif source == "bec_voltage" then
          statValue = state and (state.lastMinVoltage or state.currentFlightMinVoltage or state.bec_voltage)
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
        statValue = utils.mapTelemetrySource(source, state)
      elseif stattype == "time" then
        statValue = utils.mapTelemetrySource(source, state)
      end

      if statValue == nil and statSource then
        statValue = utils.mapTelemetrySource(statSource, state)
      end
      if statValue == nil and type(source) == "string" then
        statValue = utils.mapTelemetrySource(source, state)
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

  local colorGetter = function()
    return utils.resolveTextColor(box, state, WHITE)
  end

  local fontGetter = function()
    return utils.resolveFont(box, state, MIDSIZE, "font", "font_lowres")
  end

  utils.pushLabel(
    nodes,
    rect.x + 4,
    utils.defaultValueY(rect, box),
    rect.w - 8,
    textGetter,
    colorGetter,
    box.valuealign or box.titlealign or CENTER,
    fontGetter
  )
end

return Render
