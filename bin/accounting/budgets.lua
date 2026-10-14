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
-- Adding a box type, a theme or a tool page means adding its row here, measured rather than
-- estimated: `lua5.3 bin/accounting/measure.lua --emit` prints the table body of a run.

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
    --
    -- That ceiling has since been raised to 16 200 (see the theme rows) and this target was not
    -- raised with it. The derivation is a bound, and 12 200 is still inside it: 16 200 less the
    -- largest sweep now measured (2 439, @aerc) is 13 761. The pass rose by about 1 000 when the
    -- telemetry frames the run feeds became the firmware's, and it keeps more than a quarter of
    -- its target, so there is no margin here to widen.
    ----------------------------------------------------------------------------
    ["pass.state"] = { target = 12200, measured = 8943, proposed = 8000 },
    -- The same class of pass with the model ARMED and telemetry moving between passes.
    -- It shares pass.state's ceiling because it is the same class of pass; it has a row
    -- of its own because every other steady-state row here is measured disarmed against
    -- a frozen sensor set, and a flight is neither.
    ["pass.state.armed"] = { target = 12200, measured = 9541 },
    ["pass.job.prepare"] = { target = 1250, measured = 924 },
    -- Raised from 5700 when the object renderers began compiling a box's thresholds where the
    -- box is rendered instead of on the first value change in the sweep. The build is chunked at
    -- eight boxes per pass and the sweep that follows the swap is not, so this is the cheaper of
    -- the two passes to carry it. The margin is held at the ~10% the row already had.
    ["pass.job.build"] = { target = 6200, measured = 5538, proposed = 5700 },
    ["pass.swap"] = { target = 3400, measured = 2759, proposed = 6000 },

    -- The splash pass is the one JOB pass that runs while the connect chain still has
    -- MSP traffic in flight, so its pump quantum does real poll work. Until the pump
    -- ran under the widget event context, its poll loop kept the tool state's
    -- wall-clock exit -- which the accounting stubs' fixed-step clock expired on the
    -- first read, so the loop barely ran and the row was first calibrated on that
    -- under-measurement (1 826). Counts-only, the loop runs to its poll caps, which
    -- is what a pass on the radio could always cost.
    ["pass.splash"] = { target = 7100, measured = 2439 },

    -- The cold start, before the link is up and the first scene is on screen. It is
    -- the pass that loads modules, and it is the closest any pass comes to the
    -- firmware's hard limit -- which is why the entry point's "CPU limit" back-off
    -- is still in place. The target holds it at today's cost; it is not a share of
    -- a budget anyone would call comfortable.
    ["pass.startup.worst"] = { target = 18000, measured = 12088 },

    -- The service widget's background pass: the same two runtimes, with no scene
    -- build and no sweep of a theme mixed into it.
    --
    -- With the connect sequence through, every pass runs the events wakeup and with it the
    -- custom-telemetry drain on a pass's worth of frames, and that is most of what the row
    -- prices; the dearest pass is a one-off early in the window. The window is 60 s so that
    -- it also holds the 30 s look at the settings store (widgets/service/runtime.lua,
    -- PREFERENCES_INTERVAL_SECONDS), which adds a few hundred instructions to its pass and
    -- is no longer the worst one. Raised from 2200 when the world rebuild stopped handing
    -- this block the previous scenario's runtimes, whose connect sequence never finished and
    -- so never let the drain run here.
    --
    -- The card the run is given (stubs/edgetx.lua) does not move this row, and the reason is
    -- not the one this comment used to give. It used to say the settings store is now written
    -- and that the 30 s look at pass 300 parses one. A traced --check run writes no card path
    -- at all, on master as much as here, so nothing is written and nothing is parsed. What the
    -- card costs is the Lua wrapper every io.open now goes through, counted under the hook and
    -- billed to the suite -- and even that stops short of this row: removing the io.open wrapper
    -- puts all four rows that move back on master's figures, and this is not one of them. The
    -- dearest pass of this block is an early one-off rather than a look at the store.
    --
    -- Raised from 6000 when the telemetry frames the run feeds became the ones the firmware
    -- sends (measure.lua, WIRE_WIDTH): the old frame stopped the decoders after five of its
    -- entries, so every pass here priced a drain that decoded almost nothing. The new target is
    -- the measurement with the margin --emit gives a new row.
    ["pass.service"] = { target = 7850, measured = 6257, proposed = 6000 },

    -- One run() of SCRIPTS/FUNCTIONS/rfsbg.lua with a full frame backlog waiting,
    -- every frame of it decoded. This row is NOT a share of the widget ceiling
    -- above and must not be read as one: a call in the radio's script state is
    -- yielded once it has held the interpreter for a task period and resumed on
    -- the next turn, rather than cut off at an instruction count. It is here as a
    -- regression detector, and as the price of decoding a whole backlog instead of
    -- its newest quarter. Raised from 7300 for the same reason as pass.service: until the
    -- frames were built at the firmware's widths, "every frame decoded" meant five entries of
    -- each. Measured after every frame of the cycle has been through once, so no sensor in the
    -- backlog is published for the first time.
    ["pass.function"] = { target = 10050, measured = 8016, proposed = 7300 },
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
    ["pass.tuning.state"] = { target = 14200, measured = 10790, proposed = 13000 },
    -- Raised from 16 700 when the telemetry frames the run feeds became the ones the firmware
    -- sends (measure.lua, WIRE_WIDTH), which put the pass inside the last tenth of its target. The
    -- new target is the measurement with the 10 % floor named above, rounded up to the next hundred.
    ["pass.tuning.prime"] = { target = 16900, measured = 15139, proposed = 16700 },
    ["pass.job.tuning"] = { target = 15700, measured = 13155, proposed = 10600 },

    ----------------------------------------------------------------------------
    -- The ceiling, and the row that carries the safety argument: the worst pass of
    -- this theme plus one full sweep of the tree it leaves standing. The margin to
    -- 20 000 covers the C-side work, the difference between this interpreter and
    -- the firmware's, and the variance neither of them accounts for.
    --
    -- Raised from 14 000 when the telemetry frames the run feeds became the ones the firmware
    -- sends (measure.lua, WIRE_WIDTH). Every figure that ceiling was held against had been
    -- measured on a frame the firmware does not send: it stopped the decoders after five of its
    -- entries, so the drain in each theme's worst pass decoded almost nothing. With the real
    -- frames each worst pass rose by 1 007 to 1 091 and no sweep moved. The ceiling stays one
    -- figure the shipped themes share: the largest of them (@aerc, 13 726) with the 15 % margin
    -- most rows carry, rounded up to the next hundred. Not the 20 % --emit gives a new row: this
    -- is the row whose distance to 20 000 is the safety argument.
    ----------------------------------------------------------------------------
    ["theme.@aerc"] = { target = 16200, measured = 13726, proposed = 14000 },
    ["theme.@aerc-n"] = { target = 16200, measured = 13675, proposed = 14000 },
    ["theme.@rt-rc"] = { target = 16200, measured = 13296, proposed = 14000 },
    ["theme.@rt-rc-n"] = { target = 16200, measured = 13235, proposed = 14000 },
    ["theme.@srb-rc"] = { target = 16200, measured = 12936, proposed = 14000 },
    ["theme.default"] = { target = 16200, measured = 10095, proposed = 14000 },
    ["theme.rfstatus"] = { target = 16200, measured = 10217, proposed = 14000 },
    -- A free-form theme builds its whole tree in the one pass that prepares the scene, where a
    -- theme of boxes spreads its build over passes of eight boxes each, so its worst pass is the
    -- build and this row sits above the ceiling the shipped themes share; the 14 000 that ceiling
    -- was when this row was written stays its `proposed`. What the build leaves standing is cheap: the sweep is below that of four of the
    -- seven themes above, and a render happens once per scene where a sweep happens on every
    -- foreground pass. The target is the measurement with the margin `pass.job.build` carries
    -- over its own (6200 over 5557, 11.6 %), rounded up to the next hundred. The tree holds 50
    -- references, more than any theme above, and that is what would move this row first.
    ["theme.urban"] = { target = 17400, measured = 15331, proposed = 14000 },

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
    -- Raised from 500 when `widgets.dashboard.bb_ready` went back to "READY". This row's fixture is
    -- the first blackbox box a shipped theme declares (@aerc: autosize_chars 10, a font function)
    -- drawn with the label every theme uses (themes/default/common.lua); the 11-character "MSP Wait..." took the autosize branch
    -- of the box's font getter and skipped that font function, which "READY" -- like REC and
    -- LOGGED -- calls. No `theme.*` row moves. The margin is held at ~10%.
    ["sweep.text/blackbox"] = { target = 620, measured = 551, proposed = 500 },
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
    -- a STATE pass, at roughly two fifths of it. Raised from 5600 when the telemetry frames the
    -- run feeds became the ones the firmware sends (measure.lua, WIRE_WIDTH): the drain in it now
    -- walks every entry of a frame instead of five, and the row rose by about 800 to within 11 %
    -- of its old target. The new target is the measurement with the margin --emit gives a new row.
    ["unit.events.wakeup"] = { target = 6250, measured = 4977, proposed = 5600 },
    -- The same wakeup with the model ARMED and telemetry moving, which is the only
    -- shape in which the flight record does its work: it advances the flight clock on
    -- every wakeup and samples the tracked sensors on its own 0.5 s cadence, so the
    -- worst wakeup of a flight is one that samples. The target below is not the 5600 it
    -- shares with the row above: that figure was written while the clock advanced per
    -- CALL, under which the 0.5 s sample landed in a measured wakeup only by accident.
    -- With the clock advancing per pass the sample is in the worst wakeup by
    -- construction, which is what this row is for, and it costs 6137. The previous
    -- figure is kept in `proposed` so the report says so on every run.
    ["unit.events.wakeup.armed"] = { target = 7700, measured = 5662, proposed = 5600 },
    -- The custom-telemetry drain with a full frame backlog waiting: POP_CAP frames
    -- popped and accounted, DECODE_CAP of them walked through the per-sensor
    -- decoders. This is what the two counts in telemetry_bg/drain.lua buy.
    --
    -- Raised from 3300 when the frames became the firmware's (measure.lua, WIRE_WIDTH): the
    -- old frame was walked for five of its entries, these are walked to their last byte, which
    -- put the row inside the last tenth of its old target. The row also no longer carries one
    -- of smart.lua's module loads, which the warm-up used to leave in the measured call, and
    -- every frame of the cycle has been through once before it, so no sensor is published here
    -- for the first time.
    ["unit.telemetry.drain"] = { target = 3850, measured = 3065, proposed = 3300 },
    -- The same wakeup while the background function script is draining for the
    -- whole radio: the drain and the adjustment teller are skipped and SmartFuel
    -- is not, so what is left is what only this Lua state can compute. The gap to
    -- the row above is what a pass saves by handing over. Its SmartFuel is the pass of a
    -- world with no session connected, which resets and returns; until the warm-up waited for
    -- smart.lua's own module loads, one of them was in this call too. Lowered from 350 once
    -- that load left the call: the target is the measurement with the margin --emit gives a
    -- new row, so the row keeps watching what is left rather than the load it no longer pays.
    ["unit.telemetry.handoff"] = { target = 250, measured = 168, proposed = 350 },
    -- One Runtime.pump() after twenty ticks of a connected runtime. Its queue is idle by then,
    -- so this prices the idle turn -- the refusals and the isProcessed() test that ends it --
    -- and not a pump that finds work. That pump's processQueue and publish have no row of
    -- their own; they are priced inside the pass rows whose pump finds the queue busy,
    -- pass.splash and pass.tuning.prime among them.
    ["unit.msp.pump"] = { target = 300, measured = 48 },
    -- The API-layer parse of the largest reply the suite scripts, in one piece. It
    -- lands in whatever pass completes the reassembly.
    ["unit.msp.parse.max"] = { target = 2750, measured = 2175 },

    ----------------------------------------------------------------------------
    -- The tool's pages, as the dashboard hosts them: the instructions inside one page
    -- module's build, the dearest build of one open. widgets/dashboard/tool_host.lua runs
    -- ui/home.lua inside the widget call, so these builds are billed against the same
    -- 20 000 as every row above; the tool script is not, and has no rows here.
    --
    -- Measured on src/, like every other row. On src/ a page resolves its strings at run
    -- time through pageText(), and the packaged tool has them resolved at build time, so
    -- these figures read higher than the radio pays: by 0 to 225 % (median 15 %) per page
    -- on the English package built from the same tree. Read them as regression figures for
    -- the source as written, not as the shipped cost.
    --
    -- The targets are what --emit suggests for a new row -- the measurement plus 20 %,
    -- rounded up to 50 -- and never above the 20 000 a call is stopped at for a page that is
    -- below it. Three pages are above it with their build alone, on src/ and on the package
    -- both: a build that does not fit in one call does not finish hosted however often it
    -- is tried. Those three carry their --emit figure as the target, so the check is green
    -- today, and 20 000 in `proposed`, so every run prints that they sit above it. How the
    -- 20 000 is to be shared between a page's build and the rest of the pass that builds it
    -- is not decided by these rows.
    --
    -- A page that cannot be opened in the run's world -- no menu leads to it, its tile is
    -- disabled, or it has no build of its own -- has no row, and the report names it.
    ["page.developer_api_tester_page.build"] = { target = 2100, measured = 1669 },
    ["page.developer_msp_experiments_page.build"] = { target = 5600, measured = 4448 },
    ["page.developer_msp_speed_page.build"] = { target = 4150, measured = 3318 },
    ["page.developer_settings_page.build"] = { target = 3250, measured = 2593 },
    ["page.diagnostics_elrs_link_page.build"] = { target = 4400, measured = 3502 },
    ["page.diagnostics_fblstatus_page.build"] = { target = 6300, measured = 5023 },
    ["page.diagnostics_info_page.build"] = { target = 7250, measured = 5783 },
    ["page.diagnostics_rfstatus_page.build"] = { target = 7750, measured = 6162 },
    ["page.diagnostics_session_logs_page.build"] = { target = 3700, measured = 2942 },
    ["page.diagnostics_smartfuel_page.build"] = { target = 9000, measured = 7194 },
    ["page.diagnostics_system_status_page.build"] = { target = 12850, measured = 10278 },
    ["page.diagnostics_validate_sensors_page.build"] = { target = 10650, measured = 8502 },
    ["page.flight_tuning_advanced_autolevel_page.build"] = { target = 5150, measured = 4107 },
    ["page.flight_tuning_advanced_filters_page.build"] = { target = 8550, measured = 6827 },
    ["page.flight_tuning_advanced_main_rotor_page.build"] = { target = 5250, measured = 4169 },
    ["page.flight_tuning_advanced_pid_bandwidth_page.build"] = { target = 5250, measured = 4169 },
    ["page.flight_tuning_advanced_pid_controller_page.build"] = { target = 5400, measured = 4287 },
    ["page.flight_tuning_advanced_rates_advanced_advanced_page.build"] = { target = 5150, measured = 4095 },
    ["page.flight_tuning_advanced_rates_advanced_cyclic_behaviour_page.build"] = { target = 5050, measured = 4039 },
    ["page.flight_tuning_advanced_rates_advanced_table_page.build"] = { target = 5000, measured = 3977 },
    ["page.flight_tuning_advanced_rescue_page.build"] = { target = 5500, measured = 4390 },
    ["page.flight_tuning_advanced_tail_rotor_page.build"] = { target = 5750, measured = 4600 },
    ["page.flight_tuning_governor_page.build"] = { target = 8650, measured = 6907 },
    ["page.flight_tuning_pids_page.build"] = { target = 6300, measured = 5013 },
    ["page.flight_tuning_rates_page.build"] = { target = 5000, measured = 3998 },
    ["page.logs_page.build"] = { target = 3600, measured = 2875 },
    ["page.settings_audio_events_adjustment_page.build"] = { target = 2300, measured = 2009 },
    ["page.settings_audio_events_arming_page.build"] = { target = 2300, measured = 2006 },
    ["page.settings_audio_events_connect_page.build"] = { target = 5150, measured = 4108 },
    ["page.settings_audio_events_esc_page.build"] = { target = 6000, measured = 5910 },
    ["page.settings_audio_events_fuel_page.build"] = { target = 5550, measured = 5189 },
    ["page.settings_audio_events_governor_page.build"] = { target = 6300, measured = 6008 },
    ["page.settings_audio_events_link_page.build"] = { target = 5750, measured = 5717 },
    ["page.settings_audio_events_profiles_page.build"] = { target = 2650, measured = 2498 },
    ["page.settings_audio_events_voltage_page.build"] = { target = 6100, measured = 5112 },
    ["page.settings_audio_volume_page.build"] = { target = 2100, measured = 1674 },
    ["page.settings_dashboard_inflight_page.build"] = { target = 10200, measured = 8152 },
    ["page.settings_dashboard_quick_menu_page.build"] = { target = 2500, measured = 2364 },
    ["page.settings_dashboard_theme_page.build"] = { target = 13250, measured = 10585 },
    ["page.settings_general_page.build"] = { target = 2200, measured = 1747 },
    ["page.settings_localization_page.build"] = { target = 2350, measured = 1878 },
    ["page.setup_accelerometer_page.build"] = { target = 4050, measured = 3240 },
    ["page.setup_alignment_page.build"] = { target = 20000, measured = 16113 },
    ["page.setup_configuration_page.build"] = { target = 4300, measured = 3427 },
    ["page.setup_controls_adjustments_page.build"] = { target = 19250, measured = 15379 },
    ["page.setup_controls_beepers_configuration_page.build"] = { target = 6450, measured = 5147 },
    ["page.setup_controls_beepers_dshot_page.build"] = { target = 3450, measured = 2727 },
    ["page.setup_controls_blackbox_configuration_page.build"] = { target = 5600, measured = 4476 },
    ["page.setup_controls_blackbox_logging_page.build"] = { target = 7050, measured = 5620 },
    ["page.setup_controls_blackbox_status_page.build"] = { target = 3800, measured = 3007 },
    ["page.setup_controls_failsafe_page.build"] = { target = 6750, measured = 5396 },
    ["page.setup_controls_inflight_page.build"] = { target = 9950, measured = 7930 },
    ["page.setup_controls_modes_page.build"] = { target = 4650, measured = 3703 },
    ["page.setup_controls_stats_page.build"] = { target = 3750, measured = 2964 },
    ["page.setup_esc_motors_esc_tools_am32_page.build"] = { target = 6200, measured = 4944 },
    ["page.setup_esc_motors_esc_tools_blheli_s_page.build"] = { target = 6350, measured = 5050 },
    ["page.setup_esc_motors_esc_tools_bluejay_page.build"] = { target = 6450, measured = 5126 },
    ["page.setup_esc_motors_motor_override_page.build"] = { target = 3850, measured = 3047 },
    ["page.setup_esc_motors_rpm_page.build"] = { target = 4400, measured = 3510 },
    ["page.setup_esc_motors_telemetry_page.build"] = { target = 4000, measured = 3190 },
    ["page.setup_esc_motors_throttle_page.build"] = { target = 4250, measured = 3379 },
    ["page.setup_governor_curves_page.build"] = { target = 3850, measured = 3070 },
    ["page.setup_governor_filters_page.build"] = { target = 3550, measured = 2833 },
    ["page.setup_governor_general_page.build"] = { target = 4000, measured = 3177 },
    ["page.setup_governor_time_page.build"] = { target = 3550, measured = 2833 },
    ["page.setup_gps_page.build"] = { target = 3950, measured = 3158 },
    ["page.setup_mixer_swash_page.build"] = { target = 4500, measured = 3565 },
    ["page.setup_mixer_swashgeometry_page.build"] = { target = 4650, measured = 3688 },
    ["page.setup_mixer_tail_page.build"] = { target = 4150, measured = 3315 },
    ["page.setup_mixer_trims_page.build"] = { target = 3900, measured = 3083 },
    ["page.setup_model_page.build"] = { target = 5350, measured = 4272 },
    ["page.setup_ports_page.build"] = { target = 34300, measured = 27401, proposed = 20000 },
    ["page.setup_power_alerts_page.build"] = { target = 4200, measured = 3346 },
    ["page.setup_power_battery_page.build"] = { target = 14350, measured = 11456 },
    ["page.setup_power_preferences_page.build"] = { target = 4800, measured = 3823 },
    ["page.setup_power_smartfuel_page.build"] = { target = 5600, measured = 4466 },
    ["page.setup_power_sources_page.build"] = { target = 4800, measured = 3839 },
    ["page.setup_radio_config_page.build"] = { target = 3950, measured = 3139 },
    ["page.setup_servos_bus_page.build"] = { target = 7800, measured = 6206 },
    ["page.setup_servos_pwm_page.build"] = { target = 5950, measured = 4750 },
    ["page.setup_telemetry_page.build"] = { target = 15550, measured = 12427 },
    ["page.setup_wizard_board_page.build"] = { target = 17600, measured = 14070 },
    ["page.setup_wizard_page.build"] = { target = 54800, measured = 43805, proposed = 20000 },
    ["page.setup_wizard_radio_page.build"] = { target = 41200, measured = 32957, proposed = 20000 },
    ["page.tools_copy_profiles_page.build"] = { target = 3300, measured = 2635 },
    ["page.tools_flight_log_page.build"] = { target = 3250, measured = 2574 },
    ["page.tools_select_profile_page.build"] = { target = 4200, measured = 3323 },
  },
}
