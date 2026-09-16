-- The radio section of the setup assistant, as PROCEDURES.
--
-- What it establishes is the chain: a switch on this radio reaches a channel, that channel reaches
-- the flight controller, and the flight controller acts on it. Each half exists in the suite
-- already -- the board is told that arming sits on an aux slot, and the radio is told which switch
-- drives which channel -- but nothing today makes the two agree, and a mode configured on a
-- channel no switch reaches looks perfectly configured on its own page.
--
-- The completion criterion of a channel procedure is therefore the END-TO-END, not the half: the
-- mix is present AND the flight controller carries the matching entry. Neither alone is done.
--
-- Every visible string goes through `t(i18n, key, fallback)` with a literal key and a literal
-- one-line fallback, and this file carries its own `pageT` call. That is not style: the build
-- resolves those three things into the locale's own text and leaves anything else as the English
-- fallback in every language.

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = loadModule("app/pages/settings/common.lua")
local M_MSP = loadModule("app/pages/setup_wizard/msp.lua")
local Wlog = loadModule("app/pages/setup_wizard/log.lua") or
  { emit = function() end, wanted = function() return false end, changed = function() return false end }
local t = Common and Common.pageT("setup_wizard") or function(_, _, fb) return fb end

-- The link procedure drives the suite's own ELRS task and shows the status it reports, so it
-- reads that task's translations rather than restating them. The key there is a VARIABLE -- the
-- task decides which state it is in -- which is why this one lookup does not follow the literal
-- key rule the rest of this file does; the task supplies its own English default beside it, and
-- that default is what a locale without the key falls back to.
local tLink = Common and Common.pageT("diagnostics_elrs_link") or function(_, _, fb) return fb end

local procs = {}

local SW_SWITCH = 1
local SW_NONE = 1 << 20
local MAX_SWITCH_POSITIONS = 96
local CHAIN_MOVE_US = 150

-- Where the ends of a stick have to arrive for the chain to be more than merely wired.
--
-- `CHAIN_MOVE_US` alone answers *does this stick reach the board at all* and nothing more: a
-- channel whose travel is cut in half by a weight, a curve or an output limit passes it while
-- delivering four fifths of what the board is set up to expect. The flight controller reads its
-- own endpoints at roughly 1000 and 2000 microseconds, so a stick that stops short is a stick
-- whose full deflection the craft never sees -- and nothing else on this path would ever say so.
--
-- The band is deliberately wider than the nominal ends. It is a check for a stick that falls
-- SHORT, not a calibration, and a hundred microseconds of tolerance at each end keeps a correctly
-- set up radio from being told it is wrong.
local CHAIN_LOW_US = 1100
local CHAIN_HIGH_US = 1900

-- The configurator's own scale for a channel reading: 1500 microseconds is zero, and every five
-- microseconds either side is one percent. Written out here rather than left as arithmetic at the
-- call site, because the point of it is that the number on this screen and the number on the
-- configurator's channel page are the same number.
local function usToPercent(us)
  us = tonumber(us)
  if us == nil then return "?" end
  local value = math.floor((us - 1500) / 5 + 0.5)
  if value > 0 then return "+" .. tostring(value) end
  return tostring(value)
end

-- Adjustment functions, from the firmware's own enumeration. One slot each.
local ADJ_RATE_PROFILE = 1
local ADJ_PID_PROFILE = 2
local ADJ_SLOT_COUNT = 42

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then return value / 100 end
  end
  return 0
end

local function sessionOf()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

-- The name the pilot recognises. While a link is up the suite may have renamed the model after the
-- craft, keeping the original in the board's own store -- so the presence of that stored name is
-- exactly the test for whether a rename is in effect, and it stays correct even when the restore
-- that should undo it never runs.
local function pilotModelName()
  local session = sessionOf()
  local prefs = session and session.modelPreferences
  local stored = prefs and prefs.model and prefs.model.previous_name
  if type(stored) == "string" and stored ~= "" then return stored end
  local model = _G and _G.model
  if type(model) == "table" and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
  end
  return "?"
end

local function channelName(i18n, key)
  if key == "arm" then return t(i18n, "channel_arm", "Arming") end
  if key == "throttle" then return t(i18n, "channel_throttle", "Throttle hold") end
  if key == "profile" then return t(i18n, "channel_profile", "Profile") end
  if key == "rescue" then return t(i18n, "channel_rescue", "Rescue") end
  if key == "aileron" then return t(i18n, "channel_aileron", "Roll") end
  if key == "elevator" then return t(i18n, "channel_elevator", "Pitch") end
  if key == "collective" then return t(i18n, "channel_collective", "Collective") end
  if key == "rudder" then return t(i18n, "channel_rudder", "Yaw") end
  return key
end

local function pickerName(i18n, key)
  if key == "arm" then return t(i18n, "pick_arm", "Switch position for armed") end
  if key == "throttle" then return t(i18n, "pick_throttle", "Motor locked at") end
  if key == "profile" then return t(i18n, "pick_profile", "Profile switch") end
  if key == "rescue" then return t(i18n, "pick_rescue", "Switch position for rescue") end
  return key
end

-- A sentence that belongs to one channel and to nothing else. Not decoration: on the arming
-- channel the choice of switch has a right answer the pilot cannot read off the picker, and on
-- the profile channel what the switch will do is three flight modes rather than the one thing
-- its name says.
-- What this channel's chosen position DOES, in one sentence.
--
-- What stood here was one sentence for all four channels, describing the on-off control rather
-- than the channel -- and it opened with *switched on* / *switched off*, which the pilot read as
-- the switch on their own transmitter, the only switch the rest of the screen talks about. Twice,
-- from two different screens. So a replacement must never open with a word that could belong to
-- the pilot's switch, and it says what the position means rather than what the control does.
--
-- The profile channel gets none: the hint below it already explains the channel completely.
local function channelNote(i18n, key)
  if key == "arm" then
    return t(i18n, "note_ch_arm",
      "At this switch position the flight controller is armed.")
  end
  if key == "throttle" then
    return t(i18n, "note_ch_throttle",
      "Choose which switch stops the motor and which switch drives the governor.")
  end
  if key == "rescue" then
    return t(i18n, "note_ch_rescue",
      "At this switch position the flight controller triggers rescue. In every other position it is off.")
  end
  return nil
end

local function channelHint(i18n, key)
  if key == "arm" then
    return t(i18n, "hint_arm",
      "A two-position switch: armed or not, with no middle position.")
  end
  if key == "profile" then
    return t(i18n, "hint_profile",
      "This switch selects three flight modes: the PID profile and the rate profile change together, one per position.")
  end
  if key == "throttle" then
    return t(i18n, "note_gov_later",
      "The drivetrain section sets the final values. Until then the output side stays unplugged.")
  end
  return nil
end

local function tierName(i18n, tier)
  if tier == "required" then return t(i18n, "tier_required", "required") end
  if tier == "recommended" then return t(i18n, "tier_recommended", "recommended") end
  if tier == "unavailable" then return t(i18n, "tier_unavailable", "not yet") end
  return t(i18n, "tier_optional", "optional")
end

local function entryFor(w, channel)
  for _, entry in ipairs(w.radio.CHANNELS) do
    if entry.channel == channel then return entry end
  end
  return nil
end

local function wanted(w, entry)
  if entry.tier == "unavailable" then return false end
  local selection = w.data.wanted
  if type(selection) ~= "table" then return false end
  return selection[entry.channel] == true
end

-- The prelude, and it belongs to the RUN rather than to the opening screen.
--
-- It establishes the channel selection every later screen reads, and starts the four board reads
-- every completion criterion is derived from. The opening procedure used to own it, which held
-- only while the path was walked in order -- and the comment inside already named the failure it
-- would take: a structure that exists only when one particular procedure ran. The overview makes
-- that real, because a pilot opening one procedure straight from the list never passes the
-- opening at all. So the runner calls this once on load, and the opening screen refreshes it.
local function prime(w)
  local data = w.data
  -- The selection is established HERE and not in the layout procedure, because the layout
  -- procedure is one of the things the quick pass passes over once the board already satisfies
  -- it -- and every channel screen after it reads this table.
  if data.wanted == nil then
    data.wanted = {}
    for _, entry in ipairs(w.radio.CHANNELS) do
      data.wanted[entry.channel] = (entry.tier == "required" or entry.tier == "recommended")
    end
  end
  data.modeRanges = nil
  data.boxIds = nil
  data.boxNames = nil
  data.rxMap = nil
  w.msp.read("rx_map", function(parsed) data.rxMap = parsed w.rebuild() end)
  w.msp.read("boxids", function(parsed)
    data.boxIds = parsed and parsed.box_ids or nil w.rebuild()
  end)
  w.msp.read("boxnames", function(parsed)
    data.boxNames = parsed and parsed.box_names or nil w.rebuild()
  end)
  w.msp.read("mode_ranges", function(parsed)
    data.modeRanges = parsed and parsed.mode_ranges or nil w.rebuild()
  end)
end

procs.prime = prime

-- ---------------------------------------------------------------------------------------------
-- Opening. Not a procedure: it has no completion criterion of its own and nothing to skip, so it
-- is not counted in the section's progress either.
-- ---------------------------------------------------------------------------------------------

procs[#procs + 1] = {
  id = "opening",
  section = "radio",
  counted = false,
  title = function(i18n) return t(i18n, "step_intro", "About") end,
  enter = function(w) prime(w) end,
  screens = {
    {
      id = "about",
      nextLabel = function(i18n) return t(i18n, "begin", "Begin") end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        -- First, and before the description of what the path does, because by the time a pilot
        -- has read that they have already decided. This assistant writes mixer lines, channel
        -- ranges and board settings on a model that is somebody's helicopter; what it is worth
        -- is that it is quick, and what it costs is that it is young. Saying so is the honest
        -- half of offering it at all, and it is one line rather than a dialogue because a
        -- confirmation nobody can decline is a keypress, not a warning.
        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "intro_experimental", "This assistant is experimental. Check what it has written before you fly, and expect its screens and their order to still change.")) + 10

        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "intro_p1", "This assistant sets the transmitter model up for the flight controller and configures the flight controller to match it.")) + 10
        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "intro_p2", "The transmitter setup is needed once per model and survives a change of flight controller. Every flight controller must be set to that layout once.")) + 10
        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "intro_p3", "This part covers the radio and the basics on the board. Drivetrain, servos and mechanics are separate procedures.")) + 10

        -- The one physical precondition of the whole path, and it is on the FIRST screen because
        -- it cannot be met once the run has started.
        --
        -- Everything here writes channel ranges and mixer lines while the pilot moves switches,
        -- and one procedure calibrates the accelerometer. None of that is safe with a motor that
        -- can spin or servos that can drive against their linkage: the assistant deliberately
        -- leaves intermediate states behind that are harmless ON THE BENCH, and harmless is not
        -- the same as harmless with power on the output side.
        w.paragraph(children, area.x, y, area.w, t(i18n, "intro_safety", "Before you start: the flight controller must not be connected to the servos or the motor yet. This path writes and moves things that are only safe with the output side unplugged."))
      end
    },
    {
      id = "start",
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y
        local session = sessionOf()

        -- Naming the model IS the disclosure and the whole of the consent, because a write can
        -- only ever land in the model the pilot has open: Lua registers no way to select another.
        --
        -- The marker is one short word for two reasons. It has a column of its own that is at
        -- most a few dozen pixels wide, so a phrase wraps onto a second line and pushes the rest
        -- of the screen down; and what happens to this model is that its SETTINGS are written,
        -- not that its name is. A marker reading *changed* beside a name says the opposite.
        y = y + w.row(children, area.x, y, area.w,
          t(i18n, "field_model", "Model"), pilotModelName(), t(i18n, "marker_will_change", "target"))

        y = y + w.row(children, area.x, y, area.w,
          t(i18n, "field_firmware", "Firmware"), tostring(session and session.fcVersion or "?"), nil)

        -- The derived walk is not free: it is every procedure's criterion against a board that
        -- answers at about six commands a second. So the screen is painted at once and this line
        -- fills itself in.
        local state
        if w.data.modeRanges == nil then
          state = t(i18n, "state_reading", "reading...")
        else
          local open, total = w.walk()
          state = tostring(open) .. "/" .. tostring(total) .. " " .. t(i18n, "state_open", "open")
        end
        y = y + w.row(children, area.x, y, area.w, t(i18n, "field_progress", "Procedures"), state, nil)

        local resume = w.store and w.store.resume() or nil
        if resume then
          w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "resume_note", "You left this assistant part way through. Next continues where the machine says the work stops."))
        end
      end,
      advance = function(w, done)
        -- Whether the pilot is resuming or starting fresh is not a question: the machine answers
        -- it. Continuing means going to the first procedure the board does not already satisfy,
        -- which on a first run is the first one.
        if w.store then w.store.setSeen() end
        done(true)
      end
    }
  }
}

