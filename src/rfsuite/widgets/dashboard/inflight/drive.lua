-- The in-flight tuning drive: what the overlay does to the radio, and when it is allowed to.
--
-- The flight controller's stepped adjustments are reached through two global variables that a
-- mixer line each puts on the enable and the value channel. This module owns those two writes and
-- nothing else. It never speaks MSP -- tasks/msp/runtime.lua clears its own queue on every armed
-- tick, so a write attempted in flight would be dropped without a word -- and it never writes the
-- model: mixer lines, global variable details and trim modes are CHECKED here and reported, never
-- authored.
--
-- Everything that touches the radio goes through the small table `M.radio()` returns, so the
-- state machine can be driven under a plain Lua interpreter with those functions replaced.
--
-- The safety rule the whole file is built around: the value variable is 0 whenever no pulse is
-- running and nothing is held, including after EVERY way out of the overlay. `cleanup` is cheap
-- and idempotent for exactly that reason -- it is run on every transition away rather than on the
-- one transition that happened to be observed.

local M = {}

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

local Setup = requireModule("widgets/dashboard/inflight/setup.lua")
local Functions = requireModule("widgets/dashboard/inflight/functions.lua")

-- A dependency that did not load must not leave a WORKING-LOOKING module behind.
--
-- lib/require.lua caches whatever a chunk RETURNS. Its own load of a dependency goes through
-- pcall, and a pcall catches the firmware's instruction-limit error like any other -- so a widget
-- pass that runs out of budget while one of the files above is being read leaves the require
-- answering nil, this chunk running on to its end with a nil upvalue, and the broken table cached
-- for the rest of the session. Every call into it then raises
--   ?:0: attempt to index a nil value (upvalue '?')
-- on every pass, for ever, and the widget's refresh is abandoned each time. That is what the
-- pilot's card log recorded 913 times after a start with no flight controller: the overlay's
-- modules were first loaded on the pass the connect chain and the theme reload were already
-- filling, and the load that lost the race was cached.
--
-- Raising here instead means the pcall in lib/require.lua fails, NOTHING is cached, and the next
-- pass loads the file again on a budget that may well be quieter. A missing file behaves the same
-- way and is answered by the caller, which keeps its own retry.
if type(Setup) ~= "table" or type(Functions) ~= "table" then
  error("inflight/drive.lua: a dependency did not load", 0)
end

-- Everything about what the model must LOOK like -- the store, the radio seam, the trim block,
-- the setup check -- lives in setup.lua, so that the settings page can have it without this
-- file. Re-exported here because the widget side, the screens and the probes reach for it
-- through this module and there is no reason to make them all learn a second name.
M.DEFAULTS = Setup.DEFAULTS
M.PULSE_MS_MIN = Setup.PULSE_MS_MIN
M.PULSE_MS_MAX = Setup.PULSE_MS_MAX
M.CHANNEL_MIN = Setup.CHANNEL_MIN
M.CHANNEL_MAX = Setup.CHANNEL_MAX
M.GVAR_MAX_INDEX = Setup.GVAR_MAX_INDEX
M.TRIM_COUNT = Setup.TRIM_COUNT
M.PROFILE_MAX = Setup.PROFILE_MAX
M.TRIM_MODE_ROWS = Setup.TRIM_MODE_ROWS
M.TRIM_MODE_NAVIGATE = Setup.TRIM_MODE_NAVIGATE
M.STEP_CHOICES = Setup.STEP_CHOICES
M.nearestStep = Setup.nearestStep
M.radio = Setup.radio
M.RADIO_KEYS = Setup.RADIO_KEYS
M.MODEL_KEYS = Setup.MODEL_KEYS
M.loadRadioSettings = Setup.loadRadioSettings
M.loadModelSettings = Setup.loadModelSettings
M.settings = Setup.settings
M.storeRadioSettings = Setup.storeRadioSettings
M.storeModelSettings = Setup.storeModelSettings
M.resolveTrims = Setup.resolveTrims
M.trimsFromList = Setup.trimsFromList
M.trimEntry = Setup.trimEntry
M.normaliseTrim = Setup.normaliseTrim
M.migrateTrims = Setup.migrateTrims
M.check = Setup.check

local logDrive = Setup.log
local SWITCH_SLICE = Setup.SWITCH_SLICE
local SWITCH_WALK_LIMIT = Setup.SWITCH_WALK_LIMIT

-- A switch has to hold its new reading this long before the overlay believes it. It is not a
-- debounce for the switch, which does not bounce: it is the margin against a pilot brushing the
-- interlock on the way to something else.
local STABILITY_TICKS = 30

-- The walk is EDGE triggered: one press, one parameter. A trim held on purpose then repeats, after
-- a delay long enough that a single press can never produce two steps, at a rate a pilot can still
-- count while looking somewhere else.
local NAV_REPEAT_DELAY_TICKS = 50
local NAV_REPEAT_INTERVAL_TICKS = 33

-- How long the two profile sensors have to agree with themselves before the ground half is told to
-- read the board again. The pilot's own log is the measurement: three profile changes inside
-- thirty seconds, and each of them fired the nine value reads -- twice, because `PID#` and `RTE#`
-- arrive a pass apart and each of them counts as a change on its own. Two seconds is longer than a
-- pilot's hand takes to cross a three-position switch and far shorter than the reads it saves.
--
-- What is NOT debounced is the INVALIDATION. A value read from a profile the board is no longer
-- flying is wrong the instant the switch moves, and showing a dash is the honest answer while
-- nothing has been read; only the re-READ waits.
local PROFILE_SETTLE_TICKS = 200

-- How long the banner naming the new profile stands. The pilot's question was what the overlay is
-- tuning after he moves his profile switch, and the answer has to be on the screen he is looking
-- at rather than in a value that has quietly gone to a dash.
local PROFILE_BANNER_TICKS = 300

-- ---------------------------------------------------------------------------
-- The drive
-- ---------------------------------------------------------------------------

local Drive = {}
Drive.__index = Drive

--- Which parameters the screen offers, before anything has been read off the board.
--
-- In the STANDARD set layout that is the whole answer: the set is a constant of this build, the
-- screen names all thirty-six cells from the first frame, and the ground half reads the board's
-- own slot table only to say whether the board agrees with it. In the CUSTOM layout it is a
-- placeholder -- the documented thirty, which is the best guess available until the board's table
-- has been read and turned into the set it really describes.
--
-- Called again whenever the settings change, because the channels a cell is derived from and the
-- layout it is derived under are both settings.
function Drive:seedSet()
  local standard = (self.settings and self.settings.set_mode) ~= Setup.SET_MODE_CUSTOM
  self.bands = Functions.REFERENCE_BANDS
  self.bankValues = Functions.REFERENCE_BAND_GV
  if standard then
    self.set = Functions.STANDARD_SET
    self.setSource = "standard"
  else
    self.set = Functions.REFERENCE_SET
    self.setSource = "reference"
  end
  self.compare = nil
end

--- A drive with no history: nothing seeded, nothing written, no bank chosen.
function M.newDrive(radio, settings)
  local self = setmetatable({}, Drive)
  self.radio = radio or M.radio()
  self.settings = settings or M.settings(nil, nil)
  self.live = false
  self.seeded = false
  self.rawSwitch = nil
  self.rawSince = nil
  self.bank = 1
  self.row = 1
  self:seedSet()
  self.bankShown = nil
  self.written = 0
  self.writtenFm = nil
  self.bankWritten = nil
  self.bankFm = nil
  self.pulseCode = nil
  self.pulseUntil = nil
  self.coolUntil = 0
  self.holdRow = nil
  self.holdUp = nil
  self.trimRow = nil
  self.trimUp = nil
  self.trimCode = nil
  self.trimHold = false
  self.trimPulseUntil = nil
  self.trimCoolUntil = 0
  self.trims = nil
  self.trimsResolved = false
  self.trimScan = nil
  self.navDir = 0
  self.navNextAt = nil
  self.bankDir = 0
  self.bankNextAt = nil
  self.fastAt = nil
  self.values = {}
  -- TWO counters over the same value table, because two different readers want two different
  -- things. `valueEpoch` is the LAYOUT epoch: the widget's render key carries it, so every bump
  -- is a tree the surface throws away and builds again. `reportEpoch` says only that a number
  -- the surface reads through a closure has moved, and no render key follows it. See the AdjF
  -- block in fastTick for why the board's own answers travel on the second one.
  self.valueEpoch = 0
  self.reportEpoch = 0
  self.profile = nil
  self.rateProfile = nil
  self.profileChanged = nil
  self.profileSettleAt = nil
  self.profileBannerUntil = nil
  -- The three phases the one interlock switch shows, and the state behind them. `phase` is nil
  -- while the overlay is not up; see Drive:setPhase for what each of them means.
  self.phase = nil
  self.fired = 0
  self.post = false
  self.deltaPage = 1
  self.autoBackupWanted = false
  self.stepRefusedUntil = nil
  self.previous = {}
  self.readAt = nil
  return self
end

-- The three phases, as the snapshot spells them.
M.PHASE_GROUND = "ground"
M.PHASE_LIVE = "live"
M.PHASE_POST = "post"

