# Offline instruction accounting

Runs dashboard, service and tool sources under `debug.sethook(counter, "", 1)` -- the same
count-hook mechanism the firmware bills widget calls with -- against small deterministic
EdgeTX stubs, and gates the numbers against the checked-in table in `budgets.lua`.

Why off-radio: a caught "CPU limit" re-raises outside any `pcall` for the rest of the
call, `getUsage()` is a snapshot of the *last* pass stored in a `uint8_t` (a pass beyond
255 % wraps and reads low), and the error banner's text is whatever sat on the Lua stack.
Runtime measurement can inform but cannot gate; the structure of the work is proven here,
and the widgets' usage trace line verifies it in the field.

## Run

```
lua5.3 bin/accounting/measure.lua              # report only
lua5.3 bin/accounting/measure.lua --check      # gate: non-zero exit on any breach
lua5.3 bin/accounting/measure.lua --self-test  # proves the check can go red
lua5.3 bin/accounting/measure.lua --emit       # print the budgets.lua table of this run
lua5.3 bin/accounting/measure.lua --phases     # the arm and disarm edges at every phase
lua5.3 bin/accounting/measure.lua --pages      # every tool page opened at every phase
```

`--check` is what CI runs, after `--self-test`. The self-test poisons one target and
removes another row's budget, and fails unless *both* turn the check red -- a gate that
has never been seen red is a loop that never ran with a badge on it. It does the same to
the first two tool-page rows, which come after every other row and would otherwise never be
the ones it picks, and it drives each of the page driver's controls red once (see below).

EdgeTX 2.12 embeds Lua 5.3, so a distribution `lua5.3` counts the same mechanism. It is
still a proxy for the embedded VM's exact per-line numbers -- which is one reason every
budget row keeps a wide margin, and why a measurement within 10 % of its target is
reported as a margin to widen rather than a pass to celebrate.

## What is measured

- **Pass classes**, on the reference theme, after the widget has settled: the STATE pass
  with the background allowance fully drawn, the build chunk, the swap, the splash and
  the cold-start worst pass. The class of a pass is read from the job slot *before* the
  call, which is where the dispatcher decides it.
- **Every shipped theme**: its worst pass plus one full sweep of the tree it leaves
  standing. This is the row the safety argument rests on. The settle before it counts its
  tail from the swap of a chunked theme, and from the one prepare pass a free-form theme
  builds its whole tree in, since that theme never swaps. A build that raises on every
  pass fails the run with the error the widget caught, rather than as a dashboard that
  never settled.
- **Every shipped box type**: one render into the node table, and one sweep of the
  reactive references that render collected. Enumerated from the themes' own box
  declarations and from the object modules on disk -- a type with no row fails the check,
  which is what makes a new box type ship its cost with the PR that adds it.
- **Per unit**: the whole background wakeup, the custom-telemetry drain with a full frame
  backlog, one MSP pump on an idle queue (the turn that finds nothing to do, not a pump with
  work on it), and the API-layer parse of the largest scripted reply. The drain rows are
  measured once `telemetry_bg` is warm: the warm-up runs until a call has consumed its frame
  without calling a loader, so neither row carries one of the staggered loads of `tasks.lua`
  or `smart.lua`, and then hands every frame of the cycle through once, so the measured call
  publishes no sensor for the first time. The function script's row is primed the same way.
- **The telemetry frames** every scenario is fed are the flight controller's: each sensor of
  the decoder table that a firmware sends, at the width its encoder writes (`WIRE_WIDTH` in `measure.lua`,
  from the encoder column of the sensor table in the firmware's `telemetry/crsf.c`, not from
  the decoders), packed the way the firmware packs a frame -- entries are added while more
  than 32 of the 64 bytes are left -- so every sensor is sent once per cycle of frames, and
  a backlog is consecutive frames of that cycle. Before anything is measured, every frame is
  walked with the decoders, and the run fails unless each entry is consumed at its encoder's
  width and each frame to its last byte. A decoder added for a sensor with no width there
  fails the run too, until its width is added.
- **Every tool page the dashboard can open**: the build of the page, hosted. See below.

## The tool's pages

The dashboard opens the tool inside its own widget: `widgets/dashboard/tool_host.lua` loads
`ui/home.lua` into the widget's Lua state and drives it from `widget.refresh`, so every pass of
an open tool is a widget call and is stopped at the same 20 000 as the rows above. The tool
script is not -- a call there is yielded once it has held the interpreter for a task period --
so the rows are measured hosted, and the tool script has none.

