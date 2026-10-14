---
title: Adding a dashboard theme
sidebar_label: Dashboard themes
sidebar_position: 60
---

# Adding a dashboard theme

A dashboard theme is a folder with a manifest and one module per flight phase. The manifest
says what the theme is called and which module belongs to which phase; each module declares a
grid and a list of boxes, and the engine turns that into the LVGL node list the widget hands
to the radio. A declarative theme draws nothing itself; a free-form one (below) builds its own
node list.

This page is the contract: the folder, the manifest keys, **what puts the widget into each
flight phase**, the shape a phase module returns, the box vocabulary, the rule for a value
given as a function, the per-theme settings page, **a theme that takes fullscreen**, and what a
theme can read of the battery prompt. What a pilot needs in order to copy and
edit a theme is [user themes](../dashboard/user-themes.md); this page is the source-level
version of the same thing, plus what a theme shipped in this repository additionally owes.

## Where a theme lives

| Kind | In this repository | On the card |
| --- | --- | --- |
| Shipped | `src/rfsuite/widgets/dashboard/themes/<folder>/` | `/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/<folder>/` |
| User | not in this repository | `/SCRIPTS/TOOLS/rfsuite.user/dashboard/<folder>/` |

Both are scanned the same way, shipped first, and a theme is addressed everywhere by the path
`<source>/<folder>` — `system/default`, `user/mytheme`. That string is what a preference
stores, what the theme selector resolves and what the per-theme settings are keyed on.

The scan (`app/pages/settings/dashboard/lib.lua`, `scanThemes`) takes every entry of the
folder that is not `.` or `..` and whose name does not end in a dotted extension, loads
`<folder>/init.lua`, and accepts the folder as a theme when that returns a table with a
string `name`. A folder with no readable `init.lua` is skipped silently — it is named, with the
reason, in the one line the scan writes to the log at *DEBUG*, and nowhere else.

`app/pages/settings/dashboard/theme_index.lua` is a checked-in list of the shipped themes and
is read **only when the scan found nothing at all**, which is the case on a radio whose
firmware offers neither `dir()` nor `system.listFiles`. A new shipped theme therefore needs a
row there as well, or it is invisible on exactly those radios.

## The manifest: `init.lua`

`init.lua` returns a flat table. It is loaded by the theme selector to list the theme, and by
the widget to find the module for the phase it is in.

