-- The battery detail view (init.lua registers it as `urban_battery`, in full screen only): the
-- main pack in detail, opened by a tap on the flight view's battery gauge.
--
-- Three parts, top to bottom:
--
--   * The cell voltage as a bar on a scale around the flight controller's own cell limits --
--     its minimum, warning and full cell voltage, each marked on the bar -- with the figure
--     beside it and the three limits written out under it. The fill turns at the same limits.
--   * The pack as a battery laid on its side, filling towards the terminal: the fuel figure in
--     the middle, the cell count and the used capacity in a pill at either end. Its steps and
--     colours are the flight view's gauge's (common.lua, M.fuelLevel), so the two cannot
--     disagree about how full the pack is.
--   * One line: the pack voltage, the least cell voltage of the flight, and the reserve the
--     fuel figure keeps back.
--
-- The cell limits and the reserve are the flight controller's, read on connect into the session
-- (tasks/events/common/battery_config.lua). They are read when the view is BUILT and are terms
-- of its render key, so the view rebuilds once when they arrive or change and no per-frame
-- closure reads the session. Before they are on file the scale has no marks, the limits read
-- `-` and the bar takes no colour of verdict.
--
-- The cell voltage is the pack voltage over the cell count, as the flight view's cell row
-- reads it: no telemetry carries the voltage of each cell. So the least cell voltage is the
-- least the pack reached over the cell count, from the flight record the statistics view reads.

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require(path)
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local K = requireModule("widgets/dashboard/themes/urban/viewkit.lua") or {}
local Reserve = requireModule("lib/smartfuel_reserve.lua")

local M = {}

-- What a memo holds before its first reading: no reading equals it.
local UNSET = {}

-- How far the scale reaches past the limits it marks, in volts per cell: a little below the
-- minimum, so a pack at its minimum still shows a fill, and a little above full.
local SCALE_BELOW = 0.15
local SCALE_ABOVE = 0.10
-- The scale where no limits are on file.
local SCALE_MIN = 3.0
local SCALE_MAX = 4.3

-- The pills behind the two small figures in the battery: black, partly see-through, so the
-- figure on them reads on every segment colour, the empty one included.
local PILL_OPACITY = 140

local function session()
  return type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
end

local function batteryConfig(s)
  return s and (s.batteryConfig or s.battery_config) or nil
end

-- A cell voltage from the battery configuration, in volts, or nil where none is on file. MSP
-- BATTERY_CONFIG carries centivolts; the runtime's own reader (runtime.lua, normalizeCellVoltage)
-- takes the other encodings a stored value may be in as well, and so does this one.
local function cellVolts(cfg, key)
  local v = tonumber(cfg and cfg[key])
  if v == nil or v <= 0 then return nil end
  if v >= 1000 then v = v / 1000
  elseif v >= 100 then v = v / 100
  elseif v > 10 then v = v / 10 end
  return v
end

-- The three limits, the reserve and the cell count, as this view draws them: a voltage to the
-- hundredth, the reserve as the fuel sensor resolves it (lib/smartfuel_reserve.lua). The reserve
-- only where a battery configuration is on file -- without one there is no flight controller
-- the figure would be the reserve of.
local function readLimits(state)
  local s = session()
  local cfg = batteryConfig(s)
  local crit = cellVolts(cfg, "vbatmincellvoltage")
  local low = cellVolts(cfg, "vbatwarningcellvoltage")
  local full = cellVolts(cfg, "vbatfullcellvoltage")
  -- One limit alone places nothing on a scale: all three, or none.
  if crit == nil or low == nil or full == nil or full <= crit then crit, low, full = nil, nil, nil end
  local reserve = nil
  if cfg ~= nil and Reserve ~= nil and type(Reserve.resolve) == "function" then
    reserve = Reserve.resolve(s, cfg)
  end
  return crit, low, full, reserve, K.UD.cells(state)
end

-- One number of a state table, nil for anything else.
local function stateNumber(state, name)
  return function()
    local v = state[name]
    if type(v) ~= "number" then return nil end
    return v
  end
