local Render = {}

-- A value no box source or stattype can be equal to, so that "not resolved yet" needs no flag.
local UNRESOLVED = {}

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

-- The two sources below name one statistic each, so their record key is resolved on first use
-- and kept for the module: a value closure that ran Utils.statFields per frame would pay the
-- lookup on every frame of every postflight page.
local minLinkKey
local minVoltageKey

local function useFahrenheit()
  local prefs = type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences or nil
  local localizations = prefs and prefs.localizations or nil
  return tonumber(localizations and localizations.temperature_unit) == 1
end

function Render.render(nodes, rect, box, state, themeCommon, utils)
  local function formatWithUnit(value, src)
    local adjustedValue = value
    local unit = utils.resolveValue(box.unit, box, state)

    if src == "esc_temp" or src == "mcu_temp" or src == "temp_esc" or src == "temp_mcu" then
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

  -- The record key the box's (source, stattype) pair resolves to. A theme may give either as a
  -- function, so the pair is still read per frame, but the mapping is only consulted again when
  -- one of the two has actually changed. UNRESOLVED is a value no source can equal, so the
  -- first frame resolves without a second flag to test.
  local statSource, statStattype = UNRESOLVED, UNRESOLVED
  local statKey

  local textGetter = function()
    -- resolveValue is the identity for anything that is not a function, and this getter runs per
    -- frame in the reactive sweep: the test is inlined so that the common case -- a theme naming
    -- its source outright -- costs a type check instead of a call. A theme that computes its
    -- source still goes through resolveValue, and the field is re-read every frame, so a box
    -- whose source is replaced between frames behaves exactly as before.
    local source = box.source
    if type(source) == "function" then
      source = utils.resolveValue(source, box, state)
    end
    local raw = nil

    if source == "min_link" then
      if minLinkKey == nil then minLinkKey = utils.statFields("link", "min") end
      local val = utils.statFromRecord(state.flight, minLinkKey)
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
      if minVoltageKey == nil then minVoltageKey = utils.statFields("voltage", "min") end
      local val = utils.statFromRecord(state.flight, minVoltageKey)
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
      local stattype = box.stattype
      if type(stattype) == "function" then
        stattype = utils.resolveValue(stattype, box, state)
      end

      if source ~= statSource or stattype ~= statStattype then
        statSource, statStattype = source, stattype
        statKey = nil
        -- A box with no stattype -- which is most of them -- cannot name an extreme, so it never
        -- reaches the mapping at all, not even on the one frame that resolves.
        if stattype ~= nil and stattype ~= "" then
          statKey = utils.statFields(source, stattype)
        end
      end

      -- A recorded extreme is a read of the record with a key already resolved. What is left
      -- below is the stattypes that are not an extreme: a running total, a per-cell derivation,
      -- a live value off the derived snapshot.
      local statValue = nil
      if statKey ~= nil then
        statValue = utils.statFromRecord(state.flight, statKey)
      elseif stattype == "max" and source == "smartconsumption" then
        statValue = state and state.consumedMah
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
      elseif stattype == "count" or stattype == "time" then
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

  -- Compiled once, here where the box is rendered, rather than on every value change in the
  -- reactive sweep -- the argument for why that is the same answer is on Utils.renderThresholds.
  local renderSource = box and box.source
  local renderIsTemp = (renderSource == "esc_temp" or renderSource == "mcu_temp" or
                        renderSource == "temp_esc" or renderSource == "temp_mcu")
  local compiledThresholds = utils.renderThresholds(box, state, renderIsTemp and useFahrenheit(), WHITE)

  local colorRef = utils.staticTextColor(box, state, WHITE)
  if colorRef == nil then
    local lastColorInput = nil
    local cachedColor = nil
    colorRef = function()
      local source = box and box.source
      local stattype = box and box.stattype
      local statValue = nil
      if type(source) == "string" and type(stattype) == "string" and stattype ~= "" then
        statValue = utils.statValue(state, source, stattype)
      end
      local allowsLiveFallback = (themeCommon and themeCommon.allowStatsLiveFallback and themeCommon.allowStatsLiveFallback(source, stattype)) or
                                 stattype == nil or stattype == ""
      if statValue == nil and allowsLiveFallback and type(source) == "string" then
        statValue = readDerived(state, source)
      end
      local isTemp = (source == "esc_temp" or source == "mcu_temp" or source == "temp_esc" or source == "temp_mcu")
      local isFahr = isTemp and useFahrenheit()
      if isTemp and isFahr and type(statValue) == "number" then
        statValue = (statValue * 9 / 5) + 32
      end
      if statValue == lastColorInput and cachedColor ~= nil then
        return cachedColor
      end
      lastColorInput = statValue
      cachedColor = utils.resolveTextColor(box, state, WHITE, statValue, isFahr, compiledThresholds)
      return cachedColor
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
