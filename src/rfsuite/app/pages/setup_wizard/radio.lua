-- Radio-side helpers for the setup assistant.
--
-- Everything here reads or writes the ACTIVE EdgeTX model. Lua registers no model selection
-- function, so a write can only ever reach the model the pilot has open.
--
-- The rule this file follows throughout: read what is configured, measure only what cannot be
-- read. The mapping and the travel are in the model; only the path to the flight controller
-- needs a hand on a stick.

local M = {}

-- The channel layout the project's own radio setup documents. Index is the wire channel.
-- CH1 to CH6 are the same order the configurator offers as a prepared channel map, so a
-- flight controller at its default map already agrees with this table.
M.BASELINE = {
  [1] = "aileron",
  [2] = "elevator",
  [3] = "collective",
  [4] = "rudder",
  [5] = "arm",
  [6] = "throttle",
  [7] = "profile",
  [8] = "rescue"
}

-- The four controls, in the firmware's own numbering, against the wire channel the baseline puts
-- them on. The numbering is the one the firmware's stick sources use, so a reply that arrives
-- ordered by function meets this table without a label in between.
M.STICKS = {
  { stick = 3, channel = 1, key = "aileron" },
  { stick = 1, channel = 2, key = "elevator" },
  { stick = 2, channel = 3, key = "collective" },
  { stick = 0, channel = 4, key = "rudder" }
}

-- Channels the assistant lays out, in the order it walks them.
--
-- A channel carries a LIST of roles rather than one, on both sides, and the simplification that
-- it carries exactly one fails on real layouts in both directions: the documented blackbox
-- channel is one channel driving two mode boxes at two windows, and the throttle channel needs a
-- hold and a governor source at once. Only one role each is populated here, and the shape is a
-- list so that adding the second is data rather than a rewrite.
--
-- `kind` decides which value window is computed and what is written beside the mix:
--   condition  - one position turns a flight controller mode on, the rest leave it off
--   throttle   - two mixer lines, and the firmware has no mode box for a throttle hold at all
--   adjustment - the whole travel is mapped onto a value range, in adjustment slots
--
-- `tier` has four values and the fourth is not decoration: *required*, *recommended*, *optional*
-- and **unavailable** -- a channel the assistant knows about and cannot deliver today. Marking
-- such a channel *recommended* would promise something the run does not keep.
-- `input`, `inputName` and `channelName` are the layout itself rather than decoration on it. The
-- source belongs in the INPUT and the mixer line carries nothing but that input: writing the
-- switch straight into the mixer line produces the identical channel value and is not the same
-- setup, because it leaves the input list empty and the transmitter then shows nothing at the
-- place the configuration belongs to. A layout whose channels are called CH5..CH8 is one nobody
-- can check by looking, either.
--
-- The two name lengths differ and neither is generous: a colour radio stores four characters for
-- an input name and six for a channel name. These are chosen to fit rather than to be truncated
-- by the radio afterwards, because a truncated name would never again equal what the completion
-- criterion compares it against.
M.CHANNELS = {
  {
    -- A two-position switch, and the pilot names the POSITION that arms -- a safety function
    -- has no defensible default, and which end of a switch means on is the pilot's convention
    -- rather than anything the machine could settle. The channel is built so that exactly the
    -- named position reads at the top of the travel, whichever way the switch is mounted.
    channel = 5, input = 4, key = "arm", tier = "required",
    exactPositions = 2,
    inputName = "Arm", channelName = "Arming",
    roles = { { kind = "condition", box = "ARM" } }
  },
  {
    -- The one channel that carries TWO switches, and both live on its own input as
    -- ALTERNATIVE lines, the reference construction: MAX at -100 gated by the lock position,
    -- the governor switch at full weight beneath it. Expo lines are alternatives -- the first
    -- whose gate matches wins -- so the lock rules exactly one position and every other
    -- carries the governor's travel.
    channel = 6, input = 5, key = "throttle", tier = "required",
    inputName = "Thr", channelName = "Thr",
    roles = { { kind = "throttle" } }
  },
  {
    -- Profile selection is not a mode box: it is two adjustment slots, the rate profile and the
    -- pid profile, driven continuously from one three-position switch onto 1..3.
    -- Required rather than recommended, by the pilot's ruling: the three flight modes are not an
    -- extra. A required channel is settled once and carried out, which is also why its own screen
    -- no longer offers a way to switch it back off.
    channel = 7, input = 6, key = "profile", tier = "required",
    inputName = "Prof", channelName = "Prof",
    needsPositions = 3,
    roles = { { kind = "adjustment", functions = { 1, 2 }, min = 1, max = 3 } }
  },
  {
    channel = 8, input = 7, key = "rescue", tier = "recommended",
    exactPositions = 2,
    inputName = "Res", channelName = "Rescue",
    roles = { { kind = "condition", box = "RESCUE" } }
  }
}

-- The first role of a channel, which is what every screen renders today. Written as a lookup
-- rather than as `entry.kind` so that the day a channel grows a second role, the callers that
-- must change are the ones that say `firstRole`.
function M.firstRole(entry)
  if type(entry) ~= "table" or type(entry.roles) ~= "table" then return nil end
  return entry.roles[1]
