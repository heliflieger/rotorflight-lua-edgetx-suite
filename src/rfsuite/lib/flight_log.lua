-- Flight log data core.
--
-- Two files under the user directory, both meant to be readable and editable off the radio:
--
--   flights.csv    append-only, one line per flight. The header is written when the file is
--                  created and never again, so a line appended to an existing file carries no
--                  header of its own. A line is
--                    date,time,model,battery_id,flight_s[,<statistics columns>]
--                  and the statistics columns are optional: a five-column line is valid and is
--                  what this suite writes today.
--   batteries.cfg  the pilot's own battery registry, one pack per line,
--                    id=<unique>;name=<label>;cap=<mAh>;models=<name,name|*>;profile=<1-6>;
--                    cycles=<n>;last=<YYYY-MM-DD>
--                  `#` starts a comment line, `models` empty or `*` means every model, and a
--                  duplicate id is resolved in favour of the first line carrying it.
--
-- Every write to the registry is line surgery, never a regeneration: only the edited line
-- changes and comments, unknown fields and the file's own line endings survive byte for byte.
-- The replace is atomic (write `.new`, verify its size, park the original as `.bak`, rename),
-- because this is a file the pilot maintains by hand and a truncating in-place rewrite that is
-- interrupted loses all of it.
--
-- io.write reports nothing when the card is full, so every write is verified through fstat by
-- the number of bytes the file grew.

local M = {}

local USER_ROOT = "/SCRIPTS/TOOLS/rfsuite.user"
local DATA_DIR = USER_ROOT .. "/flightlog"

-- The registry is read whole, so it needs a ceiling: a file above this is refused rather than
-- read short, because a truncated read written back would be the file the pilot loses.
local READ_CAP = 65536
local READ_CHUNK = 4096

M.READ_CAP = READ_CAP

-- The columns that may follow flight_s, as one ordered list so the writer, the header and the
-- parser cannot drift apart. Nothing in this suite fills them yet; they are here because the
-- file format is shared with tools that already read them.
M.STAT_KEYS = {
  "mah",
  "vcel_min", "vcel_max",
  "hs1_min", "hs1_max", "hs2_min", "hs2_max", "hs3_min", "hs3_max",
  "curr_min", "curr_max", "tesc_min", "tesc_max",
  "vbec_min", "vbec_max", "sags", "sag_min"
}

local STAT_FORMAT = {
  mah = "%d",
  vcel_min = "%.2f", vcel_max = "%.2f",
  hs1_min = "%.0f", hs1_max = "%.0f",
  hs2_min = "%.0f", hs2_max = "%.0f",
  hs3_min = "%.0f", hs3_max = "%.0f",
  curr_min = "%.1f", curr_max = "%.1f",
  tesc_min = "%.0f", tesc_max = "%.0f",
  vbec_min = "%.2f", vbec_max = "%.2f",
  sags = "%d", sag_min = "%.2f"
}

local CSV_HEADER = "date,time,model,battery_id,flight_s," .. table.concat(M.STAT_KEYS, ",") .. "\n"

M.CSV_HEADER = CSV_HEADER

local function trim(s)
  return string.match(tostring(s or ""), "^%s*(.-)%s*$")
end

-- mkdir is a bare global of the firmware's filesystem library, like dir, fstat, del and
-- rename; there is no os table in this interpreter. It creates one level at a time and
-- returns an FRESULT where 8 means the directory is already there, so nothing here has to
-- tell success from "exists". Same shape as lib/log_sink.lua.
local function makeDir(path)
  if type(mkdir) ~= "function" then return end
  if type(path) ~= "string" or path == "" then return end
  pcall(mkdir, path)
end

local function ensureDir()
  makeDir(USER_ROOT)
  makeDir(DATA_DIR)
end

M.ensureDir = ensureDir

function M.dataPath()
  return DATA_DIR
end

function M.csvPath()
  return DATA_DIR .. "/flights.csv"
end

function M.registryPath()
  return DATA_DIR .. "/batteries.cfg"
end

