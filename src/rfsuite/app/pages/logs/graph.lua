-- Telemetry log plotting engine for the Logs page.
--
-- Reads one EdgeTX telemetry CSV and turns a time window of it into polylines the
-- page can hand straight to lvgl.build. It holds no UI of its own: the page owns
-- the chrome, decides the geometry and asks here for points, grid and readouts.
--
-- All file work is chunked. G.tick() does one small, fixed unit of work and
-- returns; the page calls it from its wakeup, so a multi-megabyte log is walked
-- across many ticks instead of stalling the tool in a single call. The unit sizes
-- are fixed counts rather than a measured budget on purpose: a log's line length
-- and column count vary far more than the cost per line does, so counting lines
-- is the stable dimension.
--
-- The passes are:
--   header  read line 1
--   hparse  parse its columns (a flight controller log has well over a hundred)
--   scan    walk every line for Date and Time only, building a sparse offset
--           index and splitting the file into sessions at gaps longer than 30 s
--   reset   clear the bucket arrays for the selected curves
--   seek    jump to the indexed offset just before the window start
--   extract read the window, accumulating min/max per display bucket
--   rebkt   re-bucket a cached window into the display resolution
--   pts     turn buckets into polylines, one curve per tick
--
-- Only the extract pass touches the card. The whole session is held once at four
-- times the display resolution, so zooming out and panning at moderate zoom are
-- served from that copy; only a window finer than it reads the file again.

local G = {}

local CHUNK_SIZE          = 4096   -- io.read size for the line pump
local HEADER_ITERS_TICK   = 8      -- pump iterations while looking for line 1
local HPARSE_COLS_TICK    = 48     -- header columns parsed per tick
local SCAN_LINES_TICK     = 100    -- scan-pass lines per tick
-- ... and when the same pass is also accumulating the summary. A line then costs about 3.5
-- times what an index line costs -- one capture pattern across every column the summary
-- wants, plus its guards -- so the cap is set to put roughly the same work into a tick as
-- the index pass already does, rather than to a round number.
local STATS_LINES_TICK    = 30
local EXTRACT_LINES_TICK  = 80     -- extract-pass lines per tick
local IDX_EVERY           = 256    -- sparse index: one entry every N data lines
local SESSION_GAP_CS      = 3000   -- a forward jump over 30 s starts a new session
local MAX_LINE_LEN        = 1024   -- guard: a longer line is not a telemetry row
local DAY_CS              = 8640000
local MIN_SPAN_CS         = 200    -- closest zoom: a 2 s window
local PX_PER_BUCKET       = 4      -- horizontal resolution of the min/max envelope
local BASE_MULT           = 4      -- session copy is this much finer than the display
local CACHE_MAX           = 4      -- session copy plus three zoom windows
local N_GRID              = 6      -- vertical grid lines at round time steps
local HUGE                = math.huge
local EMPTY_PTS           = { { 0, 0 }, { 0, 0 } }  -- a line object needs two points

G.MAX_CURVES = 4

