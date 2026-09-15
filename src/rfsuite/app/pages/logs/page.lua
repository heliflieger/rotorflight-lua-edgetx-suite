local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = nil
local Controls = nil
local LoadingOverlay = nil
local Graph = nil
local t = nil

-- The engine walks a log in small units, and it is what reads a log for BOTH views: the
-- flight statistics are accumulated by the same pass that indexes the file for the plot.
-- So it is loaded once a log has been chosen -- not once the plot has been -- and dropped
-- again when the page closes. The file list costs nothing for it.
local GRAPH_TICKS_PER_WAKEUP = 6

local state = {
  selectedFile = nil,
  selectedFilePath = nil,
  selectedModel = nil,
  logsList = {},
  summary = nil,
  loading = false,
  -- `loading` says a log is being read; `reading` says the engine has been given it and is
  -- walking it, which is what tells the wakeup to spend units rather than to start again.
  reading = false,
  -- The directory walk is deferred rather than run inside M.build; see the wakeup below.
  scanPending = false,
  scanned = false,
  requestRebuild = nil,
  -- The file list and the statistics of a selected log are told apart by
  -- selectedFile, as before. "graph" is the third view on top of those, and
  -- pickCurves puts it into its column chooser.
  view = nil,
  pickCurves = false,
  slots = {}
}

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("logs") or nil end
end

-- `lcd.sizeText(text, flags)` answers for the font the label is drawn in and carries no
-- drawing-context guard, so it may be called while the child list is being built. The fallback
-- is only there for a build that does not offer the call.
local function textSize(text, font)
  local fn = lcd and lcd.sizeText
  if type(fn) == "function" then
    local ok, tw, th = pcall(fn, tostring(text or ""), font)
    tw, th = tonumber(tw), tonumber(th)
    if ok and tw and th and th > 0 then
      return tw, th
    end
  end
  return #tostring(text or "") * 7, 16
end

local ELLIPSIS = "..."

-- The ellipsis is the one string every cut and every overlong label measures, and it is the
-- same three characters every time. Ask each font about it once instead of once per row.
local ellipsisW = {}
local function ellipsisWidth(font)
  local key = font or 0
  local width = ellipsisW[key]
  if not width then
    width = textSize(ELLIPSIS, font)
    ellipsisW[key] = width
  end
  return width
end

-- The largest cut length at or below `n` that does not fall inside a multi-byte character, so
-- that shortening a file name can never leave half a sequence behind.
local function charBoundary(text, n)
  while n > 0 do
    local b = string.byte(text, n + 1)
    if not b or b < 0x80 or b >= 0xC0 then return n end
    n = n - 1
  end
  return 0
end

-- The longest prefix of `text`, in bytes, that fits `maxW` px in `font`: never longer than
-- `text` less one character, never shorter than `minN`, and always on a character boundary.
--
-- A prefix does not get narrower as it grows, so the prefixes that fit are exactly the short
-- ones and the break point is the single edge between the two runs. Bisecting for that edge
-- asks the font about six substrings where walking the string backwards asked about one per
-- character -- and on a list of three hundred logs that difference is the page build.
local function fittingPrefix(text, font, maxW, minN)
  local best = minN
  local lo, hi = minN, #text - 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local n = charBoundary(text, mid)
    if textSize(string.sub(text, 1, n), font) <= maxW then
      if n > best then
        best = n
      end
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best
end

-- Cut `text` so that it, plus a trailing ellipsis, fits `maxW` px in `font`. A text that
-- already fits is returned untouched.
local function fitToWidth(text, font, maxW)
  text = tostring(text or "")
  if maxW <= 0 or textSize(text, font) <= maxW then
    return text
  end

  local room = maxW - ellipsisWidth(font)
  if room <= 0 then
    return ELLIPSIS
  end

  -- A cut of nothing at all always fits, `room` being positive here, so the search cannot
  -- come back empty-handed and the ellipsis on its own is what a zero-length cut produces.
  local cut = string.sub(text, 1, fittingPrefix(text, font, room, 0))
  -- Trailing dots and spaces would read as part of the ellipsis, so drop them first.
  return (string.gsub(cut, "[%.%s]+$", "")) .. ELLIPSIS
end

-- The characters the engine is willing to break a line after, as a Lua set: space, and the
-- punctuation that lets `Model-2026-08-10-100706.csv` be split at all. Breaking at the same
-- places is what keeps a label reading as it did before it was broken here.
local BREAK_SET = "[ ,%.;:%-_%)%]}]"

