# Flight statistics

The suite records the extremes of each flight — the highest headspeed, the lowest pack voltage, the
warmest ESC and so on — together with how long the flight was armed. This page says where that
record lives, who keeps it, and what each field means.

## Where it lives

The record is published under `rfsuite.session.flight`, in the Lua state the suite's widgets run
in, and is readable by anything else in that state.

```lua
rfsuite.session.flight = {
  current      = { maxRpm = 2050, minVoltage = 22.4, ... },  -- the flight in progress
  last         = { maxRpm = 2210, minVoltage = 21.9, ... },  -- the flight before it
  seconds      = 128.4,   -- armed seconds of the flight in progress
  lastSeconds  = 301.2,   -- armed seconds of the flight that ended
  flights      = 37,      -- flights the flight controller counts
  totalSeconds = 44210,   -- armed seconds the flight controller counts, plus the live flight
  armed        = true,    -- whether a record is open
}
```

A key of `current` or `last` is **absent until that statistic has taken a value**, so a reader asks
`current[key]` first and falls back to `last[key]`. The keys are:

| key | from | recorded |
|---|---|---|
| `maxThrottlePercent` | throttle % | maximum |
| `maxRpm`, `minRpm` | headspeed | maximum of any reading; minimum only above zero, so the spool-down is not the minimum |
| `maxCurrent`, `minCurrent` | current | both, any reading |
| `maxWatts` | power, measured or voltage × current | maximum |
| `maxAltitude` | altitude | maximum |
| `maxEscTemp` | ESC temperature | maximum |
| `maxMcuTemp` | MCU temperature | maximum |
| `minFuel` | smart fuel, else fuel | minimum, and only once a fuel sensor has answered in this flight |
| `maxVoltage`, `minVoltage` | pack voltage | both, above zero only |
| `minBecVoltage` | BEC voltage | minimum, above zero only |
| `maxLq`, `minLq` | link quality | both, and only for a 0–100 % reading from a sensor that is not a known RSSI source — a receiver without an RQly sensor falls back to 1RSS/2RSS, which carry dBm |

## Who keeps it

Whichever widget of the suite is running the background work: the dashboard widget, or — on a model
that does not use the dashboard — the service widget, which exists to run the runtimes and publish
the MSP surface for other widgets. The record is kept by the event runtimes rather than by a
screen, so **a model with no dashboard placed still records its flights**, and a dashboard placed
afterwards shows the last one.

The statistics are sampled every 0.5 s while a flight is running. The flight clock advances on
every wakeup, so a flight's duration does not depend on how often the statistics are sampled, and
a single step of that clock is capped at one second — a widget can be suspended for a whole tool
session, and the wakeup after that must not credit the flight with all of it.

## When a flight starts and ends

On the flight controller's arm flag, as the event runtimes read it — the same edge the flight log
and the post-disarm reads already fire on. The arm edge opens a record; the disarm edge moves it to
`last` and starts an empty one. The record is closed **first** of everything that runs on the
disarm edge, so anything behind it in that chain reads a finished flight.

A link that goes down ends the session the record belongs to: the record is dropped with the rest
of the connection state, because a link that comes back is, as far as anything here can tell, a
fresh pack and a fresh session.

## The two totals — what changed, and why they can go down

**The total flight time now means something else than it used to, and a tile showing it will jump.**
It used to be the armed seconds *this dashboard widget instance* had counted since it was created:
never stored, so it started at zero every time the widget was built; undercounted, because the clock
only advanced in a pass where telemetry had changed; and separate per placement, so two dashboards
disagreed. It is now the **flight controller's lifetime total for this model** — the board's own
`stats_total_time_s`, which it keeps across power cycles — plus the flight in progress while armed.
A pilot who saw this session's minutes on that tile will now see the machine's hours.

The flight count moved the same way and for the same reason: it is the board's count, not one this
widget kept.

`flights` and `totalSeconds` therefore come from the **flight controller**; `totalSeconds` has the
flight in progress added to it, since the board has not been told about that one yet. Until the
board has answered — an older firmware, a read that failed, the counter switched off on the board —
the suite falls back to what it has seen itself in this session.

The board adds a flight only once its armed time passes the board's own minimum
(`stats_min_armed_time_s`, 15 s by default; the whole counter can be switched off on the board). So
a very short flight can be counted by the suite and not by the board, and the totals can **fall** by
that flight at the moment the board is read again after the disarm. That is the board's definition,
and the suite reports what the board says rather than arguing with it.

## Reading it from a theme

A dashboard theme reads the record through the box's own `stattype`, which is the supported route:

```lua
{ type = "text", subtype = "stats", source = "rpm", stattype = "max" }
```

A theme that reaches into the widget state directly can use `state.flight`, which is the same table
as `rfsuite.session.flight`.

**Deprecated:** before the record had an owner it lived on the dashboard widget's state as flat
fields — `currentFlightMaxRpm`, `lastFlightMaxRpm`, `lastMinVoltage` and the rest. Those names still
answer, mapped onto the record, so a theme written against them keeps working. They are deprecated:
new themes should read `state.flight` or use `stattype`.