--- Which of the three the overlay is in, and everything that has to happen on a transition.
--
-- The interlock is the ONE entry the pilot has, and what it shows follows the FLIGHT rather than
-- the switch: on the ground before a flight it is the preflight read-out, in the air it is the
-- tuning surface, and on the ground after a flight that moved something it is the delta and the
-- undo. A pilot who has to remember which of three screens a switch is on has one more thing to
-- get wrong in the air than he has thumbs for.
--
-- The consequence worth stating plainly: NOTHING STEPS ON THE GROUND. The step controls and the
-- trims are live in the `live` phase and in no other, because the ground surface carries neither
-- a row list nor a step control and a step nobody can see land is a step nobody should be able to
-- ask for.
function Drive:setPhase(phase)
  if self.phase == phase then return end
  local was = self.phase
  self.phase = phase
  self.valueEpoch = self.valueEpoch + 1

  if phase == M.PHASE_GROUND and was == nil then
    -- The interlock has just been opened, on the ground, before a flight. That is the moment the
    -- undo has to exist, so it is asked for here and nowhere else -- NOT on the interlock's own
    -- rising edge, because an interlock opened IN THE AIR would then take its backup on landing
    -- and overwrite the undo with the values the flight had already moved.
    --
    -- A request and no more: the drive sends no MSP and cannot see the link. The ground half takes
    -- it on its next pass and applies every refusal the button applies.
    self.autoBackupWanted = true
  else
    self.autoBackupWanted = false
  end

  if phase == M.PHASE_LIVE then
    -- A new flight. What the last one changed is no longer the question, and the counter that
    -- decides whether there will be a delta to show starts again.
    self.post = false
    self.fired = 0
    self.deltaPage = 1
  elseif was == M.PHASE_LIVE then
    -- Out of the air. Whatever MAGNITUDE it left standing goes now, whichever transition was seen --
    -- but not the bank, which the interlock is still on for and which the surface goes on showing.
    -- See Drive:cleanup's `keepBank`: the interlock falling, the fullscreen closing, the widget
    -- going to background and the link dropping all still take it to 0, and this is the one
    -- transition that does not.
    self:cleanup(false, true)
    self.deltaPage = 1
  end
  -- `post` is the phase and nothing else: it is what tick reads on the next pass to keep the
  -- postflight surface up, and endPost is what takes it down. Written here rather than inferred,
  -- because a flag set on the transition and cleared at the bottom of the same function is how
  -- the first cut of this managed to leave the phase at `ground` after every flight.
  self.post = (phase == M.PHASE_POST)
  logDrive("phase %s -> %s", tostring(was), tostring(phase))
end

--- Leave the postflight read-out, on any of the three things that end it.
--
-- The LIST is not dropped with it. The delta is computed against the backup's own snapshot, and
-- that snapshot stands until the next backup replaces it -- so a pilot who cycles the interlock
-- and goes back in finds the same list, which is the answer he expects and not a fresh empty one.
function Drive:endPost(why)
  if not self.post then return end
  self.post = false
  self.valueEpoch = self.valueEpoch + 1
  logDrive("postflight ended: %s", tostring(why))
end

-- How long a refused press is said on the screen, in radio ticks. Long enough to read at arm's
-- length, short enough to be gone before the next one.
local REFUSAL_TICKS = 80

function Drive:pulseTicks()
  local ms = tonumber(self.settings and self.settings.pulse_ms) or M.DEFAULTS.pulse_ms
  local ticks = math.floor((ms / 10) + 0.5)
  if ticks < 1 then ticks = 1 end
  return ticks
end

--- The function id sitting in the current cell, or nil when the cell carries no slot.
function Drive:functionId(bank, row)
  local bankSet = self.set and self.set[bank or self.bank]
  if type(bankSet) ~= "table" then return nil end
  return bankSet[row or self.row]
end

local function writeGvar(self, index, fm, value)
  if not index or index <= 0 then return false end
  return self.radio.setGlobalVariable(index - 1, fm, value)
end

--- Put `value` on the value variable, and remember the flight mode it went to.
--
-- The flight mode matters: model.setGlobalVariable resolves a "same as FMx" link itself, so a
-- write made in one mode and cleared in another can leave the first one standing. The clear goes
-- back to the mode the write was made in.
--
-- The BOOKKEEPING IS PESSIMISTIC, and the order of the two lines is the whole of it. A widget pass
-- is killed wherever the firmware's instruction limit happens to land, including between the write
-- and the note of it, and the two orders fail in opposite directions. Recording afterwards, a pass
-- killed in between leaves the drive believing 0 is standing when the row's magnitude is -- and
-- `cleanup(false)` then writes nothing, for ever, because it only clears what it believes it put
-- there. Recording first, the same pass leaves the drive believing a value is standing that is
-- not, and the cost of that is one redundant write of 0.
--
-- Which of the two lines comes first therefore depends on the direction. A value going ON is
-- recorded before it is written; a value going OFF is written before it is un-recorded, because
-- for a clear it is the clear itself that must not be lost.
function Drive:writeValue(value, fm)
  if self.written == value then return end
  local settings = self.settings
  if not settings or (settings.value_gvar or 0) <= 0 then
    self.written = value
    return
  end
  local mode = fm
  if mode == nil then mode = self.writtenFm end
  if mode == nil then mode = self.radio.flightMode() end
  if value ~= 0 then
    self.written = value
    self.writtenFm = mode
    -- What decides, after the flight, whether there is a delta screen at all. Counted on the
    -- WRITE and not on the board's answer: AdjF needs sensor 99 and a custom telemetry mode, and
    -- a pilot without those still moved his parameters and still wants the undo offered.
    if self.phase == M.PHASE_LIVE then self.fired = self.fired + 1 end
    writeGvar(self, settings.value_gvar, mode, value)
  else
    writeGvar(self, settings.value_gvar, mode, 0)
    self.written = 0
    self.writtenFm = nil
  end
  logDrive("value gvar %d fm %d <- %d", settings.value_gvar, mode, value)
end

--- Park the enable channel in the middle of one band's window.
--
-- Mid-band rather than an edge, so switch, mixer and receiver tolerance all fit inside the window
-- the firmware is watching.
function Drive:armBank(bank)
  local settings = self.settings
  if not settings or (settings.bank_gvar or 0) <= 0 then return false, "no_gvar" end
  local value = self.bankValues and self.bankValues[bank]
  if value == nil then return false, "no_band" end
  local fm = self.radio.flightMode()
  -- Recorded before it is written, for the reason writeValue sets out: a pass killed between the
  -- two must leave the drive believing MORE is standing than is, never less, because a cleanup
  -- only takes back what it believes it put there.
  --
  -- The flight mode is recorded with it, for the same reason the value variable's is:
  -- model.setGlobalVariable resolves a "same as FMx" link itself, so a bank armed in one mode and
  -- cleared in another leaves the first one armed. A pilot who changes flight mode with the
  -- interlock closed -- which is a switch, not a rare event -- would otherwise land back on the
  -- ground with the enable channel still parked in a band.
  self.bankWritten = value
  self.bankFm = fm
  writeGvar(self, settings.bank_gvar, fm, value)
  logDrive("bank gvar %d fm %d <- %d (bank %d)", settings.bank_gvar, fm, value, bank)
  return true
end

--- The enable channel carries the SELECTED bank for as long as the interlock is on.
--
-- armBank on its own is EDGE work: the chip, the bank trim and a walk that crosses a bank each
-- call it once, and nothing calls it on the way into the air. The interlock's own defensive
-- cleanup(true) then takes the bank variable to 0 while `self.bank` keeps its value, and 1500 us
-- -- what the mixer line puts on the channel for 0 -- sits inside no band the firmware watches.
-- Between the interlock closing and the pilot's first bank gesture the screen therefore showed a
-- bank the wire did not carry, and every step went out against an enable channel outside every
-- adjustment's window: the board saw a value move and had no function to apply it to.
--
-- So the selection is asserted rather than followed. Called once per pass for as long as the
-- interlock is closed -- in all three phases, because all three name a bank on the screen -- it
-- costs one comparison when the variable already holds what the selection says, and it repairs the
-- defensive cleanup, an arming, a landing, a row walk and the entry point's emergency clear alike.
-- None of those is a bank CHANGE, which is why none of them had a writer.
--
-- It is the bank variable only. The value variable is still 0 whenever no pulse is running and
-- nothing is held, on every path out of the overlay, which is the rule at the top of this file: a
-- parked enable channel with the value channel at rest steps nothing, and the firmware needs a
-- magnitude inside an increment window before it counts anything at all.
--
-- Refused, silently, while a value stands on the wire: moving the enable channel under a
-- magnitude that sits inside a step window is how one press ends up counted against another
-- parameter. That is the same refusal the chip and the bank trim make, and the write lands on the
-- first pass after the pulse has gone.
function Drive:ensureBankArmed()
  local settings = self.settings
  if not settings or (settings.bank_gvar or 0) <= 0 then return false, "no_gvar" end
  local want = self.bankValues and self.bankValues[self.bank]
  if want == nil then return false, "no_band" end
  if self.bankWritten == want then return false, "armed" end
  if self.written ~= 0 then return false, "busy" end
  return self:armBank(self.bank)
end

--- A bank chosen by hand, from a chip on the fullscreen screen.
--
-- Refused while the value variable is not 0: moving the enable channel under a value that is
-- inside a step window is how one tap ends up counted against another parameter.
function Drive:setBank(bank)
  bank = tonumber(bank)
  if bank == nil or bank < 1 or bank > Functions.BANK_COUNT then return false, "range" end
  if self.written ~= 0 then return false, "busy" end
  self.bank = bank
  self.row = 1
  return self:armBank(bank)
end

