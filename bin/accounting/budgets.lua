-- What a pass, a box type and a theme are allowed to cost, in Lua VM instructions.
--
-- EdgeTX bills a widget call at 20 000 instructions (lua_widget.cpp, MAX_INSTRUCTIONS),
-- and refresh() plus the LVGL reactive sweep that follows it share that one budget. Every
-- target below is a share of it, and the row that actually decides whether the widget
-- survives is `theme.*`: the worst pass of a theme plus the full sweep of the tree it
-- leaves standing.
--
-- `target` is what the check enforces. `measured` is what the row cost when it was written
-- -- kept so that a number which has moved is visible even while it is still inside its
-- target. `proposed` is the figure that sat on the row before anything had been measured;
-- where it differs from `target` the report says so on every run, so a re-apportioned
-- budget can never pass for the original one.
--
-- Adding a box type or a theme means adding its row here, measured rather than estimated:
-- `lua5.3 bin/accounting/measure.lua --emit` prints the table body of a run.

return {
  -- The cost of one call through the empty-closure loop the sweep is replayed in,
  -- subtracted from every sweep row. It is a property of this check rather than of the
  -- suite: a run whose control has moved is measuring differently, and fails itself.
  sweepControl = 4.007,
  sweepControlTolerance = 0.25,

  rows = {
    ----------------------------------------------------------------------------
    -- Pass classes. The dispatcher runs exactly one work class per pass, so these
    -- are alternatives rather than terms that add up.
    --
    -- The STATE and JOB shares are not the ones first written down. Measurement
    -- moved the weight the other way: the background half is the expensive pass
    -- and the build chunk is cheap, where the first split had assumed the reverse.
    -- The ceiling below is unchanged, and the STATE target is derived from it --
    -- 14 000 less the largest shipped theme's sweep -- rather than chosen.
    ----------------------------------------------------------------------------
    ["pass.state"] = { target = 12200, measured = 11437, proposed = 8000 },
    -- The same class of pass with the model ARMED and telemetry moving between passes.
    -- It shares pass.state's ceiling because it is the same class of pass; it has a row
    -- of its own because every other steady-state row here is measured disarmed against
    -- a frozen sensor set, and a flight is neither.
    ["pass.state.armed"] = { target = 12200, measured = 10506 },
    ["pass.job.prepare"] = { target = 1250, measured = 1021 },
    -- Raised from 5700 when the object renderers began compiling a box's thresholds where the
    -- box is rendered instead of on the first value change in the sweep. The build is chunked at
    -- eight boxes per pass and the sweep that follows the swap is not, so this is the cheaper of
    -- the two passes to carry it. The margin is held at the ~10% the row already had.
    ["pass.job.build"] = { target = 6200, measured = 5557, proposed = 5700 },
    ["pass.swap"] = { target = 3400, measured = 2737, proposed = 6000 },

    -- The splash pass is the one JOB pass that runs while the connect chain still has
    -- MSP traffic in flight, so its pump quantum does real poll work. Until the pump
    -- ran under the widget event context, its poll loop kept the tool state's
    -- wall-clock exit -- which the accounting stubs' fixed-step clock expired on the
    -- first read, so the loop barely ran and the row was first calibrated on that
    -- under-measurement (1 826). Counts-only, the loop runs to its poll caps, which
    -- is what a pass on the radio could always cost.
    ["pass.splash"] = { target = 7100, measured = 5678 },

    -- The cold start, before the link is up and the first scene is on screen. It is
    -- the pass that loads modules, and it is the closest any pass comes to the
    -- firmware's hard limit -- which is why the entry point's "CPU limit" back-off
    -- is still in place. The target holds it at today's cost; it is not a share of
    -- a budget anyone would call comfortable.
    ["pass.startup.worst"] = { target = 18000, measured = 17598 },

    -- The service widget's background pass: the same two runtimes, with no scene
    -- build and no sweep of a theme mixed into it.
    ["pass.service"] = { target = 1600, measured = 1251 },

    -- One run() of SCRIPTS/FUNCTIONS/rfsbg.lua with a full frame backlog waiting,
    -- every frame of it decoded. This row is NOT a share of the widget ceiling
    -- above and must not be read as one: a call in the radio's script state is
    -- yielded once it has held the interpreter for a task period and resumed on
    -- the next turn, rather than cut off at an instruction count. It is here as a
    -- regression detector, and as the price of decoding a whole backlog instead of
    -- its newest quarter.
    ["pass.function"] = { target = 7300, measured = 5808 },
    -- The in-flight tuning overlay, in three rows: the pass that drives it, the pass a reply of
    -- its ground half lands on, and the build of its screens.
    --
    -- `pass.tuning.state` is the STEADY state -- the overlay driving the radio with nothing
    -- outstanding on the wire. One switch read, the trims, the enable channel, the pulse; less
    -- than the theme render key it displaces, which is why it sits below the dashboard's own
    -- STATE pass.
    --
    -- `pass.tuning.prime` is the ground half, and it is a row of its own because it is a
    -- different pass and not a worse day of the same one. Before a flight the overlay reads the
    -- receiver map, the board's slot table one record at a time and nine value replies, and the
    -- pass a reply lands on pays that reply's parse -- 42 to 933 instructions depending on the
    -- command -- on top of the drive, the progress the screen shows and the poll the outstanding
    -- request keeps busy. It is bounded by inflight/prime.lua parsing AT MOST ONE reply per pass;
    -- without that bound the row is not a number at all, because what a pass costs then depends
    -- on how many answers the link happened to deliver into it. The margin here is the check's
    -- 10 % floor rather than the 15 % most rows carry: this pass is close enough to the
    -- firmware's own 20 000 that a wider target would be widening the wrong thing.
    --
    -- The JOB pass builds the whole surface in one step, the way the menu does, and it covers
    -- two different builds: the tuning surface with its chips, rows and step buttons, and the
    -- ground surface with the three profile actions and the delta list at its cap. The setup
    -- check, which walks the two mixer lines and both variables' details, is on the ground one.
    --
    -- Its target rises again because the surface itself grew, and it grew for a pilot who could
    -- not read the old one: the chips carry letters, every row names the trim that drives it, the
    -- parameter carries what it was primed at and whether it was announced, and the step buttons
    -- carry their glyphs and three lines of hint. That is 72 nodes against 44, and at roughly 190
    -- instructions a node the arithmetic is the whole of the rise. The margin is the check's 10 %
    -- floor rather than the 15 % most rows carry, for the reason the prime's is: what the
    -- firmware's own 20 000 has to hold after this is the LVGL sweep of the tree it just built,
    -- and nothing measures that.
    --
    -- `pass.tuning.state` was re-apportioned a second time when the interlock gained its phase
    -- machine. What the pass carries now that it did not: the phase itself and the two things
    -- that follow from it -- the fired counter and the postflight latch -- the two reference
    -- values the live surface shows beside the number, and one `fstat` of the per-model store a
    -- second, which is the overlay's own answer to a setting that needed a radio restart. The
    -- steady pass was measured at 12 961 in the air and 13 080 on the ground; the target is set
    -- above the second of those and not the first.
    ["pass.tuning.state"] = { target = 14200, measured = 13080, proposed = 13000 },
    ["pass.tuning.prime"] = { target = 16700, measured = 14855 },
    ["pass.job.tuning"] = { target = 15700, measured = 13155, proposed = 10600 },

    ----------------------------------------------------------------------------
    -- The ceiling, and the row that carries the safety argument: the worst pass of
    -- this theme plus one full sweep of the tree it leaves standing. The margin to
    -- 20 000 covers the C-side work, the difference between this interpreter and
    -- the firmware's, and the variance neither of them accounts for.
    ----------------------------------------------------------------------------
    ["theme.@aerc"] = { target = 14000, measured = 11600 },
    ["theme.@aerc-n"] = { target = 14000, measured = 10950 },
    ["theme.@rt-rc"] = { target = 14000, measured = 11676 },
    ["theme.@rt-rc-n"] = { target = 14000, measured = 11170 },
    ["theme.@srb-rc"] = { target = 14000, measured = 12887 },
    ["theme.default"] = { target = 14000, measured = 13237 },
    ["theme.rfstatus"] = { target = 14000, measured = 10515 },

    ----------------------------------------------------------------------------
    -- Per box type: one render into the node table, and one sweep of the reactive
    -- references that render collected. A theme's cost is the sum of its boxes
    -- through these two rows, which is what makes a new theme priceable before it
    -- is built.
    --
    -- Ten of these rows carry a `proposed` that is their PREVIOUS target rather than a
    -- pre-measurement guess, and they are the rows where work that used to be done in the sweep
    -- is now done in the render. The trade is deliberate: a render happens once per scene, a
    -- sweep on every foreground pass.
    --
    -- Five of them are the constant colour and font resolved once at build. The other five are
    -- the box's thresholds, compiled where the box is rendered rather than on the first value
    -- change after it: the fixtures below declare literal thresholds, so what moves for them is
    -- only WHEN the list is compiled -- out of the first sweep, which the `sweep.*` rows do not
    -- measure, and into the render, which `box.*` does. Where a theme gives a threshold limit as
    -- a function the list used to be compiled again on EVERY value change, and that is the cost
    -- this removes: on a shipped arc whose warning level comes from the theme configuration the
    -- colour reference falls from 301 instructions and 528 bytes per change to 141 and none.
    --
    -- Which is why the `theme.*` rows, the ones the safety argument rests on, all fall or hold.
    ----------------------------------------------------------------------------
    ["box.dial"] = { target = 200, measured = 121 },
    ["sweep.dial"] = { target = 50, measured = 0 },
    ["box.gauge"] = { target = 960, measured = 748, proposed = 800 },
    ["sweep.gauge"] = { target = 400, measured = 180 },
    ["box.gauge/arc"] = { target = 1650, measured = 1281, proposed = 1150 },
    ["sweep.gauge/arc"] = { target = 450, measured = 262 },
    ["box.gauge/bar"] = { target = 1580, measured = 1251, proposed = 1300 },
    ["sweep.gauge/bar"] = { target = 350, measured = 305 },
    ["box.image/image"] = { target = 200, measured = 159 },
    ["sweep.image/image"] = { target = 50, measured = 0 },
    ["box.image/model"] = { target = 400, measured = 306 },
    ["sweep.image/model"] = { target = 50, measured = 0 },
    ["box.text/blackbox"] = { target = 740, measured = 577, proposed = 600 },
    ["sweep.text/blackbox"] = { target = 500, measured = 352 },
    ["box.text/governor"] = { target = 720, measured = 556, proposed = 600 },
    ["sweep.text/governor"] = { target = 500, measured = 339 },
    ["box.text/stats"] = { target = 470, measured = 365, proposed = 300 },
    ["sweep.text/stats"] = { target = 300, measured = 109 },
    ["box.text/telemetry"] = { target = 740, measured = 570, proposed = 600 },
    ["sweep.text/telemetry"] = { target = 450, measured = 301 },
    ["box.time/count"] = { target = 700, measured = 545, proposed = 600 },
    ["sweep.time/count"] = { target = 300, measured = 177 },
    ["box.time/flight"] = { target = 790, measured = 616, proposed = 650 },
    ["sweep.time/flight"] = { target = 300, measured = 116 },
    ["box.time/total"] = { target = 490, measured = 383, proposed = 300 },
    ["sweep.time/total"] = { target = 300, measured = 116 },

    ----------------------------------------------------------------------------
    -- Per unit. These do not gate a pass on their own -- they are the terms a pass
    -- is built from, and the place a regression shows up as itself rather than as
    -- a pass that has quietly grown.
    ----------------------------------------------------------------------------
    -- The whole background half of a STATE pass: the event runner, the
    -- custom-telemetry drain and the arm/disarm edges. The largest single term in
    -- a STATE pass, at roughly two fifths of it.
    ["unit.events.wakeup"] = { target = 5600, measured = 4457 },
    -- The same wakeup with the model ARMED and telemetry moving, which is the only
    -- shape in which the flight record does its work: it advances the flight clock on
    -- every wakeup and samples the tracked sensors on its own 0.5 s cadence, so the
    -- worst wakeup of a flight is one that samples. The target below is not the 5600 it
    -- shares with the row above: that figure was written while the clock advanced per
    -- CALL, under which the 0.5 s sample landed in a measured wakeup only by accident.
    -- With the clock advancing per pass the sample is in the worst wakeup by
    -- construction, which is what this row is for, and it costs 6137. The previous
    -- figure is kept in `proposed` so the report says so on every run.
    ["unit.events.wakeup.armed"] = { target = 7700, measured = 6137, proposed = 5600 },
    -- The custom-telemetry drain with a full frame backlog waiting: POP_CAP frames
    -- popped and accounted, DECODE_CAP of them walked through the per-sensor
    -- decoders. This is what the two counts in telemetry_bg/drain.lua buy.
    ["unit.telemetry.drain"] = { target = 3300, measured = 2557 },
    -- The same wakeup while the background function script is draining for the
    -- whole radio: the drain and the adjustment teller are skipped and SmartFuel
    -- is not, so what is left is what only this Lua state can compute. The gap to
    -- the row above is what a pass saves by handing over.
    ["unit.telemetry.handoff"] = { target = 350, measured = 241 },
    ["unit.msp.pump"] = { target = 300, measured = 218 },
    -- The API-layer parse of the largest reply the suite scripts, in one piece. It
    -- lands in whatever pass completes the reassembly.
    ["unit.msp.parse.max"] = { target = 2750, measured = 2175 },
  },
}