local function fileSize(path)
  if type(fstat) ~= "function" then return nil end
  local ok, st = pcall(fstat, path)
  if not ok or type(st) ~= "table" then return nil end
  return tonumber(st.size)
end

-- Reads a whole file in chunks, up to `cap`. io.read hands back at most what is asked for and
-- answers nil OR "" once the file is exhausted, so both have to end the loop.
local function readAll(path, cap)
  local f = io.open(path, "r")
  if not f then return nil end
  local parts = {}
  local total = 0
  while total < cap do
    local chunk = io.read(f, READ_CHUNK)
    if chunk == nil or chunk == "" then break end
    parts[#parts + 1] = chunk
    total = total + #chunk
  end
  io.close(f)
  if #parts == 0 then return nil end
  return table.concat(parts)
end

function M.formatDate(dt)
  if type(dt) ~= "table" then return "" end
  return string.format("%04d-%02d-%02d", dt.year or 0, dt.mon or 0, dt.day or 0)
end

function M.formatTime(dt)
  if type(dt) ~= "table" then return "" end
  return string.format("%02d:%02d:%02d", dt.hour or 0, dt.min or 0, dt.sec or 0)
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

-- Returns an array of { id, name, cap, models (lower case), profile, cycles, last }. A missing
-- file is an empty registry, not an error. Duplicate ids: the first line wins, because the
-- format declares the id unique and keeping both would show two packs of which only one is
-- ever stamped.
function M.loadRegistry()
  local list = {}
  local seen = {}
  local data = readAll(M.registryPath(), READ_CAP) or ""
  for line in string.gmatch(data, "[^\r\n]+") do
    if string.match(line, "^%s*#") == nil and string.find(line, "=", 1, true) ~= nil then
      local entry = {}
      -- The loop variables of a generic for are constants, so the key and the value are
      -- normalised into locals of their own rather than reassigned.
      for rawKey, rawValue in string.gmatch(line, "([%w_]+)%s*=%s*([^;]*)") do
        local key = string.lower(rawKey)
        local value = trim(rawValue)
        if key == "id" then
          entry.id = value
        elseif key == "name" then
          entry.name = value
        elseif key == "cap" then
          entry.cap = tonumber(value)
        elseif key == "models" then
          local models = {}
          for name in string.gmatch(value, "[^,]+") do
            local normalized = string.lower(trim(name))
            if normalized ~= "" then models[#models + 1] = normalized end
          end
          entry.models = models
        elseif key == "profile" then
          entry.profile = tonumber(value)
        elseif key == "cycles" then
          entry.cycles = tonumber(value) or 0
        elseif key == "last" then
          entry.last = value
        end
      end
      if entry.id ~= nil and entry.id ~= "" and not seen[entry.id] then
        seen[entry.id] = true
        list[#list + 1] = entry
      end
    end
  end
  return list
end

-- The packs offered for one craft: a pack matches when its model list holds the craft's name
-- case-insensitively, holds "*", or is empty -- an empty list means every model.
function M.forModel(registry, modelName)
  local want = string.lower(trim(modelName))
  local out = {}
  for i = 1, #(registry or {}) do
    local entry = registry[i]
    local models = entry.models
    local hit = (models == nil or #models == 0)
    if not hit then
      for j = 1, #models do
        if models[j] == "*" or (want ~= "" and models[j] == want) then
          hit = true
          break
        end
      end
    end
    if hit then out[#out + 1] = entry end
  end
  return out
end

function M.findById(registry, id)
  local want = trim(id)
  if want == "" then return nil end
  for i = 1, #(registry or {}) do
    if trim(registry[i].id) == want then return registry[i] end
  end
  return nil
end

-- The smallest free positive integer, which is the style a hand-maintained registry is
-- numbered in.
function M.freeId(registry)
  local used = {}
  for i = 1, #(registry or {}) do
    used[trim(registry[i].id)] = true
  end
  local n = 1
  while used[tostring(n)] do n = n + 1 end
  return tostring(n)
end

-- The pack chosen for one model, out of that model's own preference store.
--
-- The store is an INI file and its reader turns anything that looks like a number into one, so a
-- pack whose id is "1" comes back as the NUMBER 1 and a plain string test on it is false. The
-- conversion is undone here rather than at each caller, and this is the one place it is visible:
-- an all-digit id with a leading zero does not survive that round trip, which is why the ids this
-- file hands out are plain integers.
function M.storedBatteryId(modelPreferences)
  local section = type(modelPreferences) == "table" and modelPreferences.flightlog or nil
  local value = type(section) == "table" and section.battery or nil
  if type(value) == "number" then value = string.format("%s", value) end
  if type(value) ~= "string" then return nil end
  value = trim(value)
  if value == "" then return nil end
  return value
end

-- ---------------------------------------------------------------------------
-- Flight lines
-- ---------------------------------------------------------------------------

local function statField(stats, key)
  local value = stats and stats[key]
  if type(value) ~= "number" then return "" end
  return string.format(STAT_FORMAT[key] or "%s", value)
end

-- Appends one flight. `dt` is the getDateTime() table taken when the craft armed, so the line
-- carries the flight's start rather than its end. `stats` may be nil, and then the line is the
-- five-column form.
--
-- Returns true only when the file grew by exactly the bytes written: on a full card io.write
-- reports nothing at all, and a caller that believes it wrote a line it did not is the one
-- thing this file cannot afford.
function M.appendFlight(dt, modelName, batteryId, seconds, stats)
  ensureDir()
  local path = M.csvPath()
  local before = fileSize(path) or 0
  local f = io.open(path, "a")
  if not f then return false end

  local expected = before
  if before == 0 then
    io.write(f, CSV_HEADER)
    expected = expected + #CSV_HEADER
  end

  -- A comma in free text would open a column that is not there.
  local model = string.gsub(tostring(modelName or ""), ",", " ")
  local battery = string.gsub(tostring(batteryId or ""), ",", " ")
  local line = string.format("%s,%s,%s,%s,%d",
    M.formatDate(dt), M.formatTime(dt), model, battery, math.floor(tonumber(seconds) or 0))
  if stats ~= nil then
    for i = 1, #M.STAT_KEYS do
      line = line .. "," .. statField(stats, M.STAT_KEYS[i])
    end
  end
  line = line .. "\n"
  io.write(f, line)
  io.close(f)

  local after = fileSize(path)
  if after ~= nil and after ~= expected + #line then return false end
  return true
end

-- One CSV line into its fields. The header line fails this on purpose: `flight_s` is matched as
-- digits, and the header carries the word there.
function M.parseRow(line)
  local date, time, model, battery, seconds, rest =
    string.match(line, "^([^,]*),([^,]*),([^,]*),([^,]*),(%d+),?(.*)$")
  if date == nil then return nil end
  return {
    date = date,
    time = time,
    model = model,
    battery = battery,
    seconds = tonumber(seconds) or 0,
    stats = (rest ~= nil and rest ~= "") and rest or nil
  }
end

-- The statistics columns of one row, in STAT_KEYS order, as { key = number }. An empty field is
-- a value that was not recorded and stays absent. nil when the row carries nothing usable.
function M.parseStats(rest)
  if type(rest) ~= "string" or rest == "" then return nil end
  local out = {}
  local index = 1
  local any = false
  for field in string.gmatch(rest .. ",", "([^,]*),") do
    local key = M.STAT_KEYS[index]
    if key == nil then break end
    local value = (field ~= "") and tonumber(field) or nil
    if value ~= nil then
      out[key] = value
      any = true
    end
    index = index + 1
  end
  if not any then return nil end
  return out
end

-- ---------------------------------------------------------------------------
-- Chunked reading, for a page that may not stall the tool
-- ---------------------------------------------------------------------------

-- The log is walked a bounded number of lines per call so that reading it never costs more than
-- one wakeup's worth of work, however long the file has grown. The reader owns the handle; the
-- caller keeps calling readerStep until it reports that it is done, and closes on any exit.
function M.newReader(path)
  local ok, handle = pcall(io.open, path or M.csvPath(), "r")
  if not ok or not handle then return nil end
  return { handle = handle, buffer = "", eof = false, done = false, bytes = 0 }
end

function M.readerClose(reader)
  if type(reader) ~= "table" then return end
  if reader.handle then
    pcall(io.close, reader.handle)
    reader.handle = nil
  end
  reader.done = true
  reader.buffer = ""
end

-- Parses at most `maxLines` lines and hands each parsed row to `onRow`. Returns true once the
-- file is exhausted. The line count is the binding cap and the reader pulls as many chunks as
-- those lines need: a fixed byte budget is a line budget that changes with the row width, which
-- makes a long file take an unpredictable number of passes.
function M.readerStep(reader, maxLines, onRow)
  if type(reader) ~= "table" or reader.done then return true end
  local buffer = reader.buffer
  local pos = 1
  local lines = 0

  while lines < maxLines do
    local line = nil
    local nl = string.find(buffer, "\n", pos, true)
    if nl ~= nil then
      line = string.sub(buffer, pos, nl - 1)
      pos = nl + 1
    elseif not reader.eof then
      local ok, data = pcall(io.read, reader.handle, READ_CHUNK)
      if not ok or data == nil or data == "" then
        reader.eof = true
      else
        buffer = string.sub(buffer, pos) .. data
        pos = 1
        reader.bytes = reader.bytes + #data
      end
    elseif pos <= #buffer then
      line = string.sub(buffer, pos)
      pos = #buffer + 1
    else
      break
    end

    if line ~= nil then
      if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
      local row = M.parseRow(line)
      if row ~= nil and type(onRow) == "function" then onRow(row) end
      lines = lines + 1
    end
  end

  reader.buffer = string.sub(buffer, pos)
  if reader.eof and reader.buffer == "" then
    M.readerClose(reader)
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Registry writes
-- ---------------------------------------------------------------------------

-- Writes `content` over `path` without ever leaving the original truncated: the new file is
-- written beside it, its size is verified, the original is parked as `.bak` and only then is
-- the new one renamed into place. Every failure exit leaves the original where it was, and a
-- failure of the final rename leaves the data in the `.bak`.
--
-- del and rename answer an FRESULT, 0 being success. FatFS refuses a rename onto an existing
-- name, which is why the stale `.bak` is removed first.
--
-- `allowCreate` lets a missing original through: the file is then created with its first line
-- rather than the write being refused.
local function atomicReplace(path, content, allowCreate)
  local newPath = path .. ".new"
  local bakPath = path .. ".bak"

  ensureDir()
  local f = io.open(newPath, "w")
  if not f then return false end
  io.write(f, content)
  io.close(f)

  -- Verified before the original is touched: io.write says nothing on a full card, and the
  -- size is the only signal there is.
  local written = fileSize(newPath)
  if written == nil or written ~= #content then return false end
  if type(rename) ~= "function" then return false end

  local parked = not (allowCreate and fileSize(path) == nil)
  if parked then
    if type(del) == "function" then pcall(del, bakPath) end
    local ok, res = pcall(rename, path, bakPath)
    if not ok or res ~= 0 then return false end
  end

  local ok, res = pcall(rename, newPath, path)
  if not ok or res ~= 0 then
    if parked then pcall(rename, bakPath, path) end
    return false
  end
  return true
end

-- Reads the registry for a rewrite. The second return is the distinct refusal a caller has to
-- be able to explain: a file above the cap is read short, and a short read written back is the
-- rest of the pilot's registry deleted.
local function guardedRead(path)
  local size = fileSize(path)
  if size ~= nil and size > READ_CAP then return nil, "toobig" end
  return readAll(path, READ_CAP), nil
end

-- Walks the file by byte offset and answers where the first non-comment line carrying `want` as
-- its id begins, where its content ends (without the terminator) and where the line ends (with
-- it). Offsets rather than strings, so that splicing around them keeps the file's own line
-- endings exactly as they were.
local function findLine(data, want)
  local pos = 1
  while pos <= #data do
    local nl = string.find(data, "\n", pos, true)
    local lineEnd = nl ~= nil and nl or #data
    local contentEnd = nl ~= nil and nl - 1 or #data
    if contentEnd >= pos and string.sub(data, contentEnd, contentEnd) == "\r" then
      contentEnd = contentEnd - 1
    end
    local line = string.sub(data, pos, contentEnd)
    if string.match(line, "^%s*#") == nil then
      -- The id key is anchored to the line start or to a ";", so a value that merely contains
      -- the text "id=" can never be read as the key.
      local id = string.match(line, "^%s*[iI][dD]%s*=%s*([^;]*)")
        or string.match(line, ";%s*[iI][dD]%s*=%s*([^;]*)")
      if id ~= nil and trim(id) == want then return pos, contentEnd, lineEnd end
    end
    if nl == nil then break end
    pos = nl + 1
  end
  return nil
end

-- A ";" would end the field and a line break the line, so neither may reach a value.
local function cleanValue(value)
  if type(value) == "number" then return string.format("%d", math.floor(value)) end
  return string.gsub(tostring(value or ""), "[;\r\n]", "")
end

-- The known keys, in the order a new line serialises them.
local KNOWN_KEYS = { "id", "name", "cap", "models", "profile", "cycles", "last" }

-- Rewrites one line's content. `fields` maps a lower-case known key to a value to write, to
-- false to remove the key, or leaves it absent to keep the field's exact bytes -- spacing and
-- case included. The line is split on ";" and a value can never contain one, so unlike a
-- pattern search this cannot mistake text inside a value for a key. Unknown keys and the line's
-- own key order survive; a known key that is new is appended.
local function editLine(line, fields)
  local segments = {}
  local done = {}
  local pos = 1
  while true do
    local sep = string.find(line, ";", pos, true)
    local segment = string.sub(line, pos, sep ~= nil and sep - 1 or #line)
    local key = string.match(segment, "^%s*([%w_]+)%s*=")
    if key ~= nil then key = string.lower(key) end
    if key ~= nil and not done[key] and fields[key] ~= nil then
      done[key] = true
      if fields[key] ~= false then
        segments[#segments + 1] = key .. "=" .. cleanValue(fields[key])
      end
    else
      segments[#segments + 1] = segment
    end
    if sep == nil then break end
    pos = sep + 1
  end
  for i = 1, #KNOWN_KEYS do
    local key = KNOWN_KEYS[i]
    if fields[key] ~= nil and fields[key] ~= false and not done[key] then
      segments[#segments + 1] = key .. "=" .. cleanValue(fields[key])
    end
  end
  return table.concat(segments, ";")
end

local function serializeEntry(entry)
  local line = "id=" .. cleanValue(entry.id) .. ";name=" .. cleanValue(entry.name)
  if type(entry.cap) == "number" and entry.cap > 0 then
    line = line .. ";cap=" .. cleanValue(entry.cap)
  end
  if entry.models ~= nil and entry.models ~= false and cleanValue(entry.models) ~= "" then
    line = line .. ";models=" .. cleanValue(entry.models)
  end
  if type(entry.profile) == "number" and entry.profile >= 1 then
    line = line .. ";profile=" .. cleanValue(entry.profile)
  end
  line = line .. ";cycles=" .. cleanValue(type(entry.cycles) == "number" and entry.cycles or 0)
  return line
end

-- Counts one use of a pack: cycles+1 and last=<date>, with every other byte of the file left
-- as it was. A missing cycles or last field is appended rather than the line being rebuilt.
--
-- Returns false rather than raising when there is nothing to stamp: the count is a convenience
-- and losing one must never cost the flight line that was just written.
function M.markUsed(batteryId, dt)
  local path = M.registryPath()
  local size = fileSize(path)
  if size ~= nil and size > READ_CAP then return false end
  local data = readAll(path, READ_CAP)
  if data == nil then return false end
  local want = trim(batteryId)
  if want == "" then return false end

  local start, contentEnd = findLine(data, want)
  if start == nil then return false end

  local line = string.sub(data, start, contentEnd)
  -- The two fields that are rewritten are anchored by a frontier, so the match may only begin
  -- where a word character does not precede it. Unanchored, the stamp reaches inside the
  -- pilot's own fields: a field spelled "recycles" is counted up as if it were the cycle count.
  local CYCLES = "%f[%w_][cC][yY][cC][lL][eE][sS]%s*="
  local LAST = "%f[%w_][lL][aA][sS][tT]%s*="

  local cycles = tonumber(string.match(line, CYCLES .. "%s*(%d+)")) or 0
  if string.match(line, CYCLES) ~= nil then
    line = string.gsub(line, CYCLES .. "%s*%d*", "cycles=" .. (cycles + 1), 1)
  else
    line = line .. ";cycles=" .. (cycles + 1)
  end

  local date = M.formatDate(dt)
  if string.match(line, LAST) ~= nil then
    line = string.gsub(line, LAST .. "%s*[^;]*", "last=" .. date, 1)
  else
    line = line .. ";last=" .. date
  end

  local out = string.sub(data, 1, start - 1) .. line .. string.sub(data, contentEnd + 1)
  return atomicReplace(path, out)
end

-- Appends a pack at the end of the file. A missing file is not an error: it is created with
-- this first pack. `entry.models` is the serialised comma list, or nil for "every model".
function M.createBattery(entry)
  local path = M.registryPath()
  local data, err = guardedRead(path)
  if err ~= nil then return err end
  local id = trim(entry ~= nil and entry.id or "")
  if id == "" then return false end
  if data ~= nil and findLine(data, id) ~= nil then return "collision" end

  local line = serializeEntry(entry)
  local out
  if data == nil then
    out = line .. "\n"
  else
    out = data .. (string.sub(data, -1) == "\n" and "" or "\n") .. line .. "\n"
  end
  return atomicReplace(path, out, true)
end

-- Line surgery on the pack whose id is `oldId`. `fields` follows editLine's contract: a value
-- is written, false removes the key and an absent key keeps the field verbatim. Changing the id
-- is refused with "collision" when the new one already belongs to another line.
function M.updateBattery(oldId, fields)
  local path = M.registryPath()
  local data, err = guardedRead(path)
  if err ~= nil then return err end
  if data == nil then return "notfound" end
  local want = trim(oldId)
  if want == "" then return "notfound" end
  if type(fields) ~= "table" then return false end

  local newId = (fields.id ~= nil and fields.id ~= false) and trim(fields.id) or nil
  if newId ~= nil and newId ~= want and findLine(data, newId) ~= nil then
    return "collision"
  end

  local start, contentEnd = findLine(data, want)
  if start == nil then return "notfound" end
  local out = string.sub(data, 1, start - 1)
    .. editLine(string.sub(data, start, contentEnd), fields)
    .. string.sub(data, contentEnd + 1)
  return atomicReplace(path, out)
end

-- Removes one line and its terminator; everything else stays byte-identical. No tombstone is
-- left behind: what a synchronising tool makes of a missing line is that tool's question.
function M.deleteBattery(id)
  local path = M.registryPath()
  local data, err = guardedRead(path)
  if err ~= nil then return err end
  if data == nil then return "notfound" end
  local want = trim(id)
  if want == "" then return "notfound" end
  local start, _, lineEnd = findLine(data, want)
  if start == nil then return "notfound" end
  local out = string.sub(data, 1, start - 1) .. string.sub(data, lineEnd + 1)
  return atomicReplace(path, out)
end

-- ---------------------------------------------------------------------------
-- Field sanitising, shared by the editor and by anything writing a line
-- ---------------------------------------------------------------------------

function M.sanitizeId(value)
  return string.sub(string.gsub(tostring(value or ""), "[^A-Za-z0-9_%-]", ""), 1, 24)
end

function M.sanitizeName(value)
  local cleaned = string.gsub(tostring(value or ""), "[;%c]", "")
  return string.sub(trim(cleaned), 1, 24)
end

-- A comma separates the model list, so it goes the same way a ";" does.
function M.sanitizeModel(value)
  local cleaned = string.gsub(tostring(value or ""), "[,;%c]", "")
  return string.sub(trim(cleaned), 1, 32)
end

M.trim = trim

return M