-- ---------------------------------------------------------------------------------------------
-- 0b -- the board's channel map, and it comes FIRST because everything after it is derived
-- through it.
--
-- Rotorflight has FIVE primary functions, not four: roll, pitch, yaw, collective and throttle are
-- all control channels, and the aux block starts after them. Which WIRE channel carries which of
-- them is `RC_MAP` on the board, and the configurator's four presets are nothing but prepared
-- arrays of it -- index is the function, value is the channel, and their own comment says the
-- array is transposed.
--
-- The one this layout is built on is ELRS. Decoded, it is exactly the layout the assistant writes
-- on the radio side: roll, pitch, collective, yaw on one to four, **arming on five**, throttle on
-- six, and the profile and rescue channels on seven and eight.
--
-- WHY IT IS A PROCEDURE AND NOT AN ASSUMPTION: with the board left at its factory map, channel
-- five is the THROTTLE input and is not an aux channel at all. Every aux slot the assistant
-- derives is then one out, and the arming range -- which has no aux slot to land on -- is silently
-- not written. The screen said *ready* for everything else, because everything else does resolve.
-- Reported from a radio, and reproducible from the two tables alone.
-- ---------------------------------------------------------------------------------------------

-- Index is the function, in the order the board's own accessor names them; the value is the wire
-- channel, zero-based, as the board stores it.
local RX_MAP_FIELDS = { "aileron", "elevator", "rudder", "collective", "throttle", "aux1", "aux2", "aux3" }
local RX_MAP_ELRS = { 0, 1, 3, 2, 5, 4, 6, 7 }

local function rxMapValues(w)
  local raw = w.data.rxMap
  local map = type(raw) == "table" and (raw.parsed or raw) or nil
  if type(map) ~= "table" then return nil end
  local values = {}
  for index, name in ipairs(RX_MAP_FIELDS) do
    local value = tonumber(map[name])
    if value == nil then return nil end
    values[index] = value
  end
  return values
end

local function rxMapMatches(w)
  local values = rxMapValues(w)
  if values == nil then return nil end
  for index, want in ipairs(RX_MAP_ELRS) do
    if values[index] ~= want then return false end
  end
  return true
end

-- The map as the pilot reads it: which wire channel each function sits on, one-based.
local function rxMapText(values)
  if values == nil then return nil end
  local parts = {}
  for index = 1, #values do parts[index] = tostring(values[index] + 1) end
  return table.concat(parts, " ")
end

procs[#procs + 1] = {
  id = "rxmap",
  section = "radio",
  title = function(i18n) return t(i18n, "step_rxmap", "Channel map") end,
  -- Not skippable, like every other radio procedure -- see `wiz.isSkipped` for the reasoning.
  -- The anti-wall duty the skip used to carry sits in `advance` below: a board that does not
  -- answer the map accessor lets the pilot move on with the failure named, and the derived
  -- criterion keeps saying the map is wrong, on the overview and on every later run.
  isComplete = function(w) return rxMapMatches(w) end,
  enter = function(w) w.data.rxMapError = nil end,
  screens = {
    {
      id = "map",
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        y = y + w.paragraph(children, area.x, y, area.w,
          t(i18n, "rxmap_intro", "The board has to be told which channel carries which function. This layout is the ELRS order, and every step after this one depends on it.")) + 6

        local values = rxMapValues(w)
        local match = rxMapMatches(w)

        y = y + w.row(children, area.x, y, area.w,
          t(i18n, "rxmap_board", "On the board"),
          rxMapText(values) or t(i18n, "state_reading", "reading..."),
          match == true and t(i18n, "marker_ok", "ok") or nil)

        y = y + w.row(children, area.x, y, area.w,
          t(i18n, "rxmap_wanted", "ELRS order"),
          rxMapText(RX_MAP_ELRS),
          match == false and t(i18n, "marker_will_change", "target") or nil)

        if w.data.rxMapError then
          w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "write_failed", "The write did not complete.") .. " " .. tostring(w.data.rxMapError))
        end
      end,
      nextLabel = function(i18n) return t(i18n, "rxmap_write", "Set map") end,
      advance = function(w, done)
        if rxMapMatches(w) == true then
          done(true)
          return
        end
        -- Cannot be READ is not the same as differs, and it must not be treated as one: writing a
        -- map because the board did not answer would be writing on no evidence at all.
        if rxMapValues(w) == nil then
          w.data.rxMapError = "no_reply"
          done(true)
          return
        end
        local api = w.msp.api("rx_map")
        if api == nil or type(api.buildWritePayload) ~= "function" then
          w.data.rxMapError = "unavailable"
          done(false)
          return
        end

        local data = {}
        for index, name in ipairs(RX_MAP_FIELDS) do data[name] = RX_MAP_ELRS[index] end

        w.setBusy(t(w.i18n, "writing_title", "Writing"), t(w.i18n, "rxmap_writing", "Writing the channel map"))
        Wlog.emit("info", "rxmap: writing ELRS order %s", rxMapText(RX_MAP_ELRS))
        w.msp.sequence({
          function(nextStep)
            w.msp.write(api.writeCommand, api.buildWritePayload(data),
              function(ok, err) nextStep(ok, err) end)
          end,
          function(nextStep) w.msp.commit(function(ok, err) nextStep(ok, err) end) end
        }, function(ok, err)
          Wlog.emit(ok and "info" or "error", "rxmap: board -> %s", ok and "ok" or tostring(err))
          if not ok then
            w.data.rxMapError = err or "msp"
            done(false)
            return
          end
          -- Read back rather than assume: every aux slot after this is derived from what the
          -- board now holds, not from what was sent to it.
          w.msp.read("rx_map", function(parsed)
            w.data.rxMap = parsed
            done(rxMapMatches(w) == true)
          end)
        end)
      end
    }
  }
}

-- ---------------------------------------------------------------------------------------------
-- 1 -- the channel layout. The target is DECLARED before anything is measured against it;
-- without this the check that follows is a conformance test against an assumption the pilot was
-- never asked about. Ticked means created.
-- ---------------------------------------------------------------------------------------------

procs[#procs + 1] = {
  id = "layout",
  section = "radio",
  title = function(i18n) return t(i18n, "step_layout", "Layout") end,
  isComplete = function(w)
    -- Realised rather than declared: every channel this layout asks for carries mixes. A layout
    -- that is only an intention is not something the board can confirm.
    for _, entry in ipairs(w.radio.CHANNELS) do
      if entry.tier == "required" or entry.tier == "recommended" then
        local count = w.radio.mixesCount(entry.channel)
        if count == nil then return nil end
        if count == 0 then return false end
      end
    end
    return true
  end,
  screens = {
    {
      id = "pick",
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y
        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "layout_intro", "The four sticks are laid out in the next step. Choose what else this run lays out.")) + 8

        for _, entry in ipairs(w.radio.CHANNELS) do
          local name = "CH" .. tostring(entry.channel) .. "  " .. channelName(i18n, entry.key)
          if entry.tier == "required" or entry.tier == "unavailable" then
            y = y + w.row(children, area.x, y, area.w, name, tierName(i18n, entry.tier), nil)
          else
            local channel = entry.channel
            y = y + w.toggleRow(children, area.x, y, area.w, name,
              function() return w.data.wanted[channel] == true end,
              function(value) w.data.wanted[channel] = value end)
          end
        end
      end
    }
  }
}

-- ---------------------------------------------------------------------------------------------
-- 2 -- the channel check. Two screens, because the two halves need different instruments and
-- would not fit on one: what is CONFIGURED is read, and only what cannot be read is measured.
-- ---------------------------------------------------------------------------------------------

