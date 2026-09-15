local Engine = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if rChunk then
    local ok, res = pcall(rChunk)
    if ok and type(res) == "function" then
      requireModule = res
    end
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Common = requireModule("widgets/dashboard/themes/default/common.lua")
local Utils = requireModule("widgets/dashboard/objects/common.lua")
local Sensors = requireModule("lib/sensors.lua")

local OBJECTS_BASE = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/objects/"
local objectWrappers = {}

local function isSimulator()
  if type(getVersion) ~= "function" then return false end
  local ok, _, fw = pcall(getVersion)
  if not ok or type(fw) ~= "string" then return false end
  return string.sub(string.lower(fw), -4) == "simu"
end

local function loadObjectWrapper(typ)
  if objectWrappers[typ] ~= nil then
    return objectWrappers[typ]
  end

  local wrapper = requireModule("widgets/dashboard/objects/" .. typ .. ".lua")
  if not wrapper or type(wrapper) ~= "table" then
    objectWrappers[typ] = false
    return nil
  end

  objectWrappers[typ] = wrapper
  return wrapper
end

local function resolveGrid(layout)
  local cols = math.max(1, tonumber(layout and layout.cols) or 1)
  local rows = math.max(1, tonumber(layout and layout.rows) or 1)
  local padding = tonumber(layout and layout.padding) or 0
  return cols, rows, padding
end

-- The grid hands `padding` px to the space between the tracks and emits a rect per box
-- only, so nothing downstream ever draws in that gap. A Lua widget's own LVGL object
-- carries no background style, so what shows through the gap is whatever the radio's
-- theme paints behind the widget -- a different colour on every radio, and a slice of a
-- photograph where that theme has a background image. One full-zone rectangle at the head
-- of the node list is the surface the tiles sit on. A theme that wants the radio
-- background to show through sets `layout.bgcolor = false`.
local function buildBackgroundNode(zone, layout, state)
  local bgcolor = Utils.resolveValue(layout and layout.bgcolor, nil, state)
  if bgcolor == nil then bgcolor = BLACK end
  if bgcolor == false then return nil end
  return { type = "rectangle", x = zone.x, y = zone.y, w = zone.w, h = zone.h, color = bgcolor, filled = true }
end

-- A rect's geometry depends on exactly these four fields of a box; everything else a box
-- carries is read back from `rect.box` at render time. A theme whose `boxes` is a function
-- returns a fresh table on every build, so comparing the table itself can never match and the
-- whole grid is recomputed on every repaint even though nothing about the layout moved.
local function sameGridGeometry(cached, boxes)
  if cached == boxes then return true end
  if type(cached) ~= "table" or type(boxes) ~= "table" then return false end
  if #cached ~= #boxes then return false end
  for i = 1, #boxes do
    local a, b = cached[i], boxes[i]
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if a.col ~= b.col or a.row ~= b.row or a.colspan ~= b.colspan or a.rowspan ~= b.rowspan then
      return false
    end
  end
  return true
end

-- Reused rects keep their arithmetic and take the current box objects, so a box whose colour,
-- source, title or any other non-geometry field changed still renders from its own table.
local function rebindGridRects(rects, boxes)
  for i = 1, #rects do
    rects[i].box = boxes[i]
  end
  return rects
end

local function canReuseGridRects(cache, zone, boxes, cols, rows, padding)
  return cache
    and sameGridGeometry(cache.boxes, boxes)
    and cache.zoneX == zone.x
    and cache.zoneY == zone.y
    and cache.zoneW == zone.w
    and cache.zoneH == zone.h
    and cache.cols == cols
    and cache.rows == rows
    and cache.padding == padding
end