-- One line of `s` that fits `maxW` px in `font`, and what is left over.
--
-- The break is taken after the last break character that still fits, so a word is not split
-- when it need not be; a word too long for a line on its own is broken inside it, at a
-- character boundary, because there is nowhere else to break it. A break at a space drops the
-- space, which is not drawn at the end of a line either way; every other break keeps its
-- character on the line it ends.
--
-- `sw` is the width of `s` where the caller has already had it measured; leaving it out costs
-- one more measurement of a string the font has just been asked about.
local function takeLine(s, font, maxW, sw)
  if (sw or textSize(s, font)) <= maxW then
    return s, ""
  end

  -- One character is kept whatever it measures: a line that took nothing would leave the
  -- caller with the same string to break again, and the loop would not end.
  local n = fittingPrefix(s, font, maxW, 1)

  local head = string.sub(s, 1, n)
  local _, brk = string.find(head, "^.*" .. BREAK_SET)
  if brk then
    if string.byte(head, brk) == 32 then
      if brk > 1 then
        return string.sub(s, 1, brk - 1), (string.gsub(string.sub(s, brk + 1), "^ +", ""))
      end
    else
      return string.sub(s, 1, brk), string.sub(s, brk + 1)
    end
  end
  return head, string.sub(s, n + 1)
end

