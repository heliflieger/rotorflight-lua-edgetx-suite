---
title: Custom telemetry sensors
sidebar_label: Telemetry sensors
---

# Custom telemetry sensors

Rotorflight sends most of its values in a custom frame that the radio does not understand by
itself. The suite unpacks that frame and hands each value to the radio as a telemetry sensor, so
`Vbat`, `Hspd`, `EscT` and the rest exist on the radio because something in the suite decoded
them. Which values are sent is chosen on the flight controller, on the
[Telemetry page](../pages/setup/telemetry.md); what turns them back into sensors is described
here.

Where that decoding runs — in the dashboard widget, or in the small script the suite can install
outside the widgets — is a separate subject:
[background decoder](background-decoder.md).

## Every sensor the Telemetry page offers is decoded

The page's catalogue and the decoder are kept in step deliberately: a sensor you can tick there
is one the suite can unpack. The list itself lives in the code
(`src/rfsuite/lib/rf2tlm_sensors.lua`), and that file is the authority — this page does not
repeat it, because a copy would go out of date the first time the flight controller gains a
sensor.

For the meaning of an individual value — what `Vbat` measures, what the governor states are —
see the [Rotorflight documentation](https://doc.rotorflight.org/); the suite does not
redefine them.

## A sensor the suite does not know stops the frame

This is the one property worth understanding, because it does not fail the way you would expect.

One frame carries several sensors packed one after another, each as an identifier followed by its
value. The decoder walks that frame from the front: it reads an identifier, looks it up, and uses
what it finds to know **how many bytes the value takes** before it can reach the next identifier.

So a sensor it does not recognise is not simply skipped. Without knowing the width, the decoder
cannot step over the value, and it stops walking the frame there. **Everything the flight
controller packed behind that sensor in the same frame is lost** — not once, but in every frame
that carries it, for as long as the sensor is selected.

What that looks like on the radio is a sensor that never appears, plus one or more *other*
sensors that also stop updating, with nothing to connect the two. Which ones depends on how the
flight controller happened to order that frame, so it can differ between models and between
flights.

**When it can happen:** running a flight controller firmware newer than your copy of the suite,
and selecting a sensor that firmware has added. The fix is to update the suite. Until then, a
workaround is to untick the unrecognised sensor on the Telemetry page, which restores everything
that was sitting behind it.

## An unchanged value is not sent again with every frame

The decoder hands a sensor to the radio when its value changes, and otherwise repeats it every two
seconds, well inside the time the radio keeps a sensor valid, so a hand-over that carries nothing
new is not repeated at frame rate.

Some sensors arrive together and are handed over as a group: the cell voltages (`Cel#` and
`Cels`), the GPS position, the adjustment pair (`AdjF`, `AdjV`), the control angles (`Ctrl`,
`CPtc`, `CRol`, `CYaw`, `CCol`), the attitude (`Attd`, `Ptch`, `Roll`, `Yaw`) and the
acceleration (`Accl`, `AccX`, `AccY`, `AccZ`). When anything in a group changes, the whole group
is sent again. That is deliberate: the radio works out the total of `Cels` only when the last
cell arrives, so sending just the cell that changed would leave the total behind.

A group whose values move in every frame is therefore sent as often as it arrives; the difference
shows where values hold still, on the bench and while the model stands.

The control, attitude and acceleration groups fill the same sensors as the individual values of
the same name, at the finer scale the flight controller sends the group in: the control angles
(`CPtc`, `CRol`, `CYaw`, `CCol`) and the acceleration (`AccX`, `AccY`, `AccZ`) with two decimals,
the attitude (`Ptch`, `Roll`, `Yaw`) with one. Selected individually, each of these sensors
carries one decimal fewer.

EdgeTX keeps the decimals a sensor was created with and converts every later value to them,
dropping the digits it has no room for. So whichever of the two arrives first decides how many
decimals the sensor shows, and the other is scaled to it; and a model that discovered these
sensors with an older version of the suite shows the right values with its old decimals (a pitch
of 12.3 degrees as 12) until the sensors are deleted and discovered again, or their precision is
set on the sensor's page.

## The two sensors the suite computes itself

Besides decoding what the flight controller sends, the suite works out the remaining fuel of
the pack, and it can publish two sensors of its own for it. What they are computed from is on
the [SmartFuel page](../pages/setup/power/smartfuel.md); what matters here is that they are the
suite's own values rather than the flight controller's.

**They are on by default, and can be switched off per flight controller** under *Configuration*
→ *Setup* → *Power* → *[Preferences](../pages/setup/power/preferences.md)*, with *Publish
SmFt / SmCp* — worth doing on a machine whose sensors nothing reads.

| Sensor | What it holds |
| --- | --- |
| `SmFt` | remaining fuel in percent, **with the reserve already taken off** |
| `SmCp` | the consumption the suite estimates, in mAh — published only where the suite estimates it from the pack voltage, because on the other paths the flight controller's own `Capa` already says it |

**`SmFt` is not the same number as `Bat%`.** The reserve is applied on the way to `SmFt` and not
on the way to `Bat%`, so `SmFt` reaches 0 while the pack still holds the reserve. That is what makes it worth building a logical switch,
a special function or a warning on, and it is why `Bat%` is not a substitute for one.

**The sensors are the export, not the route the value takes inside the suite.** The dashboard,
the per-flight statistics and the spoken announcements read the value the suite computed, in
the same script that computed it, and they work whether the sensors are published or not. The
two sensors exist for everything the suite cannot hand a value to directly: logical switches,
special functions, the radio's own telemetry screens, and the telemetry log on the card. That is
also why they can be switched off: each one occupies a telemetry slot, which is a price worth
nothing on a machine where nothing reads them.

Two things follow that are worth knowing:

- **A model has to carry the sensor before anything on the radio can use it.** As with any
  telemetry sensor, the value reaches a logical switch or a telemetry screen only once the
  model has the sensor — discover it once on the radio's own telemetry page. The dashboard does not depend on that and shows the right value either way.
- **Switching it off again does not delete the sensor.** It stops being updated and ages out
  like any sensor that has stopped arriving; the row goes away on the radio's telemetry page.
- **The dashboard is no longer limited to whole percent.** A telemetry sensor here carries no
  decimals, so `SmFt` is a whole number; the value the dashboard works from is not rounded, and
  it can therefore differ from `SmFt` by one. What a gauge or a readout prints is the theme's
  decision, and the themes shipped here show whole percent.

## The two counters the decoder adds

Besides the flight controller's own values, the decoder creates two sensors of its own:

| Sensor | What it counts |
| --- | --- |
| `*Cnt` | custom telemetry frames received since the model connected |
| `*Skp` | frames the radio link dropped, detected from a gap in the frame numbering |

`*Cnt` rising is the simplest confirmation that custom telemetry is arriving at all; `*Skp`
rising alongside it points at the radio link rather than at the flight controller. They are
ordinary sensors and can be deleted on the radio's own telemetry screen if you do not want the
rows — nothing in the suite depends on them being visible.

## Related

- [SmartFuel page](../pages/setup/power/smartfuel.md) — where `SmFt` and `SmCp` are configured
- [Telemetry page](../pages/setup/telemetry.md) — where the sensors are selected
- [Background decoder](background-decoder.md) — where the decoding runs
- [Rotorflight documentation](https://doc.rotorflight.org/) — what each value means

*Documented against RFSuite 0.1.7.*