procs[#procs + 1] = {
  id = "sticks",
  section = "radio",
  title = function(i18n) return t(i18n, "step_sticks", "Sticks") end,
  -- The one screen of this procedure that WRITES is the reason it has a criterion at all: a stick
  -- layout is a state of the model, so the machine can answer whether it is there. The chain
  -- screen beside it is a measurement and leaves no mark.
  isComplete = function(w)
    -- Part of the criterion rather than only of the write, for the reason this note has already
    -- ruled twice: what has to be right is the END STATE. A model whose sticks are laid out and
    -- whose flight modes still carry trims is not done.
    local trims = w.radio.flightModeTrimsOff()
    if trims == nil then return nil end
    if trims == false then return false end

    local cache = w.radio.controlSources()
    for _, entry in ipairs(w.radio.STICK_INPUTS) do
      local info = w.radio.describeStick(entry, cache)
      if info == nil then return nil end
      if not info.ok then return false end
    end
    return true
  end,
  enter = function(w)
    -- Captured once, before anything is written: the first write rearranges the very
    -- inputs this mapping is read from.
    local cache = w.radio.controlSources()
    w.data.controls = cache
    local rows = {}
    for _, entry in ipairs(w.radio.STICK_INPUTS) do
      rows[#rows + 1] = w.radio.describeStick(entry, cache)
    end
    w.data.sticks = rows
    w.data.sticksError = nil

    local axes = {}
    for _, entry in ipairs(w.radio.STICK_INPUTS) do
      axes[entry.stick] = { seen = false, min = nil, max = nil }
    end
    w.data.chain = { axes = axes, pending = false, last = 0, replied = false }
  end,
  screens = {
    {
      id = "layout",
      nextLabel = function(i18n) return t(i18n, "sticks_write", "Set up") end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        y = y + w.paragraph(children, area.x, y, area.w, t(i18n, "sticks_intro", "The four sticks are laid out for the flight controller: roll, pitch, collective, yaw.")) + 8

        for _, info in ipairs(w.data.sticks or {}) do
          local entry = info.entry
          local source = tostring(info.sourceName or t(i18n, "finding_no_input", "no input"))

          -- Three columns and one comparison. The left names the FUNCTION, so the target no longer
          -- appears twice in a row that then read as a duplicate. The middle puts what is there
          -- next to what it becomes, which is the only pair the pilot is actually comparing. The
          -- marker goes back to being a marker: it says whether this row is acted on, so a row
          -- with nothing to do is quiet instead of as loud as the rest.
          --
          -- `->` is two ASCII characters on purpose; an arrow glyph is not in every EdgeTX font.
          local value, marker
          if info.ok then
            value = source
            marker = t(i18n, "marker_ok", "ok")
          else
            value = source .. " -> " .. entry.channelName
            marker = t(i18n, "marker_change", "change")
          end

          y = y + w.row(children, area.x, y, area.w,
            "CH" .. tostring(entry.channel) .. "  " .. channelName(i18n, entry.key),
            value, marker)
        end

        if w.data.sticksError then
          w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "write_failed", "The write did not complete.") .. " " .. tostring(w.data.sticksError))
        end
      end,
      advance = function(w, done)
        -- The trims of every flight mode, and they are settled here because they belong to the
        -- sticks rather than to a channel: a trim moves the neutral the flight controller was
        -- calibrated against, whichever stick it sits under.
        --
        -- Run before the "nothing to do" test below, because it is a different question. A model
        -- whose four inputs are already laid out can still be carrying live flight-mode trims,
        -- and returning early on the inputs used to leave exactly that.
        if w.radio.flightModeTrimsOff() ~= true then
          local trimOk, trimInfo = w.radio.disableFlightModeTrims()
          Wlog.emit(trimOk and "info" or "warn", "sticks: flight mode trims -> %s",
            trimOk and ("off on " .. tostring(trimInfo) .. " mode(s)") or tostring(trimInfo))
          -- Logged and NOT blocking. A radio whose firmware does not answer for flight modes would
          -- otherwise be walled at this step with nothing to do about it, which is the shape this
          -- path refuses everywhere else. The pressure stays where it belongs: the criterion above
          -- keeps reporting the procedure open, on the overview and on every later run.
        end

        -- Nothing to do is not a write. A model that already carries the layout is left alone
        -- rather than rebuilt, so a second run does not churn the pilot's inputs.
        local pending = {}
        for _, info in ipairs(w.data.sticks or {}) do
          if not info.ok then pending[#pending + 1] = info.entry end
        end
        if #pending == 0 then
          done(true)
          return
        end

        w.setBusy(t(w.i18n, "writing_title", "Writing"), t(w.i18n, "sticks_writing", "Laying out the sticks"))
        Wlog.emit("info", "sticks: writing %d input(s)", #pending)
        for _, entry in ipairs(pending) do
          local ok, err = w.radio.writeStick(entry, w.data.controls)
          Wlog.emit(ok and "info" or "error", "sticks: input %d ch%d -> %s",
            entry.input, entry.channel, ok and "ok" or tostring(err))
          if not ok then
            w.data.sticksError = err or "model"
            done(false)
            return
          end
        end

        local rows = {}
        for _, entry in ipairs(w.radio.STICK_INPUTS) do
          rows[#rows + 1] = w.radio.describeStick(entry, w.data.controls)
        end
        w.data.sticks = rows
        done(true)
      end
    },
    {
      id = "chain",
      -- NOTHING here rebuilds the scene, and that is the point of it.
      --
      -- This screen is the one the pilot holds a stick on, so its values change on nearly every
      -- reply -- which made "repaint only on a change" repaint on nearly every reply, about five
      -- times a second, tearing the whole scene down and building it again each time. The rows are
      -- fed by functions instead: the firmware evaluates a label's text on every refresh, so the
      -- screen is built once and the numbers move by themselves.
      wakeup = function(w)
        local chain = w.data.chain
        if not chain or chain.pending then return end
        local now = nowSeconds()
        if now - (chain.last or 0) < 0.2 then return end
        chain.last = now
        chain.pending = true
        w.msp.read("rc", function(parsed)
          chain.pending = false
          if type(parsed) ~= "table" then return end
          chain.replied = true
          for _, stick in ipairs(w.radio.STICKS) do
            local value = tonumber(parsed[stick.key])
            -- The board reports its channels by FUNCTION, and so does this table, so the two
            -- meet without a label in between.
            local axis = chain.axes[({ aileron = 3, elevator = 1, collective = 2, rudder = 0 })[stick.key]]
            if value ~= nil and axis then
              if axis.min == nil or value < axis.min then axis.min = value end
              if axis.max == nil or value > axis.max then axis.max = value end
              if not axis.seen and axis.min and axis.max and (axis.max - axis.min) >= CHAIN_MOVE_US then
                axis.seen = true
                Wlog.emit("debug", "chain: %s arrives, %d..%d", tostring(stick.key), axis.min, axis.max)
              end
              -- Two answers, not one. *Seen* is the wire; *full* is the travel, and only the
              -- second one says the board is given the whole of what the stick can do.
              if not axis.full and axis.min ~= nil and axis.max ~= nil
                 and axis.min <= CHAIN_LOW_US and axis.max >= CHAIN_HIGH_US then
                axis.full = true
                Wlog.emit("debug", "chain: %s full travel, %d..%d", tostring(stick.key), axis.min, axis.max)
              end
            end
          end
          if Wlog.wanted("trace") then
            local parts = {}
            for _, entry in ipairs(w.radio.STICK_INPUTS) do
              local axis = chain.axes[entry.stick] or {}
              parts[#parts + 1] = string.format("ch%d %s..%s", entry.channel,
                tostring(axis.min or "-"), tostring(axis.max or "-"))
            end
            Wlog.emit("trace", "chain sample: %s", table.concat(parts, "  "))
          end
        end)
      end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        -- No explanation paragraph, deliberately. The four rows ARE the instruction -- each one
        -- says *move it* until it stops saying it -- and a sentence above them cost a row of
        -- height, which on the smaller radios pushed the fourth stick onto a second page. A pilot
        -- cannot move a stick they cannot see move.
        for _, entry in ipairs(w.radio.STICK_INPUTS) do
          local stick = entry.stick
          y = y + w.row(children, area.x, y, area.w,
            "CH" .. tostring(entry.channel) .. "  " .. entry.channelName,
            -- Read on every refresh, so the screen is built once and the numbers move themselves.
            function()
              local chain = w.data.chain or { axes = {} }
              local axis = chain.axes[stick] or {}
              if axis.min == nil or axis.max == nil then
                if chain.replied then return "-" end
                return t(i18n, "state_reading", "reading...")
              end
              -- The two ends SEPARATELY, in the scale the configurator uses for the same
              -- reading: 1500 microseconds is zero and every five above or below it is one
              -- percent, so full deflection is about -100 and +100 there as well. One combined
              -- span number hides the case that matters -- a stick that reaches one end and
              -- falls short at the other reads as a healthy 80 percent and is not.
              return tostring(usToPercent(axis.min)) .. " / " .. tostring(usToPercent(axis.max))
            end,
            -- Three states, because *arrives* and *arrives in full* are different findings and a
            -- screen that collapses them tells the pilot the chain is good when half of it is.
            function()
              local chain = w.data.chain or { axes = {} }
              local axis = chain.axes[stick] or {}
              if axis.full then return t(i18n, "marker_arrives", "arrives") end
              if axis.seen then return t(i18n, "marker_short", "short") end
              return t(i18n, "marker_move", "move it")
            end)
        end
      end
    }
  }
}

-- ---------------------------------------------------------------------------------------------
-- 3 to 6 -- one procedure per channel. Each shows its own FINDING with equally weighted actions,
-- collects a switch, and is complete only when both halves are on the machine.
--
-- The write itself is not here. Arming written while the throttle channel is still unassigned
-- leaves a channel at centre, which the flight controller reads as half throttle rather than as
-- off -- so the set is written once, by the procedure that follows these.
-- ---------------------------------------------------------------------------------------------

local function boxIdFor(w, name)
  local ids, names = w.data.boxIds, w.data.boxNames
  if type(ids) ~= "table" or type(names) ~= "table" then return nil end
  for i = 1, #names do
    if names[i] == name and ids[i] ~= nil then return tonumber(ids[i]) end
  end
  return nil
end

local function modeRangeFor(w, boxId, aux)
  local ranges = w.data.modeRanges
  if type(ranges) ~= "table" or boxId == nil then return nil end
  for index, range in ipairs(ranges) do
    if tonumber(range.id) == boxId and tonumber(range.auxChannelIndex) == aux then
      local from = range.range and tonumber(range.range.start)
      local to = range.range and tonumber(range.range["end"])
      if from ~= nil and to ~= nil and from < to then return index, range end
    end
  end
  return nil
end

-- `taken` carries the slots this PLAN has already promised to another box. The whole plan is
-- derived from one read of the mode ranges, so without it two boxes resolve to the same free
-- slot -- on a board with no ranges yet, every record reads as ARM's (an unused record stores
-- ARM's id) or as empty, both writes land on slot one, and the second silently replaces the
-- first. One mode range on the board where two were written, and nothing anywhere went red.
local function freeModeSlot(w, boxId, aux, taken)
  local ranges = w.data.modeRanges
  if type(ranges) ~= "table" then return nil end
  local index = modeRangeFor(w, boxId, aux)
  if index and not (taken and taken[index]) then return index end
  for i, range in ipairs(ranges) do
    if not (taken and taken[i]) then
      if tonumber(range.id) == boxId then return i end
      local from = range.range and tonumber(range.range.start)
      local to = range.range and tonumber(range.range["end"])
      if from ~= nil and to ~= nil and from >= to then return i end
    end
  end
  return nil
end

-- The throttle channel is complete when BOTH of its lines force the minimum, which is what makes
-- the state it leaves behind safe on its own. A single line, or a line that does not, is not.
local function throttleComplete(w, channel)
  -- The REFERENCE construction: the channel is one plain line from its own input, and the
  -- shape lives on that input -- MAX at -100 gated by the lock position, the governor switch
  -- at full weight beneath it. Expo lines are alternatives, so the lock rules exactly one
  -- position and every other carries the governor's travel.
  local entry = entryFor(w, channel)
  if entry == nil or entry.input == nil then return nil end
  local info = w.radio.describeChannel(channel)
  if info == nil then return nil end
  if info.count ~= 1 then return false end
  local maxSource = w.radio.plainSource("MAX")
  if maxSource == nil then return nil end

  local hold = w.radio.getInput(entry.input, 0)
  local gov = w.radio.getInput(entry.input, 1)
  if hold == nil or gov == nil then return false end
  if tonumber(hold.source) ~= maxSource then return false end
  if (tonumber(hold.weight) or 0) ~= -100 then return false end
  if (tonumber(hold.switch) or 0) == 0 then return false end
  if (tonumber(gov.weight) or 0) ~= 100 then return false end
  if (tonumber(gov.switch) or 0) ~= 0 then return false end

  -- Checked against the answers only where they are known: the criterion is asked from the
  -- overview as well, before the procedure has run.
  local picked = w.data.picked and w.data.picked[channel]
  if picked ~= nil and picked ~= 0 and (tonumber(hold.switch) or 0) ~= picked then
    return false
  end
  local wantGov = w.data.pickedGov and w.data.pickedGov[channel]
  if wantGov ~= nil and wantGov ~= 0
     and tonumber(gov.source) ~= w.radio.switchSource(wantGov) then
    return false
  end
  return true
end

local function makeChannelProcedure(channel, order)
  local proc = {
    id = "ch" .. tostring(channel),
    section = "radio",
    title = function(i18n)
      local entry = { key = ({ [5] = "arm", [6] = "throttle", [7] = "profile", [8] = "rescue" })[channel] }
      return "CH" .. tostring(channel) .. " " .. channelName(i18n, entry.key)
    end
  }

  proc.isComplete = function(w)
    local entry = entryFor(w, channel)
    if entry == nil then return nil end
    if not wanted(w, entry) then return true end

    local role = w.radio.firstRole(entry)
    local count = w.radio.mixesCount(channel)
    if count == nil then return nil end
    if count == 0 then return false end

    -- The LAYOUT is part of being done, not only the value. A switch written straight into the
    -- mixer line produces the same microseconds and is not this setup: the input list stays
    -- empty, so the transmitter shows nothing where the configuration belongs, and neither list
    -- carries a name. What has to be right is the end state.
    local footing = w.radio.channelFooting(entry)
    if footing == nil then return nil end
    if footing == false then return false end

    if role and role.kind == "throttle" then return throttleComplete(w, channel) end

    if role and role.kind == "condition" then
      if w.data.modeRanges == nil or w.data.boxNames == nil then return nil end
      local aux = w.msp.wireChannelToAux(channel, w.data.rxMap)
      if aux == nil then return false end
      local boxId = boxIdFor(w, role.box)
      if boxId == nil then return false end
      return modeRangeFor(w, boxId, aux) ~= nil
    end

    if role and role.kind == "adjustment" then
      -- Only the profile channel gets here, and its slots are read by its own screen because the
      -- table is 42 records long and reading it costs seconds.
      local found = w.data.adjustments
      if found == "unavailable" then return false end
      if type(found) ~= "table" then return nil end
      for _, fn in ipairs(role.functions) do
        if found[fn] == nil then return false end
      end
      return true
    end

    return nil
  end

  -- Complete on the model is not the same as confirmed for this run. The criterion above reads
  -- the switch back off the channel's own input, so a model set up on an earlier run satisfies
  -- it before the pilot has been asked -- and the forward walk then passed this screen while the
  -- write plan still needed the answer that only this screen's `enter` proposes. So the walk
  -- stops here once per run: the found switch comes up pre-selected and one press confirms it.
  -- A channel the run does not want has no answer to hold and is passed over as before.
  proc.confirmed = function(w)
    local entry = entryFor(w, channel)
    if entry == nil or not wanted(w, entry) then return true end
    return w.data.seen ~= nil and w.data.seen[channel] == true
  end

  proc.enter = function(w)
    local data = w.data
    data.picked = data.picked or {}
    data.pickedGov = data.pickedGov or {}
    data.found = data.found or {}
    data.seen = data.seen or {}
    data.seen[channel] = true

    -- A governor already in the model is proposed back, the same way the hold is: the switch is
    -- the source of the channel's second input, so a second run does not ask again for something
    -- that is already there.
    local entry = entryFor(w, channel)
    if entry ~= nil and entry.input ~= nil and entry.key == "throttle"
       and data.pickedGov[channel] == nil then
      -- The governor is the SECOND line of this channel's own input in the reference
      -- construction; its source names the switch exactly.
      local line = w.radio.getInput(entry.input, 1)
      local source = line and tonumber(line.source) or nil
      if source ~= nil then
        data.pickedGov[channel] = w.radio.switchFromSource(source)
      end
    end
    local info = w.radio.describeChannel(channel)
    data.found[channel] = info

    -- What is already on the channel is proposed, and the two halves of it are not equally
    -- knowable. A mix maps EVERY position of its switch, so which position carries the function
    -- is not in it -- except on the throttle channel, where the hold line is gated by exactly
    -- that position and the answer is therefore exact rather than proposed.
    if data.picked[channel] == nil and info then
      local picked = nil
      -- The throttle's lock position is the gate of its input's FIRST line in the reference
      -- construction; every other channel's mix records no gate at all.
      if entry ~= nil and entry.key == "throttle" and entry.input ~= nil then
        local hold = w.radio.getInput(entry.input, 0)
        local gate = hold and tonumber(hold.switch) or 0
        if gate ~= 0 then picked = gate end
      end
      for _, mix in ipairs(info.lines or {}) do
        local gate = tonumber(mix.switch) or 0
        if picked == nil and gate ~= 0 then
          picked = gate
          break
        end
      end
      -- A plain one-to-one MIX carries a switch and not which of its positions means on -- but
      -- on a condition channel the INPUT does: this assistant writes the weight so that the
      -- meant position reads at the top, -100 topping the first position and +100 the last.
      -- So the position is proposed exactly where that signature is found, and NOT AT ALL
      -- where it is not: anything else on the input is not this assistant's work, and a safety
      -- function has no defensible default. The profile channel carries a value across the
      -- whole travel, so for it the switch itself is the answer.
      if picked == nil and info.source and entry ~= nil then
        for swsrc = 1, MAX_SWITCH_POSITIONS do
          local source = w.radio.switchSource(swsrc)
          if source ~= nil and source == info.source then
            picked = w.radio.firstPositionOf(swsrc)
            local role = w.radio.firstRole(entry)
            if role and role.kind == "condition" then
              local line = entry.input ~= nil and w.radio.getInput(entry.input, 0) or nil
              local weight = line and tonumber(line.weight) or nil
              if weight == 100 then
                picked = picked + w.radio.POSITION_DOWN
              elseif weight ~= -100 then
                picked = nil
              end
            end
            break
          end
        end
      end
      data.picked[channel] = picked
    end

    local role = entry and w.radio.firstRole(entry) or nil
    if role and role.kind == "adjustment" and data.adjustments == nil then
      -- The single-slot accessor arrived with API 12.09. Below it the command does not
      -- exist, and asking anyway does not fail loudly -- it stalls the queue behind a
      -- request nothing will answer, which is what took a whole run's write down with it.
      if w.msp.hasPagedReads() ~= true then
        data.adjustments = "unavailable"
        return
      end
      data.adjustments = false
      local found = {}
      local slot = 1
      local function readNext()
        if slot > ADJ_SLOT_COUNT then
          w.data.adjustments = found
          w.rebuild()
          return
        end
        local index = slot
        slot = slot + 1
        w.msp.readIndexed("get_adjustment_range", { index - 1 }, function(parsed)
          local record = parsed and parsed.adjustment_range or nil
          if record and tonumber(record.adjFunction) ~= 0 then
            found[tonumber(record.adjFunction)] = { slot = index, record = record }
          elseif record then
            found.free = found.free or index
          end
          readNext()
        end)
      end
      readNext()
    end
  end

  proc.screens = {
    {
      id = "assign",
      canAdvance = function(w)
        local entry = entryFor(w, channel)
        if entry == nil or not wanted(w, entry) then return true end
        local picked = w.data.picked and w.data.picked[channel]
        if picked == nil or picked == 0 then return false end
        local positions = w.radio.switchPositionCount(picked) or 0
        if entry.needsPositions and positions < entry.needsPositions then return false end
        if entry.exactPositions and positions ~= entry.exactPositions then return false end
        -- The governor carries three values across its travel, so it takes a three-position
        -- switch, and the step waits until one is named.
        if entry.key == "throttle" then
          local gov = w.data.pickedGov and w.data.pickedGov[channel]
          if gov == nil or gov == 0 then return false end
          if (w.radio.switchPositionCount(gov) or 0) < 3 then return false end
        end
        return true
      end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y
        local entry = entryFor(w, channel)
        if entry == nil then return end
        local info = w.data.found and w.data.found[channel] or nil

        -- The finding, with two actions of equal weight. "No mix" is not a defect on a board the
        -- pilot has just replaced under a transmitter they set up years ago, and a screen with one
        -- button has already decided that it is.
        -- What is on the channel, and what "unclear" is allowed to leave out. A finding the pilot
        -- cannot act on is not a finding: where the mixer cannot be read back, the row still says
        -- how many lines are there and what the first one is fed from, because that is what makes
        -- the difference between *something is here* and *this is what is here*.
        local state = t(i18n, "finding_no_mix", "no mix")
        if info and info.state == "derived" then
          state = t(i18n, "finding_found", "mix found") .. " " .. tostring(info.sourceName or "")
        elseif info and info.state == "found" then
          state = t(i18n, "finding_complex", "mix present, source unclear")
            .. " (" .. tostring(info.count or 0) .. ")"
          if info.sourceName then state = state .. " " .. tostring(info.sourceName) end
        end

        local isWanted = wanted(w, entry)

        -- A required channel is not asked about twice.
        --
        -- The layout screen shows it as a fixed row with the word `required` and offers no choice.
        -- This screen then offered the same decision again as a control that could answer it the
        -- other way -- so an answer that was forbidden two screens earlier was available here, and
        -- the run could be left with a channel the layout had called required and this screen had
        -- switched off. The row carries the same word instead, and the way out of a channel the
        -- pilot wants to do themselves is the procedure's own skip, which is a different statement.
        local required = entry.tier == "required" 
        -- One control, and it is the SAME one the layout screen offers for the same decision two
        -- screens earlier. The pair of buttons here asked that question a second way: a button
        -- that already holds the current answer does nothing visible when pressed, which is
        -- exactly what a pilot reported -- pressed it, saw nothing, concluded the screen was
        -- broken. A toggle moves when it is pressed, and it frames neither state as the defect,
        -- which is what the pair was chosen for in the first place.
        local rowName = "CH" .. tostring(channel) .. "  " .. channelName(i18n, entry.key)
        if required then
          -- A SHORT word, and it is a different string from the layout screen's on purpose. That
          -- screen carries the tier in the value column, which is wide; here it goes in the marker
          -- column, which is a fifth of the row and capped at 74 px -- seven characters in the
          -- largest of the three font sets. `erforderlich` needs 119 there, so it would be drawn
          -- over the value beside it.
          y = y + w.row(children, area.x, y, area.w, rowName, state,
            t(i18n, "marker_required", "fixed"))
        else
          y = y + w.findingToggle(children, area.x, y, area.w, rowName, state,
            function() return wanted(w, entry) end,
            function(value)
              w.data.wanted[channel] = value
              w.rebuild()
            end)
        end

        if not isWanted then
          w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "leave_note", "This channel is left as it is. The flight controller is not told about it either."))
          return
        end

        -- Correcting a channel the assistant cannot read IS the point of the button, and the
        -- screen has to say so: *Set up* clears whatever is on the channel and writes the layout
        -- from the switch below. Without this line a pilot looking at *source unclear* has no way
        -- to know that the way out is right in front of them.
        local note = channelNote(i18n, entry.key)
        if note then
          y = y + 6 + w.paragraph(children, area.x, y + 6, area.w, note)
        end

        -- The one sentence that survives from the old generic pair, and only where it is true:
        -- that setting this channel up REPLACES what is already on it. It exists because a screen
        -- reporting a state the assistant cannot read must also name the way out of it.
        -- Only while there is still something to replace. Kept unconditionally it reappeared
        -- after the write -- the channel then carries mixer lines, ours -- and warned about
        -- replacing them on every later visit, which cost the screen a page it did not have.
        if info and (info.count or 0) > 0
          and (proc.isComplete == nil or proc.isComplete(w) ~= true) then
          y = y + 6 + w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "setup_note_replace",
              "Setting this channel up replaces the mixer lines already on it."))
        end

        local hint = channelHint(i18n, entry.key)
        if hint then
          y = y + 4 + w.paragraph(children, area.x, y + 4, area.w, hint)
        end

        -- One field either way, and it starts EMPTY -- there is no defensible default for a
        -- safety function, and a pre-filled form is how a pilot ends up with one they never chose.
        -- Fixed at 150 the label beside it was left 150 px on the narrowest page, which is not
        -- enough for a field name that says what the position is for. The picker itself only ever
        -- shows a switch name, so it is the half that can give.
        local pickerW = math.min(150, math.floor(area.w * 0.42))
        w.label(children, area.x, y + math.floor((w.ROW_H - 18) / 2), area.w - pickerW - 8,
          pickerName(i18n, entry.key), w.font, COLOR_THEME_PRIMARY1)

        -- Two picker kinds for two channel kinds. Where the function sits AT a position -- arming,
        -- the throttle hold, rescue -- the radio's own position picker is exactly right: which
        -- switch and which state collapse into the one answer the pilot already knows from their
        -- transmitter, and naming the position is the half of the answer no rule may settle for
        -- them.
        --
        -- Where the channel carries a VALUE across the whole travel there is no position to name,
        -- because all three are in use, one per profile. Asked with the position picker the pilot
        -- had to pick one of three answers that all mean the same thing, and `proc.enter` then
        -- normalised two of them away with `firstPositionOf`. So that channel gets a list of
        -- SWITCHES, filtered to the ones that can carry it.
        if entry.needsPositions then
          -- The radio's OWN source picker, filtered to switches.
          --
          -- This channel's answer is a whole switch rather than one of its positions -- all three
          -- are spoken for, one per profile -- and EdgeTX has a control for exactly that: the
          -- source picker lists one entry per switch, with the radio's own switch filter in its
          -- menu, and it is answered the way every other picker on this radio is answered. A list
          -- of names built here was a second-best imitation of it, and it behaved like one.
          --
          -- What it returns is the mix SOURCE, which is the very thing that goes into the input.
          -- Everything else here is expressed in switch positions, so the two are translated at
          -- this boundary and nowhere else.
          children[#children + 1] = {
            type = "source",
            x = area.x + area.w - pickerW, y = y + 2, w = pickerW, h = w.ROW_H - 6,
            -- NO `title`. The source picker does not have one: `LvglWidgetChoice` inherits
            -- `LvglTitleParam` and `LvglWidgetSourcePicker` does not, so the property falls
            -- through to the base and the build raises *Invalid property 'title'* on the radio.
            -- It came across unnoticed when this field stopped being a choice, and neither the
            -- gate nor the layout bench can see it -- the one is a compiler and the other never
            -- reaches a real LVGL object.
            filter = (SRC_SWITCH or 0xFFFFFFFF),
            get = function()
              local picked = w.data.picked and w.data.picked[channel]
              if picked == nil or picked == 0 then return 0 end
              return w.radio.switchSource(picked) or 0
            end,
            set = function(value)
              -- The whole switch is the answer here, normalised to its first position -- the
              -- spelling everything downstream shares.
              local first = w.radio.switchFromSource(value)
              w.data.picked[channel] = first or 0
              Wlog.emit("debug", "pick ch%d -> %s", channel,
                tostring(w.radio.switchBaseName(w.data.picked[channel]) or 0))
            end
          }

          -- The picker cannot be filtered to switches with enough positions -- the radio offers
          -- them all -- so the shortfall is said in words rather than left as a Next that will
          -- not press. Nothing is refused here; the gate on the step already does that.
          local picked = w.data.picked and w.data.picked[channel]
          local positions = picked ~= nil and picked ~= 0
            and (w.radio.switchPositionCount(picked) or 0) or nil
          if positions ~= nil and entry.needsPositions and positions < entry.needsPositions then
            w.paragraph(children, area.x, y + w.ROW_H + 6, area.w,
              t(i18n, "pick_needs_three",
                "This switch has two positions. The profile channel needs three, one per profile. Pick a three-position switch."))
          end
          return
        end

        children[#children + 1] = {
          type = "switch",
          x = area.x + area.w - pickerW, y = y + 2, w = pickerW, h = w.ROW_H - 6,
          filter = SW_SWITCH | SW_NONE,
          get = function() return w.data.picked[channel] or 0 end,
          -- No repaint on a change. The button that gates this screen asks a FUNCTION whether it
          -- may be pressed, so it follows the field without the page being rebuilt -- and a rebuild
          -- would throw the focus back to the first row after every choice. The line is the one
          -- record of the answer before the write, which is what makes a report traceable.
          set = function(value)
            w.data.picked[channel] = tonumber(value) or 0
            Wlog.emit("debug", "pick ch%d -> %s", channel,
              tostring(w.radio.switchPositionName(w.data.picked[channel]) or 0))
          end
        }
        y = y + w.ROW_H

        -- Two positions and no more, on the channels that carry a mode. It is a simplification
        -- rather than a limit the machine imposes: with the channel constructed the way it is, a
        -- middle position would work. The pilot's ruling is that this assistant is for a first
        -- setup, and a first setup gets one answer, not three. The picker cannot be filtered by
        -- position count, so the shortfall is said in words; the gate on the step refuses it.
        if entry.exactPositions then
          local picked = w.data.picked and w.data.picked[channel]
          local positions = picked ~= nil and picked ~= 0
            and (w.radio.switchPositionCount(picked) or 0) or nil
          if positions ~= nil and positions ~= entry.exactPositions then
            y = y + 6 + w.paragraph(children, area.x, y + 6, area.w,
              t(i18n, "pick_needs_two",
                "This switch has more than two positions. This channel takes a two-position switch: on, or not."))
          end
        end

        -- The half the field name cannot carry: the lock rules exactly one position, and
        -- every other position hands the channel to the governor's travel.
        if entry.key == "throttle" then
          y = y + 4 + w.paragraph(children, area.x, y + 4, area.w,
            t(i18n, "hold_others_off", "In every other position the governor switch drives the motor."))
        end

        -- The SECOND switch of this channel, and it is a whole switch: all three of its
        -- positions carry values -- off, spool-up, flight -- so the answer is the switch,
        -- the same shape the profile channel needs and the same control the radio offers.
        if entry.key == "throttle" then
          w.data.pickedGov = w.data.pickedGov or {}
          w.label(children, area.x, y + math.floor((w.ROW_H - 18) / 2), area.w - pickerW - 8,
            t(i18n, "pick_governor", "Governor switch"), w.font, COLOR_THEME_PRIMARY1)
          children[#children + 1] = {
            type = "source",
            x = area.x + area.w - pickerW, y = y + 2, w = pickerW, h = w.ROW_H - 6,
            -- No `title`; the source picker does not carry the property (see the profile
            -- channel's note).
            filter = (SRC_SWITCH or 0xFFFFFFFF),
            get = function()
              local picked = w.data.pickedGov[channel]
              if picked == nil or picked == 0 then return 0 end
              return w.radio.switchSource(picked) or 0
            end,
            set = function(value)
              w.data.pickedGov[channel] = w.radio.switchFromSource(value) or 0
              Wlog.emit("debug", "pick ch%d governor -> %s", channel,
                tostring(w.radio.switchBaseName(w.data.pickedGov[channel]) or 0))
            end
          }
          y = y + w.ROW_H

          -- Three positions, because all three carry values -- off, spool-up, flight. Said in
          -- words where a narrower switch is picked; the step's gate refuses it.
          local govPicked = w.data.pickedGov[channel]
          if govPicked ~= nil and govPicked ~= 0
             and (w.radio.switchPositionCount(govPicked) or 0) < 3 then
            y = y + 4 + w.paragraph(children, area.x, y + 4, area.w,
              t(i18n, "gov_needs_three", "This switch has two positions. The governor needs three: off, spool-up, flight."))
          end

          local hold = w.data.picked[channel]
          local gov = w.data.pickedGov[channel]
          -- The starvation check, on POSITIONS: the lock rules one position of whatever switch
          -- carries it, so a lock position ON the governor switch takes that position away
          -- from the travel.
          if hold ~= nil and hold ~= 0 and gov ~= nil and gov ~= 0
             and w.radio.firstPositionOf(hold) == w.radio.firstPositionOf(gov) then
            w.paragraph(children, area.x, y + 4, area.w,
              t(i18n, "gov_starved", "One switch for both, and the hold takes a position from it. Give the governor its own switch, or use one with three positions."))
          end
        end
      end
    }
  }

  return proc