-- `text` broken into at most `maxLines` lines of `maxW` px in `font`.
--
-- What does not fit is cut on the last line rather than carried past it, so a text laid out
-- this way can never be taller than the room it was given.
local function wrapToWidth(text, font, maxW, maxLines)
  local lines = {}
  local rest = tostring(text or "")

  while rest ~= "" do
    -- One measurement of `rest` serves both the test below and the break after it. Measuring
    -- it here rather than inside the test costs nothing: takeLine needs the same number for
    -- the same string either way.
    local restW = textSize(rest, font)

    if #lines + 1 >= maxLines and restW > maxW then
      local room = maxW - ellipsisWidth(font)
      if room <= 0 then
        room = maxW
      end
      lines[#lines + 1] = takeLine(rest, font, room, restW) .. ELLIPSIS
      break
    end

    local line
    line, rest = takeLine(rest, font, maxW, restW)
    if line == "" then
      break
    end
    lines[#lines + 1] = line
  end

  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

-- The heading of the flight summary, in the width the heading actually has.
--
-- Controls.appendStaticSectionHeader gives its label no `w`, so LVGL sizes the label to its own
-- text: a heading wider than the header neither wraps nor is clipped, it runs past the right
-- edge of the page and leaves the page body scrolling sideways.
--
-- Two steps, in this order. extractFileInfo takes the model out of the file name itself when
-- the name carries one ("^(.-)%-%d%d%d%d"), and for those -- which is every log the tool
-- writes -- "<model> - <file>" prints the model twice and spends the width on the half that is
-- already there. So drop the prefix, but only when the name really does begin with it: a model
-- that came from the parent folder instead is not in the name, and is the only place that says
-- which helicopter this was.
--
-- What is left is then measured in the font the header draws in and cut to fit. Dropping the
-- duplicate is enough on its own at 480 px and wider; the cut is what a narrow screen needs.
local function summaryTitle(model, file, maxW)
  model = tostring(model or "")
  local title = tostring(file or "")
  if model ~= "" and string.sub(title, 1, #model) ~= model then
    title = model .. " - " .. title
  end
  return fitToWidth(title, MIDSIZE, maxW)
end

local function closeGraph()
  if Graph then
    Graph.close()
    Graph = nil
  end
  state.view = nil
  state.pickCurves = false
  state.slots = {}
  collectgarbage("collect")
end

local function pageText(i18n, key)
  if t then
    local translated = t(i18n, key)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return key
end

local function safeCollectEntries(listBasePath)
  local entries = {}
  if type(dir) == "function" then
    local iterator = dir(listBasePath)
    if type(iterator) == "function" then
      for name in iterator do
        if name and name ~= "." and name ~= ".." and name ~= "" then
          entries[#entries + 1] = name
        end
      end
      return entries
    end
  end

  if system and system.listFiles then
    local ok, res = pcall(system.listFiles, listBasePath)
    if ok and type(res) == "table" then
      for i = 1, #res do
        local name = res[i]
        if name and name ~= "." and name ~= ".." and name ~= "" then
          entries[#entries + 1] = name
        end
      end
      return entries
    end
  end

  return entries
end

local function formatDateText(date, time, isNarrow)
  if not date or date == "" or date == "Unknown" then
    return "Unknown"
  end
  local d = date
  if isNarrow then
    local md = string.match(date, "^%d%d%d%d%-(%d%d%-%d%d)$")
    if md then
      d = md
    end
  end
  if not time or time == "" then
    return d
  end
  local t = time
  if isNarrow then
    local hm = string.match(time, "^(%d%d:%d%d)")
    if hm then t = hm end
  end
  return d .. "  " .. t
end

local function extractFileInfo(filename, fullPath, parentFolder)
  local date = string.match(filename, "(%d%d%d%d%-%d%d%-%d%d)")
  local time = nil

  -- Pattern: YYYY-MM-DD-HHMMSS or YYYY-MM-DD_HHMMSS
  local h1, m1, s1 = string.match(filename, "%d%d%d%d%-%d%d%-%d%d[_-]?(%d%d)(%d%d)(%d%d)")
  if h1 and m1 and s1 then
    time = h1 .. ":" .. m1 .. ":" .. s1
  else
    -- Pattern: YYYY-MM-DD_HH-MM-SS or YYYY-MM-DD-HH-MM-SS
    local h2, m2, s2 = string.match(filename, "%d%d%d%d%-%d%d%-%d%d[_-](%d%d)%-(%d%d)%-(%d%d)")
    if h2 and m2 and s2 then
      time = h2 .. ":" .. m2 .. ":" .. s2
    end
  end

  local model = string.match(filename, "^(.-)%-%d%d%d%d")
  if not model or model == "" then
    model = (parentFolder and parentFolder ~= "" and parentFolder ~= "telemetry" and parentFolder ~= "rfsuite" and parentFolder ~= "LOGS") and parentFolder or "Default"
  end

  -- Fallback: peek first lines if date/time not in filename
  if not date or not time then
    local f = io.open(fullPath, "r")
    if f then
      local firstChunk = io.read(f, 512)
      io.close(f)
      if firstChunk then
        local l1, l2 = string.match(firstChunk, "([^\r\n]+)[\r\n]+([^\r\n]+)")
        if l2 then
          local d, tm = string.match(l2, "^(.-),(.-),")
          if d and string.match(d, "^%d%d%d%d%-%d%d%-%d%d$") then
            date = d
          end
          if tm then
            local tClean = string.match(tm, "^(%d%d:%d%d:%d%d)")
            if tClean then time = tClean end
          end
        end
      end
    end
  end

  local sortDate = date or "0000-00-00"
  local sortTime = (time and time ~= "") and string.gsub(time, ":", "") or "000000"
  local sortKey = sortDate .. "_" .. sortTime .. "_" .. filename

  return {
    file = filename,
    path = fullPath,
    model = model,
    date = date or "Unknown",
    time = time or "",
    sortKey = sortKey
  }
end

local function scanLogFiles()
  local found = {}
  -- The search paths NEST, and each one is walked both at its top level and one directory down.
  -- A file lying directly in /LOGS/rfsuite/telemetry is therefore reached twice: once as a
  -- top-level .csv of the first path, and once as a .csv inside the `telemetry` subdirectory of
  -- the second. Nothing downstream removes it -- `extractFileInfo` builds a fresh record each
  -- time and the sort has no uniqueness step -- so that file appears twice in the list, as two
  -- adjacent identical rows (the sort key is the same). A file inside a model folder, or one
  -- directly in /LOGS, is reached once.
  --
  -- The full path is what identifies a log, so that is what is remembered.
  local seen = {}
  local searchPaths = {
    "/LOGS/rfsuite/telemetry",
    "/LOGS/rfsuite",
    "/LOGS"
  }

  local function collect(fileName, fullPath, parentFolder)
    if seen[fullPath] then return end
    seen[fullPath] = true
    found[#found + 1] = extractFileInfo(fileName, fullPath, parentFolder)
  end

  for s = 1, #searchPaths do
    local basePath = searchPaths[s]
    local topEntries = safeCollectEntries(basePath)
    for i = 1, #topEntries do
      local entry = topEntries[i]
      if string.match(entry, "%.csv$") then
        collect(entry, basePath .. "/" .. entry, "")
      elseif not string.match(entry, "%.%w+$") then
        -- Subdirectory (e.g. Model name)
        local modelDir = basePath .. "/" .. entry
        local subEntries = safeCollectEntries(modelDir)
        for j = 1, #subEntries do
          local subFile = subEntries[j]
          if string.match(subFile, "%.csv$") then
            collect(subFile, modelDir .. "/" .. subFile, entry)
          end
        end
      end
    end
  end

  table.sort(found, function(a, b) return a.sortKey > b.sortKey end)
  state.logsList = found
  return found
end


function M.getHeaderActions()
  return {
    reload = true,
    save = false,
    help = true
  }
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/logs/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Logs", message = "" }
end

function M.wakeup(ctx)
  ensureDeps()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    state.requestRebuild = ctx.requestRebuild
  end

  -- The scan walks three directory trees and opens every candidate to read its header. Done
  -- inside M.build, that happens with nothing on the screen: the host paints no frame in front
  -- of a page, so the tool simply stands still until the walk is over. Deferring it by one
  -- wakeup lets the build that asked for it draw the notice first -- the same shape this page
  -- already uses for parsing a selected log.
  if state.scanPending then
    state.scanPending = false
    scanLogFiles()
    state.scanned = true
    state.loading = false
    if state.requestRebuild then
      state.requestRebuild()
    end
  end

  -- Reading the selected log. The whole file has to be walked to answer the flight summary,
  -- and a long one is megabytes: done in a single call it stands the tool still for as long
  -- as the walk takes, because a script gets no time slice it can be interrupted in. So the
  -- engine walks it a fixed number of lines at a time and this is where those units are
  -- spent -- with the notice the build drew already on the screen, and its bar following the
  -- position in the file rather than a constant.
  --
  -- The pass that answers the summary is the same one that indexes the file for the plot, so
  -- opening the plot afterwards reads nothing again.
  if state.loading and state.selectedFilePath then
    if not Graph then Graph = loadModule("app/pages/logs/graph.lua") end
    if not Graph then
      state.loading = false
      state.summary = nil
      if state.requestRebuild then state.requestRebuild() end
    else
      if not state.reading then
        state.reading = true
        Graph.open(state.selectedFilePath, { stats = true })
      end

      for _ = 1, GRAPH_TICKS_PER_WAKEUP do
        if Graph.tick() then break end
        if not Graph.isBusy() then break end
      end

      if not Graph.isBusy() then
        state.summary = Graph.getSummary()
        state.loading = false
        state.reading = false
        collectgarbage("collect")
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    end
  end

  -- The graph's file work happens here rather than in its build, so the notice
  -- the build drew is on the screen while the log is being walked. A few units
  -- per wakeup rather than one: the unit is sized so that it cannot stall a
  -- frame, and a long log would otherwise take longer to index than to read.
  if Graph and Graph.isBusy() then
    local redraw = false
    for _ = 1, GRAPH_TICKS_PER_WAKEUP do
      if Graph.tick() then
        redraw = true
        break
      end
      if not Graph.isBusy() then break end
    end
    if redraw and state.requestRebuild then
      state.requestRebuild()
    end
  end
end

function M.onReload(ctx)
  state.scanned = false
  state.scanPending = false
  closeGraph()
  state.selectedFile = nil
  state.selectedFilePath = nil
  state.summary = nil
  state.loading = false
  state.reading = false
  collectgarbage("collect")
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ctx.requestRebuild()
  end
  return true
end

function M.onBack(ctx)
  -- Back walks the views it came through: chooser to plot, plot to statistics,
  -- statistics to the file list, and only then out of the page.
  if state.view == "graph" then
    if state.pickCurves and Graph and #Graph.getCurves() > 0 then
      state.pickCurves = false
      return true
    end
    closeGraph()
    return true
  end

  if state.selectedFile ~= nil then
    state.selectedFile = nil
    state.selectedFilePath = nil
    state.selectedModel = nil
    state.summary = nil
    state.loading = false
    state.reading = false
    closeGraph()
    collectgarbage("collect")
    return true
  end
  return false
end

local function openGraph()
  if not Graph then Graph = loadModule("app/pages/logs/graph.lua") end
  if not Graph then return false end
  state.view = "graph"
  state.pickCurves = false
  state.slots = {}
  -- The statistics view has just had this file walked, and the walk built the index the plot
  -- needs. Opening it again here is what the engine recognises and answers without reading.
  Graph.open(state.selectedFilePath, { stats = true })
  return true
end

-- i18n is resolved when the package is built, and the card carries no locale table at all, so
-- a lookup whose key is a variable cannot be resolved on the radio -- it reaches the screen as
-- the key itself. Every text this file picks by name is therefore looked up through a literal
-- here and chosen out of the resulting table.
local function graphErrorText(i18n, err)
  local texts = {
    open = pageText(i18n, "graph_err_open"),
    empty = pageText(i18n, "graph_err_empty"),
    not_telemetry = pageText(i18n, "graph_err_not_telemetry"),
    no_data = pageText(i18n, "graph_err_no_data")
  }
  return texts[err] or texts.open
end

local function templateText(i18n, key)
  local texts = {
    tpl_power = pageText(i18n, "tpl_power"),
    tpl_battery = pageText(i18n, "tpl_battery"),
    tpl_link = pageText(i18n, "tpl_link"),
    tpl_governor = pageText(i18n, "tpl_governor")
  }
  return texts[key] or key
end

local GRAPH_INFO_H  = 20
local GRAPH_AXIS_H  = 18
local GRAPH_READ_H  = 24
local GRAPH_CTRL_H  = 34
local GRAPH_GAP     = 6
local GRAPH_MIN_CHART_H = 60

--- How much room a page really has, from its content origin down.
--
-- `h` in the build context is the height of the page BODY, not of the screen: `ui/home.lua`
-- hands a page module `pageBodyHeight()`, which is `LCD_H` less the header EdgeTX builds for
-- every Lua page. `LvglWidgetPage` parents the children to `page->getBody()`, a window at
-- {0, MENU_HEADER_HEIGHT, LCD_W, LCD_H - MENU_HEADER_HEIGHT} (lua_lvgl_widget.cpp), so `h` is
-- already the bottom edge these children may reach.
--
-- Taking the header off a second time here would only shorten the plot, and nothing would
-- complain, because the page scrolls either way.
--
-- The 8 px is the bottom margin. `chartRect` spends the rest on the fixed rows, so the last
-- control row ends `GRAPH_GAP` above the budget and stops 14 px clear of the body.
local function contentBudget(y, bodyH)
  local usable = bodyH - y - 8
  if usable < 160 then usable = 160 end
  return usable
end

local function rebuild()
  if state.requestRebuild then state.requestRebuild() end
end

-- The column chooser: the presets this log can serve, the flight to look at when
-- the file holds more than one, and one slot per curve. Slots rather than a list
-- of every column, because a telemetry log has well over a hundred of them and a
-- row each would be a page nobody can scroll.
local function buildCurvePicker(children, x, y, w, i18n)
  local cursorY = y

  -- The chooser is built out of the shared controls and has no fallback shape:
  -- without them there is no way to offer a hundred columns on one screen.
  if not (Controls and type(Controls.appendComboSelect) == "function") then
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = y + 20, w = w - 20,
      text = pageText(i18n, "graph_no_columns"),
      color = COLOR_THEME_WARNING,
      align = CENTER
    }
    return
  end

  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "graph_select"))
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local templates = Graph.getTemplates()
  if #templates > 0 then
    local n = #templates
    local btnW = math.floor((w - (n - 1) * GRAPH_GAP) / n)
    for i = 1, n do
      local tpl = templates[i]
      children[#children + 1] = {
        type = "button",
        x = x + (i - 1) * (btnW + GRAPH_GAP),
        y = cursorY,
        w = btnW,
        h = GRAPH_CTRL_H,
        text = templateText(i18n, tpl.key),
        press = function()
          state.slots = {}
          for j = 1, #tpl.cols do state.slots[j] = tpl.cols[j] end
          Graph.applyColumns(tpl.cols)
          state.pickCurves = false
          rebuild()
        end
      }
    end
    cursorY = cursorY + GRAPH_CTRL_H + GRAPH_GAP * 2
  end

  local sessions = Graph.getSessions()
  if #sessions > 1 then
    local options = {}
    for i = 1, #sessions do
      local s = sessions[i]
      options[i] = {
        value = i,
        label = string.format("%d  (%s)", i, Graph.formatOffset(s.t1 - s.t0))
      }
    end
    cursorY = cursorY + Controls.appendComboSelect(
      children, x, cursorY, w, pageText(i18n, "graph_flight"),
      options, Graph.getSessionIndex(),
      function(v)
        Graph.selectSession(v)
        rebuild()
      end)
  end

  local columns = Graph.getColumns()
  if #columns == 0 then
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = cursorY + 20, w = w - 20,
      text = pageText(i18n, "graph_no_columns"),
      color = COLOR_THEME_WARNING,
      align = CENTER
    }
    return
  end

  local options = { { value = 0, label = pageText(i18n, "graph_none") } }
  for i = 1, #columns do
    local c = columns[i]
    local label = c.name
    if c.unit ~= nil and c.unit ~= "" then label = label .. " (" .. c.unit .. ")" end
    options[#options + 1] = { value = c.col, label = label }
  end

  local curveLabel = pageText(i18n, "graph_curve")
  for k = 1, Graph.MAX_CURVES do
    local slot = k
    cursorY = cursorY + Controls.appendComboSelect(
      children, x, cursorY, w, curveLabel .. " " .. slot,
      options, state.slots[slot] or 0,
      function(v)
        if v == 0 then state.slots[slot] = nil else state.slots[slot] = v end
        rebuild()
      end)
  end

  local chosen = {}
  for k = 1, Graph.MAX_CURVES do
    if state.slots[k] then chosen[#chosen + 1] = state.slots[k] end
  end

  local btnW = 200
  if btnW > w then btnW = w end
  children[#children + 1] = {
    type = "button",
    x = x + math.floor((w - btnW) / 2),
    y = cursorY + GRAPH_GAP,
    w = btnW,
    h = GRAPH_CTRL_H,
    text = pageText(i18n, "graph_show"),
    active = function() return #chosen > 0 end,
    press = function()
      if #chosen == 0 then return end
      Graph.applyColumns(chosen)
      state.pickCurves = false
      rebuild()
    end
  }
end

-- The plot area, in absolute page pixels. It is computed for every view of the graph and not
-- only for the chart: how wide the chart will be decides how many buckets a column is reduced
-- to, so the engine has to know it BEFORE a column can be chosen. Deriving it inside the chart
-- branch meant the chooser could never leave itself -- the branch it had to reach first was the
-- one that would have supplied the number.
local function chartRect(x, y, w, availH)
  local chartH = availH - (GRAPH_INFO_H + GRAPH_AXIS_H + GRAPH_READ_H + GRAPH_CTRL_H + GRAPH_GAP * 4)
  if chartH < GRAPH_MIN_CHART_H then chartH = GRAPH_MIN_CHART_H end
  return x + 2, y + GRAPH_INFO_H + GRAPH_GAP, w - 4, chartH
end

local function buildChart(children, x, y, w, availH, i18n)
  local chartX, chartY, chartW, chartH = chartRect(x, y, w, availH)

  local winT0, winT1, sessT0 = Graph.getWindow()
  local windowText = Graph.formatOffset(winT0 - sessT0) .. " - " .. Graph.formatOffset(winT1 - sessT0)
  if Graph.isBusy() then
    windowText = windowText .. "   " .. tostring(math.floor(Graph.getProgress() * 100)) .. " %"
  end

  children[#children + 1] = {
    type = "label",
    x = x, y = y, w = math.floor(w * 0.55),
    text = tostring(state.selectedFile or ""),
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "label",
    x = x + math.floor(w * 0.55), y = y, w = w - math.floor(w * 0.55),
    text = windowText,
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE,
    align = RIGHT
  }

  -- The time axis, and the only edge the plot needs: a full frame drawn unfilled is not
  -- distinguishable from the page behind it at this theme's contrast.
  children[#children + 1] = {
    type = "rectangle",
    x = chartX, y = chartY + chartH, w = chartW, h = 1,
    color = COLOR_THEME_DISABLED,
    filled = true
  }

  -- Vertical grid lines are rectangles rather than line objects: a one-pixel
  -- column needs no point list, and the axis label belongs to the same step.
  local grid = Graph.getGrid()
  for i = 1, #grid do
    local g = grid[i]
    children[#children + 1] = {
      type = "rectangle",
      x = g.x, y = chartY + 1, w = 1, h = chartH - 2,
      color = COLOR_THEME_DISABLED,
      filled = true
    }
    children[#children + 1] = {
      type = "label",
      x = math.max(x, g.x - 18), y = chartY + chartH + 2, w = 40,
      text = g.label,
      color = COLOR_THEME_DISABLED,
      font = SMLSIZE
    }
  end

  local curves = Graph.getCurves()
  for k = 1, #curves do
    if not Graph.isCurveEmpty(k) then
      children[#children + 1] = {
        type = "line",
        x = 0, y = 0, w = 0, h = 0,
        pts = Graph.getPoints(k),
        color = Graph.getCurveColor(k),
        thickness = 1
      }
    end
  end

  local cursorX = Graph.getCursorX()
  if cursorX >= chartX and cursorX <= chartX + chartW then
    children[#children + 1] = {
      type = "rectangle",
      x = cursorX, y = chartY + 1, w = 1, h = chartH - 2,
      color = COLOR_THEME_FOCUS,
      filled = true
    }
  end

  -- Readout row: the cursor keys, the time it stands at, and what each curve
  -- reaches there.
  local readY = chartY + chartH + GRAPH_AXIS_H + GRAPH_GAP
  local stepW = 30
  children[#children + 1] = {
    type = "button",
    x = x, y = readY, w = stepW, h = GRAPH_READ_H,
    text = "<",
    press = function()
      Graph.moveCursor(-1)
      rebuild()
    end
  }
  children[#children + 1] = {
    type = "button",
    x = x + stepW + 4, y = readY, w = stepW, h = GRAPH_READ_H,
    text = ">",
    press = function()
      Graph.moveCursor(1)
      rebuild()
    end
  }

  local readX = x + 2 * (stepW + 4) + GRAPH_GAP
  local timeW = 52
  children[#children + 1] = {
    type = "label",
    x = readX, y = readY + 3, w = timeW,
    text = Graph.getCursorTimeText() or "-",
    color = COLOR_THEME_PRIMARY1,
    font = SMLSIZE
  }

  local readout = Graph.getReadout()
  local valuesX = readX + timeW + GRAPH_GAP
  local valuesW = math.max(40, (x + w) - valuesX)
  local slotW = math.floor(valuesW / Graph.MAX_CURVES)
  for k = 1, #readout do
    local r = readout[k]
    local text = r.name .. " -"
    if r.value ~= nil then
      text = string.format("%s %g%s", r.name, r.value, r.unit or "")
    end
    children[#children + 1] = {
      type = "label",
      x = valuesX + (k - 1) * slotW, y = readY + 3, w = slotW,
      text = text,
      color = Graph.getCurveColor(k),
      font = SMLSIZE
    }
  end

  -- Window controls. A drag would be the obvious gesture and is not available:
  -- the page these children live in scrolls, and it takes the gesture first.
  local ctrlY = readY + GRAPH_READ_H + GRAPH_GAP
  local labels = {
    { text = "-", press = function() Graph.zoom(-1) rebuild() end },
    { text = "+", press = function() Graph.zoom(1) rebuild() end },
    { text = pageText(i18n, "graph_full"), press = function() Graph.zoomFull() rebuild() end },
    { text = "<<", press = function() Graph.pan(-1) rebuild() end },
    { text = ">>", press = function() Graph.pan(1) rebuild() end },
    { text = pageText(i18n, "graph_curves"), press = function()
        state.pickCurves = true
        rebuild()
      end }
  }
  local n = #labels
  local btnW = math.floor((w - (n - 1) * GRAPH_GAP) / n)
  for i = 1, n do
    children[#children + 1] = {
      type = "button",
      x = x + (i - 1) * (btnW + GRAPH_GAP),
      y = ctrlY,
      w = btnW,
      h = GRAPH_CTRL_H,
      text = labels[i].text,
      press = labels[i].press
    }
  end
end

local function buildGraphView(children, x, y, w, availH, i18n)
  -- Told once per build, before anything is asked of the engine. A change drops its cached
  -- windows and starts the current one again; the points it still holds are drawn meanwhile.
  Graph.setGeometry(chartRect(x, y, w, availH))

  local err = Graph.getError()
  if err ~= nil then
    local headH = 0
    if Controls and type(Controls.appendStaticSectionHeader) == "function" then
      Controls.appendStaticSectionHeader(children, x, y, w, pageText(i18n, "graph_title"))
      headH = Controls.STATIC_SECTION_H or 50
    end
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = y + headH + 20, w = w - 20,
      text = graphErrorText(i18n, err),
      color = COLOR_THEME_WARNING,
      align = CENTER
    }
    return
  end

  -- Nothing can be chosen before the index exists, so the scan is the one wait
  -- this view reports with the overlay the rest of the tool uses.
  if #Graph.getCurves() == 0 and Graph.isBusy() then
    if LoadingOverlay then
      LoadingOverlay.append(children, {
        x = x, y = y, w = w, h = availH,
        title = pageText(i18n, "loading_title"),
        message = pageText(i18n, "graph_scanning"),
        progress = Graph.getProgress()
      })
    end
    return
  end

  if state.pickCurves or #Graph.getCurves() == 0 then
    buildCurvePicker(children, x, y, w, i18n)
    return
  end

  buildChart(children, x, y, w, availH, i18n)
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h or 200
  local i18n = ctx.i18n

  local cursorY = y

  -- If loading overlay is active. The bar is the engine's position in the file, so it stands
  -- for how much of the log has been read rather than for the fact that something is going on.
  if state.loading and LoadingOverlay then
    LoadingOverlay.append(children, {
      x = x,
      y = y,
      w = w,
      h = h,
      title = pageText(i18n, "loading_title"),
      message = pageText(i18n, "loading_message"),
      progress = (Graph and state.reading) and Graph.getProgress() or 0
    })
    return
  end

  -- The plot of the selected log, on top of its statistics.
  if state.view == "graph" and Graph then
    buildGraphView(children, x, cursorY, w, contentBudget(cursorY, h), i18n)
    return
  end

  -- If a log file is selected, show summary dashboard.
  --
  -- The file is never read from here. A build cannot be interrupted, so reading a log in one
  -- would be the stall the notice above exists to avoid; the wakeup does the walk and this
  -- draws whatever it has finished. A summary that is still nil at this point is a log the
  -- walk could not make sense of, which is the case the message below is for.
  if state.selectedFile and state.selectedFilePath then
    local summary = state.summary

    local titleText = summaryTitle(state.selectedModel or "Log", state.selectedFile, w)
    if Controls and type(Controls.appendStaticSectionHeader) == "function" then
      Controls.appendStaticSectionHeader(children, x, cursorY, w, titleText)
      cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
    end

    if not summary then
      children[#children + 1] = {
        type = "label",
        x = x + 10,
        y = cursorY + 20,
        w = w - 20,
        text = "Failed to parse log file",
        color = COLOR_THEME_WARNING,
        align = CENTER
      }
      return
    end

    local rowH = 40
    local labelColW = math.max(90, math.min(180, math.floor(w * 0.28)))
    local valColX = x + labelColW + 15
    local valColW = math.max(60, w - labelColW - 27)

    -- 1) Flight Duration Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "flight_duration"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s   (%d %s)", summary.durationStr, summary.sampleCount, pageText(i18n, "samples")),
      color = COLOR_WHITE,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY2,
      filled = true
    }

    -- 2) Voltage Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "voltage_title"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %.2fV   |   %s: %.2fV (-%.2fV)   |   %s: %.2fV",
        pageText(i18n, "start"), summary.vStart,
        pageText(i18n, "min"), summary.vMin, summary.vSag,
        pageText(i18n, "end_val"), summary.vEnd),
      color = COLOR_WHITE,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY2,
      filled = true
    }

    -- 3) Current Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "current_title"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %.1f A   |   %s: %.1f A   |   %s: ~%d mAh",
        pageText(i18n, "peak"), summary.cPeak,
        pageText(i18n, "avg"), summary.cAvg,
        pageText(i18n, "consumption_title"), math.floor(summary.mah)),
      color = COLOR_WHITE,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY2,
      filled = true
    }

    -- 4) Headspeed RPM Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "rpm_title"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %d rpm   |   %s: %d rpm (%s)",
        pageText(i18n, "max"), math.floor(summary.rMax),
        pageText(i18n, "min"), math.floor(summary.rMin),
        pageText(i18n, "in_flight")),
      color = COLOR_WHITE,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY2,
      filled = true
    }

    -- 5) ESC Temp Row
    local prefs = (ctx and ctx.preferences) or (type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences)
    local useFahrenheit = tonumber(prefs and prefs.localizations and prefs.localizations.temperature_unit) == 1
    local tMaxVal = summary.tMax
    local tStartVal = summary.tStart
    local tempUnit = "°C"
    if useFahrenheit then
      tMaxVal = (tMaxVal * 9 / 5) + 32
      tStartVal = (tStartVal * 9 / 5) + 32
      tempUnit = "°F"
    end

    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "temp_title"),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %d %s   |   %s: %d %s   |   %s %s: %d %%",
        pageText(i18n, "max"), math.floor(tMaxVal), tempUnit,
        pageText(i18n, "start"), math.floor(tStartVal), tempUnit,
        pageText(i18n, "max"), pageText(i18n, "throttle_title"), math.floor(summary.thrMax)),
      color = COLOR_WHITE,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY2,
      filled = true
    }

    -- The statistics answer what the flight came to; the plot answers when. It is
    -- opened from here rather than from the list, so the log is chosen once.
    local graphBtnW = 200
    if graphBtnW > w then graphBtnW = w end
    children[#children + 1] = {
      type = "button",
      x = x + math.floor((w - graphBtnW) / 2),
      y = cursorY + 12,
      w = graphBtnW,
      h = 36,
      text = pageText(i18n, "graph_open"),
      press = function()
        openGraph()
        if state.requestRebuild then state.requestRebuild() end
      end
    }

    return
  end

  -- List Mode: show available telemetry logs
  if not state.scanned then
    -- `state.loading` belongs to the CSV parse and drives a branch above this one with its own
    -- message, so the scan gets a flag of its own. The notice is drawn on every build until the
    -- wakeup has run, not only on the one that asks for it.
    if not state.scanPending then
      state.scanPending = true
      if state.requestRebuild then
        state.requestRebuild()
      end
    end

    if LoadingOverlay then
      LoadingOverlay.append(children, {
        x = x,
        y = y,
        w = w,
        h = h,
        title = pageText(i18n, "loading_title"),
        message = pageText(i18n, "scanning_message"),
        progress = 0.3
      })
      return
    end

    -- No overlay module: nothing can be said, so do what this page did before rather than
    -- leave the list empty.
    state.scanPending = false
    scanLogFiles()
    state.scanned = true
  end

  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "select_log"))
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  if #state.logsList == 0 then
    children[#children + 1] = {
      type = "label",
      x = x + 10,
      y = cursorY + 25,
      w = w - 20,
      text = pageText(i18n, "no_logs_found"),
      color = COLOR_THEME_DISABLED,
      align = CENTER
    }
    cursorY = cursorY + 60

    local btnW = 200
    local btnH = 36
    local btnX = x + math.floor((w - btnW) / 2)
    children[#children + 1] = {
      type = "button",
      x = btnX,
      y = cursorY,
      w = btnW,
      h = btnH,
      text = pageText(i18n, "refresh"),
      press = function()
        state.scanned = false
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    }
    return
  end

  -- Render log files list.
  --
  -- Proportional layout based on available width `w`:
  -- - Date/Time column: ~28-34% of `w` (compacts to `MM-DD HH:MM` on narrow screens < 380px)
  -- - Action button: 60px on narrow screens, 80px on medium (<480px), 100px on wide screens
  -- - Model & filename: space between date column and action button with safe margins
  -- - Row height: follows measured broken lines so wrapped titles cannot overflow into adjacent rows
  local ROW_MIN_H = 44
  local ROW_MAX_LINES = 3
  local isNarrow = w < 380
  local dateColW = isNarrow and math.floor(w * 0.34) or math.min(180, math.floor(w * 0.28))
  local btnW = isNarrow and 60 or (w < 480 and 80 or 100)
  local btnH = 30
  local btnX = x + w - btnW - 10
  local labelX = x + dateColW + 15
  local labelW = math.max(40, btnX - labelX - 10)
  local _, labelLineH = textSize("Ag", SMLSIZE)

  for i = 1, #state.logsList do
    local item = state.logsList[i]
    local itemY = cursorY

    local labelLines = wrapToWidth(string.format("[%s] %s", item.model, item.file),
                                   SMLSIZE, labelW, ROW_MAX_LINES)
    local labelText = table.concat(labelLines, "\n")
    local rowH = math.max(ROW_MIN_H, 22 + #labelLines * labelLineH)

    -- Date and Time
    children[#children + 1] = {
      type = "label",
      x = x + 10,
      y = itemY + 11,
      w = dateColW,
      text = formatDateText(item.date, item.time, isNarrow),
      color = COLOR_THEME_PRIMARY1,
      font = SMLSIZE
    }

    -- Model name and File name
    children[#children + 1] = {
      type = "label",
      x = labelX,
      y = itemY + 11,
      w = labelW,
      text = labelText,
      color = COLOR_THEME_DISABLED,
      font = SMLSIZE
    }

    -- View button
    children[#children + 1] = {
      type = "button",
      x = btnX,
      y = itemY + 7,
      w = btnW,
      h = btnH,
      text = pageText(i18n, "btn_view"),
      press = function()
        state.selectedFile = item.file
        state.selectedFilePath = item.path
        state.selectedModel = item.model
        state.summary = nil
        state.loading = true
        state.reading = false
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = itemY + rowH - 1,
      w = w,
      h = 1,
      color = COLOR_THEME_SECONDARY2,
      filled = true
    }

    cursorY = cursorY + rowH
  end
end

function M.onClose()
  state.scanned = false
  state.scanPending = false
  closeGraph()
  state.selectedFile = nil
  state.selectedFilePath = nil
  state.selectedModel = nil
  state.summary = nil
  state.loading = false
  state.reading = false
  state.logsList = {}
  LoadingOverlay = nil
  collectgarbage("collect")
end

return M
