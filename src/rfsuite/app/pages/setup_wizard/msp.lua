-- Flight-controller side of the setup assistant: one small wrapper over the MSP queue so a
-- step can ask for a value without repeating the queue idiom, and a sequencer so a step that
-- has several writes to make performs them as one act rather than one per screen.
--
-- Every read here is a read the suite already had a module for. Nothing in this file speaks
-- MSP directly.

local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

M.loadModule = loadModule

local Wlog = loadModule("app/pages/setup_wizard/log.lua") or
  { emit = function() end, wanted = function() return false end, changed = function() return false end }

local apiCache = {}

-- API modules are loaded on first use and kept for the life of the page, because a step is
-- entered and left several times while the assistant runs and reloading the same chunk on
-- every visit is pure cost.
function M.api(name)
  local mod = apiCache[name]
  if mod == nil then
    mod = loadModule("tasks/msp/api/" .. name .. ".lua") or false
    apiCache[name] = mod
  end
  if mod == false then return nil end
  return mod
end

function M.release()
  for key in pairs(apiCache) do apiCache[key] = nil end
end

local function queue()
  local runtime = loadModule("tasks/msp/runtime.lua")
  if not runtime or type(runtime.getState) ~= "function" then return nil end
  local state = runtime.getState()
  local q = state and state.queue
  if not q or type(q.add) ~= "function" then return nil end
  return q
end

M.queue = queue

