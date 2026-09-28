# Offline instruction accounting

Runs dashboard and service sources under `debug.sethook(counter, "", 1)` -- the same
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
```

`--check` is what CI runs, after `--self-test`. The self-test poisons one target and
removes another row's budget, and fails unless *both* turn the check red -- a gate that
has never been seen red is a loop that never ran with a badge on it.

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
  standing. This is the row the safety argument rests on.
- **Every shipped box type**: one render into the node table, and one sweep of the
  reactive references that render collected. Enumerated from the themes' own box
  declarations and from the object modules on disk -- a type with no row fails the check,
  which is what makes a new box type ship its cost with the PR that adds it.
- **Per unit**: the whole background wakeup, the custom-telemetry drain with a full frame
  backlog, one MSP pump, and the API-layer parse of the largest scripted reply.

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
- **The remap costs what a remap costs, and it is in the figures.** `io.open` is a Lua
  function now, so every open the measured sources make goes through a wrapper that is
  counted under the hook and billed to the suite. Four rows carry it -- `pass.startup.worst`
  +612, `pass.tuning.prime` and `unit.telemetry.drain` and `unit.telemetry.handoff` +34 each
  on Lua 5.3.6, all four inside their targets. Removing the `io.open` wrapper alone puts all
  four back on master's figures and the report becomes identical to master's line for line,
  which is how the cost was attributed to the wrapper rather than to a settings write: no
  card path is written at all in a traced `--check` run. Read the rows as
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