| Key | Type | What it does |
| --- | --- | --- |
| `name` | string | The name in the theme selector. Required: a table without it is not a theme. |
| `preflight` | string | File name of the preflight module, relative to the theme folder. |
| `armed` | string | Optional. File name of the module for the armed-but-not-flying phase. Omit it and that phase draws the preflight module. |
| `inflight` | string | File name of the inflight module. |
| `postflight` | string | File name of the postflight module. |
| `offline` | string | Optional. File name of the module for the post-flight phase once the flight controller has stopped answering. Omit it and that phase draws the postflight module. |
| `configure` | string | File name of the per-theme settings module. Omit it and the theme has no settings page. |
| `pages` | table | Optional. Splits the theme's settings into pages, one tile each. See [Splitting the settings into pages](#splitting-the-settings-into-pages). |
| `standalone` | boolean | `true` keeps the theme off the *Dashboard* → *Settings* page even if it declares `configure`. |
| `fullscreen` | string | Optional. `"theme"` makes fullscreen show this theme at the fullscreen size instead of the quick menu. See [A theme that takes fullscreen](#a-theme-that-takes-fullscreen). Omit it and fullscreen is what it has always been. |
| `fullscreenExit` | string | Optional, read only by `bin/themes/validate.lua`. `"longRtn"` declares that the theme binds no control that leaves fullscreen and relies on a long press on RTN. |
| `views` | table | Optional, for a free-form theme. Views of the theme's own, and looks for the widget's: see [Views of a theme's own](#views-of-a-themes-own). |

Beside it, `icon.png` is the tile the theme selector draws. The path is built from the folder
name and is not checked before use, so a theme without one shows an empty tile rather than an
error.

```lua
local init = {
  name = "Default",
  preflight = "preflight.lua",
  inflight = "inflight.lua",
  postflight = "postflight.lua",
  configure = "configure.lua",
  standalone = false,
}

return init
```

## What puts the widget into each phase

The phase is not something a theme chooses or a pilot sets. It is computed once per background
pass from the flight controller's own telemetry, in `computeFlightMode`
(`src/rfsuite/widgets/dashboard/runtime.lua`), out of four readings: the arm flag, the governor
state, the throttle percentage, and — with the governor off — headspeed and current.

The arm flag is the spine. It comes from the `armflags` sensor, and the widget keeps the
previous pass's value beside it, so an arm and a disarm are edges rather than states.

A reading that says *disarmed* is not taken while the MSP runtime still reads the model as armed.
The runtime reads the same sensor at the top of the same pass, ahead of the custom-telemetry
drain, so a disagreement means the sensor changed between the two reads of one pass -- and a
real disarm is taken by the first read after the runtime has seen it too. A reading that says
*armed* is always taken. Both `armed` and the raw `armFlags` a theme can read follow this rule.

| Phase | Reached when |
| --- | --- |
| `preflight` | Not armed and no inflight phase has been reached in this armed session. This is also the phase the widget starts in, and the phase a model returns to after an arm that never spooled up. |
| `armed` | Armed, and none of the inflight conditions below has been met yet. The arm edge itself enters this phase and clears the inflight latch. |
| `inflight` | Armed, and — on a later pass than the arm edge — the governor is active, or the throttle is above its threshold, or the direct-drive condition is met. |
| `postflight` | Not armed, the inflight phase had been reached in the armed session that just ended, and the flight controller is still answering. |
| `offline` | As `postflight`, but the flight controller has stopped answering — the battery is unplugged, the model is out of range, or the radio's link to it is gone. The widget cannot tell those apart. |

**Two of the five are refinements, and a theme does not have to draw them.** `armed` refines the
ground screen and `offline` refines the post-flight one; a theme that declares no module for
them draws the module it declares for the phase they refine. A theme written against the three
original phases therefore keeps behaving exactly as it did, and the widget does not rebuild the
scene for a phase change that resolves to the module already on screen.

**Arming is not flight.** The pass on which the arm flag goes from false to true enters `armed`
and clears the inflight latch, so the model is up, the blades may be turning and the phase is
still not `inflight`. A model armed on the bench that never spools up therefore stays in `armed`
for the whole arming and returns to `preflight` on disarm — it produces no postflight screen,
because there was no flight.

The three inflight conditions, any one of which is enough:

| Condition | Reading | Trigger |
| --- | --- | --- |
| Governor active | `governor` state | between `4` and `8` inclusive |
| Throttle | `throttle_percent` | above `35` |
| Direct drive | `governor` state `0` or `100` (off/disabled) **and** any of headspeed `rpm` ≥ `500`, `current` ≥ `8` A, `throttle_percent` ≥ `8` | any one of the three |

Once any of them has been true, a latch is set and the phase stays `inflight` for the rest of
the armed session — a governor dropping out or the throttle coming back through the threshold
in autorotation does not send the screen back to `armed`. The latch is cleared on the next
arm edge, and on the flight controller reconnect edge; the disarm hands it to the postflight
phase, which is what makes a landing produce a summary screen and a bench arm not produce one.

Two consequences worth knowing before writing a theme:

- **The post-flight screen outlives the link, and that is what `offline` names.** While the
  inflight latch is set and the flight controller is no longer answering, the widget stops
  reading telemetry rather than letting the values decay, so the summary a pilot walks back to
  the bench with keeps standing. A postflight or offline module can rely on the last flight's
  numbers still being there; it cannot rely on anything live. The split exists so that a theme
  can say which of the two it is showing — in `postflight` the model is still on the link and
  can be armed again, in `offline` nothing on the screen can change any more.
- **A model that never publishes `armflags` never leaves preflight.** The arm reading is what
  every phase decision is built on, and the widget deliberately distinguishes *read as disarmed*
  from *never read at all*.

### What a phase change costs

A phase change that changes the module is a full theme reload, not a redraw. The widget resolves
the theme path for the new phase, loads that phase's module, rebuilds the box list and tears the
standing LVGL tree down; the scene is then built in chunks of eight boxes, one chunk per pass,
and swapped in at the end. So the modules of one theme are independent screens that share
nothing at runtime except what they both read off the state table.

A phase change that resolves to the *same* module does not reload anything, and does not rebuild
the scene either. That is what keeps the two optional phases free for a theme that does not
declare them: entering `armed` on a theme without an `armed` module leaves the preflight scene
standing rather than rebuilding it into itself.

Two state fields carry this, and they are not the same question:

| Field | What it says |
| --- | --- |
| `state.flightMode` | The phase the widget is in — one of the five above. This is what a theme reads to know what the model is doing. |
| `state.themePhase` | The phase whose module is on screen, after the fallback. The engine's render key is built from this one, which is why a fallback phase costs no rebuild. |

So a declarative theme whose box *values* depend on the phase — one that draws the same boxes in
`preflight` and `armed` but wants a different text in each — has to say so, by giving its module
a `renderKey(zone, state)` function that includes `state.flightMode`. Without that, the scene it
built for the previous phase keeps standing, which is exactly the saving described above.

The pass that loads a new module writes both fields before the render key is computed, so the
scene the dashboard queues for a phase change is keyed on the new module, and a theme's own
`renderKey(zone, state)` sees the new phase the first time it is called after the change.

The path is resolved per phase as well (`resolveThemePathForState`), which is what the
*Per-Phase Themes* switch under *System* → *Settings* → *Dashboard* → *Design* acts on. There
are three theme slots, not five: `armed` resolves through the preflight slot and `offline`
through the postflight one, because each is a refinement of that screen rather than a screen
beside it. With the switch off, one theme covers every phase and the phase keys keep their
values for whoever turns it back on. With it on, the first of these that names a theme wins: the
model's phase override, then the model's own theme — both only while per-model settings are allowed
on the radio and on for that model (`DashboardLib.modelOverridesActive`) — then the global phase override, then the global theme, then `system/default`. A
model theme is a context of its own, so an unset phase override falls back to the model's theme
rather than jumping to the global one.

## What a phase module returns

A phase module returns a table, and there are two kinds of theme. The widget decides which by
what the table carries.

**Declarative** — `layout` and `boxes`. This is what all shipped themes are. The engine
(`widgets/dashboard/engine.lua`) computes the grid, renders each box into plain Lua tables and
hands the result to LVGL, and because it renders box by box it can spread a build over several
passes.

**Free-form** — a `build(zone, state)` function returning an LVGL node list. The widget calls
it and builds the result in one step. For a theme that takes fullscreen, the fullscreen build
passes a third argument, `ctx`; the zone build never does. Nothing chunks it, so the whole scene is constructed
inside a single instruction budget; a free-form theme of any size is the surest way to a CPU
limit fault on a slower radio.

A module that carries neither is not a theme: the loader falls through to
`system/default/<phase>.lua`, and to `system/default/preflight.lua` if even that is missing.
The same fallback catches a module that fails to compile. A theme whose `init.lua` names no
module for the phase is looked for under `widget.lua` in the theme folder first — which is how
a single-screen theme covers every phase with one file. The two optional phases resolve before
any of this: `armed` looks for the theme's `armed` module and then for its `preflight` one,
`offline` for its `offline` module and then for its `postflight` one, so what reaches the
loader is always one of the three phases every theme declares.

A module that loads but raises while the widget builds its scene — a free-form `build` that
throws is the plain case — has nothing to fall back to. Two more cases count as a raise: a
free-form `build` that returns anything but a node list (a missing `return` is enough), and a
build the radio stops at its instruction limit. The widget tries that build three
times in a row, then stops trying and shows *Dashboard error* in its place; the error is in
the log, and the first of the three goes to the card as a fault when *Log to card* is on (a
stop at the instruction limit goes to the card every time, as the widget's own `widget.refresh`
fault, and the widget waits 1.2 s before the next try). A
build that is stopped at the limit only sometimes is drawn again as soon as one try completes,
which starts the count over; one that is stopped three times in a row stays *Dashboard error*. A
theme reload starts over: choosing a theme, any change to the preferences, the flight
controller reconnecting, or a flight phase that brings up another of the theme's modules. Until
then the error stays on screen, even if the cause has gone away by itself: a build that raises
for as little as three tries in a row in flight can leave *Dashboard error* up for the rest of
the flight. If *Dashboard error* cannot be drawn either, the widget falls back to the same title
as a single label, drawn without the splash builder, and stops only if that raises three times
too. The theme at full screen ([`fullscreen = "theme"`](#a-theme-that-takes-fullscreen)), the fullscreen
menu and the in-flight tuning surface are given up the same way, each on its own count, and at
full screen *Dashboard error* carries the tool control, as the connect splash does there. The
views a theme registers are not counted for a raise: one whose `build` raises is given up on its first
raise, as [Views of a theme's own](#views-of-a-themes-own) describes. A view whose `build` the
radio stops at its instruction limit is counted like the other surfaces, on a count of its own.

### `layout`

| Key | Default | What it does |
| --- | --- | --- |
| `cols` | `1` | Grid columns. |
| `rows` | `1` | Grid rows. |
| `padding` | `0` | Pixels between tracks. |
| `bgcolor` | black | The full-zone rectangle drawn under every box. `false` draws none, and the radio's own theme background shows through the gaps. |

The grid divides the zone evenly and gives the remainder pixels to the right and bottom edges,
so early tracks keep their size when the zone changes. `padding` is spacing only — nothing
draws in it, which is why the background rectangle exists.

`header_layout` and `header_boxes` declare a second grid across the top sixteen per cent of the
zone, at least 24 px, drawn after the main grid and therefore above it. No shipped theme uses
them.

### `boxes`

`boxes` is either a list or a function `(box, state)` returning one. A function is called once
per build, which is where a theme resolves anything that depends on the zone size or on its own
configuration.

Every box takes its place from four fields — `col`, `row`, `colspan`, `rowspan`, all
1-based and clamped to the grid — and its content from `type` and `subtype`:

| `type` | `subtype` | Shows |
| --- | --- | --- |
| `text` | `telemetry` (default) | A telemetry value, formatted. |
| `text` | `governor` | The governor state as a label — or, in the two modes that have no state, the mode. See below. |
| `text` | `blackbox` | Blackbox state, the same wording in every theme: `objects/text.lua` hands every text box `themes/default/common.lua`, whose `blackboxLabel(state)` gives REC while armed, the used and total size while the flight controller reports a dataflash, LOGGED after an armed flight, and READY otherwise -- also on a board without a dataflash. |
| `text` | `stats` | One flight statistic, chosen with `stattype`. |
| `text` | `text` | Nothing — a decorative container. |
| `gauge` | `arc`, `bar` | The value between `min` and `max`; `arc` is the default. |
| `time` | `flight`, `count`, `total` | The flight clock, the flight count, the lifetime total. |
| `image` | `image`, `model` | A file from the card, or the model picture. |
| `dial` | — | Container only: no subrenderer ships for this type. |

An unknown `type` draws a container with `--` in it, which is the shape a typo takes on the
radio.

### `text` / `stats`, and which voltage values outlive the pack

A post-flight page is read after the landing, often with the pack already unplugged. For the
recorded extremes and for the pack voltage, what a `stats` box shows then depends on its
`stattype`:

| `stattype` | `source` | Shows | After the pack comes off |
| --- | --- | --- | --- |
| `max`, `min` | a recorded source, see [Flight statistics](../reference/flight-statistics.md) | The flight's extreme. | kept |
| `last` | `voltage` | The landing voltage, taken at the disarm. | kept until the next arming |
| `lastcell` | `voltage` | The landing voltage per cell, divided by the cell count taken with it at the disarm. | kept until the next arming |
| `cell` | `voltage` | The live voltage per cell, divided by the live cell count, or by an estimate from the theme's voltage range while no count is known. | follows the pack |

A `telemetry` box is live as well. A flight controller that stays powered without its main pack
reports the pack at zero volts, so a live voltage box reads `--.-V` once the pack is unplugged and
shows the next pack as soon as one is plugged in. Use `last` or `lastcell` for a voltage on a
post-flight page. `lastcell` does not use the live count for the same reason: the next pack can
have a different number of cells.

The `stats` source `min_voltage_cell` (no `stattype`) shows the flight's minimum pack voltage per
cell. After a landing it divides by the same count `lastcell` uses, the one taken at the disarm;
during a flight, and where the pack read 0 V at the disarm, it divides by the live count.

### `text` / `governor`, and the two modes that have no state

The box reads the governor STATE sensor and shows its name. The flight controller runs a
governor state machine in modes DIRECT, ELECTRIC and NITRO only; in OFF and LIMIT it never
enters one, and the state sensor stays at its initial value — throttle off — from power-up to
the end of the flight. Read literally, the box would report a hovering helicopter as having its
throttle off, and there would be nothing on screen to say why.

So in those two modes the box shows the mode instead, `Gov. Off` and `Gov. Limit`, under the
names the mode is set by. It reads `state.governorMode`, which the widget carries over from the
`gov_mode` the connect chain reads once over MSP; until that has answered the field is `nil` and
the box behaves as it always did. The earlier branches are unchanged and still come first: an
arming-disabled reason, and the disarmed label while the model is not armed.

Two things follow for a theme. A box with a `thresholds` list matching governor state names will
not match in these modes, in any language: the text is no longer a state name, and the
untranslated key tried after the text is the mode's (`MODE_OFF`, `MODE_LIMIT`), not the state
sensor's `OFF`. Such a box falls back to its plain text colour. A theme that wants to colour the
two modes adds a threshold for them: a shipped theme on `@i18n(widgets.governor.MODE_OFF)@` or
`@i18n(widgets.governor.MODE_LIMIT)@`, which the packager turns into the label as shown, and a
user theme on the names `MODE_OFF` and `MODE_LIMIT`, the way it names the states. And the mode is
configuration, not a reading: it changes only when the flight controller is reconfigured, so it
costs one comparison per value change and nothing per frame.

The value a box reads is `source`, and the names are resolved in
`widgets/dashboard/objects/common.lua`, `mapTelemetrySource`: a fixed set that comes straight
off the widget state — `voltage`, `bec_voltage`, `current`, `watts`, `rpm`, `fuel`,
`smartfuel`, `smartconsumption`, `altitude`, `governor`, `esc_temp`, `mcu_temp`,
`throttle_percent`, `link`, `pid_profile`, `rate_profile`, `battery_profile`, `model_name`,
`link_packet_rate`, `link_floor`, `link_diversity`, `esc_load`,
`esc_status`, `esc_status_level`, `esc_status_live`, `esc_status_live_level` — and, for anything
else, the sensor of that name from `lib/sensors.lua`.

### `link_packet_rate`, `link_floor`, `link_diversity`

Not sensors. The three are read out of the CRSF link-statistics frame the *transmitter module*
sends the radio — the frame the radio creates `1RSS`, `2RSS`, `RSNR`, `ANT`, `RFMD`, `TPWR`,
`TRSS`, `TQly` and `TSNR` from — and they say what the link is doing rather than what the
helicopter is doing.

**`link_packet_rate` rather than `link_rate`, and the name is deliberate.** *Link rate* is
already taken in this repository for something else: `session.crsfTelemetryConfig.linkRate` is
the flight controller's own telemetry link rate in hertz, read over MSP `telemetry_config` and
set from *Tools* → *Diagnostics* → *ELRS Link*. The air rate is what that same page calls
`packetRate`, reading it off the module's parameter list rather than off the link-statistics
frame, so this source takes the page's word for the same quantity.

| source | type | what it is | nil when |
| --- | --- | --- | --- |
| `link_packet_rate` | string | the air rate the link is running, spelled as ExpressLRS spells it: `50Hz`, `150Hz`, `100Hz Full`, `D250`, `F1000`, `K1000` | the link is down; no `RFMD` reading; the transmitter module has not yet said which ExpressLRS it runs, or is not ExpressLRS 3.x or 4.x; a byte that release leaves unused |
| `link_floor` | number | the receiver sensitivity that rate is specified down to, in dBm and negative (`-108`) | the rate is unknown; a rate ExpressLRS declares and ships no radio configuration for; on 3.x, a rate whose figure depends on the band (see below) |
| `link_diversity` | number | `1` once the readings have proved a second antenna, `0` while they have not | the receiver has reported neither `2RSS` nor `ANT`, so there is nothing to say yet |

**`link_packet_rate` and `link_floor` need to know which ExpressLRS the transmitter module runs,
and the frame does not say.** `RFMD` carries an enumeration value whose meaning belongs to
whichever module filled it, and ExpressLRS renumbered that enumeration between 3.x and 4.x: the
same byte is a different rate on each, and the common rates are exactly where the two overlap
(byte 10 is `D250` on 3.x and `D50Hz` on 4.x). So the widget asks the module. Once the link is
up and `RFMD` has a reading — and only for a theme that declares one of these two sources — it
sends the transmitter module one CRSF device ping, and the device-information frame the module
answers with carries its release number. `lib/link_rates.lua` holds a table for each generation
(3.0.0 to 3.6.4, and 4.0.0 to 4.1.0; neither changed within its generation) and names its
sources line by line.

What follows from that, for a theme author:

- **Both sources draw `--` until the module has answered.** That is normally the first pass
  after the ping, but it is a pass, and it is repeated when the widget starts a new
  flight-controller session.
- **A module that is not ExpressLRS 3.x or 4.x resolves to nothing**, rather than to a rate it is
  not running: another make of CRSF module, ExpressLRS 2.x, or a radio with no CRSF module at all.
- **On 3.x, `50Hz` and `250Hz` carry no floor.** In the 3.x numbering those two rates share one
  value across the 900 MHz and 2.4 GHz bands, with a different sensitivity on each (`-120` against
  `-115` dBm, and `-111` against `-108` dBm from 3.4.0), and the band is not in the frame. 4.x put
  the band into the value, which is why every configured 4.x rate has one floor.
- **Nothing is resolved while the link is down.** The radio answers every telemetry value with `0`
  then, and `0` is an air rate in both tables.
- The ping is the same device ping a module's own configuration script sends when it opens,
  addressed to the transmitter module only. ExpressLRS answers it the same way, and — as it does
  when that script opens — clears the module's critical-warning flags.

**The headroom arithmetic is the theme's.** `link_floor` is the floor as ExpressLRS states it, a
negative dBm figure, and nothing here divides anything. `1RSS`, `2RSS` and `TRSS` carry the same
sign: the CRSF field is specified as `dBm × -1`, and the transmitter module negates it on the way
to the handset for exactly this reason — *"OpenTX's value is signed and will display +dBm and
-dBm properly"* — so both numbers are negative dBm and directly comparable. `rssi - floor` is
therefore the headroom in dB, and `(rssi - floor) / (-30 - floor)` a fraction of the way from the
floor to a -30 dBm best case. A theme clamps that itself: an RSSI below the floor is a link that
is still working past what the rate is specified for, which happens.

**`link_diversity` only ever rises, and that is deliberate.** A receiver with one radio and two
antennas spends most of its packets on one of them, so a pass that sees only the first antenna
is not evidence against the second; the value latches at `1` and is cleared where the widget
starts a new flight-controller session. `ANT` alone is not evidence either — the field is in
every frame and a single-antenna receiver reports a constant `0` in it, so what counts is a
reading only a second antenna can produce: a non-zero `2RSS`, or `ANT` naming the second one.
The test is `ANT ~= 0` and never `ANT == 1`: the specification counts the antennas from nought
(*"Diversity active antenna ( enum ant. 1 = 0, ant. 2 )"*), and nought is the value that means
nothing has been proved whatever the numbering above it turns out to be. `2RSS` is the half of
the test that does not depend on that at all.

**What they cost.** Nothing at all on a theme that names none of them: they resolve at the end
of `mapTelemetrySource`, so an absent name is never compared for, and no ping is ever sent. A
theme that names one pays one sensor read per telemetry pass, and a theme that names both
`link_packet_rate` and `link_floor` pays the same one — the reading is memoised on the widget
state for the pass. Until the module has answered, a pass also looks for the answer in the
widget's CRSF frame queue. No box, no threshold and no formatter changed, and no shipped theme
declares any of the three.

Give a `link_floor` box `unit = "dBm"` and a `link_packet_rate` box no unit; `link_diversity` is a flag
rather than a reading and reads better through a threshold colour than as a number.

### `esc_load`

Not a sensor. It is the current as a percentage of the current limit the speed controller is
set to allow, and it exists so that a tile can show a figure a pilot can judge without knowing
the controller. The limit is kept per flight controller, in its preferences file on the radio: an AM32, Scorpion or
YGE controller reports its own and the suite takes it from the parameter block when that
family's page is opened, and for the other seven families it is typed in under *Setup* →
*Power* → *Preferences* ([page](../pages/setup/power/preferences.md)).

Where no limit is on file the source resolves to `nil`, which a box draws as `--`. That is the
state every model is in until one of the two routes has supplied a figure, so a theme shipping
an `esc_load` box should expect `--` to be what most radios show.

Give the box `unit = "%"`, and for a gauge a range of `min = 0, max = 150`: the interesting part
is above 100, where the controller is being asked for more than it is set to allow, and a gauge
ending at 100 has nowhere to draw that.

### `main_power_lost`

Not a sensor. It is `1` while the main pack is gone and the flight controller is still
answering, and `0` otherwise: the pack reads as gone rather than merely low, it had read a real
voltage earlier in this connection, and a BEC voltage is there beside it. It is the test
`lib/audio.lua` makes for its *Main power lost* announcement, decided in one place
(`Audio.mainPowerLost`); it does **not** depend on that announcement being switched on. It is
refreshed on the telemetry cadence, so like every other reading it stands still on a post-flight
screen whose link is gone.

It is never `nil`, so it never draws `--`: before any telemetry has arrived it is `0`, because
the field it reads starts out as *not lost*.

It is a number rather than a yes or no because a threshold limit takes a number or a string, and
a gauge a number only. Like `link_diversity` it is a flag rather than a reading, so it reads
better as a colour than as a digit. Give it both limits: thresholds match with `<=`, so a list
holding only `{ value = 1 }` colours `0` as well. For example:

```lua
{ type = "text", source = "main_power_lost", title = "MAIN PACK",
  thresholds = { { value = 0, textcolor = "green" }, { value = 1, textcolor = "red" } } }
```

A free-form module is handed the widget state and reads the same fact as `state.mainPowerLost`,
a boolean. A theme drawing it would show the voltage slot as running on the reserve and the fuel
reading as unknown, because neither is being measured any more.
### The speed controller's health: two pairs, and which one a surface owes

The speed controller's health, in words. There are four names and they are **two pairs**. In each
pair the first is a translated **string** for a `text` box — the same shape `model_name` already
has — and the second is a **number** for colouring it: 1 nothing wrong, 2 a warning, 3 a fault,
and `nil` where nothing answered, which is the same reading as the string being `nil`. There is no
level 0.

| Source | Level source | What it answers |
| --- | --- | --- |
| `esc_status` | `esc_status_level` | the worst the controller has reported since the flight controller connected |
| `esc_status_live` | `esc_status_live_level` | what the controller is reporting on this pass |

All four come out of one decode, so a theme may declare any of them, or all of them, without
paying for the sensors more than once.

Neither is a sensor. Both are decoded from two that the flight controller publishes — `Esc#`,
which says which telemetry protocol the controller speaks, and `EscF`, its status word — and the
layouts are in `lib/esc_status.lua`, one table per protocol. There is no common layout, which is
why the signature is needed to read the word at all, and why several protocols decode to *no
status*: they fill no status word, so their zero is not a clean bill of health. Which protocols
those are, and what the two sensors need on the flight controller before they exist on the radio,
is in [ESC status](../reference/esc-status.md).

Three properties a theme has to know:

- **`esc_status` keeps the worst reading.** What that box shows is the worst the controller has
  reported since the flight controller connected, not what it is reporting this second, and it is
  dropped where the widget starts a new session with a flight controller. A fault the controller
  has since cleared is still the reason a flight ended early, and a pass is slower than a fault.
- **`esc_status_live` keeps nothing.** It follows the status word down as well as up, so a fault
  the controller has cleared stops being shown on the next pass. A request to restart the
  controller — which the flight controller withdraws on the very next telemetry frame, and which
  is therefore never put on file — is part of this reading and of no other.
- **`nil` where nothing answered**, on both pairs, which a box draws as `--`: no controller, or
  neither sensor on this radio.

**Pick by what the surface promises, and do not treat one as a cheaper version of the other.** A
line a pilot reads as *what is wrong now* takes the live pair, or it holds an alarm the controller
withdrew. A row a pilot reads as *what this flight has seen* takes the pair on file, or it loses
the fault that ended the flight. A theme wanting both shows both, and pays one decode for it.

The level is a separate source rather than a threshold on the text, because thresholds match a
value and the value here is already translated. Colour a box from it with a `textcolor` function:

```lua
{
  col = 1, row = 1, type = "text", subtype = "telemetry",
  source = "esc_status",
  title = "ESC",
  textcolor = function(box, state)
    local level = state.derived and state.derived.esc_status_level
    if level == 3 then return RED end
    if level == 2 then return COLOR_THEME_WARNING end
    return WHITE
  end
}
```

That closure runs in the reactive sweep, so it reads `state.derived` and nothing else. **Naming
either half of a pair declares both halves of that pair**: they are one reading, so a box that
shows the text can colour itself from the level without declaring it separately, and the level
costs a cache read on the pass that resolved the text rather than a second pair of sensor reads.
**The two pairs stand alone**, so naming `esc_status_live` does not also resolve `esc_status`; a
theme that wants both names both. A theme that names none of the four reaches none of it and reads
neither sensor.

The rest of a box is presentation and is shared across the types that can use it: `title`,
`titlepos`, `titlealign`, `titlecolor`, `textcolor`, `bgcolor`, `font`, `unit`, `decimals`,
`transform`, `autosize_chars`, `thresholds`. Thresholds — the dynamic colour lists and how a
temperature limit is converted for a radio set to Fahrenheit — are described once, in
[user themes](../dashboard/user-themes.md); they behave identically in a shipped theme.

### Facts on `state` that are not a box source

A free-form module is handed the widget state and may read more than the value list above. Three
of those are worth naming, because nothing else in the tree says them -- and a theme that works
the first out for itself will not agree with the announcement that speaks it:

| Field | What it says |
| --- | --- |
| `state.mainPowerLost` | The main pack is gone while the flight controller is still answering — it reads as gone rather than merely low, it had read a real voltage earlier in this connection, and a BEC voltage is there beside it. It is the test `lib/audio.lua` makes for its *Main power lost* announcement, decided in one place (`Audio.mainPowerLost`) and published here; it does **not** depend on that announcement being switched on. A theme drawing it would show the voltage slot as running on the reserve and the fuel reading as unknown, because neither is being measured any more. It is refreshed on the telemetry cadence, so like every other reading it stands still on a post-flight screen whose link is gone. |
| `state.packNotFull` | The pack plugged in was not full: `true` when its voltage per cell was below the flight controller's *Max cell voltage* less the *Margin* of the *Pack Not Full* announcement, `false` once it was judged full, `nil` until it has been judged -- which waits for the connect chain to finish and for a pack voltage, a cell count and the battery configuration read over MSP, so it arrives after the first fuel reading. Judged once per connection and kept for the rest of it, so a pack running down in flight does not turn it `true`; judged again after a reconnect. It is the verdict `lib/audio.lua` speaks for that announcement, decided in one place (`Audio.packNotFull`) and published here on the telemetry cadence; it does **not** depend on that announcement being switched on. Read it with `== true`: `nil` and `false` both mean "nothing to say". Urban draws its fuel gauge orange instead of green while it is `true`. |
| `state.eventLog` | What changed on the craft and when: the last thirty transitions, oldest first, each `{ kind, value, text, level, time }`. `kind` is `"armed"`, `"disarmed"`, `"connected"`, `"disconnected"`, `"governor"` or `"esc"`; `value` is the governor state index for `"governor"`; `text` is the speed controller's own verdict for `"esc"`, already in the package's language, and nil otherwise, so the theme names every other kind in its own words; `level` is 1 information, 2 warning, 3 error (the speed controller's levels, which `"esc"` carries and a disconnect takes as 2); `time` is the radio's clock as `HH:MM:SS`, empty on a radio without one. A connection's first governor state is its starting point and is not an entry; its speed controller's first verdict is. An `"esc"` entry exists only while the active theme declares `esc_status_live` — the history reads the verdict the snapshot already resolved and never the sensors. The table is never nil, is kept across connections, and changes only on a transition, so a closure reading the newest entries (`log[#log]`, `log[#log - 1]`, ...) reads a few fields per frame and allocates nothing. |

**`source` is read as a literal, once, at theme load.** When a theme is loaded the widget walks
its boxes and collects every `source` that is a string into the list the derived snapshot is
built from, and it is that snapshot a box reads per frame. A `source` given as a function is
resolved at render time but is not in the list, so unless some other box names the same source
as a literal, it resolves against a snapshot that does not carry it and the box shows `--`.
Give `source` as a plain string.

## `sources`: telemetry no box of yours names

A phase module may carry a `sources` key beside `boxes` or `build`: a plain list of source
strings the module reads and the boxes do not name.

```lua
local M = {}

M.sources = { "TPWR", "TPWR+", "RQly", "RQly-", "Tmcu+" }

function M.build(zone, state)
  local peak = function() return (state.derived or {})["TPWR+"] end
  ...
end

return M
```

Everything in the list is resolved into `state.derived` on the same cadence as the collected box
sources -- twice a second, in the widget's own pass -- and is read from there by name. It is the
only way a **free-form** theme gets at anything beyond the fixed state fields, because a
free-form theme declares no boxes for the widget to walk. A declarative theme needs it wherever
one tile shows more than one reading: a box has a single `source`, so a tile drawing a session
minimum and maximum beside a live value names the other two here.

`sources` may also be a function `(box, state)` returning the list, called once per theme load
exactly like `boxes` -- which is how a theme whose `configure.lua` lets the pilot choose what to
show builds the list from its own configuration.

**It is per phase, and that is structural rather than a setting.** The list belongs to the phase
module, the widget loads only the module for the phase it is drawing, and it rebuilds the list on
every phase change. A source a statistics screen needs after the flight therefore costs nothing
while the aircraft is in the air. A theme that covers all three phases from one `widget.lua`
declares one list, which is read in all three.

**A fullscreen view may name readings of its own the same way.** A view module (see
[Views of a theme's own](#views-of-a-themes-own)) may have `sources(zone, state)`, returning a list
of the same shape. While that view is on top in fullscreen, the widget resolves its list after the
phase module's, without duplicates; on every other surface it does not. A reading only a view
shows is then read only while the view is open, where a phase module naming it would have it read
for the whole phase. The list is asked for once per view module and per theme load, after the
view's first build, so the first build of a view finds its own readings not yet resolved and
draws them as absent until the next read. A pair the widget completes for a phase module -- a
status and its level -- is not completed for a view; name both halves.

**What may go in the list.** The source vocabulary of `source` above, and any telemetry sensor of
the radio's by its own name -- the flight controller's custom sensors (`Vesc`, `Iesc`, `EscF`,
`Es2T` and the rest; see [telemetry sensors](../reference/telemetry-sensors.md)), and the link
statistics the radio makes itself (`RQly`, `1RSS`, `TPWR`, `RSNR`, `RFMD`). A name may carry a
trailing `-` or `+` for the session minimum or maximum the radio keeps for every sensor, which is
what the example above reads. A name the model has no sensor for resolves to `nil` and is then
searched for less and less often rather than on every pass; a tile reading it draws `--`.

**What it costs.** One resolved read per source per telemetry pass, and nothing per frame -- the
sweep reads the snapshot and never probes. Declaring nothing costs exactly what it did before:
the list is only walked when the module carries one. Declared sources do **not** enter the render
key, so a value changing redraws rather than rebuilding the scene.

`Sensors.getMetadata(name)` in `lib/sensors.lua` answers the unit and the number of decimals a
sensor is sent with, for the names the suite catalogues. Ask it when the theme builds, not per
frame, and title the tile in your own translated string -- the catalogue holds no labels.

**One case where a declared source stands still.** After a flight, once the flight controller has
stopped answering, the widget stops reading telemetry altogether so that the post-flight numbers
do not decay into zeroes. The snapshot is frozen with them, declared sources included.

## A value given as a function

Almost every field of a box may be a function `(box, state)` instead of a value, and the two
are resolved at different moments:

- **Structure is resolved once, when the box is built** — `layout`, `boxes`, `subtype`, a
  gauge's `min` and `max`, a threshold's limit and its colours, a named colour string. Anything
  such a function reads must be something whose change rebuilds the screen. The theme
  configuration is: saving it reloads the active theme. Live telemetry is not.
- **Display is resolved per frame, in the firmware's reactive sweep** — every function field
  handed to `lvgl.build()`. That sweep runs on whatever instruction budget the widget's own
  pass left over, outside the widget's `pcall`, so the rule in [GEMINI.md](../../GEMINI.md)
  under *Dashboard Reactive Closures* applies to a theme's closures exactly as it applies to
  the object modules: read precomputed state, probe nothing, no unbounded loop, format at most
  one string per value change.

A function that raises is caught and resolves to `nil`, which on the radio looks like a box
that draws its container and no value.

## `configure.lua`

A theme with settings returns a **factory**: a function taking the page context and returning
the page module. The context carries the theme the page was opened for, and the factory takes
the theme's path out of it. That is what makes a copied theme store its own values instead of
writing over the original's.

```lua
local THEME_PATH = "system/default"    -- fallback for a caller that passes no theme

-- ... the page module M, with getHeaderActions, onReload, onSave and build ...

return function(ctx)
  local theme = ctx and ctx.theme
  if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
    THEME_PATH = theme.path
  end
  return M
end
```

Values are read and written with `DashboardLib.getThemeConfig(prefs, path, defaults, modelPrefs)`
and `setThemeConfig`, which store them under `cfg_<path with every non-alphanumeric character
replaced by an underscore>_<key>` — `system/default` and the key `v_min` give
`cfg_system_default_v_min`. Two themes therefore cannot collide, and a theme copied to a
different folder starts from the defaults rather than inheriting.

Where the values go is decided by the page the module is opened from, not by the module. The
settings page sets an edit scope in the library before it runs anything of the module
(`DashboardLib.setEditScope`): the theme tiles edit `"standard"`, the radio's preferences, and
*Per-Model Settings* edits `"model"`, the connected model's preferences on top of the standard ones.
In the model scope `setThemeConfig` stores only the values that differ from the standard — the
radio's value, else the default the module passed to `getThemeConfig` — and removes the others
from the model, so a module has to read through `getThemeConfig` before it saves. The module
still hands both tables over and saves the model's with `model_preferences.saveByMcuId` when a
flight controller is connected; which of the two actually changes is the library's decision.
With no scope set, as in the widget, `getThemeConfig` returns what applies: the model's values
only while per-model settings are on for that model (`DashboardLib.modelOverridesActive`).

`onSave` reports the save itself, through `ctx.reportSave`, and it reports success only when the
store that carries the values was written. Which store that is depends on the scope, so read it
with `DashboardLib.getEditScope()` when the save is made:

- `"model"` — the values are in the model's preferences, and `saveByMcuId` answers whether its
  file was written (`ok, err`). That answer decides the save: a failure is reported as *Save
  failed* with its reason, and so is a `lib/model_preferences.lua` that will not load, which
  `saveConfig` answers as `"unavailable"`, the word `saveByMcuId` uses for a store it cannot load.
- `"standard"` — the values are in the radio's preferences, which `ctx.savePreferences()`
  writes, and its answer decides the save. The model's file is still rewritten while a flight
  controller is connected, but it carries none of this save's values, so its answer is not
  reported.

The shipped themes do this in `saveConfig`, which returns `true` or `false, err` by that rule
(`true` where no flight controller is connected), and in `onSave`, which reports a failure when
either `saveConfig` or `ctx.savePreferences()` failed.

What a store answers is not for the screen. A refused write comes back as a token of
`lib/config_store.lua` (`io`, `write`, `delete`, `rename`), or as the error text `io.open` gave,
which is the file's path followed by `file error`; the model's store adds `unavailable` and
`missing_mcu_id`. `onSave` therefore shows the sentence `DashboardLib.saveFailureReason(i18n, err,
modelStore)` maps the answer to, with `modelStore` true for the answer of `saveByMcuId`:
`unavailable` from the model's store reads as `model_store_unavailable` (*model settings store
not available*), `missing_mcu_id` as `model_store_missing` (*Connect the flight controller to save
this model's settings*), and every other answer of either store as `store_write_failed` (*the
settings file could not be written to the SD card*), all under
`app.pages.settings_dashboard_settings`. The *Theme* page reports its two stores the same way. The settings page refuses a model-scope
save without the model's store before `onSave` runs, so a module is not asked to save the model
scope with no flight controller connected.

`bin/themes/verify_save_scope.lua` drives every shipped theme's module through this contract
offline, in both scopes and both shipped locales; see
[README](../../bin/themes/README.md#what-a-save-reports).

The widget hands the resolved configuration to the theme as `state.themeConfig`, which is where
a box's `min`, `max` or threshold limit reads it from.

Where the configuration sets no voltage bounds of its own, the widget fills in `v_min` and `v_max`
from the pack's cell count and the flight controller's minimum and maximum cell voltage, and fills
them in again whenever the bounds it holds are still the unset defaults, no longer fit the cell
count, or were filled in for a different cell count. A move of those bounds rebuilds the scene, and
the render key is computed again in the pass that moves them, so the scene is queued under the key
for the new bounds.

The cell count is the one the flight controller reports in telemetry. Until that reads a count --
it reads 0 for the moment after a pack is plugged in, until the board has detected the pack -- and
on a model without that sensor, the widget takes the cell count configured on the flight controller
(*Setup* → *Power* → *Battery*), which is the count the board itself uses for any pack plugged in.
Only where that is 0, which leaves the detection to the board, or has not been read yet, does it
estimate the count from the pack voltage. An estimate cannot tell every pack apart: 42 V is a full
10S pack and a 12S pack at 3.5 V per cell. A voltage below half a cell gives no estimate at all:
it is no pack, not a 1S pack, so it never sets `state.batteryCellCount` and the bounds are not
fitted to one cell. A count already held -- a pack that was detected and is then pulled -- is kept.

## Splitting the settings into pages

A theme with more settings than one screen carries may declare `pages` in its `init.lua`. Its
tile under *Dashboard* → *Settings* then opens a grid of those pages instead of the settings
page itself, and each tile opens the same `configure.lua` with the page it stands for named on
the context. There is one level of it: a page holds settings, never a further grid.

```lua
pages = {
  { id = "look", title = "Look",       icon = "icons/look.png" },
  { id = "rows", title = "Value Rows", icon = "icons/rows.png" },
},
```

| Key | Type | What it does |
| --- | --- | --- |
| `id` | string | Lowercase letters, digits and underscores. It becomes part of the menu id, and it is what the module reads to tell the pages apart. Unique within the theme; a repeat of one is dropped. |
| `title` | string | The tile label and the page's header title. Required, and it takes the same `@i18n(key)@` form a theme's `name` takes. |
| `icon` | string | Optional, relative to the theme folder. |

**Fewer than two usable entries and the theme behaves as though it declared none**, because a
grid holding a single tile is a press a pilot pays for nothing. An entry missing its `id` or
`title`, or carrying an `id` the menu cannot hold, is dropped rather than costing the theme its
settings page.

Icons are resolved against the folder the theme was found in and looked up before use: a page
icon that is not there falls back to the theme's own `icon.png`, and that to the settings
icon of the tool. The theme's own tile follows the same chain, so a configurable theme is now
listed under *Settings* with its `icon.png` rather than with the settings icon.

The page is handed to `configure.lua` as `ctx.page` — on the factory context beside `theme`,
and on the context of every `build`, `onReload` and `onSave` call, because a module returned as
a plain table never sees a factory context:

```lua
ctx.page = { id = "rows", title = "Value Rows" }   -- nil when the theme declares no pages
```

Each page loads and saves the whole configuration: `loadConfig` and `saveConfig` are unchanged,
and a page is expected to build the controls belonging to `ctx.page.id` and to leave the rest of
the values as it found them. **Leaving a page discards the module.** The page registry drops the
settings module when the menu id changes (`app/pages/init.lua`, `closePageModule`), so switching
between two pages of one theme re-loads `configure.lua` and calls the factory again — an edit
that has not been saved is gone. Save before leaving a page, or keep what must survive in the
preferences.

A radio that offers no directory enumeration reads the theme list from
`theme_index.lua` instead of from `init.lua`, and the packager copies the declared pages into
it, so the split is there as well.

## A theme that takes fullscreen

By default fullscreen shows the widget's own [quick menu](../dashboard/quick-menu.md), whatever
the theme. A theme whose `init.lua` says `fullscreen = "theme"` is shown there itself instead,
built at the fullscreen size, and the quick menu and the battery picker open **over** it. In the
terms of [dashboard views](dashboard-views.md) the theme is the base layer under the view stack.
A theme without the key is not affected in any way: its zone, its fullscreen and every key are
exactly what they were.

The mode follows the theme's `init.lua`, not the module on screen: a phase whose module falls
back to the default theme's inside a theme that opted in is drawn full screen as well.

The build is the theme's own. A declarative theme is built by the engine from the same boxes as
in the zone, at the larger size; a free-form theme's `build(zone, state, ctx)` receives the
fullscreen zone and a third argument, `ctx`, which it never receives in the zone. The render key
is the theme's, taken at the fullscreen size and under the same 2 Hz throttle as in the zone.

### `ctx`

One per widget, handed to every fullscreen build of the theme, and made new when the theme on
screen changes:

| | |
| --- | --- |
| `ctx.action(after)` | performs an action: `openView:<id>`, `closeView`, `done`, `exitFullscreen`, `openTool`, `openTool:<menuId>` or `none` (see [what follows a press](dashboard-views.md#what-follows-a-press)) |
| `ctx.keys` | a table the theme fills with actions for the keys, `exit`, `pageDown`, `pageUp`, `mdl`, `sys` and `tele`; see below |
| `ctx.condition(name)` | whether a named condition holds, from the list in [dashboard views](dashboard-views.md#conditions) |
| `ctx.entries()` | the quick menu's entries, as `fullscreen_menu.lua` returns them: the ones the pilot has put in it, in the pilot's order |
| `ctx.menu(children, entries)` | the quick menu's builder: appends the menu for `entries` (the menu's own when omitted) to `children`; a list handed in chooses and orders the menu's own entries by `id`, and an item whose id the menu does not have is left out |
| `ctx.entry(id)` | the quick menu's record `id` — `erase_blackbox`, `inflight_tuning`, `battery_pick`, `tool`, `flight_log`, `battery_profile` — or `nil`; whether or not the pilot has put it in the quick menu |
| `ctx.list(name)` | the records of a named menu, in its order: `"quick"` is the quick menu as the pilot has arranged it on *Settings* → *Dashboard* → *Quick Settings*; any other name gives an empty list |
| `ctx.visible(entry)` | whether the entry is offered now — the test the quick menu makes before drawing the row |
| `ctx.run(entry, option, after)` | the entry's work, or `option`'s when one is given, and then what follows it — the menu's own record and option of that id, whatever table is handed in; `after` replaces the entry's own follow-up, `nil` keeps it |
| `ctx.status(id)` | what became of the last `ctx.run` of that entry in this visit to fullscreen: `nil`, `"busy"`, `"ok"` or `"failed"` |
| `ctx.info(entry)` | what the entry knows about the state it acts on, read now: `{ used, total }` of the blackbox for `erase_blackbox`, `nil` for the others |

### The theme draws, the widget acts

A theme may draw the quick menu's entries itself — all of them in its own layout, or a few of
them among its own controls — and the widget still does what they do. Take the records with
`ctx.list("quick")` or `ctx.entry(id)`, draw a row for each one `ctx.visible` offers, and give
its button a press that calls `ctx.run(entry)`, or `ctx.run(entry, option)` for one of the
options of a `choice` (`entry.options()` lists them as they stand now; see
[quick menu](../dashboard/quick-menu.md#for-contributors) for the fields). The work and the
action that follows it are the widget's, in one place, so a theme's ERASE BLACKBOX sends what
the quick menu's sends. A theme adds no entry of its own, and changes none: `ctx.run` looks
the entry up again by its `id` among the menu's records and the option by its `id` among that
record's options as they stand now (NO BATTERY by `none`, the picker's close by being the
entry's `close`), and runs those — never a `press` out of the table it was handed. An entry or
an option the menu does not have is refused, and so is an entry the menu does not offer now
(`ctx.visible` would answer false for it) -- except the picks and the close of an entry that
names a `view`, which the battery picker runs whatever the state. `ctx.visible` and `ctx.info` answer for the menu's
record of that id as well, and a list handed to `ctx.menu` draws the menu's records of the ids
it names, in its order, and nothing else.

What a theme can show beside an entry is read on each build:

- **State** — whether it is offered (`ctx.visible`), which profile is in force (the option's
  `current`), how full the blackbox is (`ctx.info`).
- **Outcome** — `ctx.status(id)`, for work that talks to the flight controller: `"busy"` once
  its messages are queued, `"ok"` once the last of them has been answered, `"failed"` if any of
  them was given up (out of retries, timed out, or dropped by a clear of the queue). A new
  outcome rebuilds the screen. Work that sends nothing has none, and the quick menu's own
  buttons never set one — the quick menu closes at once and shows none.

The outcome belongs to the visit to fullscreen it was started in, and lapses with the stack:
on `done`, on `exitFullscreen`, on leaving fullscreen and on a reconnect, and when another
theme is selected. ERASE BLACKBOX and a battery profile are followed by `done`, so a theme that
wants to show how they went runs them with an `after` of its own, `ctx.run(entry, nil,
"none")`, and closes the surface itself. A message that is dropped without being answered or
reported — the queue drops one that carries no simulator reply while it runs in the simulator —
leaves the outcome at `"busy"`.

A control is a node with a `press` that calls `ctx.action`, for example
`{ type = "button", x = ..., y = ..., w = 44, h = 44, press = function() ctx.action("openView:menu") end }`.
A press does its own work and then names what follows, the same way the quick menu's entries
do. Draw a glyph or a label over a button as `label` or `line` nodes, not as a `rectangle`: a
rectangle built in fullscreen takes the press and hands it to its parent, so it swallows every
press that lands on it. That same hand-over is what lets a picture made of rectangles take a press
of its own: build it as the button's `children`, and a press on any of them reaches the button.
The children are placed against the button's content area, inside the button's padding and its
2 px frame, so they have to be drawn that far up and to the left to sit where the button starts --
Urban's battery gauge does so (`themes/urban/layout.lua`, `L.gauge`).

### The controls, and what a theme owes

**The theme decides which controls it shows and what they do, including whether one leaves
fullscreen.** Two duties come with that:

- **A way into the quick menu.** It is where ERASE BLACKBOX, BATTERY and the battery profiles
  are; the page keys reach it on a radio that has them, but a touch radio needs a control.
- **A way out of fullscreen** — a control with `exitFullscreen`, or RTN bound to it with
  `ctx.keys.exit = "exitFullscreen"` (every radio has RTN) — or the author's decision to rely on
  a long press on RTN, which always leaves fullscreen in the firmware.

A fullscreen tree that binds **no press anywhere** gets the widget's own two controls, appended
after the theme's nodes so they lie above them: a menu glyph that opens the quick menu over the
theme, and an X, where the quick menu's X is, that leaves fullscreen. A declarative theme always
gets them, since a box cannot take a tap. A theme that binds even one press gets neither, and
owes both duties itself.

`bin/themes/validate.lua` checks a theme folder for both duties offline, fires every press, and
refuses a `rectangle` drawn over a pressable node and an action the widget does not know, in a
press or in `ctx.keys`; see `bin/themes/README.md`. A press that opens the menu is the menu
access it looks for. A press with `exitFullscreen` or `ctx.keys.exit = "exitFullscreen"` is a way
out; a theme that relies on a long press on RTN instead declares it with
`fullscreenExit = "longRtn"` in its `init.lua`.

### Keys

In this mode the widget answers six keys (a theme without the key answers none, as before):

| Key | With a view on top | With the theme showing |
| --- | --- | --- |
| PAGE down, PAGE up | the quick menu on top: close it; any other view: open the menu over it | `ctx.keys.pageDown` / `ctx.keys.pageUp` if set, else open the menu |
| RTN, short | the view's `back` — the picker: its close box; the menu: close it | `ctx.keys.exit` if set, else nothing |
| RTN, long | leaves fullscreen, in the firmware | leaves fullscreen, in the firmware |
| MDL, SYS, TELE, short | nothing | `ctx.keys.mdl` / `ctx.keys.sys` / `ctx.keys.tele` if set, else nothing |

A key bound to `openView:<id>`, RTN aside, closes that view again while it is on top, rather
than doing what the first column says: pressed twice, it opens the view and closes it.

Both page keys do the same because some radios have only one. The keys are not answered while
the in-flight tuning surface or the connect splash is up.

MDL, SYS and TELE open the radio's own menus everywhere but in a widget's fullscreen, where the
widget gets them and the radio opens nothing; unbound they do nothing there, as before. Not
every radio has them, so a binding is a shortcut, never the only way to something: the menu
access and the way out a theme owes are a press, the page keys or RTN.

```lua
ctx.keys.tele = "openView:link"    -- a view the theme registers
ctx.keys.mdl = "openView:menu"
```

### What the pilot sees

The quick menu's X, and every entry that used to leave fullscreen, now close the menu and put
the theme back. The battery picker's packs, NO BATTERY and its X do the same. Only a control
that says `exitFullscreen` — the widget's own X on the theme, or one of the theme's — a short
press on RTN where the theme bound `ctx.keys.exit` to it, and a long press on RTN leave fullscreen.

## Views of a theme's own

A free-form theme may list views in its `init.lua`. Each is a module in the theme's folder that
draws a whole fullscreen surface, opened over whatever fullscreen shows — the theme, where it
takes fullscreen, or the quick menu — the way the menu and the battery picker are
([dashboard views](dashboard-views.md)):

```lua
views = {
  { id = "link",         module = "link.lua" },            -- a view of the theme's own
  { id = "menu",         module = "menu.lua" },            -- the quick menu, drawn by the theme
  { id = "battery_pick", module = "picker.lua" },          -- the battery picker, drawn by the theme
},
```

| Key | What it says |
| --- | --- |
| `id` | The view's name. An id the widget already has — `menu`, `battery_pick` — replaces that view's **look** and nothing else; any other id is a view of the theme's own. A repeated id counts once. |
| `module` | The file that draws it, relative to the theme folder. |
| `openWhen` | Optional. What opens the view on its own: the name of a condition, a switch position (`{ switch = "SA", pos = "up" }`, `{ switch = "L01" }`), a switch the theme's own settings name (`{ switch = { pref = "<key>", default = "SA" }, pos = "down" }`), or a function of the state. See [what else a theme's view may open on](dashboard-views.md#what-else-a-themes-view-may-open-on); the view opens when it rises, [not while it holds](dashboard-views.md#views-that-open-themselves). Ignored where the id replaces a look. |
| `where` | Optional. `"fullscreen"` (the default), `"zone"` for a view that takes the widget zone instead ([zone views](dashboard-views.md#zone-views)), or `"both"`. |

The list is read on the first fullscreen pass after the theme on screen has changed, with the
`fullscreen` key and for the same reason, and only where the phase module on screen is
free-form: a declarative phase draws no view. The module is loaded the first time its view is
built, through the loader that loads the rest of the theme — from the theme's own folder, a
user theme from source — so registering a view costs nothing until it is opened, and a module
that fails to load, or whose `build` raises, is not asked for again (a replaced look falls back
to the widget's own; a view of the theme's own is closed and refused), with one log line. A
`build` the radio stops at its instruction limit is not a raise here: it is tried again, and after
three stops in a row the view shows *Dashboard error* until the theme is reloaded. A view of the previous theme's that is still open
when the theme changes is closed.

A theme's view module has `build(children, zone, state, ctx)` — it appends the whole tree to
`children`, at the fullscreen zone, and gets the same `ctx` as the theme's fullscreen build — and
optionally `renderKey(zone, state)`, appended to the view's key so that the view is rebuilt when
it changes, and `sources(zone, state)`, the readings it needs beyond the phase module's, resolved
only while it is on top ([`sources`](#sources-telemetry-no-box-of-yours-names)). A view of the
theme's own may have `back(ctx)`, what a short press on RTN does while
it is on top; without one RTN closes it (`closeView`). A view opens with `ctx.action("openView:<id>")`.

**A replaced look is the look only.** What the menu or the picker offers, when it opens, what RTN
does on it and what follows each press stay the widget's: draw the records through `ctx` and run
them with `ctx.run` ([the theme draws, the widget acts](#the-theme-draws-the-widget-acts)). For the
picker that is `ctx.entry("battery_pick")`: `entry.options()` are the packs and *NO BATTERY*,
each run with `ctx.run(entry, option)`, and `ctx.run(entry, entry.close)` is its close — the
theme never writes the pick or the prompt's state itself. RTN on it is the widget picker's own
close. A theme that replaces the picker's look owes it a way out, as the widget's picker has.

`bin/themes/validate.lua` checks the `views` of any theme, whether it takes fullscreen or not:
every module is built — a fullscreen view with a recording `ctx` whose presses are fired, a zone
view without one — and it is red on a zone view that binds a press, an `openWhen` that names a
condition, a switch or a setting the widget or the theme does not have, and a condition function
that raises or costs more than 35 instructions a call. A setting counts as the theme's where its
settings page names it — the `configure` module or a theme file that module loads. A number where
a switch name goes is a stored switch position, and a setting's `default` may be `0`, "no
switch", for a view that opens on a switch only once the pilot has picked one. See its
[README](../../bin/themes/README.md#a-themes-views).

## The battery prompt

With *Ask which pack after connecting* on (the [Flight Log](../pages/tools/flight_log.md) page,
*Settings*), the widget offers the pilot's battery registry once per connection — in fullscreen,
because a widget zone receives no touch and Lua can leave fullscreen but not enter it. The
picker is the widget's for every theme that does not register a look for it, so its way out is
always there; a free-form theme may draw it instead ([views of a theme's
own](#views-of-a-themes-own)), and what a pick does stays the widget's either way. A theme may
read what the prompt knows, and anything on the radio may drive it.

### `state.batteryPick`

A table from the widget's first pass on, replaced rather than emptied on a reconnect, so a
closure may index it without guarding. A theme reads it and never writes it.

| Field | |
| --- | --- |
| `loaded` | the registry has been read for this connection |
| `pending` | the prompt is on, this model has packs, and this connection the pilot has neither picked nor closed it and the model has not been armed |
| `candidates` | the registry entries for this model: `id`, `name`, `cap`, `cells`, `profile`, `cycles`, `last`, plus `targetProfile` |
| `selectedId`, `selectedName` | the pack picked this connection, else the one stored for the model, else `nil` |
| `boardProfile` | the battery profile the flight controller reported on connecting, 0-based; `nil` until it has answered, and again after any profile write, which is not confirmed |
| `dismissed` | the pilot closed the picker without picking, this connection |
| `applied` | what became of the profile write: `nil`, `"queued"`, `"skipped"` or `"refused:<why>"` |

`targetProfile` is 0-based like `boardProfile`, and is `nil` where the pack names a profile outside
1-6, or names none and none can be derived for it: no board profile matches it, more than one does
([the rules](../pages/tools/flight_log.md#the-battery-profile)), or the board's battery
configuration was not there when the registry was read. With *Set the pack's battery profile* on it
is resolved again for the picked pack when the pick is applied. The BatP telemetry sensor is
1-based and is a different number; do not mix the two.

### `rfsuite.batteryPick`

Three actions for anything on the radio that is not the picker itself — a theme, or another
widget:

| | |
| --- | --- |
| `rfsuite.batteryPick.select(id)` | record a pick; `nil` is *no battery* |
| `rfsuite.batteryPick.dismiss()` | close the prompt for this connection |
| `rfsuite.batteryPick.open()` | put the picker on screen: at once while the widget is fullscreen, otherwise the next time fullscreen is entered — unless the model is armed by then or has flown since the call, or the link has been re-established |

They are bound to the dashboard widget that published them last, and they record rather than
perform, exactly as a press does.

## Checklist for a theme shipped in this repository

1. `src/rfsuite/widgets/dashboard/themes/<folder>/` with `init.lua`, the three phase modules
   and `icon.png`.
2. A row in `app/pages/settings/dashboard/theme_index.lua`, or the theme is missing on a radio
   without directory enumeration.
3. `configure.lua` as a factory, or no `configure` key at all.
4. Every string a pilot reads through i18n — box titles take the `@i18n(key)@` form, which the
   packager resolves for a shipped theme and the widget resolves at runtime for a user theme,
   falling back to the last segment of the key when it cannot.
5. A budget row. `bin/accounting/measure.lua` prices every shipped theme — its worst pass and
   one full sweep of the tree it leaves standing — and every box type the shipped themes
   declare. A theme or a box type with no row in `budgets.lua` fails `--check`, which is what
   makes a new theme ship its cost with the pull request that adds it. See
   `bin/accounting/README.md`.
6. The documentation: this page for a change to the contract, `docs/dashboard/` for what a pilot
   sees, and an entry in `Releases.md`.

## Related

- [User themes](../dashboard/user-themes.md) — copying and editing a theme on the card, box
  styling, named colours and threshold lists.
- [Dashboard widget](../dashboard/README.md) — the pilot-facing side of the widget.
- [GEMINI.md](../../GEMINI.md) — the code conventions, and the reactive-closure rule in full.

*Documented against RFSuite 0.1.7.*