A row `page.<menuId>.build` is the instructions inside the page module's `build`, the call that
lays the page's whole screen out, taken as the dearest build of one open: most pages build more
than once while they open. It is the part of opening a page that cannot be spread over
passes -- it runs inside one call, and every attempt at it is the same deterministic code -- so a
page whose build alone needs more than a call is allowed does not finish building hosted. It is
also the figure the cadence grid does not move, which is why it is the one that is gated.

How a page is opened:

- **The inventory** is the tool's own page registry, `app/pages/init.lua`, read when the run
  starts. Every id in it gets a row or a note naming why it has none: no menu leads to it, its
  tile is disabled in this world, or it has no `build` and the tool draws it as a menu.
- **A page that is added** is measured as soon as a menu leads to it and its tile is enabled in
  the run's world, and from then on it needs a row, as a new box type does. `--check` fails with
  `page.<menuId>.build has no row in budgets.lua -- a new tool page: --emit prints its row`, and
  the fix is the line `--emit` prints for it, pasted into the page rows of `budgets.lua` in the
  same pull request. A page whose tile is disabled here -- one that needs a newer MSP API than the
  stub flight controller reports, for example -- is named in a note and needs no row until it is
  enabled; the pull request that enables it adds the row. A page that is removed leaves its row
  behind, and `--check` fails on that too, until the row is deleted.
- **The world** is the reference dashboard, settled as the other scenarios settle it, with the
  tool's firmware surface added (`Stubs.installTool`: the RSSI, the radio's general settings,
  the date, the free heap, the card's directories, the model's inputs, outputs and modules, the
  lvgl table's layout figures, the telemetry unit numbers). The dashboard reads several of the
  same names, and the other rows were written on a world without them, so only the page worlds
  get them; `install()` takes them away again.
- **The presses** are the tool's own: the tool is opened through the host the way a press on
  the dashboard opens it, and every step after that parks the target in the tool's
  `pendingMenuOpen`, which is all a tile press does. The path is read off the manifest. The
  switches for the developer pages and the preview features are on, because the pages behind
  them ship.
- **The link** answers between passes and holds one pass's worth of telemetry from the host's
  request on, as in the in-flight tuning scenario. An open is over when the page has stayed
  quiet for ten passes: no build, nothing outstanding on the link, nothing to redraw.
- **One world per page**, rebuilt as for every scenario here, and the pages opened in the
  registry's sorted order. That is not quite the same as no inheritance: run in reverse order,
  82 of the 83 rows read the same and one moves by 50 (`tools_select_profile`, which then follows
  the service widget's world instead of another page's). The order is fixed, so two runs agree;
  a page added ahead of others in that order can move a row behind it by about as much.
- **The build** is counted on the hook's own counter: the page module is wrapped where the
  registry loads it, and the wrapper hooks the build alone, so the passes around it can run
  without the hook. The wrapper's call into the build and back is billed with it, a handful of
  instructions; every other load pays one table comparison.

The driver's controls, each of which would otherwise end in a plausible number for the wrong
screen: the dashboard must have connected the flight controller before the tool is opened (a
world that never connected prices every page on the screen of a radio without one); after the
open the tool must be on the page, its build must have run and not raised, and nothing the
flight controller sent may still be held off the link (a page whose replies never reached it
builds the screen it shows while it waits). The self-test breaks the run each of those ways on
a page that reads from the flight controller, and fails unless the run stops.

What the rows are measured on, and what that means:

- **`src/`, like every other row.** On `src/` a page resolves its strings at run time through
  `pageText()`; the packaged tool has them resolved by the packager. A page row is therefore a
  regression figure for the source as written, not what the page costs on a radio: it reads
  higher than the packaged suite pays, by 0 to 225 % per page, median 15 %, against the English
  package built from the same tree. *Adjustments* is 15 379 on `src/` and 6 971 packaged, and
  *Ports* 27 401 against 20 507, so 27 401 is not what *Ports* costs on a radio. What a row is
  for is to move when the source does. The three pages over 20 000 are over it on both.
- **The stubs are billed**, as everywhere here: a page's build pays for the Lua of every stub it
  reaches -- `loadScript`, the card's `io.open`, `lcd.sizeText`. On the package that is a median
  of about 12 % of a build.
- **No sweep.** The lvgl stub collects every function field of a tree as a reactive reference.
  That holds for a dashboard theme; a page's tree also carries its press and change handlers as
  function fields, and replaying those would act on the page.
