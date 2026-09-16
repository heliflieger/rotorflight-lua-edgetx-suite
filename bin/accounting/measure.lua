-- Offline instruction accounting for the dashboard and service widget passes.
--
-- Runs the shipped sources against the stubs in stubs/ under debug.sethook(..., "count") --
-- the mechanism the firmware bills a widget call with -- and checks every measured row
-- against the table in budgets.lua. See README.md for why the gate is off-radio.
--
--   lua5.3 bin/accounting/measure.lua              report only
--   lua5.3 bin/accounting/measure.lua --check      gate: non-zero exit on any breach
--   lua5.3 bin/accounting/measure.lua --self-test  proves the gate can go red
--
-- Nothing here reads a wall clock, and no pcall swallows a failure: a stub that is missing
-- or a source that raises fails the run, because in a measurement a silence is a zero that
-- reads as "cheap".

local ROOT = "."
local HERE = "bin/accounting"

do
  local this = arg and arg[0]
  if type(this) == "string" then
    local dir = string.match(this, "^(.*)[/\\][^/\\]*$")
    if dir then
      HERE = dir
      ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]accounting$") or (dir .. "/../..")
    end
  end
end

local Stubs = assert(loadfile(HERE .. "/stubs/edgetx.lua"))()
local FC = assert(loadfile(HERE .. "/stubs/fc.lua"))()
local Budgets = assert(loadfile(HERE .. "/budgets.lua"))()

local API_DIR = ROOT .. "/src/rfsuite/tasks/msp/api"
local THEMES_DIR = ROOT .. "/src/rfsuite/widgets/dashboard/themes"
local OBJECTS_DIR = ROOT .. "/src/rfsuite/widgets/dashboard/objects"

local ZONE = { x = 0, y = 0, w = 800, h = 458 }