-- Curve colours. lcd.RGB is used where it exists so the four curves stay apart on
-- a dark page; the named constants are the fallback.
local function rgb(r, g, b, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local ok, col = pcall(lcd.RGB, r, g, b)
    if ok and col then return col end
  end
  return fallback
end

local CURVE_COLORS = nil
local function curveColors()
  if not CURVE_COLORS then
    CURVE_COLORS = {
      rgb(255, 190, 60, YELLOW),
      rgb(80, 200, 255, CYAN),
      rgb(120, 230, 120, GREEN),
      rgb(255, 130, 200, MAGENTA)
    }
  end
  return CURVE_COLORS
end

-- Column name sets offered before the user picks by hand. A set is offered only
-- when the log actually carries at least two of its columns.
local TEMPLATES = {
  { key = "tpl_power",    cols = { "Vbat", "Curr", "Hspd", "EscT" } },
  { key = "tpl_battery",  cols = { "Vbat", "Vcel", "Curr", "Capa" } },
  { key = "tpl_link",     cols = { "1RSS", "2RSS", "RQly", "TPWR" } },
  { key = "tpl_governor", cols = { "Hspd", "Thr", "Vbat", "Curr" } }
}

local S = {}

local function resetState()
  S.path = nil
  S.fh = nil
  S.fsize = 0
  S.err = nil
  S.phase = nil
  S.progress = 0

  S.buf = nil
  S.bufpos = 1
  S.filePos = 0

  S.headerLine = nil
  S.columns = {}
  S.hparsePos = 1
  S.hparseCol = 1

  S.index = {}
  S.sessions = {}
  S.sessionIndex = 1
  S.curDate = nil
  S.day = 0
  S.prevT = 0
  S.nline = 0

  S.stats = nil
  S.statCol = nil
  S.statPat = nil
  S.statOrder = nil
  S.isTelemetry = true

  S.curves = {}
  S.wantCols = nil
  S.wantK = nil
  S.xpat = nil

  S.chartX, S.chartY, S.chartW, S.chartH = 0, 0, 0, 0
  S.nbuckets = 0
  S.baseNb = 0

  S.cache = {}
  S.scrMin, S.scrMax = {}, {}
  S.tgtMin, S.tgtMax = nil, nil
  S.extEntry = nil

  S.winT0, S.winT1, S.winSpan = 0, 0, 1
  S.cursorT = nil
  S.cursorX = 0

  S.points = {}
  S.curveEmpty = {}
  S.curveLo, S.curveHi = {}, {}
  S.grid = {}
end

resetState()

-- Feeds complete lines to onLine(line, offset) for at most maxIters iterations,
-- where a fed line and a chunk refill each count as one. Returns "cap" when the
-- caller should yield, "eof" at the end of the file, "stop" when onLine returned
-- false. The offset handed to onLine is the line's byte position in the file,
-- which is what the sparse index stores and what the seek pass restores.
local function pumpLines(onLine, maxIters)
  for _ = 1, maxIters do
    local buf = S.buf
    local nl = nil
    if buf ~= nil then nl = string.find(buf, "\n", S.bufpos, true) end
    if nl ~= nil then
      local lineOff = S.filePos - #buf + S.bufpos - 1
      local line = string.sub(buf, S.bufpos, nl - 1)
      S.bufpos = nl + 1
      if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
      if #line > 0 and #line <= MAX_LINE_LEN then
        if onLine(line, lineOff) == false then return "stop" end
      end
    else
      local rest = ""
      if buf ~= nil then rest = string.sub(buf, S.bufpos) end
      local data = io.read(S.fh, CHUNK_SIZE)
      if data == nil or data == "" then
        S.buf, S.bufpos = nil, 1
        if #rest > 0 and #rest <= MAX_LINE_LEN then
          onLine(rest, S.filePos - #rest)   -- a file whose last line has no newline
        end
        return "eof"
      end
      S.filePos = S.filePos + #data
      S.buf = rest .. data
      S.bufpos = 1
    end
  end
  return "cap"
end

local function failWith(message)
  if S.fh then pcall(io.close, S.fh) end
  S.fh = nil
  S.phase = nil
  S.err = message
end

local function headerLine(line)
  S.headerLine = line
  S.columns = {}
  S.hparsePos = 1
  S.hparseCol = 1
  return false                              -- one line is all this pass wants
end

-- Parse one header column. A label reads "Name(unit)"; the closing bracket is
-- removed with string.sub rather than gsub, because "(" and ")" are pattern
-- characters and gsub would read the label as a capture.
local function parseHeaderColumn()
  local line = S.headerLine
  local len = #line
  local pos = S.hparsePos
  if pos > len + 1 then return true end
  local comma = string.find(line, ",", pos, true)
  local stop = comma and (comma - 1) or len
  local label = string.sub(line, pos, stop)
  local par = string.find(label, "(", 1, true)
  if par ~= nil then
    local unit = string.sub(label, par + 1)
    if string.sub(unit, -1) == ")" then unit = string.sub(unit, 1, -2) end
    S.columns[S.hparseCol] = { name = string.sub(label, 1, par - 1), unit = unit }
  else
    S.columns[S.hparseCol] = { name = label, unit = "" }
  end
  S.hparseCol = S.hparseCol + 1
  S.hparsePos = comma and (comma + 1) or (len + 2)
  return S.hparsePos > len + 1
end

-- "HH:MM:SS.mm0" at a fixed width, to centiseconds.
local function parseTimeCs(s)
  local h = tonumber(string.sub(s, 1, 2))
  local mi = tonumber(string.sub(s, 4, 5))
  local se = tonumber(string.sub(s, 7, 8))
  local ms = tonumber(string.sub(s, 10, 12))
  if h == nil or mi == nil or se == nil or ms == nil then return nil end
  return ((h * 60 + mi) * 60 + se) * 100 + math.floor(ms / 10)
end

-- ---------------------------------------------------------------- flight statistics
--
-- The flight summary is accumulated by the SAME pass that builds the index, because both
-- want every line of the file and reading it twice is the whole cost of opening a log.
--
-- The column aliases, the value guards and the ARM-gated RPM branch below are the summary's
-- own rules and are kept exactly as they were, down to the last-match-wins resolution and
-- the fixed-index fallbacks -- so that moving the work does not also change what it reports.
-- Both of those are defects and neither is repaired here; repairing them changes values and
-- belongs in its own change, where the difference can be shown.

local STAT_KEYS = { "date", "time", "vbat", "curr", "capa", "hspd", "esct", "thr", "arm" }

local function statKeyFor(trimmed)
  if trimmed == "date" then return "date" end
  if trimmed == "time" then return "time" end
  if trimmed == "vbat(v)" or trimmed == "vbat" or trimmed == "vfas" or trimmed == "voltage" then
    return "vbat"
  end
  if trimmed == "curr(a)" or trimmed == "curr" or trimmed == "current" or trimmed == "amp" then
    return "curr"
  end
  if trimmed == "capa(mah)" or trimmed == "capa" or trimmed == "capacity" or trimmed == "smcp(mah)" then
    return "capa"
  end
  if trimmed == "hspd(rpm)" or trimmed == "hspd" or trimmed == "rpm" or trimmed == "headspeed" then
    return "hspd"
  end
  if string.find(trimmed, "esct") or string.find(trimmed, "esc_t")
     or string.find(trimmed, "temp_esc") or trimmed == "temp" then
    return "esct"
  end
  if trimmed == "thr(%)" or trimmed == "thr%" or trimmed == "throttle%"
     or trimmed == "throttle_percent" then
    return "thr"
  end
  -- Only the ARM sensor. ARMD is the arming *disable* flag mask (0x1203 in
  -- lib/rf2tlm_sensors.lua): it reads 0 while the model is armed, so taking it for the arm
  -- flag closes the RPM gate for the whole flight.
  if trimmed == "arm" then return "arm" end
  return nil
end

-- Which column carries which statistic, and one pattern that pulls all of them out of a
-- line in a single call. Columns nothing wants are skipped without a capture, so a log with
-- 111 columns costs what its wanted ones cost rather than what all of them cost.
local function prepareStats()
  local col = {}
  for c = 1, #S.columns do
    local entry = S.columns[c]
    if entry then
      local label = entry.name
      if entry.unit ~= "" then label = label .. "(" .. entry.unit .. ")" end
      local trimmed = string.lower(string.gsub(string.gsub(label, "^%s+", ""), "%s+$", ""))
      local k = statKeyFor(trimmed)
      if k then col[k] = c end              -- last match wins, as the summary has always done
    end
  end

  -- The summary's own fallbacks: a missing column is taken to be one of the first five.
  if not col.vbat then col.vbat = 1 end
  if not col.curr then col.curr = 2 end
  if not col.hspd then col.hspd = 3 end
  if not col.esct then col.esct = 4 end
  if not col.thr then col.thr = 5 end

  S.statCol = col

  -- Build the capture pattern over the union of the wanted columns, in column order.
  local wanted, order = {}, {}
  for i = 1, #STAT_KEYS do
    local k = STAT_KEYS[i]
    local c = col[k]
    if c and not wanted[c] then wanted[c] = true end
  end
  local cols = {}
  for c in pairs(wanted) do cols[#cols + 1] = c end
  table.sort(cols)
  local maxCol = cols[#cols] or 0

  local parts = {}
  local wi = 1
  for c = 1, maxCol do
    if c > 1 then parts[#parts + 1] = "," end
    if cols[wi] == c then
      parts[#parts + 1] = "([^,]*)"
      order[#order + 1] = c
      wi = wi + 1
    else
      parts[#parts + 1] = "[^,]*"
    end
  end
  S.statPat = "^" .. table.concat(parts)
  S.statOrder = order

  -- Where each statistic sits among the captures.
  local at = {}
  for i = 1, #order do at[order[i]] = i end
  S.statAt = {}
  for i = 1, #STAT_KEYS do
    local k = STAT_KEYS[i]
    if col[k] then S.statAt[k] = at[col[k]] end
  end

  S.stats = {
    startTimeSec = nil, endTimeSec = nil,
    vStart = nil, vMin = nil, vMax = nil, vEnd = nil,
    cPeak = 0, cSum = 0, cSamples = 0,
    lastCapa = nil,
    rMax = 0, rMinFlight = nil,
    tStart = nil, tMax = nil,
    thrMax = 0, totalSamples = 0
  }
end

-- The summary's time parse: seconds with a fractional part, and deliberately NOT the
-- index pass's fixed-width centisecond one -- the two round differently and the duration
-- is computed from this one.
local function parseTimeSec(tStr)
  if not tStr then return nil end
  local h, m, s, ms = string.match(tStr, "(%d+):(%d+):(%d+)%.?(%d*)")
  if h and m and s then
    local sec = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    if ms and ms ~= "" then
      sec = sec + (tonumber("0." .. ms) or 0)
    end
    return sec
  end
  return nil
end

-- A row the one-call pattern could not take, because it has fewer columns than the header
-- promised -- a truncated last line, most often. Split it the way the summary always did,
-- so such a row still contributes exactly what it used to.
local function statFieldsBySplit(line)
  local cols = {}
  for item in string.gmatch(line .. ",", "([^,]*),") do
    cols[#cols + 1] = item
  end
  local out = {}
  local col = S.statCol
  for i = 1, #STAT_KEYS do
    local k = STAT_KEYS[i]
    if col[k] then out[k] = cols[col[k]] end
  end
  return out
end

local function statsLine(line)
  local st = S.stats
  st.totalSamples = st.totalSamples + 1

  local f
  local caps = { string.match(line, S.statPat) }
  if caps[1] == nil then
    f = statFieldsBySplit(line)
  else
    f = {}
    local at = S.statAt
    for i = 1, #STAT_KEYS do
      local k = STAT_KEYS[i]
      if at[k] then f[k] = caps[at[k]] end
    end
  end

  if f.time then
    local tSec = parseTimeSec(f.time)
    if tSec then
      if not st.startTimeSec then st.startTimeSec = tSec end
      st.endTimeSec = tSec
    end
  end

  if f.vbat then
    local v = tonumber(f.vbat)
    if v and v > 2.0 then
      if not st.vStart then st.vStart = v end
      if not st.vMin or v < st.vMin then st.vMin = v end
      if not st.vMax or v > st.vMax then st.vMax = v end
      st.vEnd = v
    end
  end

  if f.curr then
    local c = tonumber(f.curr)
    if c and c >= 0 then
      if c > st.cPeak then st.cPeak = c end
      st.cSum = st.cSum + c
      st.cSamples = st.cSamples + 1
    end
  end

  if f.capa then
    local cap = tonumber(f.capa)
    if cap and cap > 0 then st.lastCapa = cap end
  end

  if f.esct then
    local tmp = tonumber(f.esct)
    if tmp and tmp > 0 then
      if not st.tStart then st.tStart = tmp end
      if not st.tMax or tmp > st.tMax then st.tMax = tmp end
    end
  end

  if f.thr then
    local thr = tonumber(f.thr)
    if thr and thr >= 0 and thr <= 100 then
      if thr > st.thrMax then st.thrMax = thr end
    end
  end

  -- RPM, only while the motor is actually driving the head: a spool-down or an
  -- autorotation would otherwise set the minimum.
  if f.hspd then
    local r = tonumber(f.hspd)
    if r and r > 0 then
      local cVal = f.curr and tonumber(f.curr) or 0
      local thrVal = f.thr and tonumber(f.thr) or 0
      local armVal = f.arm and tonumber(f.arm) or 1

      -- ARM is a bit field: bit 0 is ARMED, bit 1 only records that the model was armed at
      -- some point, so it stays set after a disarm. lib/audio.lua tests the same bit.
      local isArmed = (math.floor(armVal) % 2) == 1
      local isPowered = isArmed and ((thrVal >= 25) or (cVal >= 1.5))
      if isPowered then
        if r > st.rMax then st.rMax = r end
        if r > 1000 then
          if not st.rMinFlight or r < st.rMinFlight then st.rMinFlight = r end
        end
      end
    end
  end
end

local function scanLine(line, off)
  if S.stats then statsLine(line) end
  local date, ts = string.match(line, "^([^,]*),([^,]*)")
  if date == nil then return end
  local tcs = parseTimeCs(ts)
  if tcs == nil then return end             -- a header or a malformed row
  if date ~= S.curDate then
    if S.curDate ~= nil then S.day = S.day + 1 end
    S.curDate = date
  end
  local t = S.day * DAY_CS + tcs
  local sessions = S.sessions
  local s = sessions[#sessions]
  if s == nil or t < S.prevT or (t - S.prevT) > SESSION_GAP_CS then
    s = { t0 = t, t1 = t, lines = 0 }
    sessions[#sessions + 1] = s
  end
  s.t1 = t
  s.lines = s.lines + 1
  S.prevT = t
  S.nline = S.nline + 1
  if S.nline % IDX_EVERY == 1 then
    S.index[#S.index + 1] = { off = off, t = t, day = S.day, date = date }
  end
end

-- Last sparse-index entry at or before t.
local function indexBefore(t0)
  local idx = S.index
  local lo, hi, best = 1, #idx, idx[1]
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if idx[mid].t <= t0 then
      best = idx[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best
end

-- One precompiled pattern pulls Date, Time and the wanted columns out of a line
-- in a single call. Columns that are not wanted are skipped without a capture,
-- which is what keeps a curve on column 90 as cheap as one on column 4.
local function prepareWanted()
  local cols, keys = {}, {}
  for k = 1, #S.curves do
    cols[#cols + 1] = S.curves[k].col
    keys[#keys + 1] = k
  end
  for i = 2, #cols do                       -- insertion sort, at most four entries
    local c, s, j = cols[i], keys[i], i - 1
    while j >= 1 and cols[j] > c do
      cols[j + 1], keys[j + 1] = cols[j], keys[j]
      j = j - 1
    end
    cols[j + 1], keys[j + 1] = c, s
  end
  S.wantCols, S.wantK = cols, keys

  local parts = { "^([^,]*),([^,]*)" }
  local wi = 1
  for col = 3, cols[#cols] or 2 do
    if cols[wi] == col then
      parts[#parts + 1] = ",([^,]*)"
      wi = wi + 1
    else
      parts[#parts + 1] = ",[^,]*"
    end
  end
  S.xpat = table.concat(parts)
end

local function accumulate(wi, bi, s)
  local v = tonumber(s)
  if v == nil then return end
  local k = S.wantK[wi]
  local bmin, bmax = S.tgtMin[k], S.tgtMax[k]
  if v < bmin[bi] then bmin[bi] = v end
  if v > bmax[bi] then bmax[bi] = v end
end

local function extractLine(line)
  local date, ts, s1, s2, s3, s4 = string.match(line, S.xpat)
  if date == nil then return end
  local tcs = parseTimeCs(ts)
  if tcs == nil then return end
  if date ~= S.curDate then
    S.day = S.day + 1
    S.curDate = date
  end
  local t = S.day * DAY_CS + tcs
  if t < S.extT0 then return end
  if t > S.extStopT then return false end   -- past the window: the pass is done
  -- Float arithmetic on purpose: a long session in centiseconds leaves the range
  -- an integer bucket index could be computed in safely.
  local bi = math.floor(((t - S.extT0) / S.extSpan) * (S.extNb - 1)) + 1
  if bi < 1 then bi = 1 elseif bi > S.extNb then bi = S.extNb end
  if s1 ~= nil then accumulate(1, bi, s1) end
  if s2 ~= nil then accumulate(2, bi, s2) end
  if s3 ~= nil then accumulate(3, bi, s3) end
  if s4 ~= nil then accumulate(4, bi, s4) end
end

local function cacheAlloc(t0, t1, nb)
  local e = {
    t0 = t0, t1 = t1, nb = nb,
    span = (t1 - t0 > 0) and (t1 - t0) or 1,
    min = {}, max = {}
  }
  for k = 1, #S.curves do e.min[k] = {}; e.max[k] = {} end
  return e
end

-- The coarsest cached window that contains [t0,t1] and is at least as fine as the
-- display. Coarsest keeps the re-bucketing walk short; "at least as fine" is what
-- stops a zoom-in from inventing detail the cached copy never held.
local function cacheFind(t0, t1)
  local displayBw = (t1 - t0) / math.max(1, S.nbuckets - 1)
  if displayBw <= 0 then displayBw = 1 end
  local best, bestBw
  for i = 1, #S.cache do
    local e = S.cache[i]
    if e.t0 <= t0 and e.t1 >= t1 then
      local bw = e.span / math.max(1, e.nb - 1)
      if bw <= displayBw and (best == nil or bw > bestBw) then best, bestBw = e, bw end
    end
  end
  return best
end

local function cacheAdd(e)
  if e == nil then return end
  if e.nb == S.baseNb then
    S.cache[1] = e                          -- the session copy, never evicted
  else
    S.cache[#S.cache + 1] = e
    while #S.cache > CACHE_MAX do table.remove(S.cache, 2) end
  end
end

local function rebucketCurve(src, k)
  local nb = S.nbuckets
  local dmn, dmx = S.scrMin[k], S.scrMax[k]
  local smn, smx = src.min[k], src.max[k]
  local wt0, wsp = S.winT0, S.winSpan
  local snb, st0, ssp = src.nb, src.t0, src.span
  for i = 1, nb do
    local ta = wt0 + (i - 1) / (nb - 1) * wsp
    local tb = wt0 + i / (nb - 1) * wsp
    local ja = math.floor((ta - st0) / ssp * (snb - 1)) + 1
    local jb = math.floor((tb - st0) / ssp * (snb - 1)) + 1
    if ja < 1 then ja = 1 end
    if jb > snb then jb = snb end
    if jb < ja then jb = ja end
    local mn, mx = HUGE, -HUGE
    for j = ja, jb do
      local a, b = smn[j], smx[j]
      if a and a < mn then mn = a end
      if b and b > mx then mx = b end
    end
    dmn[i], dmx[i] = mn, mx
  end
end

-- Start showing [t0,t1]. Served from the cache when one entry holds it; otherwise
-- the whole session is read once at the base resolution, or a finer window is read
-- and kept.
local function beginExtract(t0, t1)
  local s = S.sessions[S.sessionIndex]
  if s == nil or S.nbuckets < 2 then return end
  S.winT0, S.winT1 = t0, t1
  S.winSpan = (t1 - t0 > 0) and (t1 - t0) or 1
  S.extEntry = nil

  local src = cacheFind(t0, t1)
  if src ~= nil then
    S.rbSrc, S.rbK = src, 1
    S.phase = "rebkt"
    S.progress = 0
    return
  end

  local full = (t0 <= s.t0 and t1 >= s.t1)
  local e0, e1, nb
  if full then
    e0, e1, nb = s.t0, s.t1, S.baseNb
  else
    e0, e1, nb = t0, t1, S.nbuckets
  end
  local e = cacheAlloc(e0, e1, nb)
  S.extEntry = e
  S.tgtMin, S.tgtMax = e.min, e.max
  S.extT0 = e0
  S.extSpan = (e1 - e0 > 0) and (e1 - e0) or 1
  S.extNb = nb
  S.extStopT = e1
  S.seekTo = indexBefore(e0)
  S.progBase = S.seekTo and S.seekTo.off or 0
  S.resetK = 1
  S.phase = "reset"
  S.progress = 0
end

-- A min/max envelope: two points per bucket, so a spike between two samples is
-- drawn rather than averaged away. The coordinates are absolute page pixels,
-- because a line object takes its own position from the smallest point it was
-- given and ignores any offset passed beside them.
local function buildPoints(k)
  local nb, h = S.nbuckets, S.chartH
  local x0, y0 = S.chartX, S.chartY
  local bmin, bmax = S.tgtMin[k], S.tgtMax[k]
  local lo, hi = HUGE, -HUGE
  for i = 1, nb do
    local a, b = bmin[i], bmax[i]
    if a and a < lo then lo = a end
    if b and b > hi then hi = b end
  end
  if lo > hi then
    S.curveLo[k], S.curveHi[k] = nil, nil
    S.points[k] = EMPTY_PTS
    S.curveEmpty[k] = true
    return
  end
  local pad = (hi - lo) * 0.05
  lo, hi = lo - pad, hi + pad
  if hi - lo < 1e-6 then                    -- a flat curve, drawn down the middle
    lo, hi = lo - 0.5, hi + 0.5
  end
  local scale = h / (hi - lo)
  local pts, n = {}, 0
  local lastMin, lastMax = nil, nil
  for i = 1, nb do
    local mn, mx = bmin[i], bmax[i]
    if mn == nil or mx == nil or mn > mx then mn, mx = lastMin, lastMax end
    if mn ~= nil then
      lastMin, lastMax = mn, mx
      local x = x0 + (i - 1) * PX_PER_BUCKET
      local ya = math.floor(h - (mx - lo) * scale + 0.5)
      local yb = math.floor(h - (mn - lo) * scale + 0.5)
      if ya < 0 then ya = 0 elseif ya > h then ya = h end
      if yb < 0 then yb = 0 elseif yb > h then yb = h end
      n = n + 1; pts[n] = { x, y0 + ya }
      n = n + 1; pts[n] = { x, y0 + yb }
    end
  end
  S.curveLo[k], S.curveHi[k] = lo, hi
  if n >= 2 then
    S.points[k] = pts
    S.curveEmpty[k] = false
  else
    S.points[k] = EMPTY_PTS
    S.curveEmpty[k] = true
  end
end

local function formatOffset(cs)
  local s = math.floor(cs / 100)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
G.formatOffset = formatOffset

local function buildGrid()
  local span = S.winSpan
  local steps = { 100, 200, 500, 1000, 3000, 6000, 12000, 30000, 60000, 120000, 300000 }
  local step = steps[#steps]
  for i = 1, #steps do
    if span / steps[i] <= N_GRID then step = steps[i]; break end
  end
  local s0 = S.sessions[S.sessionIndex].t0
  local grid = {}
  local t = (math.floor((S.winT0 - s0) / step) + 1) * step + s0
  while t < S.winT1 and #grid < N_GRID do
    local x = S.chartX + math.floor(((t - S.winT0) / span) * S.chartW)
    grid[#grid + 1] = { x = x, label = formatOffset(t - s0) }
    t = t + step
  end
  S.grid = grid
end

local function updateCursor(t)
  if t == nil then return end
  if t < S.winT0 then t = S.winT0 end
  if t > S.winT1 then t = S.winT1 end
  S.cursorT = t
  S.cursorX = S.chartX + math.floor(((t - S.winT0) / S.winSpan) * S.chartW)
end

-- What identifies the file this engine is holding. A log still being written grows, so the
-- size is part of it and a re-open of a file that has changed is a real re-open.
local function identity(path)
  local info = (type(fstat) == "function") and fstat(path) or nil
  return path, (info and tonumber(info.size)) or 0
end

--- Start reading `path`.
--
-- `opts.stats` accumulates the flight summary during the index pass, so that a caller
-- wanting the summary and a caller wanting the plot cost one walk between them rather
-- than one each.
--
-- Re-opening the file this engine already holds, with the index already built, is a no-op:
-- the sessions and the summary are still there and re-reading the card would produce the
-- same ones. That is what lets the plot open on a log whose summary has just been read
-- without touching the card again.
function G.open(path, opts)
  local wantStats = opts and opts.stats or false
  local p, size = identity(path)

  if S.path == p and S.fsize == size and S.err == nil and S.phase == nil
     and #S.index > 0 and #S.sessions > 0 and (not wantStats or S.stats ~= nil) then
    -- The walk is done and its result is still held. Only the handle may be missing, and
    -- the extract pass needs one; re-open it rather than re-reading the file.
    if S.fh == nil then
      local fh = io.open(path, "r")
      if not fh then
        S.err = "open"
        return false
      end
      S.fh = fh
      S.buf, S.bufpos, S.filePos = nil, 1, 0
    end
    return true
  end

  G.close()
  resetState()
  S.path = p
  S.fsize = size
  local fh = io.open(path, "r")
  if not fh then
    S.err = "open"
    return false
  end
  S.fh = fh
  S.wantStats = wantStats
  S.phase = "header"
  return true
end

function G.close()
  if S.fh then pcall(io.close, S.fh) end
  S.fh = nil
  S.phase = nil
  S.cache = {}
  S.index = {}
  S.points = {}
  S.scrMin, S.scrMax = {}, {}
  S.tgtMin, S.tgtMax = nil, nil
  S.extEntry = nil
end

function G.isOpen() return S.path ~= nil end
function G.isBusy() return S.phase ~= nil end
function G.isTelemetry() return S.isTelemetry end

--- The flight summary, once the index pass has run, or nil if this log has no data rows.
--
-- The derived fields are computed here rather than per line: a duration that cannot be read
-- off the timestamps falls back to the sample count at the logger's nominal 10 Hz, and the
-- consumption falls back to the average current over the duration when the log carries no
-- capacity column.
function G.getSummary()
  local st = S.stats
  if st == nil or S.phase ~= nil then return nil end
  if st.totalSamples == 0 then return nil end

  local durationSec = 0
  if st.startTimeSec and st.endTimeSec and st.endTimeSec >= st.startTimeSec then
    durationSec = math.floor(st.endTimeSec - st.startTimeSec)
  else
    durationSec = math.floor(st.totalSamples / 10)
  end

  local durationMin = math.floor(durationSec / 60)
  local durationRemSec = durationSec % 60
  local durationStr = string.format("%02d:%02d min", durationMin, durationRemSec)

  local cAvg = st.cSamples > 0 and (st.cSum / st.cSamples) or 0
  local consumedMah = st.lastCapa
    or ((st.cSum / (st.cSamples > 0 and st.cSamples or 1)) * (durationSec / 3600) * 1000)

  return {
    sampleCount = st.totalSamples,
    durationStr = durationStr,
    vStart = st.vStart or 0,
    vMin = st.vMin or (st.vStart or 0),
    vMax = st.vMax or (st.vStart or 0),
    vEnd = st.vEnd or (st.vStart or 0),
    vSag = ((st.vStart or 0) > (st.vMin or 0)) and ((st.vStart or 0) - (st.vMin or 0)) or 0,
    cPeak = st.cPeak,
    cAvg = cAvg,
    mah = consumedMah,
    rMax = st.rMax,
    rMin = st.rMinFlight or 0,
    tStart = st.tStart or 0,
    tMax = st.tMax or (st.tStart or 0),
    thrMax = st.thrMax
  }
end
function G.getError() return S.err end
function G.getPhase() return S.phase end
function G.getPath() return S.path end

function G.getProgress()
  local p = S.progress or 0
  if p < 0 then p = 0 elseif p > 1 then p = 1 end
  return p
end

-- Geometry is the page's to decide, and it is only known inside its build. A
-- change invalidates every bucket array, so the cache is dropped and the current
-- window read again rather than stretched.
function G.setGeometry(x, y, w, h)
  local nb = math.floor(w / PX_PER_BUCKET)
  if nb < 2 then nb = 2 end
  local same = (S.chartX == x and S.chartY == y and S.chartW == w and S.chartH == h)
  S.chartX, S.chartY, S.chartW, S.chartH = x, y, w, h
  if same then return false end
  S.nbuckets = nb
  S.baseNb = nb * BASE_MULT
  S.cache = {}
  for k = 1, #S.curves do
    S.scrMin[k], S.scrMax[k] = {}, {}
  end
  if #S.curves > 0 and S.sessions[S.sessionIndex] then
    beginExtract(S.winT0, S.winT1)
  end
  return true
end

function G.getColumns()
  local out = {}
  for c = 3, #S.columns do
    local col = S.columns[c]
    if col and col.name ~= "" then
      out[#out + 1] = { col = c, name = col.name, unit = col.unit }
    end
  end
  return out
end

function G.getSessions() return S.sessions end
function G.getSessionIndex() return S.sessionIndex end

function G.selectSession(i)
  local s = S.sessions[i]
  if not s then return false end
  S.sessionIndex = i
  S.cache = {}
  S.cursorT = nil
  if #S.curves > 0 then
    beginExtract(s.t0, s.t1)
  end
  return true
end

-- Which of the offered column sets this log can actually serve, with the columns
-- each one resolves to. A set needs two matches to be worth offering.
function G.getTemplates()
  local out = {}
  local byName = {}
  for c = 3, #S.columns do
    local col = S.columns[c]
    if col and col.name ~= "" and byName[col.name] == nil then byName[col.name] = c end
  end
  for i = 1, #TEMPLATES do
    local tpl = TEMPLATES[i]
    local cols = {}
    for j = 1, #tpl.cols do
      local c = byName[tpl.cols[j]]
      if c then cols[#cols + 1] = c end
    end
    if #cols >= 2 then
      out[#out + 1] = { key = tpl.key, cols = cols }
    end
  end
  return out
end

-- Show these columns. The list is truncated to the four the envelope pattern can
-- capture in one pass.
function G.applyColumns(colIndices)
  if S.nbuckets < 2 then return false end
  local s = S.sessions[S.sessionIndex]
  if s == nil then return false end

  local curves = {}
  for i = 1, #colIndices do
    if #curves >= G.MAX_CURVES then break end
    local c = colIndices[i]
    local col = S.columns[c]
    if col then
      curves[#curves + 1] = { col = c, name = col.name, unit = col.unit }
    end
  end
  if #curves == 0 then return false end

  S.curves = curves
  prepareWanted()
  S.scrMin, S.scrMax = {}, {}
  S.points, S.curveEmpty = {}, {}
  S.curveLo, S.curveHi = {}, {}
  S.cache, S.extEntry = {}, nil
  for k = 1, #curves do
    S.scrMin[k], S.scrMax[k] = {}, {}
    S.points[k] = EMPTY_PTS
    S.curveEmpty[k] = true
  end
  S.cursorT = nil
  beginExtract(s.t0, s.t1)
  return true
end

function G.getCurves() return S.curves end

function G.getCurveColor(k)
  local colors = curveColors()
  return colors[((k - 1) % #colors) + 1]
end

function G.getPoints(k) return S.points[k] or EMPTY_PTS end
function G.isCurveEmpty(k) return S.curveEmpty[k] ~= false end
function G.getCurveRange(k) return S.curveLo[k], S.curveHi[k] end
function G.getGrid() return S.grid end

function G.getWindow()
  local s = S.sessions[S.sessionIndex]
  return S.winT0, S.winT1, s and s.t0 or 0, s and s.t1 or 0
end

function G.getCursorX() return S.cursorX end

-- Value under the cursor per curve. The bucket maximum is reported: with a
-- min/max envelope there is no single value to report, and the peak is the one a
-- pilot is looking for.
function G.getReadout()
  local out = {}
  if S.cursorT == nil or S.nbuckets < 2 then return out end
  local bi = math.floor(((S.cursorT - S.winT0) / S.winSpan) * (S.nbuckets - 1)) + 1
  if bi < 1 then bi = 1 elseif bi > S.nbuckets then bi = S.nbuckets end
  for k = 1, #S.curves do
    local c = S.curves[k]
    local v = S.tgtMax and S.tgtMax[k] and S.tgtMax[k][bi] or nil
    if S.curveEmpty[k] or v == nil or v == -HUGE then v = nil end
    out[k] = { name = c.name, unit = c.unit, value = v }
  end
  return out
end

function G.getCursorTimeText()
  local s = S.sessions[S.sessionIndex]
  if S.cursorT == nil or s == nil then return nil end
  return formatOffset(S.cursorT - s.t0)
end

function G.zoom(dir)
  if S.phase ~= nil or #S.curves == 0 then return end
  local s = S.sessions[S.sessionIndex]
  if s == nil then return end
  local span = S.winT1 - S.winT0
  local center = S.cursorT or (S.winT0 + math.floor(span / 2))
  local newSpan
  if dir > 0 then
    newSpan = math.floor(span / 2)
    if newSpan < MIN_SPAN_CS then newSpan = MIN_SPAN_CS end
  else
    newSpan = span * 2
  end
  if newSpan >= (s.t1 - s.t0) then
    beginExtract(s.t0, s.t1)
    return
  end
  local t0 = center - math.floor(newSpan / 2)
  if t0 < s.t0 then t0 = s.t0 end
  local t1 = t0 + newSpan
  if t1 > s.t1 then
    t1 = s.t1
    t0 = t1 - newSpan
  end
  beginExtract(t0, t1)
end

function G.zoomFull()
  if S.phase ~= nil or #S.curves == 0 then return end
  local s = S.sessions[S.sessionIndex]
  if s == nil then return end
  if S.winT0 <= s.t0 and S.winT1 >= s.t1 then return end
  beginExtract(s.t0, s.t1)
end

function G.pan(dir)
  if S.phase ~= nil or #S.curves == 0 then return end
  local s = S.sessions[S.sessionIndex]
  if s == nil then return end
  local span = S.winT1 - S.winT0
  if span >= (s.t1 - s.t0) then return end
  local t0 = S.winT0 + math.floor(span / 2) * dir
  if t0 < s.t0 then t0 = s.t0 end
  local t1 = t0 + span
  if t1 > s.t1 then
    t1 = s.t1
    t0 = t1 - span
  end
  if t0 == S.winT0 then return end
  beginExtract(t0, t1)
end

-- The cursor steps by whole display buckets, which is the finest position the
-- readout can distinguish.
function G.moveCursor(buckets)
  if #S.curves == 0 or S.nbuckets < 2 then return false end
  local step = (S.winSpan / (S.nbuckets - 1)) * buckets
  updateCursor((S.cursorT or S.winT0) + step)
  return true
end

function G.setCursorFraction(f)
  if #S.curves == 0 then return false end
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  updateCursor(S.winT0 + math.floor(f * S.winSpan))
  return true
end

-- One capped unit of work. Returns true when the page has something new to draw.
function G.tick()
  local ph = S.phase
  if ph == nil or S.fh == nil then return false end

  if ph == "header" then
    local r = pumpLines(headerLine, HEADER_ITERS_TICK)
    if S.headerLine ~= nil then
      S.phase = "hparse"
    elseif r == "eof" then
      failWith("empty")
      return true
    end
    return false
  end

  if ph == "hparse" then
    local done = false
    for _ = 1, HPARSE_COLS_TICK do
      if parseHeaderColumn() then
        done = true
        break
      end
    end
    if done then
      S.headerLine = nil
      local cols = S.columns
      S.isTelemetry = (cols[1] and cols[1].name == "Date" and cols[2] and cols[2].name == "Time")
                      and true or false
      if S.wantStats then prepareStats() end
      if not S.isTelemetry then
        -- The plot needs Date and Time; the summary never did, and reported on whatever
        -- columns it could resolve. So a caller after the summary walks the file anyway,
        -- and only a caller after a plot is refused.
        if not S.wantStats then
          failWith("not_telemetry")
          return true
        end
      end
      S.phase = "scan"
    end
    return false
  end

  if ph == "scan" then
    local r = pumpLines(scanLine, S.stats and STATS_LINES_TICK or SCAN_LINES_TICK)
    if S.fsize > 0 then S.progress = S.filePos / S.fsize end
    if r == "eof" then
      if #S.sessions == 0 and not S.stats then
        failWith("no_data")
        return true
      end
      S.sessionIndex = #S.sessions          -- the most recent flight in the file
      if S.sessionIndex < 1 then S.sessionIndex = 1 end
      S.phase = nil
      S.progress = 1
      return true
    end
    return false
  end

  if ph == "reset" then
    local k = S.resetK or 1
    local bmin, bmax = S.tgtMin[k], S.tgtMax[k]
    for i = 1, S.extNb do
      bmin[i] = HUGE
      bmax[i] = -HUGE
    end
    if k >= #S.curves then
      S.resetK = nil
      S.phase = "seek"
    else
      S.resetK = k + 1
    end
    return false
  end

  if ph == "seek" then
    local e = S.seekTo
    if e == nil then
      failWith("no_data")
      return true
    end
    io.seek(S.fh, e.off)
    S.filePos = e.off
    S.buf, S.bufpos = nil, 1
    S.curDate, S.day = e.date, e.day
    S.phase = "extract"
    return false
  end

  if ph == "extract" then
    local r = pumpLines(extractLine, EXTRACT_LINES_TICK)
    if S.fsize > S.progBase then
      S.progress = (S.filePos - S.progBase) / (S.fsize - S.progBase)
    end
    if r == "eof" or r == "stop" then
      cacheAdd(S.extEntry)
      S.rbSrc, S.rbK, S.extEntry = S.extEntry, 1, nil
      S.phase = "rebkt"
    end
    return false
  end

  if ph == "rebkt" then
    local k = S.rbK
    if k > #S.curves then
      S.tgtMin, S.tgtMax = S.scrMin, S.scrMax
      S.ptsK = 1
      S.phase = "pts"
    else
      rebucketCurve(S.rbSrc, k)
      S.rbK = k + 1
    end
    return false
  end

  if ph == "pts" then
    local k = S.ptsK
    if k > #S.curves then
      buildGrid()
      updateCursor(S.cursorT or (S.winT0 + math.floor(S.winSpan / 2)))
      S.phase = nil
      S.progress = 1
      return true                           -- the page redraws with the new points
    end
    buildPoints(k)
    S.ptsK = k + 1
    return false
  end

  return false
end

return G