local function buildGridRects(zone, boxes, cols, rows, padding)
  local rects = {}

  local function buildTrackStarts(totalSize, trackCount, gap)
    local starts = {}
    local sizes = {}
    local totalGap = (trackCount - 1) * gap
    local usable = totalSize - totalGap
    if usable < 0 then usable = 0 end

    local base = math.floor(usable / trackCount)
    local remainder = usable - (base * trackCount)
    local cursor = 0

    for i = 1, trackCount do
      -- Keep early tracks stable and distribute extra pixels to the right/bottom edge.
      local extra = (i > (trackCount - remainder)) and 1 or 0
      sizes[i] = base + extra
      starts[i] = cursor
      cursor = cursor + sizes[i] + gap
    end

    return starts, sizes
  end

  local colStarts, colSizes = buildTrackStarts(zone.w, cols, padding)
  local rowStarts, rowSizes = buildTrackStarts(zone.h, rows, padding)

  for index = 1, #boxes do
    local box = boxes[index]
    local col = Utils.clamp(tonumber(box.col) or 1, 1, cols)
    local row = Utils.clamp(tonumber(box.row) or 1, 1, rows)
    local colSpan = math.max(1, tonumber(box.colspan) or 1)
    local rowSpan = math.max(1, tonumber(box.rowspan) or 1)
    local endCol = Utils.clamp(col + colSpan - 1, 1, cols)
    local endRow = Utils.clamp(row + rowSpan - 1, 1, rows)

    local x = zone.x + colStarts[col]
    local y = zone.y + rowStarts[row]

    local w = 0
    for c = col, endCol do
      w = w + colSizes[c]
    end
    w = w + (endCol - col) * padding

    local h = 0
    for r = row, endRow do
      h = h + rowSizes[r]
    end
    h = h + (endRow - row) * padding

    rects[#rects + 1] = { box = box, x = x, y = y, w = w, h = h }
  end

  return rects
end
local function renderBox(nodes, rect, state)
  local box = rect.box
  local typ = box.type or "text"
  local wrapper = loadObjectWrapper(typ)
  if wrapper and type(wrapper.render) == "function" then
    wrapper.render(nodes, rect, box, state)
  else
    Utils.drawContainer(nodes, rect, box, state)
    Utils.pushLabel(nodes, rect.x + 4, Utils.defaultValueY(rect, box), rect.w - 8, "--", box.textcolor or BLACK, box.valuealign or box.titlealign or CENTER, MIDSIZE)
  end
end

-- Everything the build decides, bound once: layout and boxes resolved, grid rects taken
-- through the cache, main rects and header rects concatenated IN THAT ORDER -- later nodes
-- draw on top, which is what keeps the header above the scene. Values are read per step;
-- structure is never re-resolved.
function Engine.beginBuild(zone, state, theme)
  local layout = Utils.resolveValue(theme.layout, nil, state) or { cols = 1, rows = 1, padding = 0 }
  local boxes = Utils.resolveValue(theme.boxes, nil, state) or {}
  local cols, rows, padding = resolveGrid(layout)
  local engineCache = state and state._engineCache
  if type(engineCache) ~= "table" and type(state) == "table" then
    engineCache = {}
    state._engineCache = engineCache
  end

  local mainRects = nil
  if canReuseGridRects(engineCache and engineCache.main, zone, boxes, cols, rows, padding) then
    mainRects = rebindGridRects(engineCache.main.rects, boxes)
    engineCache.main.boxes = boxes
  else
    mainRects = buildGridRects(zone, boxes, cols, rows, padding)
    if engineCache then
      engineCache.main = {
        boxes = boxes,
        zoneX = zone.x,
        zoneY = zone.y,
        zoneW = zone.w,
        zoneH = zone.h,
        cols = cols,
        rows = rows,
        padding = padding,
        rects = mainRects
      }
    end
  end

  -- The combined list is a fresh table: the cached rect lists are long-lived and must not
  -- grow header entries.
  local rects = {}
  for i = 1, #mainRects do
    rects[#rects + 1] = mainRects[i]
  end

  local headerLayout = Utils.resolveValue(theme.header_layout, nil, state)
  local headerBoxes = Utils.resolveValue(theme.header_boxes, nil, state)
  if type(headerLayout) == "table" and type(headerBoxes) == "table" and #headerBoxes > 0 then
    local headerHeight = math.max(24, math.floor(zone.h * 0.16))
    local headerZone = { x = zone.x, y = zone.y, w = zone.w, h = headerHeight }
    local hCols, hRows, hPadding = resolveGrid(headerLayout)
    local headerRects = nil
    if canReuseGridRects(engineCache and engineCache.header, headerZone, headerBoxes, hCols, hRows, hPadding) then
      headerRects = rebindGridRects(engineCache.header.rects, headerBoxes)
      engineCache.header.boxes = headerBoxes
    else
      headerRects = buildGridRects(headerZone, headerBoxes, hCols, hRows, hPadding)
      if engineCache then
        engineCache.header = {
          boxes = headerBoxes,
          zoneX = headerZone.x,
          zoneY = headerZone.y,
          zoneW = headerZone.w,
          zoneH = headerZone.h,
          cols = hCols,
          rows = hRows,
          padding = hPadding,
          rects = headerRects
        }
      end
    end
    for i = 1, #headerRects do
      rects[#rects + 1] = headerRects[i]
    end
  end

  -- Seeded here rather than pushed by the first step: the background has to precede every
  -- tile, and the stepped and the single-pass path must hand LVGL the same node order.
  local nodes = {}
  local background = buildBackgroundNode(zone, layout, state)
  if background then nodes[1] = background end

  return { rects = rects, nodes = nodes, cursor = 1 }
end

-- Renders up to `k` boxes from the cursor into the build's node table -- pure Lua data
-- construction, no LVGL call anywhere on this path. Returns true when every rect has been
-- rendered.
function Engine.stepBuild(build, state, k)
  local rects = build.rects
  local last = math.min(build.cursor + k - 1, #rects)
  for i = build.cursor, last do
    renderBox(build.nodes, rects[i], state)
  end
  build.cursor = last + 1
  return build.cursor > #rects
end

-- One call, one pass: beginBuild plus a single step over everything. Same nodes in the
-- same order as the stepped path, which is what makes the two interchangeable.
function Engine.build(zone, state, theme)
  local build = Engine.beginBuild(zone, state, theme)
  Engine.stepBuild(build, state, #build.rects)
  return build.nodes
end

function Engine.renderKey(state, _)
  local cells = Utils.toNumber(state and state.batteryCellCount, 0)
  local themeMin = Utils.toNumber(state and state.themeConfig and state.themeConfig.v_min, 0)
  local themeMax = Utils.toNumber(state and state.themeConfig and state.themeConfig.v_max, 0)
  local zoneW = Utils.toNumber(state and state.zoneW, 0)
  local zoneH = Utils.toNumber(state and state.zoneH, 0)
  local flightMode = tostring((state and state.flightMode) or "")

  return string.format("%s|%dx%d|%d|%d|%d",
    flightMode,
    zoneW,
    zoneH,
    math.floor(cells + 0.5),
    math.floor(themeMin * 10 + 0.5),
    math.floor(themeMax * 10 + 0.5)
  )
end

return Engine