end

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" then return children end
  state = state or {}
  local g = K.begin(zone, state)
  if g == nil then return children end
  local UD, C, T = K.UD, K.C, K.T

  local closePress = nil
  if type(ctx) == "table" and type(ctx.action) == "function" then
    closePress = function() ctx.action("closeView") end
  end
  local top = K.header(children, g, T.view_battery, closePress)

  local crit, low, full, reserve, cells = readLimits(state)
  local x, w = g.x + g.pad, g.w - 2 * g.pad
  local f = K.rowFonts(g)

  -- The cell voltage, read the way the flight view's cell row reads it, and nil while the main
  -- pack is gone: the figure is then no measurement of the pack at all.
  local function cellVoltage()
    if state.mainPowerLost == true then return nil end
    local v = state.voltage
    if type(v) ~= "number" or v <= 0 then return nil end
    return v / cells
  end

  -- -------------------------------------------------------------------------
  -- the cell voltage scale
  -- -------------------------------------------------------------------------
  local y = top
  UD.label(children, x, y, w, f.subH, T.cell_voltage, f.sub, C.label, LEFT)
  y = y + f.subH + g.textPad

  -- The figure as large as the title may be, the bar as tall as the row's own name.
  local valueFont = UD.selectFont(math.floor(g.fontH * 1.6), math.floor(w / 3), "4.20")
  local valueH = UD.measure(valueFont, "4.20")
  local valueW = UD.textWidth(valueFont, "88.88") + g.pad
  local barW = math.max(20, w - valueW - g.pad)
  local barH = math.max(12, g.fontH)
  local rowH = math.max(barH, valueH)
  local barX, barY = x, y + math.floor((rowH - barH) / 2)

  local sMin = crit and (crit - SCALE_BELOW) or SCALE_MIN
  local sMax = full and (full + SCALE_ABOVE) or SCALE_MAX
  local function scaleX(v)
    local p = (v - sMin) / (sMax - sMin)
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    return math.floor(barW * p)
  end

  UD.rect(children, barX, barY, barW, barH, C.track, true, 3)
  local lastSV, lastW = UNSET, 0
  local lastCV, lastColor = UNSET, nil
  children[#children + 1] = {
    type = "rectangle", x = barX, y = barY, w = 1, h = barH, filled = true, rounded = 3,
    color = function()
      local v = cellVoltage()
      if v == lastCV then return lastColor end
      lastCV = v
      if v == nil then lastColor = C.track
      elseif crit == nil then lastColor = C.neut
      elseif v <= crit then lastColor = C.crit
      elseif v <= low then lastColor = C.warn
      else lastColor = C.ok end
      return lastColor
    end,
    size = function()
      local v = cellVoltage()
      if v ~= lastSV then
        lastSV = v
        lastW = (v == nil) and 0 or math.max(1, scaleX(v))
      end
      return lastW, barH
    end
  }
  if crit ~= nil then
    UD.rect(children, barX + scaleX(crit), barY, 2, barH, C.tick, true, 0)
    UD.rect(children, barX + scaleX(low), barY, 2, barH, C.tick, true, 0)
    UD.rect(children, barX + scaleX(full), barY, 2, barH, C.tick, true, 0)
  end
  UD.rect(children, barX, barY, barW, barH, C.frame, false, 3, 1)
  UD.label(children, x + w - valueW, y + math.floor((rowH - valueH) / 2), valueW, valueH,
    UD.scaledGetter(cellVoltage, 2), valueFont, UD.packColor(state, C.text), RIGHT)
  y = y + rowH + g.textPad

  -- The limits written out, a build-time string: they change only through a rebuild.
  local function limit(v) return v and string.format("%.2f", v) or "-" end
  local legend = string.format("%s %s   %s %s   %s %s V", T.batt_crit, limit(crit),
    T.batt_low, limit(low), T.batt_full, limit(full))
  UD.label(children, x, y, w, f.subH, UD.fit(f.sub, legend, w), f.sub, C.label, LEFT)
  y = y + f.subH + g.gap

  -- -------------------------------------------------------------------------
  -- the foot line
  -- -------------------------------------------------------------------------
  local footY = g.y + g.h - g.pad - g.fontH
  local thirdW = math.floor(w / 3)
  UD.label(children, x, footY, thirdW, g.fontH,
    UD.getter(stateNumber(state, "voltage"), function(v)
      if v == nil or v <= 0 then return T.batt_pack .. " -" end
      return string.format("%s %.2f V", T.batt_pack, v)
    end), g.font, UD.packColor(state, C.text), LEFT)
  UD.label(children, x + thirdW, footY, w - 2 * thirdW, g.fontH,
    UD.getter(function()
      -- The flight in progress first, the flight that ended after it: the record's own rule.
      local flight = state.flight
      if type(flight) ~= "table" then return nil end
      local v = type(flight.current) == "table" and flight.current.minVoltage or nil
      if v == nil and type(flight.last) == "table" then v = flight.last.minVoltage end
      if type(v) ~= "number" or v <= 0 then return nil end
      return v / cells
    end, function(v)
      if v == nil then return T.batt_cell_min .. " -" end
      return string.format("%s %.2f V", T.batt_cell_min, v)
    end), g.font, C.text, CENTER)
  local reserveText = T.batt_reserve .. " " .. (reserve and string.format("%d %%", reserve) or "-")
  UD.label(children, x + w - thirdW, footY, thirdW, g.fontH, reserveText, g.font, C.text, RIGHT)

  -- -------------------------------------------------------------------------
  -- the battery, laid on its side
  -- -------------------------------------------------------------------------
  local bodyY = y
  local bodyH = footY - g.gap - bodyY
  if bodyH < 20 then return children end
  local capW = math.max(7, math.floor(g.w * 0.018))
  local capH = math.floor(bodyH * 0.36)
  local bodyX = x
  local bodyW = w - capW
  local bodyRounding = math.max(3, math.floor(bodyH * 0.10))
  local innerPad = math.max(3, math.floor(bodyH * 0.10))
  local innerX, innerY = bodyX + innerPad, bodyY + innerPad
  local innerW, innerH = bodyW - 2 * innerPad, bodyH - 2 * innerPad
  local segRounding = math.max(1, math.floor(innerH * 0.10))
  local segGap = math.max(1, math.floor(innerW * 0.01))
  -- The flight view's gauge's steps: at most ten, so one segment reads as ten percent.
  local segCount = math.max(6, math.min(10, math.floor(innerW / 16)))
  local segW = math.floor((innerW - (segCount - 1) * segGap) / segCount)
  local segLastW = innerW - segW * (segCount - 1) - segGap * (segCount - 1)

  UD.rect(children, bodyX + bodyW, bodyY + math.floor((bodyH - capH) / 2), capW, capH, C.frame, true, 2)
  UD.rect(children, bodyX, bodyY, bodyW, bodyH, C.frame, false, bodyRounding, 1)

  local level = UD.fuelLevel(state)
  local empty = C.empty
  for i = 1, segCount do
    local segX = innerX + (i - 1) * (segW + segGap)
    local thisW = (i == segCount) and segLastW or segW
    local threshold = (i / segCount) * 100
    local color = function()
      local p, fill = level()
      if p ~= nil and p >= threshold then return fill end
      return empty
    end
    local corner = (i == 1 or i == segCount) and segRounding or 0
    UD.rect(children, segX, innerY, thisW, innerH, color, true, corner)
    if corner > 0 then
      -- The end segments keep their outer corners and lose the inner pair, so the segments
      -- still tile into one bar.
      local flatW = math.max(1, math.min(segRounding, thisW))
      local flatX = (i == 1) and (segX + thisW - flatW) or segX
      UD.rect(children, flatX, innerY, flatW, innerH, color, true, 0)
    end
  end

  -- The two pills: the cell count at the left end, the used capacity at the right, each as wide
  -- as its text. The capacity's pill follows the figure's number of digits, every width
  -- measured here, so a frame picks one out of a table instead of measuring text.
  local pillFont = f.name
  local pillTextH = f.nameH
  local pillPadX = math.max(4, math.floor(pillTextH * 0.35))
  local pillPadY = math.max(2, math.floor(pillTextH * 0.16))
  local pillH = pillTextH + 2 * pillPadY
  local pillY = bodyY + math.floor((bodyH - pillH) / 2)
  local pillRound = math.floor(pillH / 2)
  local pillInk = WHITE
  local edge = innerX + math.max(4, math.floor(innerW * 0.02))
  local rightEdge = innerX + innerW - math.max(4, math.floor(innerW * 0.02))

  local cellsText = string.format("%dS", cells)
  local cellsW = UD.textWidth(pillFont, cellsText)
  children[#children + 1] = { type = "rectangle", x = edge, y = pillY, w = cellsW + 2 * pillPadX, h = pillH,
    filled = true, color = BLACK, opacity = PILL_OPACITY, rounded = pillRound }
  UD.label(children, edge + pillPadX, pillY + pillPadY, cellsW, pillTextH, cellsText, pillFont, pillInk, LEFT)

  local mahWidths = {}
  for digits = 1, 6 do
    mahWidths[digits] = UD.textWidth(pillFont, string.rep("8", digits) .. " " .. T.mah) + 2 * pillPadX
  end
  local mahLabelW = mahWidths[6]
  local function mahValue()
    local v = state.consumedMah
    if type(v) ~= "number" then return nil end
    return math.floor(v + 0.5)
  end
  local lastDigits, lastPillW = UNSET, 0
  local function pillWidth()
    local v = mahValue()
    local digits = (v == nil) and 1 or #tostring(math.abs(v))
    if digits ~= lastDigits then
      lastDigits = digits
      lastPillW = mahWidths[math.min(6, digits)]
    end
    return lastPillW
  end
  children[#children + 1] = { type = "rectangle", x = rightEdge - mahWidths[1], y = pillY, w = mahWidths[1], h = pillH,
    filled = true, color = BLACK, opacity = PILL_OPACITY, rounded = pillRound,
    pos = function() return rightEdge - pillWidth(), pillY end,
    size = function() return pillWidth(), pillH end }
  UD.label(children, rightEdge - pillPadX - mahLabelW, pillY + pillPadY, mahLabelW, pillTextH,
    UD.getter(mahValue, function(v)
      if v == nil then return "- " .. T.mah end
      return string.format("%d %s", v, T.mah)
    end), pillFont, pillInk, RIGHT)

  -- The fuel figure across the middle, the flight view's gauge's rule: with the main pack gone
  -- there is no reading, and the figure turns rather than holding the last one.
  local pctFont = UD.selectFont(math.floor(bodyH * 0.50), math.floor(innerW * 0.40), "100%")
  local pctH = UD.measure(pctFont, "100%")
  UD.label(children, bodyX, bodyY + math.floor((bodyH - pctH) / 2), bodyW, pctH,
    UD.getter(function()
      if state.mainPowerLost == true then return false end
      return UD.fuel(state)
    end, function(p)
      if p == nil or p == false then return "--%" end
      return string.format("%d%%", math.floor(p + 0.5))
    end), pctFont, UD.packColor(state, C.ink), CENTER)
  return children
end

-- The limits, the reserve and the cell count are drawn as built: a change of any of them builds
-- the view again. Kept as one string while none of them moves, so a pass that asks costs five
-- comparisons and no allocation.
local lastCrit, lastLow, lastFull, lastReserve, lastCells, lastKey = UNSET, UNSET, UNSET, UNSET, UNSET, ""
function M.renderKey(_, state)
  if K.UD == nil then return "" end
  local crit, low, full, reserve, cells = readLimits(state or {})
  if crit == lastCrit and low == lastLow and full == lastFull and reserve == lastReserve and cells == lastCells then
    return lastKey
  end
  lastCrit, lastLow, lastFull, lastReserve, lastCells = crit, low, full, reserve, cells
  lastKey = string.format("%s|%s|%s|%s|%d", tostring(crit), tostring(low), tostring(full), tostring(reserve), cells)
  return lastKey
end

return M