-- ---------------------------------------------------------------------------
-- Directory listing. `ls -1` is the one external call in here; everything else
-- is the interpreter. Sorted, because two hosts must enumerate in one order.
-- ---------------------------------------------------------------------------
local function listDir(path)
  local pipe = io.popen("ls -1 " .. path .. " 2>/dev/null")
  if not pipe then error("accounting: cannot list " .. path) end
  local names = {}
  for name in pipe:lines() do names[#names + 1] = name end
  pipe:close()
  table.sort(names)
  return names
end

local function listLuaFiles(path)
  local out = {}
  for _, name in ipairs(listDir(path)) do
    if string.match(name, "%.lua$") then out[#out + 1] = name end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The counter.
-- ---------------------------------------------------------------------------

--- Instructions billed to one call.
--
-- The collector is stopped across the measured section: the events runtime runs a full
-- collection when the connect chain finishes, and a GC step would land in the count
-- wherever the allocator happens to be. The firmware's own incremental collection is part
-- of what the budget margin covers.
local function count(fn, ...)
  -- One pass of the host clock per measured call. The stub's clock does not run by itself.
  Stubs.tick()
  local n = 0
  collectgarbage("collect")
  collectgarbage("stop")
  debug.sethook(function() n = n + 1 end, "", 1)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  collectgarbage("restart")
  if not ok then error(err, 0) end
  return n
end

--- What one call of an empty closure costs through the loop the sweep is replayed in.
--
-- The firmware walks LVGL's reactive references in C; this check calls the collected
-- function fields in a plain Lua loop, and the loop is not free. Measured here, subtracted
-- from every sweep row, and compared against budgets.lua -- a run whose control has
-- drifted is measuring something else, and every sweep row it prints is wrong by that
-- difference.
local function sweepControl(iterations)
  local refs = {}
  local empty = function() end
  for i = 1, iterations do refs[i] = empty end
  local total = count(function()
    for i = 1, #refs do refs[i]() end
  end)
  return total / iterations
end

--- Call every reactive reference in `refs` once, with the loop's own cost taken back out.
local function sweepCost(refs, control)
  if #refs == 0 then return 0, 0 end
  local total = count(function()
    for i = 1, #refs do refs[i]() end
  end)
  return math.max(0, math.floor(total - control * #refs + 0.5)), #refs
end

--- Collect every function field of a node tree, the way the lvgl stub does at build time.
local function collectRefs(node, refs)
  for _, v in pairs(node) do
    if type(v) == "function" then
      refs[#refs + 1] = v
    elseif type(v) == "table" then
      collectRefs(v, refs)
    end
  end
  return refs
end

-- ---------------------------------------------------------------------------
-- The world, rebuilt per scenario so no measurement inherits another's caches.
-- ---------------------------------------------------------------------------

-- The sensor set a settled dashboard reads, under the four-character names
-- lib/sensors.lua searches for. Values are a helicopter idling on the bench: they only
-- have to be plausible and constant, because a value that moved would move the render key
-- and put a rebuild into a pass being measured for something else.
local SENSORS = {
  ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74,
  ["SmFt"] = 74, ["SmCp"] = 850, ["Cel#"] = 6,
  ["Hspd"] = 1750, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45,
  ["Vbec"] = 8.1, ["EscT"] = 48, ["Tmcu"] = 39, ["Thr%"] = 12,
  ["PID#"] = 1, ["RTE#"] = 1, ["BatP"] = 1, ["ARM"] = 0, ["ARMD"] = 0,
  ["Gov"] = 4, ["Alt"] = 1.5, ["Ptch"] = 0, ["Roll"] = 0, ["Yaw"] = 0,
}

local World = { sensorIds = {} }

function World.reset()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  for k, v in pairs(SENSORS) do Stubs.sensors[k] = v end
end

function World.require(path)
  return _G.rfsuite.require(path)
end

-- One custom telemetry frame carrying the full sensor set, built from the repository's own
-- decoder table so the byte walk a pass pays for is the walk the firmware sends.
local function buildTelemetryFrame(frameId, sensorIds)
  local frame = { 0xEA, 0xC8, frameId & 0xFF }
  for _, sid in ipairs(sensorIds) do
    frame[#frame + 1] = (sid >> 8) & 0xFF
    frame[#frame + 1] = sid & 0xFF
    frame[#frame + 1] = 0x01
    frame[#frame + 1] = 0x00
  end
  return frame
end

-- What "the allowance fully drawn" means for a STATE pass: the drain finds a full backlog
-- waiting and decodes its cap out of it, and the MSP poll loop finds a reply on every poll
-- instead of running out of work early. tasks.lua pops at most POP_CAP per wakeup.
local FRAME_BACKLOG = 15

local function feedLink(sensorIds, frameId)
  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(frameId + i, sensorIds))
  end
end

-- The frame type feedLink pushes: a custom telemetry frame, as against a flight controller's MSP
-- response, which arrives on the same queue and is what a prime is waiting for.
local FRAME_TELEMETRY = 0x88

--- Put the link back to the backlog feedLink models, before a pass that is about to be measured.
--
-- feedLink tops the stub's frame queue up on every pass and nothing takes back what the pass did
-- not read, so the leftovers grow for as long as a scenario runs -- five figures by the end of a
-- long one. Nothing reads them until an MSP request is outstanding. Then the CRSF transport walks
-- maxFramesPerPoll frames per poll and mspPollSlicePolls polls per call, on BOTH turns the widget
-- pass gives the queue, and a pile that never runs out is what makes those caps reachable:
-- fifteen thousand instructions of polling that a radio does not pay, because a radio's queue
-- holds a pass's worth of frames and the loop runs out of frames long before it runs out of caps.
--
-- Leaving them in is what made pass.tuning.state measure 12 730 or 24 107 for identical code --
-- the difference was not the work the pass did, but whether the prime happened to have a request
-- outstanding while the pile was deep. So the scenario that drives the overlay -- the only one
-- here that runs several hundred passes with MSP requests in flight -- holds the queue at one
-- pass's worth before every pass it drives. The flight controller's own replies are kept: the
-- oldest telemetry is what a queue that overflows drops.
local function holdLinkBacklog()
  local frames = Stubs.telemetryFrames
  local surplus = #frames - FRAME_BACKLOG
  if surplus <= 0 then return end
  local kept, n = {}, 0
  for i = 1, #frames do
    local frame = frames[i]
    if surplus > 0 and frame.command == FRAME_TELEMETRY then
      surplus = surplus - 1
    else
      n = n + 1
      kept[n] = frame
    end
  end
  Stubs.telemetryFrames = kept
end

-- The frame type the flight controller stub answers with.
local FRAME_MSP_REPLY = 0x7B

--- A link that answers between two passes instead of inside the call that asked.
--
-- stubs/fc.lua answers at the wire and synchronously: it decodes the frame the transport pushed
-- and queues the reply before crossfireTelemetryPush has returned. A board answers milliseconds
-- later, so its reply is always already waiting when a pass polls -- and a widget pass polls the
-- MSP queue (Runtime.tick) BEFORE it drains custom telemetry, so the poll is always what sees it.
-- Answered synchronously, the reply instead lands between those two, and the drain is what finds
-- it: lib/crsf.lua buffers a frame only for a frame type its OWN instance has been asked for, and
-- the drain and the MSP transport each load that file for themselves, so a reply the drain reaches
-- first is discarded rather than handed on. Every retry of that request then goes out from the
-- same place and is lost the same way.
--
-- That is why a prime in this world used to stop wherever it happened to stop, and why the same
-- code measured 12 730 or 24 107: the rows depended on how far the run had got, not on what the
-- pass did. Holding the replies for one pass is the link the rest of this file already assumes.
local heldReplies = {}
local realPushFrame = Stubs.pushFrame

local function installDeferredLink()
  realPushFrame = Stubs.pushFrame
  Stubs.pushFrame = function(command, data)
    if command == FRAME_MSP_REPLY then
      heldReplies[#heldReplies + 1] = { command = command, data = data }
      return
    end
    return realPushFrame(command, data)
  end
end

local function removeDeferredLink()
  Stubs.pushFrame = realPushFrame
  for i = #heldReplies, 1, -1 do heldReplies[i] = nil end
end

--- Deliver what the flight controller answered during the previous pass.
local function releaseReplies()
  local n = #heldReplies
  if n == 0 then return end
  for i = 1, n do realPushFrame(heldReplies[i].command, heldReplies[i].data) end
  for i = n, 1, -1 do heldReplies[i] = nil end
end

-- ---------------------------------------------------------------------------
-- Pass classification. The dispatcher in widgets/dashboard/runtime.lua decides what a
-- pass does from the job slot BEFORE the call, so that is where the class is read.
-- ---------------------------------------------------------------------------
local function passClass(widget)
  local job = widget._job
  if not job then return "state" end
  if job.kind == "splash" then return "splash" end
  if job.kind == "menu" then return "menu" end
  if job.kind == "tuning" or job.kind == "tuning_fs" then return "tuning" end
  if job.swap then return "swap" end
  if job.build then return "build" end
  return "prepare"
end

--- Drive a dashboard widget until it has settled: link up, connect chain done, scene built.
--
-- Everything before that is the cold start, which loads several dozen modules and is
-- reported as a row of its own rather than folded into the steady-state numbers.
--
-- The tail also has to outlast the one-time announcements a fresh connection makes.
-- Those are spaced by their own cooldowns, so how many passes after the swap the last
-- of them lands depends on which of them ran at all. With a tail of 20, silencing one
-- moves a later one into the first measured pass, where it reads as +2892 instructions
-- of steady-state cost that no pass on a radio pays: on an otherwise untouched tree,
-- forcing the initial fuel announcement off takes pass.state from 11460 to 14352 at a
-- tail of 20, and leaves it at 10706 once the tail is long enough to cover it. A tail
-- of 31 is the first that clears it, so 40 keeps ten passes of margin.
local SETTLE_TAIL = 40

-- The pass budgets handed to settle() and to the prime loop below are ten times what they were
-- under the per-call clock. Nothing waits longer in seconds: a pass is now worth a fixed 100 ms of
-- clock rather than however many ticks that pass happened to ask for, so the same elapsed time is
-- reached in about ten times the passes. The budgets are a guard against a loop that never
-- finishes, so they are scaled with the clock rather than tuned to a run.
local function settle(widget, sensorIds, maxPasses)
  local coldWorst = 0
  local startupWorst = {}
  local swapAt = nil
  for i = 1, maxPasses do
    feedLink(sensorIds, i)
    local before = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > coldWorst then coldWorst = n end
    if n > (startupWorst[before] or 0) then startupWorst[before] = n end
    if before == "swap" then swapAt = swapAt or i end
    -- The first scene on screen, plus a tail: the pass after a swap still carries the
    -- module loads the first build pulled in, and those belong to the cold start.
    if swapAt and i >= swapAt + SETTLE_TAIL then return coldWorst, i, startupWorst end
  end
  error("accounting: the dashboard never settled in " .. maxPasses .. " passes")
end

--- Force the next STATE pass to enqueue a scene build: a render key that has moved.
local function invalidate(widget)
  widget._cachedRenderKey = nil
  widget._cachedTuningKey = nil
  widget.renderKey = nil
  widget._lastUIRefresh = 0
  widget.built = false
end

--- Run one scenario: a widget on `themePath`, settled, then `passes` measured passes.
local function runScenario(themePath, passes)
  World.reset()
  local sensorIds = World.sensorIds
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = themePath }

  local coldWorst, settlePasses, startupWorst = settle(widget, sensorIds, 4000)

  local worst = {}
  for i = 1, passes do
    feedLink(sensorIds, i)
    -- Every third pass, move the render key so the build and swap classes keep occurring.
    if i % 3 == 0 then invalidate(widget) end
    local class = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end

  return {
    theme = themePath,
    worst = worst,
    coldWorst = coldWorst,
    settlePasses = settlePasses,
    startupWorst = startupWorst,
    refs = Stubs.lvgl.refs,
    widget = widget,
  }
end

--- Run one scenario ARMED, with telemetry that moves between passes.
--
-- Every steady-state row of this report is measured disarmed and against a frozen sensor set,
-- which is the right shape for what those rows price. It does mean that two things are never
-- entered in a measured pass: the derived half of the telemetry read, which runs only where a
-- value has actually changed, and everything a flight costs -- the record of the flight's own
-- statistics among it. A row measured there would be a zero that reads as free.
--
-- So: arm the model, and move the values a flight moves. The arm edge itself is settled out
-- first, because the widget changes flight mode on it and reloads the theme behind it, and that
-- is a build rather than the steady state this measures.
local function runArmedScenario(themePath, passes)
  World.reset()
  local sensorIds = World.sensorIds
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = themePath }

  settle(widget, sensorIds, 400)

  Stubs.sensors["ARM"] = 1
  for i = 1, SETTLE_TAIL do
    feedLink(sensorIds, 10000 + i)
    widget.refresh(widget, nil, nil)
  end

  local worst = {}
  local eventsWorst = 0
  local Events = World.require("tasks/events/runtime.lua")
  local session = _G.rfsuite.session
  for i = 1, passes do
    feedLink(sensorIds, 20000 + i)
    -- What a flight does to the values the record tracks. A sensor set that does not move
    -- leaves telemetryChanged false, and then this scenario measures the same thing as the
    -- disarmed rows above.
    local k = i % 8
    Stubs.sensors["Hspd"] = 1500 + k * 100
    Stubs.sensors["Curr"] = 10 + k
    Stubs.sensors["Vbat"] = 23 + k / 10
    Stubs.sensors["EscT"] = 40 + k
    Stubs.sensors["Thr%"] = 20 + k * 5

    local class = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > (worst[class] or 0) then worst[class] = n end

    session.event_context = "widget"
    local e = count(Events.wakeup)
    session.event_context = nil
    if e > eventsWorst then eventsWorst = e end
  end

  Stubs.sensors["ARM"] = 0
  return worst, eventsWorst
end

-- ---------------------------------------------------------------------------
-- Report and gate
-- ---------------------------------------------------------------------------

local rows = {}
local rowIndex = {}
local notes = {}

local function addRow(name, measured, extra)
  if rowIndex[name] then error("accounting: duplicate row " .. name) end
  rowIndex[name] = true
  rows[#rows + 1] = { name = name, measured = measured, extra = extra }
end

local function note(fmt, ...)
  notes[#notes + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

local args = {}
for _, a in ipairs(arg or {}) do args[a] = true end
local checking = args["--check"] == true
local selfTest = args["--self-test"] == true

------------------------------------------------------------------------------
-- Inventory: what the gate has to cover, read off the tree rather than a list.
------------------------------------------------------------------------------
World.reset()

local apiFiles = listLuaFiles(API_DIR)
local indexed = FC.loadReplies(API_DIR, apiFiles)

local themes = {}
for _, name in ipairs(listDir(THEMES_DIR)) do
  local probe = io.open(THEMES_DIR .. "/" .. name .. "/init.lua", "r")
  if probe then
    probe:close()
    themes[#themes + 1] = name
  end
end
if #themes == 0 then error("accounting: no shipped theme found under " .. THEMES_DIR) end

-- Object modules on disk: objects/<type>.lua, and objects/<type>/<subtype>.lua where the
-- type has a folder of its own.
local objectFiles = listLuaFiles(OBJECTS_DIR)

-- The sensor id list the telemetry frames carry, from the repository's own decoder table.
local RFSensors = World.require("lib/rf2tlm_sensors.lua")
if type(RFSensors) ~= "table" then error("accounting: lib/rf2tlm_sensors.lua did not load") end
local sensorIds = {}
for sid in pairs(RFSensors) do
  if type(sid) == "number" then sensorIds[#sensorIds + 1] = sid end
end
table.sort(sensorIds)
if #sensorIds == 0 then error("accounting: no sensor decoders found") end
World.sensorIds = sensorIds

local control = sweepControl(2000)

------------------------------------------------------------------------------
-- Pass classes, on the reference theme.
------------------------------------------------------------------------------
local reference = "system/default"
local base = runScenario(reference, 240)

addRow("pass.state", base.worst.state or 0)
addRow("pass.job.prepare", base.worst.prepare or 0)
addRow("pass.job.build", base.worst.build or 0)
addRow("pass.swap", base.worst.swap or 0)
-- The splash pass only ever happens while the widget is NOT ready, so its only home is
-- the startup window. A row measured on a window where the class never occurs would be a
-- zero that reads as free.
addRow("pass.splash", base.startupWorst.splash or base.worst.splash or 0)
addRow("pass.startup.worst", base.coldWorst, base.settlePasses .. " passes to settle")

-- The background half of a STATE pass, as the widget calls it: the onconnect runner, the
-- custom-telemetry drain and the arm/disarm edges in one. It is the largest single term in
-- a STATE pass, so it gets a row of its own rather than being visible only as the
-- difference between two other rows. Measured on the world the reference scenario left
-- standing, which is the only one with a settled link in it.
do
  local Events = World.require("tasks/events/runtime.lua")
  local session = _G.rfsuite.session
  local worst = 0
  for i = 1, 120 do
    feedLink(World.sensorIds, 5000 + i)
    session.event_context = "widget"
    local n = count(Events.wakeup)
    session.event_context = nil
    if n > worst then worst = n end
  end
  addRow("unit.events.wakeup", worst)
end

------------------------------------------------------------------------------
-- The armed pass, with telemetry that moves. See runArmedScenario.
------------------------------------------------------------------------------
do
  local armedWorst, armedEvents = runArmedScenario(reference, 240)
  addRow("pass.state.armed", armedWorst.state or 0, "armed, telemetry moving between passes")
  addRow("unit.events.wakeup.armed", armedEvents, "same wakeup, armed and moving")
end

------------------------------------------------------------------------------
-- Every shipped theme: worst pass plus the full sweep of the tree it leaves.
------------------------------------------------------------------------------
local boxTypes = {}
local boxFixtures = {}

local function harvestBoxes(run)
  local Utils = World.require("widgets/dashboard/objects/common.lua")
  local themeModule = run.widget.theme
  if type(themeModule) ~= "table" then return end
  local boxes = Utils.resolveValue(themeModule.boxes, nil, run.widget.state)
  local headerBoxes = Utils.resolveValue(themeModule.header_boxes, nil, run.widget.state)
  for _, list in ipairs({ boxes, headerBoxes }) do
    if type(list) == "table" then
      for _, box in ipairs(list) do
        local typ = box.type or "text"
        local sub = box.subtype
        local key = (sub ~= nil) and (typ .. "/" .. tostring(sub)) or typ
        if boxFixtures[key] == nil then
          boxTypes[#boxTypes + 1] = key
          boxFixtures[key] = { box = box, from = run.theme }
        end
      end
    end
  end
end

for _, theme in ipairs(themes) do
  local run = (theme == "default") and base or runScenario("system/" .. theme, 160)
  local worstPass = 0
  for _, n in pairs(run.worst) do
    if n > worstPass then worstPass = n end
  end
  local sweep, refCount = sweepCost(run.refs, control)
  addRow("theme." .. theme, worstPass + sweep,
    string.format("worst pass %d + sweep %d over %d refs", worstPass, sweep, refCount))
  harvestBoxes(run)
end

-- Every object module on disk that no shipped theme happens to declare still needs a row:
-- it is shipped, so it can be reached.
for _, file in ipairs(objectFiles) do
  local typ = string.gsub(file, "%.lua$", "")
  if typ ~= "common" then
    local subdir = OBJECTS_DIR .. "/" .. typ
    local subtypes = listLuaFiles(subdir)
    if #subtypes > 0 then
      for _, sub in ipairs(subtypes) do
        local key = typ .. "/" .. string.gsub(sub, "%.lua$", "")
        if boxFixtures[key] == nil then
          boxTypes[#boxTypes + 1] = key
          boxFixtures[key] = {}
        end
      end
    elseif boxFixtures[typ] == nil then
      boxTypes[#boxTypes + 1] = typ
      boxFixtures[typ] = {}
    end
  end
end
table.sort(boxTypes)

------------------------------------------------------------------------------
-- Per box type: one render, and one sweep of what that render collected.
------------------------------------------------------------------------------
World.reset()
do
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  local Engine = World.require("widgets/dashboard/engine.lua")
  local Derived = World.require("widgets/dashboard/derived.lua")
  local state = widget.state
  Derived.build(state, widget.boxSources)

  for _, key in ipairs(boxTypes) do
    local fixture = boxFixtures[key]
    local box = fixture.box
    if box == nil then
      local typ, sub = string.match(key, "^([^/]+)/(.+)$")
      box = { col = 1, row = 1, colspan = 1, rowspan = 1, type = typ or key, subtype = sub }
      note("box type %s is declared by no shipped theme; measured on a minimal fixture", key)
    end
    local theme = { layout = { cols = 1, rows = 1, padding = 0 }, boxes = { box } }
    -- Warm the object wrapper first: loading its module is a cold-start cost, not a render.
    Engine.build(ZONE, state, theme)
    local build = Engine.beginBuild(ZONE, state, theme)
    addRow("box." .. key, count(Engine.stepBuild, build, state, 1))

    local refs = collectRefs(build.nodes, {})
    local sweep = sweepCost(refs, control)
    addRow("sweep." .. key, sweep, #refs .. " refs")
  end
end

------------------------------------------------------------------------------
-- Per unit: the telemetry drain, the MSP poll quantum, the largest parse.
------------------------------------------------------------------------------
--- Warm telemetry_bg's staggered lazy loads, and prove they are warm.
--
-- tasks.lua loads at most one module per wakeup and RETURNS, so a fixed number of warm-up calls
-- is a number that goes stale the moment another module joins that chain -- and the symptom is
-- silent: the measured call returns on a load instead of draining, and the row reports the load.
-- Warm until a call actually consumes a frame, and fail where none ever does.
local function warmTelemetryBg(Events)
  for _ = 1, 10 do
    Stubs.telemetryFrames = {}
    Stubs.pushFrame(0x88, buildTelemetryFrame(0, sensorIds))
    Events.wakeup()
    if #Stubs.telemetryFrames == 0 then return end
  end
  error("accounting: telemetry_bg never consumed a frame; the drain row would measure a load")
end

World.reset()
do
  local Events = World.require("tasks/events/telemetry_bg/tasks.lua")
  warmTelemetryBg(Events)
  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(i, sensorIds))
  end
  addRow("unit.telemetry.drain", count(Events.wakeup),
    FRAME_BACKLOG .. " frames queued, " .. #sensorIds .. " sensors per frame")
end

-- The same wakeup while the background function script is draining: the liveness counter in the
-- shared-memory slot moves, so this pass leaves the drain and the adjustment teller to that
-- script and does only what stays its own. The difference against the row above is what the
-- widget gains by handing over.
World.reset()
do
  local Events = World.require("tasks/events/telemetry_bg/tasks.lua")
  local Drain = World.require("tasks/events/telemetry_bg/drain.lua")
  warmTelemetryBg(Events)

  -- The liveness reader's FIRST read only records, so the pass that establishes the handover is
  -- not the pass to measure: bump, spend a pass on it, bump again, then measure.
  Drain.publishLiveness()
  Events.wakeup()
  Drain.publishLiveness()

  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(i, sensorIds))
  end
  local queued = #Stubs.telemetryFrames
  local billed = count(Events.wakeup)
  -- The control this row cannot do without: a pass that drained after all would still produce a
  -- plausible number, and it would be the number of the row above under a different name.
  if #Stubs.telemetryFrames ~= queued then
    error("accounting: the handoff row drained the queue; it is measuring the wrong pass")
  end
  addRow("unit.telemetry.handoff", billed,
    FRAME_BACKLOG .. " frames queued, left to the background script")
end

-- The background script's own pass. It is the host the drain moves to, and it is billed
-- differently -- a call there is yielded on a task period rather than cut off at an instruction
-- count -- so it decodes the whole backlog. What that costs belongs in this table beside the
-- widget's capped pass rather than in nobody's.
World.reset()
do
  -- By the path the installed tree carries it under, through the stub's own remap, so the
  -- script is reached here the way it is reached on a radio.
  local script = assert(loadScript("/SCRIPTS/FUNCTIONS/rfsbg.lua", "bt"))()
  if type(script) ~= "table" or type(script.run) ~= "function" then
    error("accounting: src/functions/rfsbg.lua does not return a run function")
  end
  -- The first run only loads; the second is the first that drains, and it pulls in the decoder
  -- table and the CRSF multiplexer while doing it. Both are cold-start cost.
  script.run()
  Stubs.pushFrame(0x88, buildTelemetryFrame(0, sensorIds))
  script.run()

  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(i, sensorIds))
  end
  local queued = #Stubs.telemetryFrames
  local billed = count(script.run)
  if #Stubs.telemetryFrames >= queued then
    error("accounting: the function script drained nothing; the row would measure an idle pass")
  end
  addRow("pass.function", billed, FRAME_BACKLOG .. " frames queued, every one decoded")
end

World.reset()
do
  local Msp = World.require("tasks/msp/runtime.lua")
  Msp.attach("accounting")
  for _ = 1, 20 do Msp.tick() end
  addRow("unit.msp.pump", count(Msp.pump))
end

do
  local widest, widestFile = nil, nil
  for _, file in ipairs(apiFiles) do
    local mod = assert(loadfile(API_DIR .. "/" .. file))()
    if type(mod) == "table" and type(mod.simulatorResponse) == "table"
      and type(mod.parse) == "function" then
      if widest == nil or #mod.simulatorResponse > #widest.simulatorResponse then
        widest, widestFile = mod, file
      end
    end
  end
  if widest == nil then error("accounting: no API module carries both a payload and a parser") end
  addRow("unit.msp.parse.max", count(widest.parse, widest.simulatorResponse),
    widestFile .. ", " .. #widest.simulatorResponse .. " bytes")
end

------------------------------------------------------------------------------
-- The in-flight tuning overlay: the pass that drives it, the pass a reply lands on, and the
-- builds of its two screens.
--
-- The overlay replaces the scene while its interlock is closed, so the widget is settled FIRST
-- with the interlock open -- that is the only way the reference scene ever reaches its swap --
-- and the switch is thrown afterwards. The fullscreen build is measured with a non-nil event,
-- which is what the firmware passes there and what no other row in this file covers.
--
-- The ground half is measured as a window of its own, between the prime starting and the prime
-- being finished, and everything after it is measured with the prime DONE. Both halves of that
-- are deliberate: a pass that parses a reply and a pass that does not are different passes, and
-- a row that sometimes contains one and sometimes does not is a row nobody can reproduce.
------------------------------------------------------------------------------
World.reset()
do
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = reference }
  -- THREE switches decide whether there is an overlay at all, and the rows below measure a plain
  -- dashboard if any of them is off. Two of them are the radio's and are staged here; the third
  -- is the model's and is staged with the per-model store further down.
  --
  -- The preview switch is the pilot saying he wants an unfinished feature on the radio; the
  -- [inflight] section's own `enabled` is the overlay's master switch, and the rest of that
  -- section is the radio's half of the settings -- the interlock switch, the two channels and
  -- variables, the pulse length and the trims. See widgets/dashboard/inflight/setup.lua.
  widget.preferences.general = widget.preferences.general or {}
  widget.preferences.general.preview_inflight_tuning = true
  widget.preferences.inflight = {
    enabled = true, switch = 1, bank_ch = 11, value_ch = 12,
    bank_gvar = 1, value_gvar = 2, pulse_ms = 150, trims = true,
    trim_mode = "rows", nav_trim = 2, adj_trim = 4,
    row_trim_1 = 2, row_trim_2 = 4, row_trim_3 = 1,
    row_trim_4 = 3, row_trim_5 = 5, row_trim_6 = 6
  }

  -- The enable channel, as a raw reading: 998 microseconds, the middle of the first band.
  Stubs.sensors["ch11"] = -1028
  Stubs.sensors["ch12"] = 0
  -- A machine that is NOT turning. The sensor set above is a helicopter with its governor in the
  -- active state and the head at 1750 rpm, which is the right world for the dashboard rows and the
  -- wrong one for this scenario: the overlay's ground half refuses to speak MSP while the rotor is
  -- turning, whatever the arm flag says, so a prime priced in that world would be a prime that
  -- never starts. The bench is what a prime and a profile copy actually happen on.
  Stubs.sensors["Gov"] = 0
  Stubs.sensors["Hspd"] = 0
  -- The board reporting its last adjustment, which is the branch a CRSF link actually takes.
  Stubs.sensors["AdjF"] = 14
  Stubs.sensors["AdjV"] = 100
  Stubs.sensors["PID#"] = 1

  settle(widget, World.sensorIds, 4000)

  -- The per-model store, as the widget reads it.
  --
  -- Written after the settle, and written where the MSP runtime keeps it rather than only on the
  -- session: that runtime republishes its own copy onto the session on every publish, so a store
  -- put only on the session is overwritten by the next one and the overlay measures as switched
  -- off -- which is what a first run of this driver did, silently, with a zero in the row.
  local store = {
    inflight = {
      -- The model's own switch. The radio's two are staged above; all three have to be on.
      enabled = true,
      -- The STANDARD set layout, which is the default and, measured, the dearer of the two here.
      --
      -- The two layouts differ in what the passes after the slot table does with it: the custom
      -- one DERIVES a set from the board's own windows, the standard one holds the board against
      -- a set this build already has. Both are taken in slices and both land inside a window whose
      -- worst pass is dominated by an MSP reply parse rather than by the slice -- measured on this
      -- tree, `pass.tuning.prime` reads 15069 in the standard layout over 28 passes and 15063 in
      -- the custom one over 29, so the row bounds either. It is pinned to the one a pilot gets
      -- without changing anything, and the other is six instructions below it.
      set_mode = "standard",
      step = 5, step_headspeed = 50, backup_profile = 0
    }
  }
  _G.rfsuite.session.modelPreferences = store
  do
    local Msp = World.require("tasks/msp/runtime.lua")
    local mspState = (type(Msp) == "table" and type(Msp.getState) == "function") and Msp.getState() or nil
    if type(mspState) == "table" and type(mspState.values) == "table" then
      mspState.values.modelPreferences = store
    end
  end

  -- From here on the flight controller answers between passes rather than inside the push, and
  -- the link is held at one pass's worth of telemetry. Both are properties of this check rather
  -- than of the suite, and both are what make the rows below reproducible; see their comments.
  installDeferredLink()

  -- The interlock, thrown after the dashboard is up. The drive seeds on its first evaluation and
  -- waits out its stability delay, so the passes in between are the ones a pilot's hand produces.
  Stubs.switchValues[1] = true

  -- Swapping the store is a change the widget reacts to -- it compares what a rebuild would
  -- read and reloads the theme when that moved -- so the passes right after the swap carry a
  -- theme load that belongs to this driver rather than to the overlay. They are spent here,
  -- before anything is measured.
  for i = 1, 30 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 900 + i)
    Stubs.tick()
    widget.refresh(widget, nil, nil)
  end

  local drive = widget._inflight
  if drive == nil then error("accounting: the tuning overlay never built a drive") end
  -- Both halves reached the drive. The radio's settings are re-read from the card by the widget's
  -- own preference reload, so a stage that the settle above quietly replaced would leave the rows
  -- pricing an overlay that is switched off -- which is a zero in the row rather than an error.
  if drive.settings.radio_enabled ~= true or drive.settings.model_enabled ~= true then
    error("accounting: the tuning overlay settled with radio_enabled="
      .. tostring(drive.settings.radio_enabled)
      .. " model_enabled=" .. tostring(drive.settings.model_enabled))
  end

  ----------------------------------------------------------------------------
  -- The GROUND HALF, priced as the window it occupies.
  --
  -- The overlay reads the board before a flight: the receiver map, the slot table one record at a
  -- time, and nine value reads. Each of those replies is parsed on a widget pass, and
  -- widgets/dashboard/inflight/prime.lua parses AT MOST ONE PER PASS -- which is the only reason
  -- the cost of a reply can be written down as a row at all. So the window is driven pass by pass
  -- from the run starting to the run reporting itself done, and the check below is the bound's own
  -- positive control: the run's completed-reply counter may never move by more than one in a pass.
  --
  -- Nothing is faked into the run. The widget's own tick starts it, the flight controller stub
  -- answers at the wire, and the number of passes it takes is printed on the row so a run that
  -- took a different number of them is visible rather than silently equivalent.
  ----------------------------------------------------------------------------
  local primeWorst = {}
  local primePasses = 0
  local Prime = World.require("widgets/dashboard/inflight/prime.lua")
  local Functions = World.require("widgets/dashboard/inflight/functions.lua")
  if type(Prime) ~= "table" or type(Functions) ~= "table" then
    error("accounting: the overlay's ground half did not load")
  end

  for i = 1, 4000 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 5000 + i)
    local prime = drive.prime
    local phase = type(prime) == "table" and prime.phase or nil
    if phase == Prime.PHASE_DONE then break end
    if phase == Prime.PHASE_ERROR then
      error("accounting: the prime failed with " .. tostring(prime.error))
    end
    local doneBefore = (type(prime) == "table" and prime.done) or 0
    local class = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    -- Only the passes the run itself occupies are counted and priced. Before the widget's own
    -- tick starts it there is a settle to wait out, and those passes are the dashboard's.
    if type(prime) == "table" then
      primePasses = primePasses + 1
      if n > (primeWorst[class] or 0) then primeWorst[class] = n end
    end
    local after = drive.prime
    if type(after) == "table" and type(prime) == "table" and after == prime then
      local step = (after.done or 0) - doneBefore
      if step > 1 then
        error(string.format(
          "accounting: one pass completed %d replies, so the overlay's per-pass bound is gone", step))
      end
    end
  end
  if type(drive.prime) ~= "table" or drive.prime.phase ~= Prime.PHASE_DONE then
    error("accounting: the prime never finished in 4000 passes")
  end
  if primePasses < #Functions.VALUE_READS then
    error(string.format(
      "accounting: the prime finished in %d passes, fewer than its %d value reads -- a pass parsed "
      .. "more than one reply", primePasses, #Functions.VALUE_READS))
  end

  ----------------------------------------------------------------------------
  -- THE LIVE SURFACE, which since the phase machine is the ARMED one.
  --
  -- One interlock switch, three surfaces, and the drive picks between them off the widget's own
  -- arm reading: the ground read-out before a flight, the tuning surface in the air, the delta
  -- after a flight that moved something. All three are the same job kind and their worst pass is
  -- one row, so all three are driven here -- and the state has to be SET rather than assumed,
  -- because a driver that armed nothing would have priced the ground surface three times over
  -- and the row would have looked exactly the same.
  --
  -- The arm flag is moved on the SENSOR and not on the state: the widget's telemetry read puts
  -- the sensor back over anything written there.
  ----------------------------------------------------------------------------
  local worst = {}
  Stubs.sensors["ARM"] = 1
  -- The arming itself is spent before anything is measured, for the same reason the store swap
  -- above is: the widget's own flight mode moves to `inflight` on that edge and it reloads the
  -- theme, which is a dashboard cost that happens once and belongs to no overlay row. Measured,
  -- it lands on the second pass of the loop and is worth about four thousand instructions.
  for i = 1, 30 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 800 + i)
    Stubs.tick()
    widget.refresh(widget, nil, nil)
  end
  for i = 1, 240 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, i)
    if i % 3 == 0 then invalidate(widget) end
    local class = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end
  if drive.phase ~= "live" then
    error("accounting: the live surface was priced in phase " .. tostring(drive.phase))
  end

  -- The same surface in fullscreen. `event` is an integer there and nil everywhere else, so this
  -- is also the only place any row in this file exercises the interactive path.
  for i = 1, 60 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 1000 + i)
    invalidate(widget)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end

  ----------------------------------------------------------------------------
  -- THE OTHER TWO SURFACES, on the same budget row.
  --
  -- Both are reached by DISARMING with the interlock still on, which is the pilot's whole flow:
  -- the delta after a flight that fired a step, the ground read-out after one that did not. They
  -- are two different trees and they are one job kind, so their worst pass goes into the same
  -- `pass.job.tuning` as the live surface's -- named here rather than given a row of its own,
  -- because a budget per tree would be three budgets for one dispatcher slot.
  ----------------------------------------------------------------------------

  -- Twelve parameters away from the snapshot the backup was taken with, which is more than a
  -- 272-pixel zone holds and therefore more than one page. Written straight onto the drive rather
  -- than stepped in over MSP: what is being priced is the BUILD of that list, and how the numbers
  -- got there does not change its shape.
  local changed = {
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
    39, 40, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 63, 66, 75, 80
  }
  local baseline = {}
  for _, id in ipairs(changed) do
    baseline[id] = 50
    drive.values[id] = 62
  end
  drive.backup = { profile = 2, at = 0, values = baseline }
  drive.primedValues = baseline
  drive.setSource = "board"
  -- A flight that asked for a step, which is what earns the delta screen at all.
  drive.fired = 1

  Stubs.sensors["ARM"] = 0
  -- and the DISARM is spent the same way the arming was: the widget's flight mode moves to
  -- postflight on that edge and reloads the theme behind the overlay. Priced into a tuning row it
  -- put four to six thousand instructions of somebody else's work on this feature's budget.
  for i = 1, 30 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 2800 + i)
    Stubs.tick()
    widget.refresh(widget, nil, nil)
  end
  for i = 1, 60 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 3000 + i)
    drive.valueEpoch = drive.valueEpoch + 1
    widget.inflightFullscreen = true
    invalidate(widget)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end

  -- What was actually built, read back off the recorder. A surface that had quietly fallen back
  -- to the dashboard scene -- or to the wrong phase -- would have measured a plausible number for
  -- the wrong tree, and the row would have looked exactly the same.
  if drive.phase ~= "post" then
    error("accounting: the postflight surface was priced in phase " .. tostring(drive.phase))
  end
  do
    local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
    local buttons, deltaRows, paged = 0, 0, false
    for _, node in ipairs(tree or {}) do
      if node.type == "button" then buttons = buttons + 1 end
      if type(node.text) == "string" then
        if string.find(node.text, " -> ", 1, true) then deltaRows = deltaRows + 1 end
        if string.find(node.text, "/", 1, true) and #node.text <= 5 then paged = true end
      end
    end
    -- The close box plus the restore; a list that ran out of screen before it ran out of
    -- parameters; and the page counter that says so.
    if buttons ~= 2 then error("accounting: the postflight surface built " .. buttons .. " buttons, not 2") end
    if deltaRows < 4 then error("accounting: the delta list built only " .. deltaRows .. " rows") end
    if not paged then error("accounting: the delta list was not measured over more than one page") end
  end

  -- and the GROUND read-out, which is what the same disarmed state shows after a flight that
  -- moved nothing. Four status lines and three actions, so it is the cheaper of the two -- priced
  -- anyway, because "cheaper" is a reading and not an assumption.
  drive.post = false
  drive.fired = 0
  for i = 1, 60 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 4000 + i)
    drive.prime = { phase = "slots", done = 20, total = 53, skipped = {} }
    drive.valueEpoch = drive.valueEpoch + 1
    widget.inflightFullscreen = true
    invalidate(widget)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end
  if drive.phase ~= "ground" then
    error("accounting: the ground surface was priced in phase " .. tostring(drive.phase))
  end
  do
    local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
    local buttons, reactive = 0, 0
    for _, node in ipairs(tree or {}) do
      if node.type == "button" then buttons = buttons + 1 end
      if type(node.text) == "function" then reactive = reactive + 1 end
    end
    -- The close box plus read, back up and restore; and the three lines that move while a run is
    -- on without anything rebuilding to move them.
    if buttons ~= 4 then error("accounting: the ground surface built " .. buttons .. " buttons, not 4") end
    if reactive < 3 then error("accounting: the ground surface built " .. reactive .. " reactive lines") end
  end

  removeDeferredLink()

  addRow("pass.tuning.state", worst.state or 0)
  addRow("pass.tuning.prime", primeWorst.state or 0,
    string.format("%d replies over %d passes, one parse per pass",
      drive.prime.done or 0, primePasses))
  addRow("pass.job.tuning", math.max(worst.tuning or 0, primeWorst.tuning or 0))
end

------------------------------------------------------------------------------
-- The service widget's background pass: the pure background half, no build.
------------------------------------------------------------------------------
World.reset()
do
  local Service = World.require("widgets/service/runtime.lua")
  local widget = Service.new({ x = 0, y = 0, w = 200, h = 100 }, {})
  local worst = 0
  for i = 1, 200 do
    feedLink(World.sensorIds, i)
    local n = count(widget.background, widget)
    if i > 60 and n > worst then worst = n end
  end
  addRow("pass.service", worst)
end

------------------------------------------------------------------------------
-- Check and report.
------------------------------------------------------------------------------
local unanswered = {}
for cmd, n in pairs(FC.unanswered) do
  unanswered[#unanswered + 1] = string.format("%d(x%d)", cmd, n)
end
table.sort(unanswered)

local collisions = {}
for cmd, files in pairs(FC.collisions) do
  collisions[#collisions + 1] = string.format("%d(%s)", cmd, table.concat(files, ","))
end
table.sort(collisions)

print("offline instruction accounting")
print(string.format("  interpreter        %s, count hook at 1 instruction", _VERSION))
print(string.format("  sweep control      %.3f instructions per reference (budgets.lua %.3f)",
  control, Budgets.sweepControl))
print(string.format("  api replies        %d of %d modules indexed", indexed, #apiFiles))
print(string.format("  themes             %d: %s", #themes, table.concat(themes, " ")))
print(string.format("  box types          %d", #boxTypes))
if #unanswered > 0 then
  print("  answered empty     " .. table.concat(unanswered, " "))
end
if #collisions > 0 then
  print("  command claimed by more than one module, first wins: " .. table.concat(collisions, " "))
end
for _, n in ipairs(notes) do print("  note               " .. n) end
print("")

local failures = {}
local warnings = {}

if math.abs(control - Budgets.sweepControl) > Budgets.sweepControlTolerance then
  failures[#failures + 1] = string.format(
    "sweep control %.3f is outside %.3f +/- %.3f: this run is measuring itself differently",
    control, Budgets.sweepControl, Budgets.sweepControlTolerance)
end

-- The self-test drives BOTH ways the check can go red -- a row over its target and a row
-- with no budget at all -- because a gate never seen red is a loop that never ran with a
-- badge on it. It fails unless both mechanisms fire.
local poisoned = selfTest and rows[1] and rows[1].name or nil
local hidden = selfTest and rows[2] and rows[2].name or nil
if hidden then Budgets.rows[hidden] = nil end

print(string.format("  %-32s %9s %9s %7s", "row", "measured", "target", "margin"))
for _, row in ipairs(rows) do
  local budget = Budgets.rows[row.name]
  local target = budget and budget.target
  if poisoned == row.name then target = 1 end
  local marginText = "-"
  if target and target > 0 then
    marginText = string.format("%.0f%%", 100 * (target - row.measured) / target)
  end
  -- A target that was moved off the figure first written down says so on every run.
  -- Otherwise a re-apportioned budget reads exactly like the original one.
  local extra = row.extra
  if budget and budget.proposed and budget.proposed ~= target then
    local moved = string.format("re-apportioned from %d", budget.proposed)
    extra = extra and (moved .. ", " .. extra) or moved
  end
  print(string.format("  %-32s %9d %9s %7s%s",
    row.name, row.measured, target and tostring(target) or "MISSING", marginText,
    extra and ("   " .. extra) or ""))
  if target == nil then
    failures[#failures + 1] = row.name .. " has no row in budgets.lua"
  elseif row.measured > target then
    failures[#failures + 1] = string.format("%s: %d instructions over a target of %d",
      row.name, row.measured, target)
  elseif row.measured > target * 0.9 then
    -- A flag to widen the row, not a build failure: the row is still inside its ceiling,
    -- and turning a thin margin into a red build would make the honest answer -- write
    -- down what it costs -- the expensive one.
    warnings[#warnings + 1] = string.format(
      "%s: %d is within 10%% of its target of %d, so this is a margin to widen, not a pass to celebrate",
      row.name, row.measured, target)
  end
end

-- The other half of the coverage rule: a row nothing measures is a target nothing
-- enforces, and a removed box type or theme leaves exactly that behind.
local orphans = {}
for name in pairs(Budgets.rows) do
  if not rowIndex[name] then orphans[#orphans + 1] = name end
end
table.sort(orphans)
for _, name in ipairs(orphans) do
  failures[#failures + 1] = name .. " has a budget row but nothing measured it"
end

-- A PR that adds a box type or a theme needs its cost row, and the number in it has to be
-- a measurement rather than a guess. This prints the table body ready to paste; the
-- targets it suggests carry the same margin the rows above are read with.
if args["--emit"] then
  print("")
  print("-- budgets.lua rows, emitted from this run")
  print(string.format("sweepControl = %.3f,", control))
  print("rows = {")
  for _, row in ipairs(rows) do
    local budget = Budgets.rows[row.name]
    local target = (budget and budget.target) or (math.ceil(row.measured / 0.8 / 50) * 50)
    print(string.format("  [%q] = { target = %d, measured = %d },", row.name, target, row.measured))
  end
  print("}")
end

print("")
for _, w in ipairs(warnings) do print("WARN: " .. w) end
if selfTest then
  local sawPoisoned, sawHidden = false, false
  for _, f in ipairs(failures) do
    if poisoned and string.find(f, poisoned, 1, true)
      and string.find(f, "over a target", 1, true) then
      sawPoisoned = true
    end
    if hidden and string.find(f, hidden, 1, true)
      and string.find(f, "no row in budgets.lua", 1, true) then
      sawHidden = true
    end
  end
  for _, f in ipairs(failures) do print("(self-test) " .. f) end
  if not sawPoisoned then
    print("SELF-TEST FAILED: a target poisoned to 1 did not turn the check red")
    os.exit(1)
  end
  if not sawHidden then
    print("SELF-TEST FAILED: a row with its budget removed did not turn the check red")
    os.exit(1)
  end
  print("SELF-TEST PASSED: both a breached target and a missing budget row turn the check red")
  os.exit(0)
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("%d row(s) over budget or unaccounted", #failures))
  if checking then os.exit(1) end
else
  print(string.format("%d rows, 0 failures", #rows))
end