end

-- The four sticks, as INPUTS. This is the level the setup actually lives on: a source belongs in
-- an input, and the mixer line below it is a plain one-to-one from that input to its channel. A
-- switch or a stick written straight into a mixer line produces the same channel value and is not
-- the same setup -- it leaves the input list empty, so the pilot's own radio shows nothing where
-- the configuration is supposed to be.
--
-- The order is the flight controller's, not the transmitter's. A radio at its factory setting
-- carries RETA, and this layout is roll, pitch, collective, yaw -- so on a fresh model two of the
-- four inputs have the wrong source and the assistant is what puts them right.
--
-- `stick` is a FUNCTION, not a label: 0 yaw, 1 pitch, 2 collective, 3 roll, which is the order
-- the firmware's own stick sources are in. The names beside it are what the pilot will read and
-- nothing is resolved from them -- `Ail` is a label the pilot may edit, and on a radio set up
-- differently it means another stick or does not exist. What has to come out right is the
-- RESULT: roll on channel one, whatever it is called here.
--
-- `field` is the name the FIRMWARE knows a control by, and it is deliberately not one of the
-- names beside it. EdgeTX generates it from the target's own hardware description and its own
-- documentation says so in as many words: the names `getFieldInfo` takes are not the names shown
-- on the radio's menus. So it is neither the label the pilot edits nor one that moves when the
-- stick mode changes -- which is exactly what the two name columns here ARE, and why nothing is
-- ever resolved through them.
--
-- `key` is the FUNCTION, in the pilot's own language, and it is what the screen shows on the left.
-- The name that is written into the model stands on the right as the target, and having the target
-- in both columns is what made the row read as a duplicate: `CH1 Ail ... Rud ... Ail`.
M.STICK_INPUTS = {
  { input = 0, channel = 1, stick = 3, field = "ail", key = "aileron",
    inputName = "Ail", channelName = "Ail" },
  { input = 1, channel = 2, stick = 1, field = "ele", key = "elevator",
    inputName = "Ele", channelName = "Ele" },
  { input = 2, channel = 3, stick = 2, field = "thr", key = "collective",
    inputName = "Col", channelName = "Col" },
  { input = 3, channel = 4, stick = 0, field = "rud", key = "rudder",
    inputName = "Rud", channelName = "Rud" }
}

local function callGlobal(name, ...)
  local fn = _G and _G[name]
  if type(fn) ~= "function" then return nil end
  local ok, a, b = pcall(fn, ...)
  if not ok then return nil end
  return a, b
end

local function modelApi(name)
  local model = _G and _G.model
  if type(model) ~= "table" then return nil end
  local fn = model[name]
  if type(fn) ~= "function" then return nil end
  return fn
end

-- Raw channel values run from -1024 to 1024 around centre; the flight controller speaks
-- microseconds. Values already in the microsecond band are passed through, because the same
-- helper is used on numbers arriving from both sides.
function M.rawToUs(value)
  value = tonumber(value)
  if value == nil then return nil end
  if value >= -1200 and value <= 1200 then
    return math.floor(1500 + (value * 500 / 1024) + 0.5)
  end
  if value >= 700 and value <= 2300 then
    return math.floor(value + 0.5)
  end
  return nil
end

-- What the radio is sending on a wire channel right now. This is the radio's own mixer output
-- and says nothing about what arrives at the flight controller.
function M.channelUs(channel)
  local raw = callGlobal("getValue", "ch" .. tostring(channel))
  return M.rawToUs(raw)
end

function M.mixesCount(channel)
  local fn = modelApi("getMixesCount")
  if not fn then return nil end
  local ok, value = pcall(fn, channel - 1)
  if not ok then return nil end
  return tonumber(value) or 0
end

function M.getMix(channel, index)
  local fn = modelApi("getMix")
  if not fn then return nil end
  local ok, mix = pcall(fn, channel - 1, index)
  if not ok or type(mix) ~= "table" then return nil end
  return mix
end

function M.getOutput(channel)
  local fn = modelApi("getOutput")
  if not fn then return nil end
  local ok, out = pcall(fn, channel - 1)
  if not ok or type(out) ~= "table" then return nil end
  return out
end

-- A switch position, as the radio's own picker returns it. Positions are grouped three to a
-- switch from the first switch onward, which is what lets a single field carry both halves of
-- the answer: which switch, and which of its states.
local SWSRC_FIRST_SWITCH = 1
local POSITIONS_PER_SWITCH = 3

-- What the firmware allows, and every one of them carries its own trims.
local MAX_FLIGHT_MODES = 9

-- Trim, as an input carries it. The firmware stores it inverted against what Lua reads and
-- writes, so the value a script sees is the one the radio's own input editor shows: 0 is the
-- trim of the input's own stick, and -1 is no trim at all. Anything below -1 names another
-- stick's trim.
--
-- Every input this assistant lays out gets -1. A flight controller holds the model itself and a
-- trim under it moves the neutral the controller was calibrated against, so a trim that is one
-- click off is a craft that flies away from centre and a stick position that no longer means
-- what the board was told it means.
M.TRIM_OFF = -1

M.POSITION_UP = 0
M.POSITION_MIDDLE = 1
M.POSITION_DOWN = 2