end

for order, channel in ipairs({ 5, 6, 7, 8 }) do
  procs[#procs + 1] = makeChannelProcedure(channel, order)
end

-- ---------------------------------------------------------------------------------------------
-- 7 -- the write, and it is one act for the whole set. Everything before it read; this is where
-- that changes, so the screen is not "are you sure" but a list of what is about to happen, naming
-- both targets: the model on this radio, and this flight controller.
-- ---------------------------------------------------------------------------------------------

local function toS8Byte(value)
  value = math.floor((tonumber(value) or 0) + 0.5)
  if value < -128 then value = -128 end
  if value > 127 then value = 127 end
  if value < 0 then return value + 256 end
  return value
end

local function toS16Bytes(value)
  value = math.floor((tonumber(value) or 0) + 0.5)
  if value < 0 then value = value + 0x10000 end
  return value & 0xFF, (value >> 8) & 0xFF
end

local function stepOf(us)
  local step = (tonumber(us) or 1500) - 1500
  step = step / 5
  if step < -125 then step = -125 end
  if step > 125 then step = 125 end
  return step
end

-- Every channel the run WANTS gets a row here, including one with no switch behind it.
--
-- It used to build a row only where a switch had been picked, so a required channel the pilot
-- skipped -- or never reached -- simply was not on the write screen. No row, no marker, no
-- complaint: the screen listed what it was about to do and the missing channel was not part of
-- that list, which is indistinguishable from a screen that has nothing to say about it. A pilot
-- reported the throttle channel's mixer as never created, and this is how a channel goes missing
-- without anything going wrong.
--
-- A row that says *blocked* is the whole fix. The write loop already skips a blocked action, so
-- nothing about what is written changes -- only what is SHOWN.
local function plannedActions(w)
  local actions = {}
  local takenSlots = {}
  for _, entry in ipairs(w.radio.CHANNELS) do
    if wanted(w, entry) then
      local swsrc = w.data.picked and w.data.picked[entry.channel]
      do
        local role = w.radio.firstRole(entry)
        local action = {
          entry = entry,
          role = role,
          swsrc = swsrc,
          govSwsrc = w.data.pickedGov and w.data.pickedGov[entry.channel] or nil,
          switchName = w.radio.switchPositionName(swsrc),
          aux = w.msp.wireChannelToAux(entry.channel, w.data.rxMap)
        }
        if role and role.kind == "condition" then
          action.boxId = boxIdFor(w, role.box)
          action.window = w.radio.windowFor(swsrc)
          if action.boxId and action.aux then
            action.slot = freeModeSlot(w, action.boxId, action.aux, takenSlots)
            if action.slot then takenSlots[action.slot] = true end
          end
        elseif role and role.kind == "adjustment" then
          action.travel = w.radio.travelRange(swsrc)
          action.slots = {}
          local found = w.data.adjustments
          if type(found) == "table" then
            local nextFree = found.free
            for _, fn in ipairs(role.functions) do
              local hit = found[fn]
              if hit then
                action.slots[fn] = hit.slot
              elseif nextFree then
                action.slots[fn] = nextFree
                nextFree = nextFree + 1
              end
            end
          end
        end
        actions[#actions + 1] = action
      end
    end
  end
  return actions
end

local function actionBlocked(action)
  local role = action.role
  if role == nil then return true end
  -- No switch, nothing to write. This is the case that used to be absent from the list rather
  -- than blocked in it.
  if action.swsrc == nil or action.swsrc == 0 then return true end
  -- The throttle needs BOTH its answers: without the governor the reference construction has
  -- no second line to carry the travel.
  if role.kind == "throttle" and (action.govSwsrc == nil or action.govSwsrc == 0) then
    return true
  end
  -- Both surfaces index the same array in the firmware, so both take the same bound, and
  -- neither write path enforces it. A field past the end is not refused and not clamped;
  -- it is stored and then read out of bounds on every evaluation.
  if role.kind ~= "throttle" and not M_MSP.auxFieldUsable(action.aux) then return true end
  if role.kind == "condition" then
    return action.boxId == nil or action.slot == nil
  end
  if role.kind == "adjustment" then
    if action.travel == nil then return true end
    for _, fn in ipairs(role.functions) do
      if action.slots == nil or action.slots[fn] == nil then return true end
    end
    return false
  end
  return false
end

-- The plan rests on five board reads, and one of them is not a single request: the adjustment
-- ranges are enumerated one slot at a time, which is tens of seconds on a radio link. Every one
-- of them can therefore still be outstanding while the plan screen is already on the display.
--
-- A stamp over the five is what makes that recoverable. The plan used to be derived once, in the
-- procedure's `enter`, so a screen opened during the enumeration resolved no adjustment slot,
-- blocked the action that needs one, and STAYED blocked -- the enumeration's own `rebuild` redraws
-- the screen and does not re-derive what it draws. Waiting did not help, which is the part that
-- made it unreadable from the outside.
local function planReadsStamp(w)
  local data = w.data
  local adjustments = data.adjustments
  return table.concat({
    type(adjustments) == "table" and "table" or tostring(adjustments),
    type(data.modeRanges) == "table" and #data.modeRanges or -1,
    type(data.boxIds) == "table" and #data.boxIds or -1,
    type(data.boxNames) == "table" and #data.boxNames or -1,
    data.rxMap ~= nil and "map" or "-"
  }, "/")
end

-- Whether the plan is blocked on a board that has not finished answering, as opposed to a plan
-- that has nothing in it. The distinction is the whole content of the refusal below: the first
-- resolves by itself and the second never does, and a pilot cannot tell them apart from a row
-- that says `blocked` in both cases. `false` is the adjustment enumeration's own in-flight
-- marker; the other four are simply absent until their reply lands.
local function planStillReading(w)
  local data = w.data
  return data.adjustments == false
    or data.rxMap == nil or data.modeRanges == nil
    or data.boxIds == nil or data.boxNames == nil
end

procs[#procs + 1] = {
  id = "commit",
  section = "radio",
  title = function(i18n) return t(i18n, "step_write", "Write") end,
  isComplete = function(w)
    -- Derived from the channel procedures rather than from a flag: the set is written when every
    -- channel it covers is complete on both sides.
    local anyUnknown = false
    for _, proc in ipairs(w.procedures()) do
      if proc.section == "radio" and string.sub(tostring(proc.id), 1, 2) == "ch" then
        local value = w.isComplete(proc)
        if value == nil then anyUnknown = true end
        if value == false and not w.isSkipped(proc) then return false end
      end
    end
    if anyUnknown then return nil end
    return true
  end,
  enter = function(w)
    w.data.planStamp = planReadsStamp(w)
    w.data.actions = plannedActions(w)
    w.data.writeError = nil
    w.data.planRefusal = nil
  end,
  screens = {
    {
      id = "plan",
      nextLabel = function(i18n) return t(i18n, "write_now", "Write") end,
      wakeup = function(w)
        -- Re-derived when, and only when, one of the reads it rests on has answered. Deriving it
        -- every wakeup would walk every channel and name every switch several times a second for
        -- an answer that changes perhaps twice in a run; deriving it once on entry is what left a
        -- plan standing that the board had since made writable.
        local stamp = planReadsStamp(w)
        if w.data.planStamp == stamp then return end
        w.data.planStamp = stamp
        w.data.actions = plannedActions(w)
        -- A refusal is a statement about the plan that was refused. This is a different one.
        w.data.planRefusal = nil
        w.rebuild()
      end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        for _, action in ipairs(w.data.actions or {}) do
          local target = tostring(action.switchName or "?")
          if action.swsrc == nil or action.swsrc == 0 then
            target = t(i18n, "no_switch", "no switch chosen")
          end
          local role = action.role
          if role and role.kind == "throttle" then
            target = target .. "  " .. t(i18n, "note_motor_off", "hold and governor")
          elseif role and role.kind == "condition" and action.window then
            target = target .. "  " .. tostring(role.box) .. " " ..
              tostring(action.window.start) .. "-" .. tostring(action.window["end"])
          elseif role and role.kind == "adjustment" then
            target = target .. "  " .. t(i18n, "note_profiles", "profiles 1-3")
          end
          local marker = t(i18n, "marker_ready", "ready")
          if actionBlocked(action) then marker = t(i18n, "marker_blocked", "blocked") end
          y = y + w.row(children, area.x, y, area.w,
            "CH" .. tostring(action.entry.channel) .. " " .. tostring(action.entry.channelName or ""),
            target, marker)
        end

        if w.data.planRefusal == "reading" then
          w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "plan_still_reading",
              "Nothing was written: the flight controller is still being read. Wait until no row says blocked, then press Write again."))
        elseif w.data.planRefusal == "blocked" then
          w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "plan_all_blocked",
              "Nothing was written: every row is blocked. Go back and give each channel a switch."))
        elseif w.data.writeError then
          w.paragraph(children, area.x, y + 6, area.w,
            t(i18n, "write_failed", "The write did not complete.") .. " " .. tostring(w.data.writeError))
        end
      end,
      advance = function(w, done)
        local actions = w.data.actions or {}
        w.data.writeError = nil
        w.data.planRefusal = nil

        -- Nothing writable means nothing to write. Committing anyway would send a lone
        -- persist for a change that was never made, and a failure of it would be reported
        -- as if the plan had failed.
        --
        -- But it is not an ADVANCE either, and it used to be one. The screen went on to the
        -- verification, which then held the switches against a flight controller nobody had
        -- written: every row of it waited for a change that was never sent, and a row whose
        -- board happened to already agree reported ok. A write that did not happen must not be
        -- able to produce either of those, so the refusal stays on this screen and says which of
        -- the two reasons it is -- a plan that is only unread yet becomes writable by itself, a
        -- plan with no switches in it never does.
        local writable = false
        for _, action in ipairs(actions) do
          if not actionBlocked(action) then writable = true break end
        end
        if not writable then
          w.data.planRefusal = planStillReading(w) and "reading" or "blocked"
          done(false)
          return
        end

        w.setBusy(t(w.i18n, "writing_title", "Writing"), t(w.i18n, "writing_message", "Writing the model and the flight controller"))
        for _, action in ipairs(actions) do
          Wlog.emit("info", "commit: ch%d %s switch=%s aux=%s slot=%s %s",
            action.entry.channel, tostring(action.role and action.role.kind),
            tostring(action.switchName), tostring(action.aux), tostring(action.slot),
            actionBlocked(action) and "BLOCKED" or "ready")
        end

        -- The radio half first, and as one act. Nothing is committed to the board until every
        -- mixer line of the set is in place.
        for _, action in ipairs(actions) do
          if not actionBlocked(action) then
            local ok, err
            -- Three kinds, three constructions. It used to be two, with everything that was not
            -- the throttle taking the condition write -- which quietly took the PROFILE channel
            -- with it the moment that write stopped passing the switch straight through.
            if action.role.kind == "throttle" then
              ok, err = w.radio.writeThrottleChannel(action.entry, action.swsrc, action.govSwsrc)
            elseif action.role.kind == "condition" then
              ok, err = w.radio.writeConditionChannel(action.entry, action.swsrc)
            else
              ok, err = w.radio.writeTravelChannel(action.entry, action.swsrc)
            end
            Wlog.emit(ok and "info" or "error", "commit: ch%d model -> %s",
              action.entry.channel, ok and "ok" or tostring(err))
            if not ok then
              w.data.writeError = err or "model"
              done(false)
              return
            end
          end
        end

        local queue = {}
        for _, action in ipairs(actions) do
          if not actionBlocked(action) then
            local role = action.role
            if role.kind == "condition" then
              local slot, boxId, aux, window = action.slot, action.boxId, action.aux, action.window
              queue[#queue + 1] = function(nextStep)
                w.msp.write(35, {
                  slot - 1, boxId, aux,
                  toS8Byte(stepOf(window.start)), toS8Byte(stepOf(window["end"])), 0, 0
                }, function(ok, err) nextStep(ok, err) end)
              end
            elseif role.kind == "adjustment" then
              for _, fn in ipairs(role.functions) do
                local slot, aux, travel = action.slots[fn], action.aux, action.travel
                queue[#queue + 1] = function(nextStep)
                  local minLo, minHi = toS16Bytes(role.min)
                  local maxLo, maxHi = toS16Bytes(role.max)
                  -- Always enabled, and the firmware has a sentinel for exactly that:
                  -- `enaChannel == 0xFF` means the enable window is not consulted at all.
                  -- That is how a profile selector ships on a craft that does not gate it
                  -- behind a switch. Reproducing it as a wide window on the same channel
                  -- would look equivalent and is not: it would still be evaluated.
                  w.msp.write(53, {
                    slot - 1, fn, 0xFF,
                    toS8Byte(-125), toS8Byte(125),
                    aux,
                    toS8Byte(stepOf(travel.start)), toS8Byte(stepOf(travel["end"])),
                    toS8Byte(0), toS8Byte(0),
                    minLo, minHi, maxLo, maxHi,
                    0
                  }, function(ok, err) nextStep(ok, err) end)
                end
              end
            end
          end
        end
        queue[#queue + 1] = function(nextStep) w.msp.commit(function(ok, err) nextStep(ok, err) end) end

        Wlog.emit("info", "commit: %d board write(s) queued", #queue)
        w.msp.sequence(queue, function(ok, err)
          Wlog.emit(ok and "info" or "error", "commit: board -> %s", ok and "ok" or tostring(err))
          if not ok then
            w.data.writeError = err or "msp"
            done(false)
            return
          end
          -- What was just written is now what the next derivation must see, so the board is asked
          -- again rather than the screen assuming.
          w.msp.read("mode_ranges", function(parsed)
            w.data.modeRanges = parsed and parsed.mode_ranges or w.data.modeRanges
            done(true)
          end)
        end)
      end
    },
    {
      id = "verify",
      wakeup = function(w)
        local verify = w.data.verify
        if verify == nil then
          verify = { pending = false, last = 0, replied = false,
                     statusPending = false, statusLast = 0 }
          w.data.verify = verify
        end
        local now = nowSeconds()

        -- The channel values are the fast half: the pilot is holding a switch and the row has to
        -- move with it.
        if not verify.pending and now - (verify.last or 0) >= 0.2 then
          verify.last = now
          verify.pending = true
          w.msp.read("rc", function(parsed)
            verify.pending = false
            if type(parsed) ~= "table" then return end
            verify.replied = true
            -- No rebuild, for the same reason as the stick screen: this is a LIVE read, so
            -- "repaint on a change" means repaint on nearly every reply, five times a second,
            -- with the whole scene torn down each time. The rows below read themselves instead.
            verify.channels = parsed.channels
          end)
        end

        -- And the board's own state is the slow half. It carries the profile the board has
        -- actually switched to and the reasons it would refuse to arm -- neither of which moves
        -- fast enough to be worth a request five times a second on a link that answers about six.
        if not verify.statusPending and now - (verify.statusLast or 0) >= 1.0 then
          verify.statusLast = now
          verify.statusPending = true
          w.msp.read("status", function(parsed)
            verify.statusPending = false
            if type(parsed) ~= "table" then return end
            verify.status = parsed.parsed or parsed
          end)
        end
      end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        -- What this screen claims, in words, because the marker alone was read as a riddle.
        --
        -- *Arrives* meant "the number in the middle column came from the flight controller" --
        -- which is the whole proof and says none of it. The row now names the aux slot the board
        -- sees the channel on, and the marker says what the board would DO at the position the
        -- switch is resting in right now.
        y = y + w.paragraph(children, area.x, y, area.w,
          t(i18n, "verify_intro", "These values come back from the flight controller, so the channel reaches it. On / off is what it would do at the switch position you are holding now.")) + 6

        -- What each row proves, and it is the END RESULT rather than the write.
        --
        -- The rows used to name the wire -- `CH5 -> AUX1` and a microsecond count -- which says
        -- where something was written and nothing about whether it works. Each row now names the
        -- FUNCTION and the switch that drives it, and shows what the board reports at the position
        -- the switch is resting in this instant. Move the switch and the row has to follow; the
        -- expectation is computed from the switch, so a row can go red.
        --
        -- Still without entering the state it verifies. Arming is the one function whose "the
        -- board reports it" means the board is armed, so that row shows what the board says it
        -- would do and, where it would refuse, its own reason for refusing. Proving that it arms
        -- is the sign-off procedure's, not this screen's.
        local waiting = t(i18n, "marker_waiting", "waiting")
        local okMark = t(i18n, "marker_ok", "ok")
        local badMark = t(i18n, "marker_deviates", "deviates")

        for _, action in ipairs(w.data.actions or {}) do
          local entry, role = action.entry, action.role

          local function state()
            local live = w.data.verify or {}
            local status = live.status

            -- The write skips a blocked action, so nothing about it reached the board and there is
            -- nothing there for the switch to move. Comparing anyway produced both failure modes
            -- this screen has: a row that waits for a change that was never sent, and -- where the
            -- board already happened to hold the value -- a row reporting ok for a write that did
            -- not happen. Neither is readable as *this was never written*, so the row says it.
            if actionBlocked(action) then
              return t(i18n, "verify_not_written", "not written"),
                     t(i18n, "marker_blocked", "blocked")
            end

            local held = action.swsrc ~= nil and action.swsrc ~= 0
              and w.radio.switchActive(action.swsrc) or false

            if role and role.kind == "condition" then
              if action.aux == nil or type(live.channels) ~= "table" then return "-", waiting end
              local us = tonumber(live.channels[5 + action.aux + 1])
              if us == nil or action.window == nil then return "-", waiting end
              local inside = us >= action.window.start and us <= action.window["end"]

              local text
              if entry.key == "arm" then
                if not inside then
                  text = t(i18n, "verify_not_armed", "not armed")
                else
                  local reasons = status
                    and M_MSP.armingDisableReasons(status.arming_disable_flags) or {}
                  if #reasons > 0 then
                    -- The chain is right and the board still will not arm. That is not a wiring
                    -- fault, so it is neither an ok nor a deviation -- it is the board naming its
                    -- own reason, which is the most this screen can honestly show.
                    return string.format(t(i18n, "verify_blocked", "blocked: %s"),
                                         tostring(reasons[1])),
                           t(i18n, "marker_blocked", "blocked")
                  end
                  text = t(i18n, "verify_would_arm", "would arm")
                end
              else
                text = inside and t(i18n, "marker_on", "on") or t(i18n, "marker_off", "off")
              end

              if inside == held then return text, okMark end
              return text, badMark
            end

            if role and role.kind == "adjustment" then
              if status == nil then return "-", waiting end
              local pid = (tonumber(status.current_pid_profile_index) or 0) + 1
              local rate = (tonumber(status.current_control_rate_profile_index) or 0) + 1
              local text = string.format(t(i18n, "verify_profile", "profile %d, rate %d"),
                                         pid, rate)

              -- The whole chain in one comparison, and the only thing anywhere that proves the
              -- adjustment slots were written: the position the switch is resting in against the
              -- profile the board has actually switched to.
              local offset = action.swsrc and w.radio.activePosition(action.swsrc) or nil
              if offset == nil then return text, waiting end
              local want = offset + 1
              if pid == want and rate == want then return text, okMark end
              return text .. string.format(t(i18n, "verify_want", " - want %s"), tostring(want)),
                     badMark
            end

            if role and role.kind == "throttle" then
              if type(live.channels) ~= "table" then return "-", waiting end
              -- Function-ordered, so the fifth entry is the throttle whatever the wire carries it.
              local us = tonumber(live.channels[5])
              if us == nil then return "-", waiting end

              local want = 988
              if not held then
                if action.govSwsrc == nil or action.govSwsrc == 0 then return tostring(us) .. " us", waiting end
                -- What the WRITE put there: the lock position pins the bottom; everywhere else
                -- the governor's own position carries the travel at +100 -- first position
                -- bottom, middle centre, last top.
                local offset = w.radio.activePosition(action.govSwsrc)
                if offset == nil then return tostring(us) .. " us", waiting end
                if offset == w.radio.POSITION_MIDDLE then
                  want = 1500
                elseif offset == w.radio.POSITION_UP then
                  want = 988
                else
                  want = 2012
                end
              end
              local text = tostring(us) .. " us"
              if math.abs(us - want) <= 150 then return text, okMark end
              return text .. string.format(t(i18n, "verify_want", " - want %s"), tostring(want)),
                     badMark
            end

            return "-", waiting
          end

          local label = channelName(i18n, entry.key)
          if action.switchName then
            label = label .. "  " .. tostring(action.switchName)
          end
          y = y + w.row(children, area.x, y, area.w, label,
            function() local value = state() return value end,
            function() local _, marker = state() return marker end)
        end
      end
    }
  }
}

-- ---------------------------------------------------------------------------------------------
-- 8 -- the transmitter link, and it is the strongest case on this path for the assistant existing
-- at all: BOTH sides of this setting are on one screen here and nowhere else.
--
-- The flight controller does not measure the link. It carries a DECLARATION of it --
-- `crsf_telemetry_link_rate` and `_link_ratio` -- and paces every telemetry frame it emits out of
-- a token bucket computed from that pair. Declared faster than the link runs and the board
-- schedules more than the link drains: backlog, dropped frames, values that are stale rather than
-- absent. Declared slower and the bandwidth is simply left unused. Both read as *telemetry is
-- laggy* and neither is an error anywhere.
--
-- Nothing here is new machinery. The suite already walks the module's parameter tree, classifies
-- the packet rate and telemetry ratio fields by name, and writes either side to match the other;
-- and `lib/crsf.lua` multiplexes the frames, so this conversation and the MSP one do not eat each
-- other's replies. This procedure drives that task and shows what it found.
--
-- ON ARMING, deliberately: every frame pushed to the module replaces one RC channel frame for
-- that cycle, so this must not run while the craft is armed. That is not re-tested here -- the
-- assistant's own menu entry is `lockedWhileArmed`, which is the suite's mechanism for it, and a
-- second, weaker test beside it would answer *not armed* for three different reasons.
-- ---------------------------------------------------------------------------------------------

local ELRS_TASK_PATH = "app/pages/tools/diagnostics/elrs_link/elrslink_task.lua"

local function linkTask(w)
  if w.data.linkTask == nil then
    w.data.linkTask = loadModule(ELRS_TASK_PATH) or false
  end
  if w.data.linkTask == false then return nil end
  return w.data.linkTask
end

local function linkIsCrsf()
  local session = sessionOf()
  return session ~= nil and session.telemetryType == "crsf"
end

-- The board's own copy of the pair, and the buffer a write back to it needs. Both live on the
-- session because the task reads them from there; this is the same read the diagnostics page
-- makes, made from here so that a pilot who never opens that page still gets an answer.
local function readTelemetryConfig(w)
  local session = sessionOf()
  if session == nil then return end
  if w.data.linkConfigAsked == true then return end
  w.data.linkConfigAsked = true
  w.msp.read("telemetry_config", function(parsed)
    if type(parsed) == "table" then
      session.crsfTelemetryConfig = {
        mode = parsed.crsf_telemetry_mode,
        linkRate = parsed.crsf_telemetry_link_rate,
        linkRatio = parsed.crsf_telemetry_link_ratio
      }
      session.telemetryConfigBuffer = parsed.buffer
    end
    w.rebuild()
  end)
end

local function boardPair()
  local session = sessionOf()
  local fc = session and session.crsfTelemetryConfig
  if type(fc) ~= "table" then return nil end
  return tonumber(fc.linkRate), tonumber(fc.linkRatio), tonumber(fc.mode)
end

local function modulePair()
  local session = sessionOf()
  local link = session and session.elrsLinkConfig
  if type(link) ~= "table" then return nil end
  return tonumber(link.packetRate), tonumber(link.telemetryRatio),
         link.packetRateLabel, link.telemetryRatioLabel
end

-- One picker over a field the module itself described. Returns the height it took, or 0 where the
-- walk has not produced that field -- a module that does not offer it gets no row rather than an
-- empty one.
-- The values this project offers, in the order it offers them.
--
-- The screen used to hand over the module's whole option list on the grounds that a list of ours
-- can name something a given module cannot do. That is true and it is now the pilot's decision:
-- the list is short, it is ours, and it is maintained here.
--
-- `D500` carries BOTH of its rates in its own label, and that is the point of naming it. It is a
-- DVDA mode: the module repeats every packet, so the handset and the flight controller see 500 Hz
-- while the air runs at 1000. The telemetry schedule divides the AIR rate, so 1000 is the number
-- the board's pacing is computed from -- and on every non-D mode the two coincide, which is why
-- nothing has ever shown the difference.
local LINK_RATES = {
  { key = "333", label = function(i18n) return "333 Hz" end },
  { key = "500", label = function(i18n) return "500 Hz" end },
  { key = "d500", label = function(i18n) return t(i18n, "link_rate_dvda", "D500 - 1000 Hz air") end }
}

local LINK_RATIOS = { "1:4", "1:8", "1:16", "1:32" }

-- Which of the module's own options is this entry? Matched on the module's label, because that
-- string is the only thing the parameter walk brings back. `500` has to refuse `D500` and `F500`
-- explicitly: a plain substring test would take the first of them and quietly offer a different
-- mode under the right name.
local function moduleOptionIndex(options, want)
  for index, option in ipairs(options or {}) do
    local text = string.lower(tostring(option or ""))
    if want == "d500" then
      if string.find(text, "d500", 1, true) then return index - 1 end
    elseif want == "500" then
      if string.find(text, "500", 1, true)
        and not string.find(text, "d500", 1, true)
        and not string.find(text, "f500", 1, true) then return index - 1 end
    elseif want == "333" then
      if string.find(text, "333", 1, true) then return index - 1 end
    else
      if string.find(text, want, 1, true) then return index - 1 end
    end
  end
  return nil
end

local function linkChoice(w, children, area, y, kind, label, task)
  local field = (kind == "rate") and task.getRateField() or task.getRatioField()
  if type(field) ~= "table" or type(field.options) ~= "table" or #field.options == 0 then
    return 0
  end

  -- Our list, reduced to what this module actually has. The choice control has no disabled entry,
  -- so an option it cannot do is left out rather than shown greyed; and if it has none of ours at
  -- all the module's own list stands, because a screen that offers nothing is worse than one that
  -- offers more than we chose.
  local values, indices = {}, {}
  if kind == "rate" then
    for _, rate in ipairs(LINK_RATES) do
      local index = moduleOptionIndex(field.options, rate.key)
      if index ~= nil then
        values[#values + 1] = rate.label(w.i18n)
        indices[#indices + 1] = index
      end
    end
  else
    for _, ratio in ipairs(LINK_RATIOS) do
      local index = moduleOptionIndex(field.options, string.lower(ratio))
      if index ~= nil then
        values[#values + 1] = ratio
        indices[#indices + 1] = index
      end
    end
  end
  if #values == 0 then
    for index, option in ipairs(field.options) do
      values[#values + 1] = option
      indices[#indices + 1] = index - 1
    end
  end

  local pickerW = math.min(150, math.floor(area.w * 0.42))
  w.label(children, area.x, y + math.floor((w.ROW_H - 18) / 2), area.w - pickerW - 8,
    label, w.font, COLOR_THEME_PRIMARY1)

  children[#children + 1] = {
    type = "choice",
    x = area.x + area.w - pickerW, y = y + 2, w = pickerW, h = w.ROW_H - 6,
    title = label,
    values = values,
    -- The module counts its options from zero and the control from one, and this list is a subset
    -- of the module's in our own order -- so the position in the control and the index on the wire
    -- are two different numbers and are kept apart here rather than in the task.
    get = function()
      local current = (kind == "rate") and task.getRateField() or task.getRatioField()
      local selected = current and tonumber(current.selectedIndex) or nil
      if selected ~= nil then
        for position, index in ipairs(indices) do
          if index == selected then return position end
        end
      end
      return 1
    end,
    set = function(value)
      local position = tonumber(value) or 1
      local index = indices[position]
      local current = (kind == "rate") and task.getRateField() or task.getRatioField()
      if index == nil or current == nil or tonumber(current.selectedIndex) == index then return end
      task.selectOption(kind, index)
      w.rebuild()
    end
  }
  return w.ROW_H
end

procs[#procs + 1] = {
  id = "link",
  section = "radio",
  title = function(i18n) return t(i18n, "step_link", "Link") end,
  -- A radio that is not on CRSF has no question here at all -- the screen says so, and nothing
  -- on this procedure gates the step, so Next simply walks on.
  isComplete = function(w)
    if not linkIsCrsf() then return nil end
    local fcRate, fcRatio = boardPair()
    local modRate, modRatio = modulePair()
    if fcRate == nil or fcRatio == nil or modRate == nil or modRatio == nil then return nil end
    return fcRate == modRate and fcRatio == modRatio
  end,
  enter = function(w)
    if not linkIsCrsf() then return end
    readTelemetryConfig(w)
    -- The walk is a READ, so it starts by itself: a pilot arriving here has already asked the
    -- question this screen answers, and an empty screen with a button on it asks them to ask
    -- twice. Every WRITE below still costs a press.
    local task = linkTask(w)
    if task and w.data.linkProbed ~= true then
      w.data.linkProbed = true
      task.start(task.MODE_PROBE)
    end
  end,
  screens = {
    {
      id = "pair",
      wakeup = function(w)
        local task = linkTask(w)
        if task == nil then return end
        if task.isRunning() then task.wakeup() end
        -- Repaint on a CHANGE and on nothing else. This runs at the page's own rate, and a
        -- rebuild on every tick destroys the buttons under the pilot's finger.
        local statusKey = task.getStatus()
        local modRate, modRatio = modulePair()
        local fcRate, fcRatio = boardPair()
        local key = table.concat({
          tostring(statusKey), tostring(modRate), tostring(modRatio),
          tostring(fcRate), tostring(fcRatio), tostring(task.isRunning())
        }, "|")
        if w.data.linkSignature ~= key then
          w.data.linkSignature = key
          Wlog.emit("debug", "link: %s  module %s/%s  board %s/%s",
            tostring(statusKey), tostring(modRate), tostring(modRatio),
            tostring(fcRate), tostring(fcRatio))
          w.rebuild()
        end
      end,
      build = function(w, ctx, area)
        local children, i18n, y = ctx.children, ctx.i18n, area.y

        if not linkIsCrsf() then
          w.paragraph(children, area.x, y, area.w,
            t(i18n, "link_needs_crsf", "This step needs a CRSF link. None of it applies to another telemetry protocol."))
          return
        end

        local task = linkTask(w)
        if task == nil then
          w.paragraph(children, area.x, y, area.w,
            t(i18n, "link_unavailable", "The module probe is not available in this build."))
          return
        end

        -- WHY this matters is in the help, not on the screen. The rule the help file already
        -- states: every explanatory line taken out of a body is a control row gained, and this
        -- screen carries five of them plus two pickers.

        local statusKey, statusDefault = task.getStatus()
        y = y + w.findingRow(children, area.x, y, area.w,
          t(i18n, "link_status", "Probe"), tLink(i18n, statusKey, statusDefault),
          {
            { text = t(i18n, "link_probe", "Read"),
              active = function() return not task.isRunning() end,
              press = function()
                w.data.linkConfigAsked = nil
                readTelemetryConfig(w)
                task.start(task.MODE_PROBE)
                w.rebuild()
              end }
          })

        local fcRate, fcRatio, fcMode = boardPair()
        local modRate, modRatio, modRateLabel, modRatioLabel = modulePair()
        local unknown = t(i18n, "link_unknown", "not read yet")

        local readable = (fcRate ~= nil and fcRatio ~= nil and modRate ~= nil and modRatio ~= nil)
        local differ = readable and not (fcRate == modRate and fcRatio == modRatio)

        local boardText = unknown
        if fcRate ~= nil and fcRatio ~= nil then
          boardText = tostring(fcRate) .. " Hz  1:" .. tostring(fcRatio)
          if fcMode == 0 then boardText = boardText .. "  " .. t(i18n, "link_mode_native", "native") end
        end

        local moduleText = unknown
        if modRate ~= nil and modRatio ~= nil then
          moduleText = tostring(modRateLabel or (tostring(modRate) .. " Hz")) .. "  " ..
            tostring(modRatioLabel or ("1:" .. tostring(modRatio)))
        end

        -- Which side wins is read off the ROW, not off a button.
        --
        -- Two buttons stood at the bottom, *set module* and *set board*, with nothing saying which
        -- direction was the ordinary one -- and a wrong press silently changed the other side. A
        -- button on each row means *use this one*, and aligning the other side is simply what
        -- pressing it does. It is offered only where the two differ; where they agree the marker
        -- says so and there is nothing to press.
        local useThis = t(i18n, "link_use_this", "use this")
        local matches = t(i18n, "marker_matches", "matches")

        if differ then
          y = y + w.findingRow(children, area.x, y, area.w,
            t(i18n, "link_board", "Flight controller"), boardText,
            { { text = useThis,
                active = function() return not task.isRunning() end,
                press = function()
                  task.start(task.MODE_ROTORFLIGHT_TO_ELRS)
                  w.rebuild()
                end } })
          y = y + w.findingRow(children, area.x, y, area.w,
            t(i18n, "link_module", "Transmitter module"), moduleText,
            { { text = useThis,
                active = function() return not task.isRunning() end,
                press = function()
                  task.start(task.MODE_ELRS_TO_ROTORFLIGHT)
                  w.rebuild()
                end } })
        else
          y = y + w.row(children, area.x, y, area.w,
            t(i18n, "link_board", "Flight controller"), boardText,
            readable and matches or nil)
          y = y + w.row(children, area.x, y, area.w,
            t(i18n, "link_module", "Transmitter module"), moduleText,
            readable and matches or nil)
        end

        -- And the pilot may simply SAY what the link should run at.
        --
        -- The two sync buttons below answer "which side wins", which is not the same question as
        -- "what do I want" -- and the option lists these pickers offer are the MODULE's own, read
        -- off it during the walk rather than written down here. A rate this firmware does not
        -- offer therefore cannot be picked, which is the only way a list like this stays true
        -- across module versions.
        y = y + linkChoice(w, children, area, y, "rate",
          t(i18n, "link_pick_rate", "Packet rate"), task)
        y = y + linkChoice(w, children, area, y, "ratio",
          t(i18n, "link_pick_ratio", "Telemetry ratio"), task)

        -- What the two buttons do is in the HELP, not on the screen, and that is the second
        -- attempt rather than the first choice.
        --
        -- Measured on the narrow radios: below the row the sentence landed on the next page, and
        -- moved above the row it landed on the previous one -- the cutter packs whatever fits and
        -- a gap between two elements is where it prefers to cut. A grouping flag was written to
        -- forbid that cut and did not take effect; rather than ship a mechanism that does not do
        -- its job, it is out again and the sentence is where it costs no height at all. The help
        -- is one press and the button labels say their direction on their own.
      end
    }
  }
}

-- ---------------------------------------------------------------------------------------------
-- NOT here, and the reason is the assistant's own entry gate: choosing between the internal and
-- the external module and switching one ON. `model.setModule` can do both -- it takes the module
-- type and goes through the firmware's own `setModuleType` -- but the moment such a write lands,
-- the link to this flight controller is gone, and a module the pilot has just enabled is bound to
-- nothing. The assistant is reachable only WITH a flight controller connected, which is exactly
-- the state in which that choice must not be made. It belongs to a procedure that runs before
-- there is a link, and that is a different entry point rather than a screen missing from this one.
-- ---------------------------------------------------------------------------------------------

return procs