-- Read one API module and hand the parsed table to `onDone`. `onDone` is called with nil when
-- the flight controller does not answer, and the caller decides what an unanswered read means
-- -- a step that treats a missing answer as a zero would report a configuration it never saw.
function M.read(name, onDone)
  local api = M.api(name)
  local q = queue()
  if not api or not q then
    if onDone then onDone(nil, "unavailable") end
    return false
  end

  Wlog.emit("trace", "msp read %s (cmd %s)", name, tostring(api.command))
  q:add({
    command = api.command,
    simulatorResponse = api.simulatorResponse,
    processReply = function(_, buf)
      local parsed = nil
      if type(api.parse) == "function" then parsed = api.parse(buf) end
      -- An answer after a silence closes the warning above, so a run that recovered does not read
      -- as one that never did.
      Wlog.forget("noreply:" .. tostring(name))
      Wlog.emit("trace", "msp read %s -> %d byte(s), parsed %s",
        name, buf and #buf or 0, tostring(parsed ~= nil))
      if onDone then onDone(parsed, nil) end
    end,
    errorHandler = function()
      -- An unanswered read is the shape every stall on this page has taken, and it is invisible
      -- from the screen: the row simply keeps saying it is reading. So the FIRST one is a warning
      -- and the rest are trace -- one screen here polls the live channels five times a second, and
      -- a board that has stopped answering would otherwise write five warnings a second into a
      -- ring buffer that is meant to still hold what happened before it.
      if not Wlog.changed("warn", "noreply:" .. tostring(name), true,
        "msp read %s -> no reply", name) then
        Wlog.emit("trace", "msp read %s -> no reply", name)
      end
      if onDone then onDone(nil, "no_reply") end
    end
  })
  return true
end

-- Does this board have the paged accessors at all? They arrived with API 12.09; below it the
-- single-slot read does not exist and must not be sent, whoever asks. Stated here rather than at
-- each call, because a caller that forgets it does not get an error -- it gets a silence that
-- reads exactly like an empty table.
function M.hasPagedReads()
  local root = _G and _G.rfsuite
  local session = root and root.session or nil
  local version = session and session.apiVersion
  if type(version) ~= "string" or version == "" then return nil end
  local major, minor = string.match(version, "^(%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  if major == nil or minor == nil then return nil end
  if major > 12 then return true end
  if major < 12 then return false end
  return minor >= 9
end

-- A read whose REQUEST carries a payload. One accessor in the tree needs it -- the single
-- adjustment slot, which is asked for by index -- and the firmware answers a request of any other
-- length with an error, so the payload is part of the read rather than an option on it.
function M.readIndexed(name, payload, onDone)
  local api = M.api(name)
  local q = queue()
  if not api or not q then
    if onDone then onDone(nil, "unavailable") end
    return false
  end

  q:add({
    command = api.command,
    payload = payload or {},
    -- Said explicitly, because the queue classifies any message carrying a payload as a
    -- WRITE when nothing says otherwise -- and this is a read that happens to name which
    -- record it wants. The flag only reaches the transport; the payload goes either way.
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    processReply = function(_, buf)
      local parsed = nil
      if type(api.parse) == "function" then parsed = api.parse(buf) end
      if onDone then onDone(parsed, nil) end
    end,
    errorHandler = function()
      if onDone then onDone(nil, "no_reply") end
    end
  })
  return true
end

-- Write a raw payload against a command. Used for the writes whose payload a step builds
-- itself, which is every mode range and every adjustment slot -- their API modules take the
-- finished byte list.
function M.write(command, payload, onDone)
  local q = queue()
  if not q then
    if onDone then onDone(false, "unavailable") end
    return false
  end

  q:add({
    command = command,
    payload = payload or {},
    isWrite = true,
    simulatorResponse = {},
    processReply = function()
      if onDone then onDone(true, nil) end
    end,
    errorHandler = function()
      if onDone then onDone(false, "write_failed") end
    end
  })
  return true
end

function M.commit(onDone)
  local api = M.api("eeprom_write")
  if not api then
    if onDone then onDone(false, "unavailable") end
    return false
  end
  return M.write(api.writeCommand, {}, onDone)
end

-- A list of steps run one after the other, each of them `function(next) ... next(ok) end`.
-- The MSP queue is asynchronous and every write has to wait for the reply of the one before
-- it; without this the assistant would either fire them all at once or grow a nest of
-- callbacks per screen.
function M.sequence(steps, onDone)
  local index = 0
  local function advance(ok, err)
    if ok == false then
      if onDone then onDone(false, err) end
      return
    end
    index = index + 1
    local step = steps[index]
    if step == nil then
      if onDone then onDone(true, nil) end
      return
    end
    step(advance)
  end
  advance(true, nil)
end

-- The reason the board gives for refusing to arm, as a list of names. The suite already parses
-- the flag word; what is added here is only the naming, because a failed check that says "it
-- did not work" sends the pilot to a forum while a named cause sends them to a setting.
M.ARMING_DISABLE_FLAGS = {
  "NO_GYRO", "FAILSAFE", "RX_FAILSAFE", "BAD_RX_RECOVERY", "BOXFAILSAFE",
  "GOVERNOR", "RPM_SIGNAL", "THROTTLE", "ANGLE", "BOOT_GRACE_TIME",
  "NOPREARM", "LOAD", "CALIBRATING", "CLI", "CMS_MENU", "BST", "MSP", "PARALYZE"
}

function M.armingDisableReasons(flags)
  flags = tonumber(flags)
  local names = {}
  if flags == nil or flags == 0 then return names end
  for bit = 0, #M.ARMING_DISABLE_FLAGS - 1 do
    if (flags >> bit) & 1 == 1 then
      names[#names + 1] = M.ARMING_DISABLE_FLAGS[bit + 1]
    end
  end
  return names
end

-- Which wire channel an aux slot lands on. Everything the flight controller exposes is
-- ordered by function, and the channel map is the only bridge back to a wire channel -- so
-- "arming is on channel five" is a result of the map and never a constant. Slots 0 to 4 are
-- the five controls, so aux one is slot five.
local CONTROL_CHANNEL_COUNT = 5

-- The map, in the order the firmware sorts its own slots. Index is the slot; the value the map
-- carries at that slot is the WIRE channel, counted from zero.
local SLOT_NAMES = {
  "aileron", "elevator", "rudder", "collective", "throttle", "aux1", "aux2", "aux3"
}

function M.auxWireChannel(auxIndex, rxMap)
  auxIndex = tonumber(auxIndex)
  if auxIndex == nil then return nil end
  -- The channel map arrives wrapped, as every field-spec module in the tree wraps its result.
  -- Reading it flat gives nil for every field, and a slot computed from that would be a guess
  -- with the shape of a fact -- so there is deliberately NO fallback here: no map, no answer.
  local map = type(rxMap) == "table" and (rxMap.parsed or rxMap) or nil
  if type(map) ~= "table" then return nil end
  local key = SLOT_NAMES[CONTROL_CHANNEL_COUNT + auxIndex + 1]
  local mapped = key and tonumber(map[key])
  if mapped == nil then return nil end
  return mapped + 1
end

-- The highest aux index a channel field may carry. The firmware indexes
-- `rcInput[field + CONTROL_CHANNEL_COUNT]` into a `float[18]` with no bound test, on every
-- evaluation, so the valid fields are 0..12 -- and `MSP_SET_ADJUSTMENT_RANGE` validates the SLOT
-- INDEX and nothing else, storing whatever else arrives. The CLI refuses an out-of-range field;
-- the wire does not. So the writer is the validator or nobody is.
M.MAX_AUX_FIELD = 12

function M.auxFieldUsable(auxIndex)
  auxIndex = tonumber(auxIndex)
  return auxIndex ~= nil and auxIndex >= 0 and auxIndex <= M.MAX_AUX_FIELD
end

-- The reverse direction: which aux slot carries a given wire channel under this map. Returns
-- nil where the map puts no aux slot on that channel at all, which is a finding rather than a
-- default.
function M.wireChannelToAux(channel, rxMap)
  channel = tonumber(channel)
  if channel == nil then return nil end
  for auxIndex = 0, #SLOT_NAMES - CONTROL_CHANNEL_COUNT - 1 do
    if M.auxWireChannel(auxIndex, rxMap) == channel then return auxIndex end
  end
  return nil
end

return M