function M.switchNumber(swsrc)
  swsrc = tonumber(swsrc)
  if swsrc == nil or swsrc < SWSRC_FIRST_SWITCH then return nil end
  return math.floor((swsrc - SWSRC_FIRST_SWITCH) / POSITIONS_PER_SWITCH)
end

function M.switchPosition(swsrc)
  swsrc = tonumber(swsrc)
  if swsrc == nil or swsrc < SWSRC_FIRST_SWITCH then return nil end
  return (swsrc - SWSRC_FIRST_SWITCH) % POSITIONS_PER_SWITCH
end

function M.firstPositionOf(swsrc)
  local number = M.switchNumber(swsrc)
  if number == nil then return nil end
  return SWSRC_FIRST_SWITCH + number * POSITIONS_PER_SWITCH
end

function M.switchPositionName(swsrc)
  return callGlobal("getSwitchName", swsrc)
end

-- The name of the switch itself, without the position symbol the radio appends. The upper and
-- lower symbols are two bytes wide and the middle one is a single hyphen, so how much to drop
-- follows from the position rather than from guessing at the encoding.
function M.switchBaseName(swsrc)
  local name = M.switchPositionName(swsrc)
  if type(name) ~= "string" or name == "" then return nil end
  local drop = 2
  if M.switchPosition(swsrc) == M.POSITION_MIDDLE then drop = 1 end
  if #name <= drop then return nil end
  return string.sub(name, 1, #name - drop)
end

-- The mix source of the switch a position belongs to. A switch and its own source carry the
-- same name, a custom one included, so the lookup goes through the name rather than through a
-- constant Lua is never told. A nil answer means the switch cannot be expressed as a mix
-- source, and then nothing is written for it.
function M.switchSource(swsrc)
  local base = M.switchBaseName(swsrc)
  if base == nil then return nil, nil end
  local id = callGlobal("getSourceIndex", base)
  if id ~= nil then return tonumber(id), base end
  local info = callGlobal("getFieldInfo", base)
  if type(info) == "table" and info.id ~= nil then return tonumber(info.id), base end
  return nil, base
end

-- The physical switches this radio has, one entry per SWITCH rather than per position.
--
-- A channel that carries a VALUE across the whole travel -- the profile channel is the one -- is
-- answered by naming a switch: all three of its positions are spoken for, one per profile. The
-- radio's own picker only ever returns a position, so asking with it offers three spellings of
-- the same answer and then discards two of them. `minPositions` filters to switches that can
-- actually carry the function, which leaves nothing for a "this needs three positions" complaint
-- to be about.
local MAX_SWITCHES = 32

function M.switches(minPositions)
  minPositions = tonumber(minPositions) or 2
  local list = {}
  for number = 0, MAX_SWITCHES - 1 do
    local first = SWSRC_FIRST_SWITCH + number * POSITIONS_PER_SWITCH
    local count = M.switchPositionCount(first)
    local name = count and M.switchBaseName(first) or nil
    if name ~= nil and count >= minPositions then
      list[#list + 1] = { swsrc = first, name = name, positions = count }
    end
  end
  return list
end

-- The switch a mix SOURCE stands for, and it is the other half of the radio's own source picker.
--
-- That picker answers with a source id -- one entry per SWITCH rather than one per position, which
-- is the shape a channel carrying a value across the whole travel actually needs -- and the id it
-- returns is exactly what goes into the input. Everything else on this path is expressed in switch
-- POSITIONS, so the two have to meet somewhere, and this is it.
--
-- Walked rather than computed. The first id of the switch block is not a constant Lua is ever
-- told, and deriving it from one radio's numbering would be a guess that happens to hold there.
function M.switchFromSource(id)
  id = tonumber(id)
  if id == nil or id == 0 then return nil end
  for number = 0, MAX_SWITCHES - 1 do
    local first = SWSRC_FIRST_SWITCH + number * POSITIONS_PER_SWITCH
    local source = M.switchSource(first)
    if source ~= nil and source == id then
      return first, M.switchBaseName(first), M.switchPositionCount(first)
    end
  end
  return nil
end

-- How many positions this switch actually has. A two-position switch has no middle, so it
-- never rests at centre and its windows are the two ends alone.
function M.switchPositionCount(swsrc)
  local first = M.firstPositionOf(swsrc)
  if first == nil then return nil end
  local count = 0
  for offset = 0, POSITIONS_PER_SWITCH - 1 do
    if M.switchPositionName(first + offset) ~= nil then count = count + 1 end
  end
  if count == 0 then return nil end
  return count
end

-- Which position this switch is resting in right now, as an offset from its first. The firmware
-- answers per POSITION and not per switch, so the three are asked in turn and the one that is
-- true is the answer. `nil` where the radio does not answer for this switch at all.
--
-- It is what lets a pilot name a switch by moving it. The radio's own picker already does that
-- for a position; a channel that needs the whole switch is asked with a plain list, and a list
-- does not listen to the hardware unless something makes it.
-- Is this exact position the one the switch is resting in? The read-back needs it for every row:
-- what the board reports has to be compared against what the pilot's hand is doing right now, and
-- nothing else on the screen knows that.
function M.switchActive(swsrc)
  return callGlobal("getSwitchValue", swsrc) == true
end

function M.activePosition(swsrc)
  local first = M.firstPositionOf(swsrc)
  if first == nil then return nil end
  for offset = 0, POSITIONS_PER_SWITCH - 1 do
    if callGlobal("getSwitchValue", first + offset) == true then return offset end
  end
  return nil
end

-- The travel a switch actually produces on a channel the assistant wrote itself -- both ends, not
-- the theoretical span of the step encoding.
--
-- This is the difference between a profile switch that lands on 1 / 2 / 3 and one that lands on
-- 1.18 / 2.00 / 2.82 and is only correct by rounding. The assistant authors the mix, so it knows
-- the travel and has no reason to approximate it.
function M.travelRange(swsrc)
  local first = M.firstPositionOf(swsrc)
  if first == nil then return nil end
  return { start = 988, ["end"] = 2012 }
end

-- The value window a mode box gets for a picked position: wide enough to hold the position
-- against switch and receiver tolerance, narrow enough that no other position of the same
-- switch falls inside it.
-- ALWAYS the upper band, and that is a rule rather than a reading.
--
-- It used to answer per position -- the top for an up position, the bottom for a down one -- which
-- is correct only if the picked position produces a matching value on the channel. Nothing checked
-- that, and nothing in the model records it. Measured on a real flight controller: a plain chain
-- from switch to input to channel at weight +100 throughout, the assistant's own picked position,
-- and the board reporting the function OFF there and ON at the other end.
--
-- So the window is fixed and the CHANNEL is built to match it -- see `writeConditionChannel`. The
-- two now agree by construction, and a switch wired either way round produces the same result.
function M.windowFor(swsrc)
  if M.switchPosition(swsrc) == nil then return nil end
  return { start = 1700, ["end"] = 2100 }
end

-- Reading a channel back out of the model. A single-line mix with a constant weight, no offset,
-- no curve and no switch of its own is fully computable; anything more involved is reported as
-- found but not derived, because inverting it means simulating the mixer and getting that
-- subtly wrong is easy.
function M.describeChannel(channel)
  local count = M.mixesCount(channel)
  if count == nil then return nil end

  local info = { channel = channel, count = count, lines = {} }
  for i = 0, count - 1 do
    local mix = M.getMix(channel, i)
    if mix then info.lines[#info.lines + 1] = mix end
  end

  if count == 0 then
    info.state = "empty"
    return info
  end

  local first = info.lines[1]
  local simple = (count == 1) and (first ~= nil)
  if simple then
    if (tonumber(first.curveType) or 0) ~= 0 then simple = false end
    if (tonumber(first.offset) or 0) ~= 0 then simple = false end
    if (tonumber(first.switch) or 0) ~= 0 then simple = false end
  end

  info.state = simple and "derived" or "found"
  if first then
    info.source = tonumber(first.source)
    info.sourceName = callGlobal("getSourceName", info.source)
    info.weight = tonumber(first.weight)
  end

  -- Follow the input, because that is where this assistant puts the source. A layout it wrote
  -- itself has the mixer line pointing at an input and the switch one step further in, so a
  -- reader that stops at the mixer line cannot recognise its own work on a second run -- and the
  -- pilot would be asked again for a switch that is already there.
  local viaInput = info.source ~= nil and M.inputIndexOfSource(info.source) or nil
  if viaInput ~= nil then
    info.viaInput = viaInput
    local line = M.getInput(viaInput, 0)
    if line then
      info.source = tonumber(line.source)
      info.sourceName = callGlobal("getSourceName", info.source)
      info.inputName = line.inputName
    end
  end
  return info
end

-- Is this channel laid out the way this assistant lays one out?
--
-- It answers the SHAPE and deliberately not which switch: which switch is the pilot's answer and
-- is not knowable before they give it. `nil` where the model cannot be read at all, so a missing
-- API is never reported as a channel that is merely wrong.
function M.channelFooting(entry)
  if type(entry) ~= "table" or entry.input == nil then return nil end
  local mixSource = M.inputSource(entry.input)
  local count = M.mixesCount(entry.channel)
  local inputLines = M.inputCount(entry.input)
  if mixSource == nil or count == nil or inputLines == nil then return nil end
  if inputLines == 0 or count == 0 then return false end

  -- Every line takes this channel's own input -- the throttle included, whose whole shape
  -- lives on the input's two alternative lines rather than on a second mixer line.
  for index = 0, count - 1 do
    local mix = M.getMix(entry.channel, index)
    if mix == nil then return false end
    if tonumber(mix.source) ~= mixSource then return false end
  end

  local line = M.getInput(entry.input, 0)
  if line == nil or line.inputName ~= entry.inputName then return false end
  if tonumber(line.trimSource) ~= M.TRIM_OFF then return false end
  local output = M.getOutput(entry.channel)
  if output == nil or output.name ~= entry.channelName then return false end
  return true
end

-- Writing. Nothing here is called until the pilot has seen the whole list on one screen and
-- pressed once: an assistant that writes a channel per step leaves states behind that are not
-- safe on their own.
function M.clearChannel(channel)
  local fn = modelApi("deleteMix")
  if not fn then return false end
  local count = M.mixesCount(channel) or 0
  for _ = 1, count do
    local ok = pcall(fn, channel - 1, 0)
    if not ok then return false end
  end
  return true
end

local MULTIPLEX_ADD = 0
local MULTIPLEX_REPLACE = 2

-- Lay the INPUT out for a channel this assistant owns: the picked switch becomes the input's
-- source and the input carries its name. Returns the mix source every line of that channel then
-- has to use.
--
-- Nothing of an existing input is carried across. The stick version does carry the curve, because
-- there it may be re-laying an input the pilot has tuned for that same stick; here the input is
-- being given a switch it did not have, and a curve left over from whatever was on it before
-- would be applied to that switch.
-- `weight` is the whole of the polarity question, and it is the caller's because only the caller
-- knows which way round this channel has to read.
local function writeChannelInput(entry, swsrc, weight)
  local insertInput = modelApi("insertInput")
  local deleteInput = modelApi("deleteInput")
  if not insertInput or not deleteInput then return nil, "no_model_api" end
  if entry.input == nil then return nil, "no_input" end

  local source = M.switchSource(swsrc)
  if source == nil then return nil, "no_source" end
  local mixSource = M.inputSource(entry.input)
  if mixSource == nil then return nil, "no_input_source" end

  local line = {
    name = "",
    inputName = entry.inputName,
    source = source,
    weight = tonumber(weight) or 100,
    offset = 0,
    switch = 0,
    curveType = 0,
    curveValue = 0,
    scale = 0,
    side = 3,
    trimSource = M.TRIM_OFF,
    flightModes = 0
  }

  local count = M.inputCount(entry.input) or 0
  for _ = 1, count do
    if not pcall(deleteInput, entry.input, 0) then return nil, "clear_input_failed" end
  end
  if not pcall(insertInput, entry.input, 0, line) then return nil, "insert_input_failed" end
  return mixSource
end

-- Does the picked position read HIGH on this switch, or low?
--
-- Nothing in the model says. A mixer line records which switch feeds a channel and never which of
-- its positions is the one the pilot meant, and assuming that an upper position yields an upper
-- value is the defect a real flight controller caught: it reported the function off at exactly the
-- position that had been chosen.
--
-- So it is read instead, and it can be read whatever position the switch is resting in. The radio
-- answers two things at once -- the switch's live value, and whether the picked position is the
-- active one -- and the pair gives the mapping: if the picked position is the one being held, the
-- sign of the value is the sign this channel wants; if it is not, the wanted sign is the opposite.
--
-- `nil` where the answer would be a guess: a switch resting at centre has no sign, which on a
-- two-position switch cannot happen and is therefore a fault rather than a case.
function M.pickedReadsHigh(swsrc)
  local source = M.switchSource(swsrc)
  if source == nil then return nil end
  local value = tonumber(callGlobal("getValue", source))
  if value == nil or value == 0 then return nil end
  local held = M.switchActive(swsrc)
  if held == nil then return nil end
  return (value > 0) == held
end

-- A channel that carries the switch's FULL TRAVEL, one value per position.
--
-- The profile channel is the only one, and it is not a condition: its three positions map onto
-- three profiles through an adjustment, so what has to reach the board is the travel and not a
-- two-state high or low. It kept this shape while the condition channels moved off it, and it is
-- separated here because sharing the write is what took it along with them -- caught by the
-- layout script, which counts what a walk leaves in the model.
function M.writeTravelChannel(entry, swsrc)
  local insert = modelApi("insertMix")
  if not insert then return false, "no_model_api" end
  local mixSource, err = writeChannelInput(entry, swsrc)
  if mixSource == nil then return false, err end
  if not M.clearChannel(entry.channel) then return false, "clear_failed" end
  local ok = pcall(insert, entry.channel - 1, 0, {
    source = mixSource,
    weight = 100,
    offset = 0,
    switch = 0,
    multiplex = MULTIPLEX_ADD,
    curveType = 0,
    curveValue = 0,
    flightModes = 0
  })
  if not ok then return false, "insert_failed" end
  M.setChannelName(entry.channel, entry.channelName)
  return true
end

-- A condition channel: the picked position turns the function on, and the channel is built so
-- that it reads at the top of the travel there and at the bottom everywhere else.
function M.writeConditionChannel(entry, swsrc)
  local insert = modelApi("insertMix")
  if not insert then return false, "no_model_api" end
  -- ONE line, and the polarity is measured rather than built around.
  --
  -- This was briefly two lines -- a floor plus a gated override -- which produced the right value
  -- for any switch without knowing anything about it. On a two-position switch, which is the only
  -- kind these channels take, it produces exactly the same two values as a plain one-to-one does,
  -- so it was paying an extra mixer line for an answer a single reading gives.
  --
  -- What it was really for was the assumption underneath: that the picked position reads high.
  -- That assumption is gone either way; here it is replaced by asking the radio, and the answer
  -- goes into the INPUT's weight. The mixer line is then the plain one the pilot would draw.
  local high = M.pickedReadsHigh(swsrc)
  if high == nil then return false, "switch_unreadable" end

  local mixSource, err = writeChannelInput(entry, swsrc, high and 100 or -100)
  if mixSource == nil then return false, err end
  if not M.clearChannel(entry.channel) then return false, "clear_failed" end

  local ok = pcall(insert, entry.channel - 1, 0, {
    source = mixSource,
    weight = 100,
    offset = 0,
    switch = 0,
    multiplex = MULTIPLEX_ADD,
    curveType = 0,
    curveValue = 0,
    flightModes = 0
  })
  if not ok then return false, "insert_failed" end

  M.setChannelName(entry.channel, entry.channelName)
  return true
end

-- The throttle channel, in the REFERENCE construction: the channel is a plain one-to-one from
-- its own input, and the whole shape lives on that input's two ALTERNATIVE lines -- expo lines
-- are alternatives, the first whose gate matches wins. Line one is MAX at -100, gated by the
-- one position the pilot names as the LOCK, so exactly that position pins the motor; line two
-- is the governor switch at full weight, so every other position carries its travel -- off,
-- spool-up, flight. This is the shape the pilot's own reference models carry and the shape the
-- template's wizard writes, and having ONE construction is the point: the assistant proposes
-- it back instead of re-asking in different words.
function M.writeThrottleChannel(entry, lockSwsrc, govSwsrc)
  local insert = modelApi("insertMix")
  local insertInput = modelApi("insertInput")
  local deleteInput = modelApi("deleteInput")
  if not insert or not insertInput or not deleteInput then return false, "no_model_api" end
  if entry.input == nil then return false, "no_input" end
  if govSwsrc == nil or govSwsrc == 0 then return false, "no_gov" end

  local maxSource = M.plainSource("MAX")
  if maxSource == nil then return false, "no_max" end
  local govSource = M.switchSource(govSwsrc)
  if govSource == nil then return false, "no_source" end
  local mixSource = M.inputSource(entry.input)
  if mixSource == nil then return false, "no_input_source" end

  local function line(source, weight, gate, name)
    return {
      name = name or "",
      inputName = entry.inputName,
      source = source,
      weight = weight,
      offset = 0,
      switch = gate or 0,
      curveType = 0,
      curveValue = 0,
      scale = 0,
      side = 3,
      trimSource = M.TRIM_OFF,
      flightModes = 0
    }
  end

  local count = M.inputCount(entry.input) or 0
  for _ = 1, count do
    if not pcall(deleteInput, entry.input, 0) then return false, "clear_input_failed" end
  end
  if not pcall(insertInput, entry.input, 0, line(maxSource, -100, lockSwsrc, "Hold")) then
    return false, "insert_input_failed"
  end
  if not pcall(insertInput, entry.input, 1, line(govSource, 100, 0, "GOV")) then
    return false, "insert_input_failed"
  end

  if not M.clearChannel(entry.channel) then return false, "clear_failed" end
  local ok = pcall(insert, entry.channel - 1, 0, {
    source = mixSource,
    weight = 100,
    offset = 0,
    switch = 0,
    multiplex = MULTIPLEX_ADD,
    curveType = 0,
    curveValue = 0,
    flightModes = 0
  })
  if not ok then return false, "insert_failed" end
  M.setChannelName(entry.channel, entry.channelName)
  return true
end

-- A plain source by the name the firmware knows it under -- MAX is the one this file needs:
-- the reference construction pins the hold line to the top of the travel through it.
function M.plainSource(name)
  local id = callGlobal("getSourceIndex", name)
  if id ~= nil then return tonumber(id) end
  local info = callGlobal("getFieldInfo", name)
  if type(info) == "table" and info.id ~= nil then return tonumber(info.id) end
  return nil
end

-- The mix source that stands for an input. The inputs are the first block of mix sources -- the
-- enumeration opens with "none" and the input block follows it -- so input n is source n + 1. It
-- is derived rather than looked up by name because an input's NAME is something the pilot edits,
-- and a source resolved from a name would move when they rename it.
--
-- The bound is the control, and it is deliberately NOT a check that the radio knows the source.
-- The firmware only reports an input source as available while that input carries at least one
-- line, so asking for the source of an EMPTY input answers nothing -- which is precisely the
-- state every channel is in before this assistant lays it out. Using that as the control refused
-- the write on exactly the models the assistant exists for, and reported it as a channel that
-- could not be read rather than as one that is not there yet.
local MIXSRC_FIRST_INPUT = 1
local MAX_INPUTS = 32

function M.inputSource(inputIndex)
  inputIndex = tonumber(inputIndex)
  if inputIndex == nil or inputIndex < 0 or inputIndex >= MAX_INPUTS then return nil end
  return MIXSRC_FIRST_INPUT + inputIndex
end

-- Is this source id one of the INPUTS? The input block is the first one, so input n is id n + 1,
-- and an id that addresses an input with lines on it is an input rather than a control.
--
-- The test exists because a name cannot tell them apart: an input the pilot has not named is
-- DISPLAYED under the name of its own source, so on a factory model `getSourceIndex("Ail")`
-- answers with the input that happens to carry the aileron stick -- and writing that back makes an
-- input feed itself. Measured on a fresh model: the four stick inputs came out as I3, I1, I2 and
-- one stick, which is what a name lookup produces here rather than a wrong constant.
local MAX_INPUTS_SCAN = 31

-- Is this source id one of the INPUTS? Answered by building the set of ids the inputs actually
-- occupy, rather than by inverting the arithmetic -- `id - 1` is only an input index while it IS
-- one, and asking `getInputsCount` about an index past the end answers something rather than
-- refusing. Reading that answer as "yes, an input" rejected every stick on the first attempt.
function M.inputIndexOfSource(id)
  id = tonumber(id)
  if id == nil then return nil end
  for index = 0, MAX_INPUTS_SCAN do
    local count = M.inputCount(index)
    if count ~= nil and count > 0 and M.inputSource(index) == id then return index end
  end
  return nil
end

local function isInputSource(id)
  return M.inputIndexOfSource(id) ~= nil
end

-- The source id of a control, asked of the RADIO and of nothing else.
--
-- The firmware's stick sources are SEMANTIC: reading one applies the stick mode itself, so the id
-- that stands for roll is the same id whatever mode the radio is in, and there is nothing here to
-- correct for. `getFieldInfo` hands that id over against a name the firmware generated from the
-- target description -- see `field` on the table above.
--
-- CORRECTED. This used to go through the MODEL: it asked which channel a function sits on by
-- default and then read the source out of the input sitting at that channel. That is only true
-- while the inputs are still in the radio's own default order, and on a model already laid out
-- for a flight controller they are not -- the two orders differ by exactly the roll/yaw pair. So
-- every lookup landed one input away and the assistant wrote roll and yaw into each other's
-- inputs. Measured on a transmitter model that was correct before the run and wrong after it, and
-- invisible until then because the run that established this step used a factory-fresh model,
-- where the two orders agree.
--
-- The general form is worth keeping: a question about the RADIO must not be answered out of the
-- MODEL, because the model is the thing being changed.
function M.controlSources()
  local found = {}
  for _, entry in ipairs(M.STICK_INPUTS) do
    local info = callGlobal("getFieldInfo", entry.field)
    local id = type(info) == "table" and tonumber(info.id) or nil
    -- Used only where the radio agrees the source exists, and never where it resolves to an
    -- INPUT -- that is the shape the old derivation produced, and an input feeding itself is
    -- what it looked like on the screen.
    if id ~= nil and not isInputSource(id) and callGlobal("getSourceName", id) ~= nil then
      found[entry.stick] = id
    end
  end
  return found
end

-- The source for one entry, from a map captured before the first write. A control the radio and
-- the model do not agree on has no answer here, and then nothing is written for that channel: a
-- guessed source id would have the shape of a fact.
function M.controlSource(entry, cache)
  if type(entry) ~= "table" then return nil end
  local map = cache or M.controlSources()
  return map[entry.stick]
end

function M.inputCount(inputIndex)
  local fn = modelApi("getInputsCount")
  if not fn then return nil end
  local ok, value = pcall(fn, inputIndex)
  if not ok then return nil end
  return tonumber(value) or 0
end

function M.getInput(inputIndex, line)
  local fn = modelApi("getInput")
  if not fn then return nil end
  local ok, value = pcall(fn, inputIndex, line)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

-- What one stick input holds today, against what the layout asks of it.
function M.describeStick(entry, cache)
  local info = {
    entry = entry,
    lines = M.inputCount(entry.input),
    wantSource = M.controlSource(entry, cache)
  }
  local first = M.getInput(entry.input, 0)
  if first then
    info.source = tonumber(first.source)
    info.sourceName = callGlobal("getSourceName", info.source)
    info.inputName = first.inputName
  end
  local mixSource = M.inputSource(entry.input)
  local mix = M.getMix(entry.channel, 0)
  info.mixCount = M.mixesCount(entry.channel)
  info.mixSource = mix and tonumber(mix.source) or nil
  info.wantMixSource = mixSource

  info.sourceOk = (info.source ~= nil and info.wantSource ~= nil and info.source == info.wantSource)
  info.mixOk = (info.mixCount == 1 and info.mixSource ~= nil and mixSource ~= nil
                and info.mixSource == mixSource)

  -- The names are part of the target state, not decoration on top of it. Leaving them out of the
  -- criterion is how a channel whose SOURCE was already right kept no name at all: the write only
  -- ran where something was wrong, and the naming lived inside the write. What has to come out
  -- right is the end state.
  local output = M.getOutput(entry.channel)
  info.channelNameNow = output and output.name or nil
  info.nameOk = (info.inputName == entry.inputName and info.channelNameNow == entry.channelName)

  -- And so is the trim, for the same reason: a stick input left on its own trim is not the layout
  -- this assistant writes, and a criterion that ignores it would report a model as done while the
  -- trims are still live under the flight controller.
  info.trimOk = (first ~= nil and tonumber(first.trimSource) == M.TRIM_OFF)

  info.ok = info.sourceOk and info.mixOk and info.nameOk and info.trimOk
  return info
end

-- Lay one stick out: the input carries the source and the name, the mixer line carries nothing but
-- the input. Existing lines are replaced rather than added to, because a second line on the same
-- channel is a different setup and not a stronger one.
function M.writeStick(entry, cache)
  local insertInput = modelApi("insertInput")
  local deleteInput = modelApi("deleteInput")
  local insertMix = modelApi("insertMix")
  if not insertInput or not deleteInput or not insertMix then return false, "no_model_api" end

  local source = M.controlSource(entry, cache)
  if source == nil then return false, "no_source" end
  local mixSource = M.inputSource(entry.input)
  if mixSource == nil then return false, "no_input_source" end

  -- The existing first line is read before anything is removed, so the fields this layout does not
  -- speak about -- the curve, the side, which trim follows the input -- are carried across rather
  -- than invented. A fresh input is only built where there was none.
  local existing = M.getInput(entry.input, 0)
  local line = {
    name = "",
    inputName = entry.inputName,
    source = source,
    weight = 100,
    offset = 0,
    switch = 0,
    curveType = existing and existing.curveType or 0,
    curveValue = existing and existing.curveValue or 0,
    scale = existing and existing.scale or 0,
    side = existing and existing.side or 3,
    -- The one field of an existing input that is NOT carried across. The rest is the pilot's
    -- tuning of that stick and survives; the trim is a setting this layout has an opinion about.
    trimSource = M.TRIM_OFF,
    flightModes = 0
  }

  local count = M.inputCount(entry.input) or 0
  for _ = 1, count do
    if not pcall(deleteInput, entry.input, 0) then return false, "clear_input_failed" end
  end
  if not pcall(insertInput, entry.input, 0, line) then return false, "insert_input_failed" end

  if not M.clearChannel(entry.channel) then return false, "clear_failed" end
  local ok = pcall(insertMix, entry.channel - 1, 0, {
    source = mixSource,
    weight = 100,
    offset = 0,
    switch = 0,
    multiplex = MULTIPLEX_ADD,
    curveType = 0,
    curveValue = 0,
    flightModes = 0
  })
  if not ok then return false, "insert_failed" end

  M.setChannelName(entry.channel, entry.channelName)
  return true
end

-- The channel's own label. Not decoration: it is what the pilot reads in the transmitter's output
-- list, and a layout whose channels are called CH1..CH12 is one nobody can check by looking.
-- Every trim of every flight mode, switched off.
--
-- `TRIM_MODE_NONE` is the firmware's own constant, `0x1F`, and it is what the pilot's own target
-- model carries on all of them. This is a DIFFERENT mechanism from the input trim the assistant
-- already turns off: that one says the input does not follow a trim, this one says the flight mode
-- holds no trim to follow. A model can have the first and still be trimmed through the second,
-- which is the state the assistant used to leave.
--
-- The reason is the flight controller's, and it is the same reason as for the input trim: the
-- board holds the model, and a trim under it moves the neutral the board was calibrated against.
--
-- The trim count is read off the radio rather than assumed -- it differs per target -- and the
-- table the setter takes is ONE-based, which its own documentation gets wrong and its code does
-- not.
M.TRIM_MODE_NONE = 0x1F

function M.disableFlightModeTrims()
  local getFlightMode = modelApi("getFlightMode")
  local setFlightMode = modelApi("setFlightMode")
  if not getFlightMode or not setFlightMode then return false, "no_model_api" end

  local first = nil
  local ok = pcall(function() first = getFlightMode(0) end)
  if not ok or type(first) ~= "table" or type(first.trimsModes) ~= "table" then
    return false, "no_flight_modes"
  end

  local trims = 0
  for _ in pairs(first.trimsModes) do trims = trims + 1 end
  if trims == 0 then return false, "no_trims" end

  local modes = {}
  for index = 1, trims do modes[index] = M.TRIM_MODE_NONE end

  local touched = 0
  for mode = 0, MAX_FLIGHT_MODES - 1 do
    local current = nil
    if pcall(function() current = getFlightMode(mode) end) and type(current) == "table" then
      if pcall(setFlightMode, mode, { trimsModes = modes }) then touched = touched + 1 end
    end
  end
  if touched == 0 then return false, "no_flight_mode_written" end
  return true, touched
end

-- Are they already off? Asked of the machine, like every other criterion here, so a model that
-- arrives correct is not written to and a model that is written to can be checked afterwards.
function M.flightModeTrimsOff()
  local getFlightMode = modelApi("getFlightMode")
  if not getFlightMode then return nil end
  for mode = 0, MAX_FLIGHT_MODES - 1 do
    local current = nil
    if not pcall(function() current = getFlightMode(mode) end) then return nil end
    if type(current) ~= "table" or type(current.trimsModes) ~= "table" then return nil end
    for _, value in pairs(current.trimsModes) do
      if tonumber(value) ~= M.TRIM_MODE_NONE then return false end
    end
  end
  return true
end

function M.setChannelName(channel, name)
  local fn = modelApi("setOutput")
  if not fn or type(name) ~= "string" then return false end
  local current = M.getOutput(channel)
  local value = { name = name }
  if current then
    value.min = tonumber(current.min)
    value.max = tonumber(current.max)
    value.offset = tonumber(current.offset)
    value.ppmCenter = tonumber(current.ppmCenter)
    value.symetrical = tonumber(current.symetrical)
    value.revert = tonumber(current.revert)
  end
  return pcall(fn, channel - 1, value)
end

return M