- **Targets** are what `--emit` suggests for a new row, held at 20 000 for a page below it. A page
  whose build alone is above 20 000 carries its `--emit` figure as the target and 20 000 in
  `proposed`, so the check is green and every run says that the page sits above the limit.

`--pages` opens every page twenty times with the press moved by one 100 ms pass each, and prints
per page the build's range, the range of the open's worst pass with the phase of its maximum, and
the largest total of an open. A report like `--phases`: it adds no row and checks nothing. It
runs for minutes.

What is gated, and what is not:

- **The build is gated**, because it is the one figure that is a property of the page alone: it
  runs inside one call, so it cannot be spread over passes, and over the twenty phases it is
  identical on 82 of the 83 pages.
- **The worst pass of an open is reported by `--pages` and not gated.** A pass that builds a
  page hosted also carries the host's own step, the MSP tick and the events runner, and which of
  those share the pass depends on the phase: across the twenty phases the worst pass of one open
  moves by up to 1 412, median 1 399. A row taken at one phase would move with any change that
  shifts the timeline, as `pass.state.armed` does (see below), and the phase-swept figure takes
  minutes rather than seconds. And 19 of the 83 pages have a phase whose worst pass is over
  20 000 on `src/` (14 of them at every phase; 12 pages on the package), so a gate on it would
  start with 19 rows carrying `proposed = 20000`.
- **So a page can be green here while the pass that builds it is stopped by the firmware and
  retried by the host.** That is a known limit of these rows, not something they rule out.
  Gating it would take a per-page row for the worst pass over all twenty phases, the phase sweep
  in CI, a target for each of those 19 pages, and a decision on how much of the 20 000 a page's
  build may take when the rest of the pass has to fit beside it.

## The phase sweep