--- The next assigned cell in the set's own order: bank by bank, row by row, unassigned cells
-- skipped. It wraps, because a walk that stops without a sound cannot be told apart from a trim
-- that stopped answering -- and this is the control a pilot uses without looking.
function Drive:stepCell(up)
  local perBank = Functions.ROW_COUNT
  local total = Functions.BANK_COUNT * perBank
  local index = (self.bank - 1) * perBank + (self.row - 1)
  for _ = 1, total do
    index = (index + (up and 1 or -1)) % total
    local bank = (index // perBank) + 1
    local row = (index % perBank) + 1
    if self:functionId(bank, row) ~= nil then return bank, row end
  end
  return nil
end

--- One step of the walk, in navigate mode.
--
-- Refused outright while the value variable is not 0. The alternative -- moving the selection and
-- leaving the enable channel where it was -- puts the screen and the board on different
-- parameters, which is the one state a tuning surface must never be in.
function Drive:navigate(up)
  if not self:tuning() then return false, "not_live" end
  if self.written ~= 0 then return false, "busy" end
  local bank, row = self:stepCell(up)
  if bank == nil then return false, "empty" end
  self.bank = bank
  self.row = row
  self.valueEpoch = self.valueEpoch + 1
  -- Unconditional, where this used to write only when the step crossed a bank boundary. A walk
  -- inside one bank is not a bank change and still has to leave the wire carrying that bank, which
  -- it does not when the interlock's cleanup was the last thing to touch the variable.
  self:ensureBankArmed()
  return true
end

function Drive:selectRow(row)
  row = tonumber(row)
  if row == nil or row < 1 or row > Functions.ROW_COUNT then return false end
  self.row = row
  return true
end

--- A press on the minus or plus control. Refused inside the cool-down, which is one pulse long:
-- the flight controller needs REPEAT_DELAY between steps, and two taps closer together than that
-- would look like one held position rather than two steps.
function Drive:press(row, up)
  if not self:tuning() then return false, "not_live" end
  local now = self.radio.now()
  if self.pulseUntil ~= nil or now < (self.coolUntil or 0) then
    -- Said on the screen rather than returned to a caller that drops it. The pilot's own report
    -- after three rounds is "sometimes no step at all", and his card log shows what that is: a
    -- tap inside the cool-down writes nothing, logs nothing and looks exactly like a control that
    -- is not wired up. The cool-down is right -- the board cannot tell two steps that close apart
    -- -- so what was missing is the sentence, not the step.
    self.stepRefusedUntil = now + REFUSAL_TICKS
    return false, "cooling"
  end
  local code = Functions.rowCode(row or self.row, up)
  if code == nil then return false, "range" end
  self.row = row or self.row
  self.pulseCode = code
  self.pulseUntil = now + self:pulseTicks()
  self.holdRow = row or self.row
  self.holdUp = up
  self:writeValue(code, self.radio.flightMode())
  return true
end

--- The release of a held control. The value falls away at the end of the pulse rather than here,
-- so a control tapped faster than the flight controller's own trigger delay still produces a step.
function Drive:release()
  self.holdRow = nil
  self.holdUp = nil
end

--- One tap, for a radio whose LVGL build has no momentary button: press without the hold, so the
-- pulse ends on its own timer and nothing waits for a release that never comes.
function Drive:tap(row, up)
  local ok, reason = self:press(row, up)
  if ok then self:release() end
  return ok, reason
end

--- Both variables to 0 and every pending motion dropped.
--
-- Cheap and idempotent by design: it runs on the interlock falling, on leaving fullscreen, on the
-- widget going to background, on the link dropping, and once defensively on the interlock rising.
-- `force` writes even when the drive believes the variables are already clear, which is what the
-- rising edge needs -- what a previous session left behind is not knowable from here.
--
-- `keepBank` leaves the enable channel alone, and exactly one caller passes it: the transition OUT
-- of the air. The value variable going to 0 there is the safety rule this whole file is built
-- around and stays unconditional. The bank variable is not a magnitude, steps nothing on its own,
-- and while the interlock is still on it has to go on saying which bank the surface has selected --
-- so clearing it on the landing and writing it straight back on the next pass would be a pair of
-- model writes that cancel out.
function Drive:cleanup(force, keepBank)
  local settings = self.settings
  local fm = self.writtenFm
  if fm == nil then fm = self.radio.flightMode() end

  self.pulseCode = nil
  self.pulseUntil = nil
  self.holdRow = nil
  self.holdUp = nil
  self.trimRow = nil
  self.trimUp = nil
  self.trimCode = nil
  self.trimHold = false
  self.trimPulseUntil = nil
  self.navDir = 0
  self.navNextAt = nil
  self.bankDir = 0
  self.bankNextAt = nil

  if settings and (settings.value_gvar or 0) > 0 and (force or self.written ~= 0) then
    writeGvar(self, settings.value_gvar, fm, 0)
    logDrive("cleanup: value gvar %d fm %d <- 0", settings.value_gvar, fm)
  end
  self.written = 0
  self.writtenFm = nil

  if not keepBank then
    if settings and (settings.bank_gvar or 0) > 0 and (force or (self.bankWritten or 0) ~= 0) then
      -- The mode the bank was ARMED in, not the mode the radio happens to be in now. Cleared in the
      -- wrong one, the write goes to a different slot -- or is redirected by a "same as FMx" link --
      -- and the enable channel stays parked in a band nobody chose.
      local bankFm = self.bankFm
      if bankFm == nil then bankFm = self.radio.flightMode() end
      writeGvar(self, settings.bank_gvar, bankFm, 0)
      logDrive("cleanup: bank gvar %d fm %d <- 0", settings.bank_gvar, bankFm)
    end
    self.bankWritten = 0
    self.bankFm = nil
  end
  self.coolUntil = 0
  self.trimCoolUntil = 0
end

--- The cached setup verdict: a list of fault codes, the string "ok", or nil for "nothing about
-- this model could be looked at".
--
-- The walk behind it reads the model's mixer lines, its global variable details and its trim
-- modes. It is taken at most once per settings change and once per interlock closing, and NEVER
-- while the craft is in the air: the airborne pass is the one driving the flight controller, and
-- a verdict cannot change under a pilot who is flying.
--
-- The screen reads this same cache -- see inflight/screen.lua M.checkVerdict -- so the sentence
-- on the ground surface and the refusal below are one answer and not two walks.
function M.verdict(drive)
  if type(drive) ~= "table" then return nil end
  if drive.phase == M.PHASE_LIVE then return drive._checkResult end
  if drive._checkedAt == nil then
    drive._checkedAt = drive.radio.now()
    drive._checkResult = Setup.check(drive)
  end
  return drive._checkResult
end

--- The verdict is about a model that has just changed, so it is taken again.
function Drive:forgetVerdict()
  self._checkedAt = nil
  self._checkResult = nil
end

--- The tuning session is over: the pilot has closed the feature while standing on the ground.
--
-- His ruling after the fourth radio round is that closing it on the ground or after the flight
-- starts everything fresh, so the next opening of the interlock is a NEW session and not a
-- continuation of this one -- the board is read again and a fresh undo is laid down over whichever
-- profile is active then.
--
-- What goes is everything that describes the session that has just ended. The record of the undo
-- goes with it: the board still holds the copy in its spare profile, but a copy nobody can say the
-- source or the age of is not an undo, and the restore refuses without that record rather than
-- writing a profile it cannot describe. So do the snapshot the comparison was measured against, the
-- cached values and the evidence that they were ever read, the counter that decides whether a flight
-- earned a comparison at all, and the outcome of the last profile copy -- which would otherwise open
-- the next session with the previous one's refusal on its first line.
--
-- What STAYS is what the board answered about itself: the derived set, the verdict on its slot table
-- and the run that read it. Those describe a LAYOUT and a flight controller rather than a session,
-- and nothing a switch does can move one -- which is why the read the next opening asks for is the
-- nine value commands and not forty-odd round trips. See inflight/prime.lua, M.refreshValues.
--
-- NOT reached when the widget goes to the background, nor when the feature is switched off in the
-- settings. Neither of those is the pilot closing the overlay on the flight line, and a theme
-- reload or a tool session would otherwise throw his undo away between two flights.
function Drive:endSession()
  self.backup = nil
  self.primedValues = nil
  self.transfer = nil
  self.values = {}
  self.previous = {}
  self.valuesRead = nil
  self.readAt = nil
  self.fired = 0
  self.deltaPage = 1
  self._deltaList = nil
  self._deltaEpoch = nil
  -- The nine value reads are due, and the ground half sends them once the surface is back on the
  -- ground -- never while the feature is closed, which is what the interlock promises.
  self.readAgain = true
  self.valueEpoch = self.valueEpoch + 1
  logDrive("tuning session ended: the undo, the values and the comparison go with it")
end

--- Where the interlock stands, with the first evaluation seeding rather than firing.
--
-- A widget that starts up with the switch already ON must not read that as the pilot having just
-- turned it on: the overlay would open, and on the transition it would write. So the first
-- evaluation only records what it saw.
function Drive:evaluateInterlock(now)
  local settings = self.settings
  -- BOTH switches, through the one answer M.settings computes: the radio's, which says the pilot
  -- wants the overlay on this transmitter at all, and the model's, which says this machine is set
  -- up for it. See inflight/setup.lua M.settings.
  if not settings or settings.active ~= true or (settings.switch or 0) == 0 then
    if self.live then
      self.live = false
      self:setPhase(nil)
      self:endPost("interlock_off")
      self:cleanup(false)
    end
    self.seeded = false
    self.rawSwitch = nil
    return false
  end

  local raw = (self.radio.switchValue(settings.switch) == true)

  -- The setup check, as a gate rather than as a sentence. What it names are the conditions under
  -- which a press would move something other than the parameter on the screen: a bank and a value
  -- pointed at one variable or one channel, so the board reads a step as a bank change and a bank
  -- change as a step; a mixer line that is not there or carries the wrong weight, so the code
  -- never reaches the board; a global variable whose range or precision cannot express the codes;
  -- a trim the active flight mode still moves the stick neutral with. A FAULT therefore refuses.
  --
  -- An UNKNOWN does not. The walk answers nil when the radio's seam offered nothing to look at --
  -- no mixer reader, no flight mode data -- and a check that could not run is not a check that
  -- failed. Silencing the overlay on a radio that cannot answer the question would take the
  -- feature away from it for good, which is a worse outcome than the one being guarded against.
  if type(M.verdict(self)) == "table" then
    if self.live then
      self.live = false
      self:setPhase(nil)
      self:endPost("setup_fault")
      self:cleanup(false)
      logDrive("interlock refused: the model's setup check reports a fault")
    end
    -- The switch is still tracked while the gate refuses, so that letting it go re-takes the
    -- verdict below and a pilot who has just repaired his model gets the new answer by switching
    -- the interlock off and on. Nothing re-walks on a timer.
    if raw ~= self.rawSwitch then
      self.rawSwitch = raw
      self.rawSince = now
      if not raw then self:forgetVerdict() end
    end
    return false
  end

  if not self.seeded then
    self.seeded = true
    self.rawSwitch = raw
    self.rawSince = now
    self.live = false
    return false
  end

  if raw ~= self.rawSwitch then
    self.rawSwitch = raw
    self.rawSince = now
    -- Released: the model is walked again on the next closing. See the gate above.
    if not raw then self:forgetVerdict() end
    return self.live
  end

  if self.live == raw then return self.live end
  if (now - (self.rawSince or now)) < STABILITY_TICKS then return self.live end

  self.live = raw
  if raw then
    -- Defensive on the way in, never only on the way out: what the previous session left in the
    -- two variables cannot be read back from a drive that has just been constructed.
    self:cleanup(true)
    self.bankShown = nil
    logDrive("interlock on: bank ch%d value ch%d", settings.bank_ch, settings.value_ch)
  else
    -- Closed. On the GROUND -- before a flight or after one -- that ends the tuning session, and
    -- everything the session stood on goes with it; see Drive:endSession. In the AIR it ends
    -- nothing: nothing may be sent to a flying machine, and the comparison the landing is going to
    -- show is measured against a snapshot that has to survive the cycle.
    --
    -- The phase read here is the one the previous pass left, and that is what tells the two apart:
    -- Drive:tick evaluates the interlock before it decides which surface the pass belongs to.
    local closedOnGround = (self.phase == M.PHASE_GROUND or self.phase == M.PHASE_POST)
    self:setPhase(nil)
    -- One of the three things that end the postflight read-out. In the air the list itself stands --
    -- it is measured against the backup's own snapshot -- so the same interlock brings the same list
    -- back; on the ground the line above has just taken that snapshot away with the session.
    self:endPost("interlock_off")
    self.autoBackupWanted = false
    self:cleanup(false)
    if closedOnGround then self:endSession() end
    logDrive("interlock off")
  end
  return self.live
end

--- The radio's trim block, resolved once and kept. Re-resolved when the settings change, because
-- the walk that finds it is not free and nothing else moves it.
--
-- The walk is taken a slice at a time and answers nil until it is complete, so no single pass can
-- be killed by it -- and the cursor is advanced BEFORE the slice is asked for, so a pass that is
-- killed inside it anyway loses that slice rather than starting the same walk again on the next
-- pass, for ever. That ordering is the whole defect this function was rewritten for: with the
-- state written after the work, a walk that overruns the instruction limit is retried by every
-- following pass and the widget never gets past it.
--
-- The epoch is bumped on the pass that completes the walk, because the row list carries a marker
-- per trim and that marker becomes knowable exactly then.
function Drive:ensureTrims()
  if self.trimsResolved then
    if type(self.trims) ~= "table" then return nil end
    return self.trims
  end

  local scan = self.trimScan
  if scan == nil then
    scan = { list = {}, from = nil }
    self.trimScan = scan
  end

  local slice, resumeAt = self.radio.switchList(scan.from, SWITCH_SLICE)
  scan.from = resumeAt
  if type(slice) == "table" then
    for i = 1, #slice do
      scan.list[#scan.list + 1] = slice[i]
    end
  end
  if resumeAt ~= nil and #scan.list < SWITCH_WALK_LIMIT then return nil end

  self.trims = M.trimsFromList(scan.list)
  self.trimsResolved = true
  self.trimScan = nil
  -- A store written before the trims were picked with the radio's own picker holds semantic
  -- indices, 1..6. The walk is the first moment anything here can say what those mean, so the
  -- conversion happens on the pass that completes it. Nothing is written to the card from the
  -- widget: this is an in-memory reading of an old file, and the settings page's next save is
  -- what puts the new form on it.
  if type(self.trims) == "table" then Setup.migrateTrims(self.settings, self.trims) end
  self.valueEpoch = self.valueEpoch + 1
  if type(self.trims) ~= "table" then return nil end
  return self.trims
end

--- Whether a step may be asked for at all: the overlay up AND the machine in the air.
--
-- One function rather than a test spelled at each control, because every one of them has to agree
-- and a control that forgot the phase would be a step taken on a screen showing no rows.
function Drive:tuning()
  return self.live == true and self.phase == M.PHASE_LIVE
end

function Drive:navigateMode()
  local settings = self.settings
  return settings ~= nil and settings.trim_mode == M.TRIM_MODE_NAVIGATE
end

--- Whether a trim of this radio's is actually stepping the bank.
--
-- Configured is not enough: a bank trim named in the settings and absent from this radio would
-- otherwise leave the walk trim confined to one bank with no way of reaching the other five, which
-- is worse than either arrangement on its own. So the split is decided by what the walk can
-- REACH, and a radio without the named trim falls back to walking the whole set.
function Drive:bankTrimActive()
  local settings = self.settings
  if not settings or settings.trims ~= true or not self:navigateMode() then return false end
  if (tonumber(settings.bank_trim) or 0) <= 0 then return false end
  return Setup.trimEntry(self.trims, settings.bank_trim) ~= nil
end

--- One step of the walk WITHIN the current bank, wrapping. The other half of the pilot's own
-- arrangement: with a bank trim of its own the walk trim no longer has to count its way across
-- thirty-six cells to reach the row beside the one it started on.
function Drive:navigateRow(up)
  if not self:bankTrimActive() then return self:navigate(up) end
  if not self:tuning() then return false, "not_live" end
  if self.written ~= 0 then return false, "busy" end
  local total = Functions.ROW_COUNT
  local index = self.row - 1
  for _ = 1, total do
    index = (index + (up and 1 or -1)) % total
    if self:functionId(self.bank, index + 1) ~= nil then
      self.row = index + 1
      self.valueEpoch = self.valueEpoch + 1
      -- The bank does not move here, and that is precisely why the assertion belongs in it: a
      -- pilot who walks rows with a bank trim configured never makes a bank change at all.
      self:ensureBankArmed()
      return true
    end
  end
  return false, "empty"
end

--- One bank previous or next, wrapping, with the first assigned row of the new bank selected.
--
-- Refused while the value variable is not 0, for the reason the bank CHIP is: moving the enable
-- channel under a value that sits inside a step window is how one press ends up counted against
-- another parameter. A bank with no assigned cell at all is stepped over rather than shown empty.
function Drive:navigateBank(up)
  if not self:tuning() then return false, "not_live" end
  if self.written ~= 0 then return false, "busy" end
  local count = Functions.BANK_COUNT
  local bank = self.bank
  for _ = 1, count do
    bank = ((bank - 1 + (up and 1 or -1)) % count) + 1
    for row = 1, Functions.ROW_COUNT do
      if self:functionId(bank, row) ~= nil then
        self.bank = bank
        self.row = row
        self.valueEpoch = self.valueEpoch + 1
        return self:armBank(bank)
      end
    end
  end
  return false, "empty"
end

--- One walk trim, read as an EDGE with a repeat clock of its own. One press moves one step,
-- however long the pass takes; held on purpose it repeats, after a delay no single press reaches.
local function walkTrim(self, now, trim, dirKey, nextKey, step)
  local direction = 0
  if self.radio.switchValue(trim.plus) == true then
    direction = 1
  elseif self.radio.switchValue(trim.minus) == true then
    direction = -1
  end

  if direction ~= self[dirKey] then
    self[dirKey] = direction
    if direction ~= 0 then
      step(self, direction > 0)
      self[nextKey] = now + NAV_REPEAT_DELAY_TICKS
    else
      self[nextKey] = nil
    end
    return
  end

  if direction ~= 0 and self[nextKey] ~= nil and now >= self[nextKey] then
    step(self, direction > 0)
    self[nextKey] = now + NAV_REPEAT_INTERVAL_TICKS
  end
end

--- The two walk trims: one steps the bank, one steps the row inside it.
--
-- The bank is polled FIRST. Both refuse while a value is standing on the variable, and a pilot
-- who presses the two together means the bank -- the row he lands on is chosen by the bank step
-- anyway, so reading the row first would make the pair depend on which one his thumb reached a
-- millisecond earlier.
function Drive:pollNavigate(now)
  local settings = self.settings
  if not settings or settings.trims ~= true or not self:navigateMode() then return end
  local trims = self:ensureTrims()
  if trims == nil then return end

  local bankTrim = Setup.trimEntry(trims, settings.bank_trim)
  if bankTrim ~= nil then
    walkTrim(self, now, bankTrim, "bankDir", "bankNextAt", Drive.navigateBank)
  end

  local navTrim = Setup.trimEntry(trims, settings.nav_trim)
  if navTrim ~= nil then
    walkTrim(self, now, navTrim, "navDir", "navNextAt", Drive.navigateRow)
  end
end

--- The walk trim, out on the ground, paging the delta list.
--
-- The same trim and the same edge-and-repeat clock the walk uses in the air; only what it steps
-- is different. `deltaPages` is put on the drive by the screen that laid the list out, because how
-- many rows fit is a property of the surface and not of the drive -- and until a postflight surface
-- has been built there is nothing to page.
function Drive:pollDeltaPaging(now)
  local settings = self.settings
  if not settings or settings.trims ~= true then return end
  local pages = math.floor(tonumber(self.deltaPages) or 0)
  if pages < 2 then return end
  local trims = self:ensureTrims()
  if trims == nil then return end
  local navTrim = Setup.trimEntry(trims, settings.nav_trim)
  if navTrim == nil then return end
  walkTrim(self, now, navTrim, "navDir", "navNextAt", function(drive, up)
    drive:pageDelta(up, pages)
  end)
end

--- Which row a held trim is asking for, read once per pass.
--
-- In `rows` mode every assigned trim is a row of its own. In `navigate` mode ONE trim adjusts and
-- it always means the selected row; every other trim, the walk trim included, is inert here.
function Drive:pollTrims()
  local settings = self.settings
  if not settings or settings.trims ~= true then return nil, nil end
  local trims = self:ensureTrims()
  if trims == nil then return nil, nil end

  if self:navigateMode() then
    local trim = Setup.trimEntry(trims, settings.adj_trim)
    if trim then
      if self.radio.switchValue(trim.plus) == true then return self.row, true end
      if self.radio.switchValue(trim.minus) == true then return self.row, false end
    end
    return nil, nil
  end

  -- The row with the largest magnitude wins when two trims are held at once. It is a choice
  -- rather than a reading: the shipped template SUMS its trims onto the value channel, and a sum
  -- of two lands outside every window, so two trims there produce no step at all.
  for row = 1, Functions.ROW_COUNT do
    local trim = Setup.trimEntry(trims, settings.rowTrim and settings.rowTrim[row])
    if trim then
      if self.radio.switchValue(trim.plus) == true then return row, true end
      if self.radio.switchValue(trim.minus) == true then return row, false end
    end
  end
  return nil, nil
end

--- The adjust trim, read as an EDGE and answered with a PULSE.
--
-- Why it is not the level, which is what this was. A trim is a momentary contact and a pilot's
-- press on one lasts as long as a pilot's press: the two in his own log are 0.0 and 0.1 seconds
-- long. The flight controller counts no step at all until the value channel has stood STILL
-- inside one window for TRIGGER_DELAY, 100 ms (fc/rc_adjustments.c) -- so a relay that wrote the
-- magnitude while the trim was down and 0 when it came up made the channel move out and back
-- without ever standing still. Short press: no step, and nothing on the screen to say why. Held
-- for a second: three or four. That is the pilot's report exactly -- it works "only after a
-- while, and very inaccurately".
--
-- So one press is one pulse, which is what the touch control has always done: the magnitude goes
-- on at the edge and stays on for at least `pulse_ms` however early the trim is let go, and a
-- trim genuinely held keeps it on past that for as long as it is held -- which is where the
-- board's own REPEAT_DELAY takes over and steps at its own rate. The cool-down after a pulse is
-- the same length, so two presses closer together than the board can tell apart are one step and
-- not an arbitrary number of them.
--
-- The pulse and the hold are the trim's OWN, deliberately not the touch control's. A held touch
-- button is published as `holding` and freezes the widget's render key, because a rebuild would
-- delete the object that reports its release; a trim has no object and a rebuild cannot lose it,
-- and freezing the surface for as long as a thumb is on a trim would freeze it for the whole of
-- the tuning.
function Drive:pollTrimStep(now)
  local row, up = self:pollTrims()

  if row ~= self.trimRow or up ~= self.trimUp then
    self.trimRow, self.trimUp = row, up
    self.valueEpoch = self.valueEpoch + 1
    if row == nil then
      -- Let go. The magnitude does not fall away here: a pulse still running owns it until its
      -- own clock says otherwise, and that is the whole of what makes a short press step at all.
      self.trimHold = false
    else
      self.row = row
      -- The same thumb moved to another row without coming up. The magnitude follows the new row
      -- rather than finishing the old one's pulse: the screen has already followed the pilot and
      -- the wire has to agree with the screen.
      if self.trimHold == true then self.trimCode = Functions.rowCode(row, up) end
    end
  end

  if row == nil then return end
  -- Already holding the value, or a pulse of this trim's own still on the wire: nothing to start.
  if self.trimHold == true or self.trimPulseUntil ~= nil then return end
  -- The board needs its REPEAT_DELAY between two magnitudes before it counts them as two steps.
  -- A trim still down when that gap has passed gets its pulse then; two TAPS inside the gap get
  -- ONE pulse between them, which is the point of having it.
  if now < (self.trimCoolUntil or 0) then return end

  self.trimCode = Functions.rowCode(row, up)
  self.trimPulseUntil = now + self:pulseTicks()
  self.trimHold = true
end

--- Which rows the pilot can actually reach, as a mask the zone screen hides rows by.
--
-- In `rows` mode that is the rows whose trim this radio has; in `navigate` mode it is every
-- assigned cell, because the walk reaches all of them with the same two trims.
-- This is the SNAPSHOT's view and it never starts the walk. The mask describes the tuning
-- surface's rows, and that surface exists only while the overlay is live; starting the walk from
-- here put it in every pass of the widget's cold start instead, which is where it does not fit.
-- Until `pollTrims` has finished the walk the rows publish no marker, and the epoch bump on the
-- completing pass is what puts them on the screen.
function Drive:trimRowsPresent()
  local mask = {}
  local settings = self.settings
  if not settings or settings.trims ~= true then return mask end
  if self.trimsResolved ~= true then return mask end
  local trims = self.trims
  if type(trims) ~= "table" then return mask end

  if self:navigateMode() then
    if Setup.trimEntry(trims, settings.adj_trim) == nil then return mask end
    for row = 1, Functions.ROW_COUNT do
      mask[row] = self:functionId(self.bank, row) ~= nil
    end
    return mask
  end

  for row = 1, Functions.ROW_COUNT do
    mask[row] = Setup.trimEntry(trims, settings.rowTrim and settings.rowTrim[row]) ~= nil
  end
  return mask
end

--- The fast half of a pass: what the board is reporting and what the pilot's thumb is doing.
--
-- Split out of `tick` because the two clocks are not the same one. The widget's background half
-- runs on a 100 ms logic tick while the firmware calls the widget every 50 ms, and neither of the
-- things in here can wait for the slower clock. The value on the screen is the board's answer to
-- the step the pilot has just asked for, and it is the only thing that tells him the step landed;
-- the trims are momentary contacts, and a press that begins and ends between two logic ticks is a
-- press nothing ever saw. Both are cheap -- two telemetry reads and a handful of switch reads, no
-- allocation and no model call -- and none of it runs while the interlock is open.
--
-- Guarded on the radio's own clock, so a pass that runs the whole tick as well as this one does
-- the work once rather than twice.
function Drive:fastTick(now)
  if self.fastAt == now then return end
  self.fastAt = now

  -- The last adjustment the board reports having made. AdjF reads 0 between adjustments, so a
  -- non-zero reading is a fresh one and its value belongs to that function.
  local adjF = self.radio.sensor("AdjF")
  if adjF and adjF > 0 then
    local adjV = self.radio.sensor("AdjV")
    if adjV ~= nil and self.values[adjF] ~= adjV then
      -- Where this parameter stood BEFORE the step the board has just reported. It is what the
      -- live surface shows beside the value, and it is the only number that tells a pilot whether
      -- the step that just landed went the way he asked -- the primed value is where the flight
      -- started and says nothing about the last press.
      self.previous[adjF] = self.values[adjF]
      self.values[adjF] = adjV
      -- The REPORT counter and not the layout epoch, and that one word is the whole of this fix.
      --
      -- The board answers a step 300-400 ms after the press, which is while the pulse that asked
      -- for it is still standing on the value variable. The layout epoch is in the widget's
      -- render key, so bumping it here tore the live surface down and built it again inside the
      -- pulse window -- and the pass that ENDS the pulse is a widget pass. EdgeTX hands those out
      -- in fixed slots from its menus task and never catches up (radio/src/tasks.cpp,
      -- MENU_TASK_PERIOD; the call site is LuaWidget::refresh in lua_widget.cpp): a pass that
      -- overruns its slot loses the next ones rather than running twice, so the clear arrived
      -- late, the magnitude stood on the wire past the firmware's own repeat window, and the
      -- board counted a second step the pilot never asked for.
      --
      -- Nothing a report carries is layout. The value, the value it stepped from and the six row
      -- values are all read off the snapshot by closures, so a fresh snapshot is published, the
      -- numbers follow the board on the next frame, and the tree is left standing.
      self.reportEpoch = self.reportEpoch + 1
    end
    -- Which function the board last reported, kept even when its value did not move: the one
    -- witness the radio has that the adjustment teller had something to say about THIS parameter.
    -- No epoch either: which function was reported is a field on the snapshot, and the guard in
    -- `publish` watches it, so it travels on the next published snapshot without a rebuild.
    self.spokenId = adjF
  end

  -- The postflight list is paged with the walk trim, and it is the ONLY thing a trim does out
  -- there: a phase with no rows and no step controls must not have a thumb writing a magnitude.
  if self.phase == M.PHASE_POST then
    self:pollDeltaPaging(now)
    return
  end

  -- A running touch pulse suspends both trim paths: the pilot's thumb and the pilot's finger must
  -- not both be writing the same variable.
  local pulsing = (self.pulseUntil ~= nil) or (self.holdRow ~= nil)
  if self:tuning() and not pulsing then
    self:pollNavigate(now)
    self:pollTrimStep(now)
  end

  if self.pulseUntil ~= nil and now >= self.pulseUntil then
    self.pulseUntil = nil
    self.pulseCode = nil
    self.coolUntil = now + self:pulseTicks()
  end
  -- The trim's pulse ends on its own clock, and it ends on every pass -- including one the touch
  -- path took over above. A magnitude left standing by a pulse nothing is looking at any more is
  -- precisely the state this module exists to make impossible.
  if self.trimPulseUntil ~= nil and now >= self.trimPulseUntil then
    self.trimPulseUntil = nil
    self.trimCode = nil
    self.trimCoolUntil = now + self:pulseTicks()
  end

  local want = 0
  if self.pulseUntil ~= nil then
    want = self.pulseCode or 0
  elseif self.holdRow ~= nil then
    want = Functions.rowCode(self.holdRow, self.holdUp) or 0
  elseif self.trimPulseUntil ~= nil then
    want = self.trimCode or 0
  elseif self.trimHold == true and self.trimRow ~= nil then
    want = Functions.rowCode(self.trimRow, self.trimUp) or 0
  end

  if want ~= self.written then
    self:writeValue(want, want ~= 0 and self.radio.flightMode() or nil)
  end
end

--- Which profiles the board is flying, and what a change of one of them invalidates.
--
-- The firmware's adjustment functions act on the ACTIVE profile: the PID, rescue and
-- governor-profile terms on `currentPidProfile`, the rates on `currentControlRateProfile`, and a
-- handful of settings on neither. So the profile the pilot is flying is the profile being tuned,
-- and he chooses it with his own switch rather than through this overlay -- which means every
-- value the overlay believes it knows is true of ONE profile, and a change of that profile turns
-- the lot of them into guesses about a profile nobody has read.
--
-- What is dropped is decided by the MSP command each value is read back with, which is already in
-- the function table: functions.lua's `scopeOf`. Everything scoped to the profile that moved goes
-- back to unknown and shows as a dash; the acc trims, the governor config, the battery profile
-- and the status indices are global and are kept. Nothing is READ here -- in the air there is
-- nothing that could be, and on the ground the ground half sends the nine value reads again.
--
-- The first reading of each sensor SEEDS. A widget that comes up on profile 3 has not seen the
-- pilot change anything, and dropping a cache that is not there yet would only cost an epoch.
function Drive:watchProfiles()
  local dropPid, dropRate = false, false
  local now = self.radio.now()

  local pid = self.radio.sensor("PID#")
  if pid ~= nil and pid > 0 then
    if self.profile ~= nil and self.profile ~= pid then
      dropPid = true
      -- The banner, and only for the PID profile: the firmware's adjustments act on the ACTIVE
      -- profile, the pilot chooses it with his own switch, and after he moves it every value the
      -- overlay is showing describes a profile nobody is flying. It is set here whether or not
      -- the overlay is live, because the surface that shows it decides that for itself.
      self.profileBannerUntil = now + PROFILE_BANNER_TICKS
    end
    if self.profile ~= pid then self.valueEpoch = self.valueEpoch + 1 end
    self.profile = pid
  end

  local rate = self.radio.sensor("RTE#")
  if rate ~= nil and rate > 0 then
    if self.rateProfile ~= nil and self.rateProfile ~= rate then dropRate = true end
    if self.rateProfile ~= rate then self.valueEpoch = self.valueEpoch + 1 end
    self.rateProfile = rate
  end

  -- The banner is dropped by the pass it runs out on, so that the snapshot never carries a stamp
  -- from a profile change the pilot has long since forgotten.
  if self.profileBannerUntil ~= nil and now >= self.profileBannerUntil then
    self.profileBannerUntil = nil
  end

  -- The RE-READ waits for the switch to stand still. Both sensors are watched, because either of
  -- them moving is a profile change, and the pilot's log has them arriving one pass apart -- which
  -- on its own doubled every re-read.
  if dropPid or dropRate then self.profileSettleAt = now + PROFILE_SETTLE_TICKS end
  if self.profileSettleAt ~= nil and now >= self.profileSettleAt then
    self.profileSettleAt = nil
    -- The ground half's signal to read the nine value commands again. It is a flag rather than a
    -- call because this runs wherever the widget's pass happens to be -- including in the air,
    -- where the one thing that must not happen is an MSP request.
    self.profileChanged = true
    logDrive("profile settled: pid %s rate %s, the value reads are due",
      tostring(self.profile), tostring(self.rateProfile))
  end

  if not (dropPid or dropRate) then return false end

  local dropped = 0
  for id in pairs(self.values) do
    local scope = Functions.scopeOf(id)
    if (dropPid and scope == Functions.SCOPE_PID) or (dropRate and scope == Functions.SCOPE_RATE) then
      self.values[id] = nil
      dropped = dropped + 1
    end
  end
  logDrive("profile changed: pid %s rate %s, %d cached value(s) now unknown",
    tostring(self.profile), tostring(self.rateProfile), dropped)
  return true
end

--- One pass of the drive. Everything with a cost is behind `live`; a widget whose pilot has the
-- interlock off pays one switch read per pass and nothing else.
function Drive:tick(armed)
  local now = self.radio.now()
  local wasLive = self.live
  self:evaluateInterlock(now)
  if not self.live then
    if wasLive then self.valueEpoch = self.valueEpoch + 1 end
    return false
  end

  -- Which of the three surfaces this pass belongs to. Armed is the pivot and everything else
  -- follows from what the last flight did: a flight that moved nothing lands back on the ground
  -- read-out, and only one that asked for a step earns the delta.
  --
  -- `armed` is the widget's own copy of the ARM sensor's bit 0. It is passed in rather than read
  -- here because the drive touches no telemetry it does not have to, and because the ground half
  -- already has a stricter reading of the same fact for the writes it makes.
  if armed == true then
    self:setPhase(M.PHASE_LIVE)
  elseif self.phase == M.PHASE_LIVE then
    -- The disarm. The delta is worth a screen only if this drive actually asked for a step: a
    -- flight nobody tuned lands back on the ground read-out and not on an empty list.
    self:setPhase((self.fired > 0) and M.PHASE_POST or M.PHASE_GROUND)
  elseif self.post then
    self:setPhase(M.PHASE_POST)
  else
    self:setPhase(M.PHASE_GROUND)
  end

  -- What the enable channel is actually doing. Read rather than assumed, so a six-position switch
  -- wired straight to it shows the right bank without the overlay having written anything, and a
  -- missing mixer line is visible as a bank that does not move.
  local shown = Functions.usToBand(self.radio.channelUs(self.settings.bank_ch), self.bands)
  if shown ~= self.bankShown then
    self.bankShown = shown
    self.valueEpoch = self.valueEpoch + 1
  end
  -- The reading is ADOPTED only while the drive has put nothing on the variable itself. Once it
  -- has, the selection is what the wire is being driven from and the channel is an echo of it --
  -- one frame behind, on a radio whose mixer and channel output do not run on this pass's clock.
  -- Adopting that echo would let a lagging frame drag the selection back into the band it has just
  -- left, and the assertion below would then write the wrong bank rather than repair it. So the two
  -- do not overlap: the wire is believed where nothing of ours drives it, the selection everywhere
  -- else. `bankShown` is unaffected either way -- what the channel carries is still shown, which is
  -- how a missing mixer line stays visible.
  if shown ~= nil and shown ~= self.bank and (self.bankWritten or 0) == 0 then
    self.bank = shown
  end

  -- The bank the pilot has selected belongs on the wire for the whole time the interlock is on, not
  -- only on the pass a bank changed and not only in the air. One comparison once it is there.
  --
  -- Unconditional at this point on purpose: everything above has already established that the
  -- interlock is closed and that the setup check allows it -- evaluateInterlock returns early and
  -- clears both variables where either is untrue -- and all three phases the interlock shows are
  -- phases in which the surface names a bank. Gating it on the air instead would leave the ground
  -- read-out and the postflight list showing a bank the wire does not carry, and would put the
  -- repair of the interlock's own defensive clear a whole arming away.
  self:ensureBankArmed()

  self:fastTick(now)
  return true
end

--- One page of the delta list forward or back, wrapping, from the walk trim.
--
-- The postflight list is the one screen a pilot reads standing beside the machine, and on a
-- 272-pixel radio it holds four or five rows of a list that can be twenty long. The trim that
-- walks the parameters in the air walks the pages here -- the same thumb, the same gesture, and
-- nothing new to remember.
function Drive:pageDelta(up, pages)
  local total = math.floor(tonumber(pages) or 0)
  if total < 1 then return false end
  local page = ((self.deltaPage or 1) - 1 + (up and 1 or -1)) % total + 1
  if page == self.deltaPage then return false end
  self.deltaPage = page
  self.valueEpoch = self.valueEpoch + 1
  return true
end


-- ---------------------------------------------------------------------------
-- The widget's side
-- ---------------------------------------------------------------------------

local function settingsSignature(settings)
  if type(settings) ~= "table" then return "" end
  local rows = settings.rowTrim or {}
  return table.concat({
    tostring(settings.radio_enabled), tostring(settings.model_enabled), tostring(settings.switch),
    tostring(settings.bank_ch),
    tostring(settings.value_ch), tostring(settings.bank_gvar), tostring(settings.value_gvar),
    tostring(settings.pulse_ms), tostring(settings.trims), tostring(settings.backup_profile),
    tostring(settings.trim_mode), tostring(settings.nav_trim), tostring(settings.bank_trim),
    tostring(settings.adj_trim),
    tostring(settings.set_mode), tostring(settings.step),
    tostring(rows[1]), tostring(rows[2]), tostring(rows[3]),
    tostring(rows[4]), tostring(rows[5]), tostring(rows[6])
  }, "|")
end

-- How often the per-model store is stat'ed, in radio ticks. One second, which is the cadence the
-- widget's own preference watcher already runs its stat at.
local STORE_STAT_TICKS = 100

--- What the PER-MODEL store looks like on the card right now: its size and its modification time,
-- as one string.
--
-- A STATE and not a signal, and the difference is the whole of why this exists. A signal is
-- consumed by whoever reads it first; a state is not, so a pass killed by the instruction limit
-- between reading this and acting on it changes nothing -- the next pass sees the same difference
-- and does the work then.
--
-- `fstat` returns the modification time as a TABLE (api_filesystem.cpp), so it is spelled out
-- field by field: tostring() on it is an ADDRESS, different on every call, and a stamp built that
-- way never equals the previous one.
local function storeStamp(path)
  if type(path) ~= "string" or type(_G.fstat) ~= "function" then return nil end
  local ok, info = pcall(_G.fstat, path)
  if not ok or type(info) ~= "table" then return nil end
  local time = info.time
  local parts = tostring(info.size)
  if type(time) == "table" then
    parts = parts .. ":" .. tostring(time.year) .. tostring(time.mon) .. tostring(time.day)
      .. tostring(time.hour) .. tostring(time.min) .. tostring(time.sec)
  end
  return parts
end

--- The per-model store, re-read off the card when the file on the card has moved.
--
-- WHY THE OVERLAY DOES ITS OWN. The guard was written against a module-level cache in
-- lib/model_preferences.lua that nothing invalidated: the tool that saves the settings file runs
-- in a different Lua state (`lsWidgets` is its own `lua_newstate`, not a coroutine of the main
-- one), so a save refreshed the TOOL's copy of that cache while the widget's still held the file
-- as it stood at connect, and the widget's own preference watcher handed back a brand-new table
-- containing the old content. That cache is gone -- `loadByMcuId` reads the disk on every call.
--
-- The guard stays for two reasons that outlive it. It is the path the overlay's
-- settings-to-widget behaviour was measured on, and it does not depend on the runtime's own
-- reload, which is deliberately held back while armed, while the widget is off-screen and after a
-- flight with no link -- the states the overlay is live in.
--
-- So the overlay looks at the file itself. One `fstat` a second while the feature is enabled; on a
-- change, one forced read that goes to the disk. Nothing of theirs is touched and
-- `widget.modelPreferences` is left exactly where it was -- their theme reload still reads what it
-- always read -- because a fix that reached into their state would be a second writer of it.
--
-- THIS GUARD IS THE MODEL HALF'S ALONE. The radio's settings live in the radio's own preferences
-- file, and the runtime already watches that one and hands the new table down; opening a second
-- watcher on it would be the very duplication the paragraph above refuses. Only the per-model
-- store is stat'ed here.
--
-- And what it is gated on is the RADIO's switch, not the combined answer. The model's switch is
-- IN the file being stat'ed, so gating the stat on it would mean a model switched on from the
-- tool is never noticed by a widget that has already read the store once.
--
-- Answers the table to settle from, or nil for "use what the widget was given".
local function freshPreferences(widget)
  local settings = widget._inflight and widget._inflight.settings
  if settings ~= nil and settings.radio_enabled ~= true then return nil end

  local session = _G.rfsuite and _G.rfsuite.session
  local mcuId = type(session) == "table" and session.mcu_id or nil
  if mcuId == nil then return nil end

  local clock = _G.getTime
  local now = (type(clock) == "function") and (tonumber(clock()) or 0) or 0
  if widget._inflightStoreAt ~= nil and (now - widget._inflightStoreAt) < STORE_STAT_TICKS then
    return widget._inflightPrefs
  end
  widget._inflightStoreAt = now

  -- The path, resolved once per model and kept. It is a function of the MCU id alone -- the
  -- store is named after it -- and resolving it walks every candidate root and builds a string,
  -- which is not work to do once a second for an answer that cannot have changed.
  local path = widget._inflightStorePath
  if path == nil or widget._inflightStoreFor ~= mcuId then
    local MPath = requireModule("lib/model_preferences.lua")
    path = (type(MPath) == "table" and type(MPath.buildPath) == "function") and MPath.buildPath(mcuId) or false
    widget._inflightStorePath = path
    widget._inflightStoreFor = mcuId
  end
  if path == false then return widget._inflightPrefs end
  local stamp = storeStamp(path)
  -- No stamp at all: no file, or a firmware without fstat. Neither is a change, and re-reading on
  -- every pass because nothing can be measured is how a guard becomes the cost it was avoiding.
  if stamp == nil then return widget._inflightPrefs end
  if stamp == widget._inflightStamp then return widget._inflightPrefs end

  -- The FIRST reading seeds and reads nothing. What the widget was handed at start-up came off
  -- the card a moment earlier -- the runtime loads the store on the connect -- so there is
  -- nothing to correct yet, and forcing a read here puts a whole file parse on a cold-start pass.
  -- Measured on a radio: three runs out of three raised `CPU limit` in this function about
  -- thirteen seconds in, on the pass this seed replaces. A stamp is a state, so a seed loses
  -- nothing: the next real change still differs from it.
  local seeding = (widget._inflightStamp == nil)
  widget._inflightStamp = stamp
  if seeding then return widget._inflightPrefs end

  local MP = requireModule("lib/model_preferences.lua")
  if type(MP) ~= "table" or type(MP.loadByMcuId) ~= "function" then return widget._inflightPrefs end
  local prefs = MP.loadByMcuId(mcuId, true)
  if type(prefs) ~= "table" then return widget._inflightPrefs end
  widget._inflightPrefs = prefs
  Setup.log("store re-read: %s", tostring(path))
  return prefs
end

--- The drive belonging to this widget, constructed on first use and re-settled whenever the
-- per-model store has been re-read.
--
-- A different TABLE is not a different setting. The store arrives here as a fresh table several
-- times per second -- the MSP runtime republishes its own copy on every publish -- so the identity
-- test is the cheap path taken on almost every pass, and the section is parsed and its signature
-- built only when the table really was replaced. Without it every pass paid for both, which is the
-- same trap widgets/dashboard/runtime.lua documents for its own theme reload.
function M.get(widget)
  if type(widget) ~= "table" then return nil end
  -- The overlay's own copy where the file has moved under the widget's, and the widget's
  -- otherwise. See freshPreferences: the widget's copy is only refreshed by the runtime's own
  -- reload, and that reload is held back in the very states the overlay runs in.
  local prefs = freshPreferences(widget) or widget.modelPreferences
  -- The radio's half, exactly as the runtime publishes it. Nothing of the overlay watches that
  -- file: widgets/dashboard/runtime.lua re-reads it on its own signal and hands the new table
  -- down, and that reload is deliberately held back while the craft is armed -- so a radio
  -- setting changed in the air is adopted once it has landed. That is the clock the theme and the
  -- preview switch already run on, and the overlay does not open a second one beside it.
  local radioPrefs = widget.preferences
  local drive = widget._inflight
  if drive ~= nil and drive._source == prefs and drive._radioSource == radioPrefs then
    return drive
  end

  local settings = M.settings(radioPrefs, prefs)
  local signature = settingsSignature(settings)
  if drive == nil then
    drive = M.newDrive(nil, settings)
    drive._signature = signature
    widget._inflight = drive
  elseif drive._signature ~= signature then
    drive:cleanup(false)
    drive.settings = settings
    drive._signature = signature
    -- and the setup verdict with it: a changed channel, variable or trim is a different question
    -- for the walk, and the answer gates the drive as well as filling the line on the screen.
    drive:forgetVerdict()
    drive.trimsResolved = false
    -- and with it whatever a walk in progress had collected: a half-read list belongs to the
    -- settings it was started under.
    drive.trimScan = nil
    drive.seeded = false
    -- The set goes back to what this build knows, and the verdict on the board with it. Both were
    -- reached under the channels and the layout that have just changed; a set derived from the
    -- old value channel would keep naming parameters no window on the new one reaches.
    drive:seedSet()
  end
  drive._source = prefs
  drive._radioSource = radioPrefs
  return drive
end

--- The snapshot the screen's reactive closures read.
--
-- Rebuilt as a FRESH table whenever anything on it moved, and reused otherwise: a closure holds
-- the widget and reads mid-sweep, so the swap has to be atomic. Nothing here is a probe, which is
-- the whole point -- the closures never reach past this table.
--
-- It is published on `state.inflight` rather than inside `state.derived`, because
-- widgets/dashboard/derived.lua assigns a brand new table to `state.derived` on every telemetry
-- read and anything parked there would vanish with it.
local function publish(widget, drive)
  local state = widget.state
  if type(state) ~= "table" then return end
  local snapshot = state.inflight
  local epoch = drive.valueEpoch
  -- The board's own answers, which move numbers and no layout. They have to be in the guard --
  -- the closures read this table and a stale one would leave the pilot looking at the value
  -- before his step -- and they must NOT be in the widget's render key; see fastTick.
  local reportEpoch = drive.reportEpoch
  -- Whether a control is being HELD, which is the one thing on here that no epoch bump reports:
  -- a press and a release both leave the value cache alone. It is on the snapshot because the
  -- widget's render key must not move while a finger is down -- the rebuild would delete the very
  -- object that reports the release -- so the guard below has to notice it changing.
  local holding = (drive.holdRow ~= nil)
  -- And how far the ground half has got, which since the pilot's third radio round is the OTHER
  -- thing no epoch bump reports. A prime used to move the epoch on every reply, and the epoch is
  -- in the widget's render key -- so a prime tore the surface down and built it again once per
  -- reply while its replies were being parsed, which is the mechanism behind a frozen radio and an
  -- instruction budget at 70 % of its five-second peak. The counters travel here instead and the
  -- surface reads them through a closure, so the number moves and the tree does not.
  local prime = drive.prime
  local primePhase, primeDone = nil, nil
  if type(prime) == "table" then primePhase, primeDone = prime.phase, prime.done end
  if type(snapshot) == "table" and snapshot.epoch == epoch
    and snapshot.reportEpoch == reportEpoch
    and snapshot.spokenId == drive.spokenId
    and snapshot.live == drive.live
    and snapshot.bank == drive.bank and snapshot.row == drive.row
    and snapshot.holding == holding
    and snapshot.phase == drive.phase
    and snapshot.primePhase == primePhase and snapshot.primeDone == primeDone
    and snapshot.stepRefusedUntil == drive.stepRefusedUntil
    and snapshot.profileBannerUntil == drive.profileBannerUntil then
    return
  end

  -- The names of the trims the rows are driven from. Read here rather than in the screen because
  -- the resolved block is the drive's -- the screen is forbidden to probe the radio at all -- and
  -- because the labels are the LOCALISED, renameable stick short names, so no stem can be guessed
  -- from the row number. In navigate mode a row carries no trim of its own and the field stays
  -- nil: one trim adjusts whichever row is selected, and naming it on all six would be a lie.
  local rows = {}
  local mask = drive:trimRowsPresent()
  local trims = (drive.trimsResolved == true) and drive.trims or nil
  local rowTrim = drive.settings.rowTrim
  local navigate = drive:navigateMode()
  for row = 1, Functions.ROW_COUNT do
    local id = drive:functionId(drive.bank, row)
    local trimName = nil
    if not navigate and type(trims) == "table" and type(rowTrim) == "table" then
      local entry = Setup.trimEntry(trims, rowTrim[row])
      trimName = entry and entry.name or nil
    end
    rows[row] = {
      id = id,
      name = id and Functions.nameOf(id) or nil,
      value = id and drive.values[id] or nil,
      trim = mask[row] == true,
      trimName = trimName
    }
  end

  -- Which trim moves the parameter that is selected. In navigate mode that is the adjust trim,
  -- whatever the row; in rows mode it is the selected row's own.
  local activeTrim = nil
  if type(trims) == "table" then
    local stored = navigate and drive.settings.adj_trim
      or (type(rowTrim) == "table" and rowTrim[drive.row] or 0)
    local entry = Setup.trimEntry(trims, stored)
    activeTrim = entry and entry.name or nil
  end

  -- The ground half's progress, summarised rather than handed over. Its own table is mutated in
  -- place as replies arrive, and everything published here is read from a tree that is being
  -- built -- so what travels is a copy of the counters, taken at the moment of the swap.
  --
  -- `skipped` travels as a COUNT and not as the list it is kept as. The list is the run's own and
  -- goes on being appended to; a snapshot holding a reference to it is not a snapshot, and the
  -- screen wants the number anyway -- how many of the board's slots the overlay cannot drive is a
  -- fact the pilot needs, and it was being published in a form the screen never showed.
  local primeState = nil
  if type(prime) == "table" then
    primeState = {
      phase = prime.phase,
      done = prime.done,
      total = prime.total,
      error = prime.error,
      skipped = #(prime.skipped or {})
    }
  end

  -- The undo and the transfer, likewise copied rather than aliased. The transfer table in
  -- particular is mutated in place -- a copy that is running writes its own outcome into it when
  -- the reply lands -- so a snapshot pointing at it would change under a closure that is reading
  -- it. Only the scalars travel; the backup's own value table is not on this screen.
  local backup = drive.backup
  local backupState = nil
  if type(backup) == "table" then
    -- The profile the backup was taken FROM travels with it. A backup is an undo for that one
    -- profile and for no other, because the board's adjustments only ever moved that one.
    backupState = { profile = backup.profile, at = backup.at, source = backup.source,
      -- The wall clock the copy was made at, so the ground line can say WHEN and not only THAT.
      clock = backup.clock }
  end

  local transfer = drive.transfer
  local transferState = nil
  if type(transfer) == "table" then
    transferState = { kind = transfer.kind, state = transfer.state, reason = transfer.reason }
  end

  -- What the board's own slot table said when it was held against the standard set. Only the
  -- verdict and the count travel: the list of slots behind it is the ground half's own table and
  -- goes on being appended to, and the screen has room for a sentence rather than for a list.
  local compare = drive.compare
  local compareState = nil
  if type(compare) == "table" then
    compareState = { verdict = compare.verdict, count = compare.count,
      -- Whether the step is the whole of the difference. It travels because the pilot can fix
      -- that one on the radio, in one field, and the sentence on screen is a different sentence.
      stepOnly = compare.stepOnly }
  end

  local activeId = drive:functionId(drive.bank, drive.row)
  state.inflight = {
    epoch = epoch,
    -- The report counter travels beside the layout epoch so that the guard above reads one flat
    -- table. Nothing in the widget's render key may ever be derived from it.
    reportEpoch = reportEpoch,
    -- Both switches, and the conjunction the drive actually runs on. The two flags travel beside
    -- it because a surface that says nothing is happening should be able to say which of them is
    -- the one that is off.
    active = drive.settings.active == true,
    -- and the third reason nothing is happening: the model's own setup check refused. It is on
    -- the snapshot because the widget decides from the snapshot alone which surface a pass
    -- belongs to, and a refusal has to reach a surface that can say so.
    setupFault = type(drive._checkResult) == "table",
    radioEnabled = drive.settings.radio_enabled == true,
    modelEnabled = drive.settings.model_enabled == true,
    live = drive.live,
    -- Which of the three surfaces this is. It is on the snapshot AND in the widget's render key,
    -- because a phase change is a different screen and not a different number on the same one.
    phase = drive.phase,
    -- How many pages the postflight list has and which one is showing. The screen writes the
    -- first back onto the drive when it lays the list out; the trim reads it to page.
    deltaPage = drive.deltaPage,
    -- True exactly while a step control is held down. The widget reads it and leaves the render
    -- key alone while it is true; see M.release above for what a rebuild would cost here.
    holding = holding,
    bank = drive.bank,
    bankShown = drive.bankShown,
    row = drive.row,
    rows = rows,
    activeId = activeId,
    activeName = activeId and Functions.nameOf(activeId) or nil,
    activeValue = activeId and drive.values[activeId] or nil,
    -- What the ground half read off the board before the flight, so the screen can show where a
    -- parameter started as well as where it is.
    activePrimed = activeId and type(drive.primedValues) == "table" and drive.primedValues[activeId] or nil,
    -- Where this parameter stood before the last step the board reported. It is what the live
    -- surface puts beside the value now that the caption line is gone.
    activePrevious = activeId and drive.previous[activeId] or nil,
    -- When a refused press stops being said on screen. Read through a closure against the clock,
    -- the way the profile banner is, so nothing rebuilds to put it up or to take it down.
    stepRefusedUntil = drive.stepRefusedUntil,
    -- When the ground half last finished reading the board, as the radio's own wall clock.
    readAt = drive.readAt,
    activeTrim = activeTrim,
    -- The last function the board reported having stepped, for a surface to hold against the
    -- selected one. It moves no epoch: the guard above watches it, so it reaches the snapshot on
    -- the next publish and no tree is rebuilt to carry it.
    spokenId = drive.spokenId,
    navigate = drive:navigateMode(),
    profile = drive.profile,
    rateProfile = drive.rateProfile,
    -- When the banner naming a just-changed PID profile runs out, as a radio tick. The surface
    -- reads it in a closure and holds it against the clock, so the banner goes away on its own
    -- without any pass having to rebuild anything to take it off.
    profileBannerUntil = drive.profileBannerUntil,
    prime = primeState,
    -- The two scalars the guard above compares. They are the same numbers primeState carries; a
    -- copy of them sits here so that the guard reads one flat table rather than reaching into a
    -- nested one that may be nil.
    primePhase = primePhase,
    primeDone = primeDone,
    -- Which of the two layouts the rows above came from: the board's own slot table once the
    -- prime has read it, the documented one until then and whenever the board's yields nothing
    -- usable. It is on the screen because a set that silently fell back to the reference layout
    -- and a set that came off this board look exactly alike otherwise.
    setSource = drive.setSource,
    -- and, in the standard layout, whether the board carries it: the set is known without the
    -- board in that mode, so its table is read to be compared rather than to be believed.
    compare = compareState,
    backup = backupState,
    -- Which profile the pilot chose as the undo, 0 when he has chosen none. On the snapshot
    -- because the ground surface says where to set it when it is unset, and a reactive closure
    -- reads the snapshot and nothing else.
    backupProfile = math.floor(tonumber(drive.settings.backup_profile) or 0),
    transfer = transferState
  }
end

--- One pass, called from the widget's background half.
function M.tick(widget)
  local drive = M.get(widget)
  if drive == nil then return false end
  if drive.settings.active ~= true then
    if widget.state and widget.state.inflight ~= nil then widget.state.inflight = nil end
    return false
  end
  -- The setup check as a gate, the second of the two places it stands. evaluateInterlock refuses
  -- to close on a fault; this refuses the rest of the pass, so that a model the check has just
  -- turned down is not primed over MSP and its profiles are not watched either. The call below is
  -- that same refusal and not a second one: it drops `live`, takes both variables back to zero if
  -- anything was standing in them, and tracks the switch so the next closing walks the model
  -- again. The snapshot IS published, because the surface has to be able to say why the interlock
  -- did nothing.
  if type(M.verdict(drive)) == "table" then
    drive:evaluateInterlock(drive.radio.now())
    publish(widget, drive)
    return false
  end
  -- The two profile sensors, watched whether or not the overlay is up and gated on the link
  -- rather than on the interlock: the pilot changes a profile with his own switch, at any time,
  -- and what the overlay believes about a value is only ever true of the profile it was read
  -- from. Two getValue calls on the widget's logic tick.
  if widget.state ~= nil and widget.state.fblConnected == true then
    drive:watchProfiles()
  end
  local live = drive:tick(widget.state.armed == true)
  publish(widget, drive)
  return live == true
end

--- The fast half of a pass, called from the widget's FOREGROUND half on every pass.
--
-- The widget's background work runs on a 100 ms logic tick and a build pass skips it altogether,
-- which is the right cadence for reading telemetry into a dashboard and the wrong one for a
-- tuning surface: the pilot's own report is that the value lags and that a trim press often does
-- nothing. Both come off the same clock. So the two things that must not wait -- the board's
-- AdjF/AdjV report and the trims -- are polled here instead, at the firmware's own 50 ms widget
-- cadence, and everything else stays where it was.
--
-- Costs one table lookup and one boolean test unless the overlay is live, and never constructs a
-- drive: a widget that has not run the overlay this session has nothing to sample.
function M.sample(widget)
  if type(widget) ~= "table" then return false end
  local drive = widget._inflight
  if drive == nil or drive.live ~= true then return false end
  drive:fastTick(drive.radio.now())
  publish(widget, drive)
  return true
end

--- The held control let go, from a caller that is about to destroy the object which would have
-- reported the release itself.
--
-- EdgeTX raises a momentary button's release handler on LV_EVENT_RELEASED and on nothing else
-- (lua_lvgl_widget.cpp, MomentaryButton::customEventHandler), and an object that is deleted while
-- the finger is still down never receives that event. So a rebuild -- lvgl.clear() drops the whole
-- tree -- would take the release with it and leave the drive writing the row's magnitude with
-- nothing left in the world able to take it back. The rebuild path lets go here instead.
--
-- Answers whether there was a hold to let go, so a caller can tell the two cases apart.
function M.release(widget)
  if type(widget) ~= "table" then return false end
  local drive = widget._inflight
  if drive == nil or drive.holdRow == nil then return false end
  drive:release()
  return true
end

--- Everything off, from a widget that is going away. Never allocates a drive that does not
-- already exist: a widget that never ran the overlay has nothing to clean up.
--
-- The PHASE goes with it, and that is a defect measured on a radio rather than a tidying up. This
-- is reached on every pass that is not a foreground pass of an enabled overlay, so a widget put
-- into the background after a flight came back with `live` false and the phase still `post`: the
-- next closing of the interlock was then not a nil -> ground transition, it raised no request for
-- an undo, and the postflight surface stood across two interlock cycles -- 79 seconds of them in
-- the pilot's own card log, neither of which could have asked for a backup.
--
-- Ended the way the interlock's falling edge ends it, because that is this file's own contract for
-- leaving: setPhase writes the phase and takes the postflight flag down with it, and endPost is the
-- defensive second half of the same statement.
function M.cleanup(widget)
  if type(widget) ~= "table" then return end
  local drive = widget._inflight
  if drive == nil then return end
  local wasLive, wasPhase = drive.live, drive.phase
  drive.live = false
  drive.seeded = false
  drive:setPhase(nil)
  drive:endPost("cleanup")
  drive:cleanup(false)
  -- Once per exit rather than once per pass. What is worth a line here is the pass that actually
  -- took the overlay down: a backgrounded widget was invisible in the card log until now, and a
  -- trace that simply stops reads like a widget that died.
  if wasLive == true or wasPhase ~= nil then
    logDrive("overlay off: was live %s, phase %s", tostring(wasLive == true), tostring(wasPhase))
  end
  if widget.state then widget.state.inflight = nil end
end

M.Drive = Drive

return M
