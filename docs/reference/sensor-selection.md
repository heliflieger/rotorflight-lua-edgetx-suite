---
title: How a value finds its telemetry sensor
sidebar_label: Sensor selection
---

# How a value finds its telemetry sensor

The suite asks for values by what they are -- fuel, voltage, headspeed, current, link quality --
and the radio holds telemetry sensors with four-character names. This page is what sits between
the two: how a value is matched to one of the model's sensors, how long that choice lasts, and
why a sensor the radio has never sent is not taken for a reading of zero.

It applies everywhere a telemetry value is used: the dashboard widget, the audio announcements,
the flight log and the flight record.

## Choosing a sensor

Each value has a list of sensor names, most preferred first -- fuel is looked for as `Bat%`,
then `Fuel`, then `fuel`. The list is tried in order and the first name that answers is taken.
That choice is then remembered, so later passes read the chosen sensor directly instead of
searching again.

Where a value has been matched to something other than the first name on its list, the first name
is re-tried every few seconds, and the value moves back to it as soon as it starts answering.
That covers a sensor which appears late -- the flight controller's own values arrive a moment
after the link comes up, and two of them the suite publishes itself.

A value the model carries no sensor for at all -- no altimeter, no BEC voltage, no ESC
temperature -- would otherwise be searched for on every pass, for the whole flight. Those searches
are spaced out instead: the first retry comes after about two seconds and the wait doubles up to
half a minute.

## Why a sensor the radio has never sent is not a reading of zero

A model keeps the sensors it has ever seen. Load a model that flew with a sensor the radio is no
longer receiving -- the value was switched off in the flight controller's telemetry set, an ESC
that is not on the bus today, a receiver that has not been powered up -- and the row is still
there in *Model* -> *Telemetry*, with nothing to say it is stale.

Asked for such a row, the radio answers **zero**, not "no value". Zero is a perfectly good
reading, so a stale row can be mistaken for a working sensor that happens to read nothing, and the
value then stays at zero for as long as the model is loaded. For fuel that is the number the
SmartFuel calculation publishes, the callouts speak and the flight log records.

The suite therefore asks a second question of any sensor reading zero, and takes the reading only
where the radio has actually received that sensor. A row that has never arrived is treated as
missing rather than as zero.

**What that question can and cannot separate.** It separates *"nothing has arrived for this sensor
since the model was loaded"* from *"something has"*. It does **not** tell a sensor that fell silent
a moment ago from one that is still arriving: a sensor which stops mid-flight keeps its last
reading, and a link that drops does not undo what has already arrived. That is the radio's own
behaviour, not something the suite can see behind.

## What you will see

- **The fuel callout** says nothing for a fuel row the radio is not sending, where it used to
  announce 0 %.
- **The flight log** leaves its minimum-fuel columns empty for such a flight instead of filling
  them with a zero that was never measured.
- **The dashboard is unchanged.** Every telemetry value it keeps starts at zero and is only
  overwritten by a reading that arrived, so a value with no sensor behind it shows `0` there
  before and after. Making those tiles show `--` is a separate gate and this is not it.

## When the choice is made again

The sensor chosen for a value is forgotten in three places, and it is worth knowing which,
because they are not the same event:

- **The dashboard widget and the tool** each forget the choice on their own link edges, so a
  session that begins after a reconnect matches everything again from the top of its list. That
  matching is spread over the first few reads -- normally no more than four values start their
  search in one pass -- so after a reconnect the dashboard's values appear over about two seconds rather than
  all on the first read, and somewhat later where other readers in the same pass start searches
  of their own. The same applies when the widget starts.
- **The radio's own telemetry reset** -- which happens when a model is loaded, when the radio is
  switched on, and on *Reset Telemetry* -- is what puts the sensor rows themselves back to "never
  received". That is the event the zero test above is measured against.

A link that merely drops does neither of those to the rows: what has already been received stays
received until one of the resets above. So a model flown with a different ESC, or with a value
switched on since, picks up the right sensor when it is next loaded rather than in the middle of
a session.

## Related

- [No connection to the flight controller](../troubleshooting/no-connection.md) -- when nothing
  off the flight controller is shown at all, rather than one value.
- [Collecting logs](../troubleshooting/collecting-logs.md) -- the suite's log names the sensor
  each value was matched to when the debug level is raised.
- [Flight statistics](flight-statistics.md) -- what the flight record keeps, and which values it
  reads through this layer.