`pass.state.armed` is the worst STATE pass of one run in which the model is armed at a fixed
pass. The widget's work is a set of periodic items -- the 0.5 s telemetry read, the flight
record's 0.5 s sample, SmartFuel's 1 s wake, the audio pass -- and an arm or disarm edge
lands on whichever of them fall on the same pass. So that row prices one phase of the
cadence grid, and a change that moves the timeline by one pass can move it by thousands
without the edge code changing (#440).

`--phases` runs the armed scenario again with the arm moved by 0-9 passes, and separately
the disarm, and prints for every phase the worst pass of the first 16 armed passes, of
armed passes 21-240 and of the first 16 post-flight passes, with the pass it was, whether
it ran the telemetry read, and the window's sum; the arm and disarm tables add the whole
run's sum and how many passes ran the announcements. It is a report: it adds no row,
checks nothing, and leaves `--check` byte-identical. The run takes under a minute.

## Determinism

- `getTime` advances a fixed step once per measured pass, driven by `measure.lua` through
  `Stubs.tick()`; nothing reads a wall clock. Per PASS rather than per call, because a step
  per call makes a second worth however many times the code under test happens to ask the
  time -- so anything the suite does on a cadence, a read every 0.5 s or a cooldown or a
  throttle, fires in almost every pass or in almost none, and cannot be priced at all.
- Sensor, model and telemetry answers come from scripted tables in the stubs.
- `collectgarbage("stop")` brackets every measured section: the events runtime triggers
  collections, and GC steps would land in the count nondeterministically.
- The sweep is replayed, not simulated: `lvgl.build` collects every function field as a
  reactive ref and the runner calls them in a plain loop. The loop's own overhead is
  measured once against an empty closure and printed as the control; a run whose control
  drifts from the value in `budgets.lua` fails itself.
- The world is rebuilt between scenarios, and the rebuild reaches the module singletons the
  suite parks in globals (`__rfsuite*`) as well as the stubs' own state, so no measurement
  inherits another's caches, another's connect state or another's link. Without that, every
  scenario after the first ran on the previous one's runtimes, and its connect chain stopped
  on the `telemetry` task with the telemetry drain never started. The API reply index is
  built from a sorted file list, so two hosts resolve a command claimed by two modules the
  same way.
- The run is given a card of its own. The suite addresses its settings by absolute card
  path (`/SCRIPTS/TOOLS/rfsuite.user/...`), and under the stubs that path used to mean the
  host's own `/SCRIPTS` -- so a run read whatever settings file the machine had and wrote
  its own into the machine's card, and a local `--check` could disagree with the CI job
  over a file outside the repository. Every card path is remapped onto a directory in the
  system temp directory, emptied when the run starts and again when the last measurement
  is done; nothing on the host can reach the measurement and nothing the measurement writes
  survives it. A path outside the card is left alone, so `measure.lua`'s own repo-relative
  file access is untouched.
- The sound pack is answered as absent. `lib/audio.lua` finds out whether an announcement
  file is there by opening it under `/SOUNDS/`, the one other absolute path a measured source
  opens, and that open used to reach the host's own `/SOUNDS` -- so a machine with a sound
  pack there measured the branch that finds the file, every other machine the branch that
  does not, and the two reports differed in rows no change had touched. Every `/SOUNDS/`
  open is now answered the way the host answers a file that is not there, so every host
  measures a radio without a pack: the case a host with no `/SOUNDS`, the CI runner among
  them, measured already.
- **The remap costs what a remap costs, and it is in the figures.** `io.open` is a Lua
  function now, so every open the measured sources make goes through a wrapper that is
  counted under the hook and billed to the suite. Four rows carry it -- `pass.startup.worst`
  +612, `pass.tuning.prime` and `unit.telemetry.drain` and `unit.telemetry.handoff` +34 each
  on Lua 5.3.6, all four inside their targets. Removing the `io.open` wrapper alone puts all
  four back on master's figures and the report becomes identical to master's line for line,
  which is how the cost was attributed to the wrapper rather than to a settings write: no
  card path is written at all in a traced `--check` run. The `/SOUNDS/` test is one more
  comparison on every open outside the card, and the same four rows carry it:
  `pass.startup.worst` +41, the other three +13 each. Read the rows as
  *suite + instrument*, and the way to take the instrument out is the third report in the
  pull request.
- **One card per run, not one per machine.** The card is claimed with `mkdir` as the test,
  so two runs on one machine cannot share it -- running master and a branch side by side is
  the case that would otherwise have one run's startup empty land in the middle of the
  other's measurement. The name is given back on every way out, including the green path that
  ends the file rather than exiting.
  **Two ways a card is left behind, and both are litter rather than a wrong measurement:**
  a run killed outright, and -- the more common one -- a run that stops on a Lua error in the
  measured tree, which bypasses the `os.exit` wrapper. Either leaves an empty directory with
  a unique name in the temp folder, and a later run takes a card of its own rather than
  reading it. It is not swept, deliberately: collecting stale cards means deciding that a
  directory is not a *running* one, which needs a lock or a clock heuristic, and both are
  worth more than an empty directory in TEMP. A `pcall` around the body would be worse still,
  in an instrument whose job is to go red.
- The card has a self-test, run from `measure.lua --self-test` so both CI jobs exercise it.
  Every defect the card can have -- a nested write that does not make its deepest directory,
  the two spellings of a card path answering at two different directories, a write landing
  outside the card, a card that is not emptied, a directory cache that still claims a
  directory the empty took away -- leaves all 51 rows exactly as they were.
  The report cannot see any of it, so something has to. Two of the cases only bite on Linux
  (`fopen` on a directory succeeds there and `os.remove` on an empty one does too), and on a
  Windows host the self-test passes with those two defects put back: the platform is the
  only thing that makes them visible, which is why the job that runs this is on the CI.

Three consecutive runs produce byte-identical reports.

## The stubs

`stubs/edgetx.lua` is the firmware surface the measured sources touch, and `stubs/fc.lua`
is a scripted flight controller on the far side of the CRSF link. The peer is scripted at
the *wire*: the measured tree keeps its real transport, its real chunked framing and its
real poll loop. Its replies are the repository's own -- every module under
`tasks/msp/api/` that carries a `simulatorResponse` is indexed by its command, so the
payload sizes a pass parses are the sizes the firmware sends, and a reply that drifts
drifts with the API definition that owns it. A command with no scripted payload is
answered empty and counted; the count is printed in the report header.

Module loading goes through the suite's own `lib/require.lua` rather than a hand-written
cache here, because that one returns nil for a module that is not there and several
objects probe for optional submodules exactly that way. Both of its failure paths report
through `print()`, and the stub records those lines: a missing stub surface shows up as a
module that would not execute, instead of as a pass that came out cheap.

Stubs answer; they never compute. Anything clever in a stub is a measurement error
waiting to be found.

## Reading the report

`budgets.lua` carries `target` (enforced), `measured` (what the row cost when it was
written) and, where the two differ, `proposed` -- the figure that sat on the row before
anything had been measured. The report prints "re-apportioned from N" on every such row,
so a budget that was moved can never pass for the one it replaced.

Sources that print unconditionally show up in the run's output. Those lines are the
measured tree's own; they are not suppressed, because a pass pays for them on the radio
too.
