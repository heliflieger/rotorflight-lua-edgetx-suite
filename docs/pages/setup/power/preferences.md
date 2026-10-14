---
title: Power Preferences
sidebar_label: Preferences
sidebar_position: 50
---

# Power Preferences

The power settings that belong to the radio rather than to the flight controller: what kind of
model this is, which SmartFuel estimate to fall back on when the board computes none, whether
SmartFuel's two telemetry sensors are published, and the current limit the speed controller is
set to allow.

## Where to find it

*Configuration* → *Setup* → *Power* → *Preferences*

Always available.

## Settings

| Setting | What it does |
| --- | --- |
| Model Type | What the suite treats this machine as for the fuel estimate and for the announcements: *AUTO*, *ELECTRIC* or *NITRO*. Default *AUTO*, which decides from the battery telemetry. |
| Local SmartFuel Source | Which estimate the suite computes itself when the flight controller does not: *CURRENT*, *VOLTAGE* or *COMBINED*. Default *CURRENT*. Used where the board computes none itself (Firmware Source *OFF (LOCAL)*) — see the [SmartFuel page](smartfuel.md), whose three tuning values it unlocks when it is *VOLTAGE* or *COMBINED*. |
| Publish SmFt / SmCp | Whether the remaining fuel and the estimated consumption are published as the `SmFt` and `SmCp` telemetry sensors. **On by default**, which is what the suite has always done; turn it off on a machine whose sensors nothing reads. |
| ESC Current Limit | The current limit the speed controller is set to allow, in amps, and the figure the dashboard's ESC load reading is a percentage of. *NOT SET* is the default and means there is no reading. |

## The ESC current limit, and why it is usually already filled in

The dashboard can show the current as a percentage of what the speed controller allows rather
than as a number of amps, which is the figure a pilot can judge without knowing the controller.
That needs the limit, and the limit is not something to ask for where it can be read.

Three of the ten supported families carry the limit in their own parameter block — AM32,
Scorpion and YGE. Opening that family's page under *ESC Tools* reads the block anyway, and the
limit is taken from it and stored here in the same step. Nothing is asked of the flight
controller for it and nothing is added to the connect sequence; the figure is a by-product of a
page that was opened for another reason. A later visit that finds the same limit writes nothing.
If the preferences cannot be written to the card at that moment, the limit is not kept, and the
next visit to the page tries again.

The remaining seven families do not report one, and that is what this row is for. Typed in by
hand it behaves in every other respect the same way. A controller that reports a limit of zero --
which is how all three spell "no limit set" -- is not remembered, so a figure typed in by hand is
left alone rather than being wiped by a controller that has none.

Left at *NOT SET* — and that includes every machine until one of the two routes above has
supplied a figure — a dashboard tile whose source is `esc_load` shows `--` rather than a reading.

## Notes

- **The settings are stored per flight controller**, in this machine's own file on the card, not
  per radio and not per model. Plugging a different board in brings its own values up. A save
  that file does not take shows *Save failed* with the reason, for example *the settings file
  could not be written to the SD card*.
- ***Publish SmFt / SmCp* only matters for things outside the suite.** The dashboard, the
  per-flight statistics and the spoken announcements read the value directly from the script that
  computes it and are unaffected by this setting either way. Logical switches, special functions,
  the radio's own telemetry screens and the telemetry log can only read a sensor, so they need it
  on. What the two sensors hold is described under
  [custom telemetry sensors](../../../reference/telemetry-sensors.md).
- **Turning it off is worth it only on a machine whose sensors nothing reads**, and what it saves
  is two of the model's telemetry slots plus a model write on every update of them.
- **Switching it off does not delete a sensor the model already has.** `SmFt` stops being
  updated and ages out like any sensor that has stopped arriving; remove the row on the radio's
  own telemetry page if you do not want it there.
- What the manufacturer means by the ESC current limit -- a continuous rating or a peak -- is not
  something the parameter block says, so it is described here as the limit the controller is set
  to allow and nothing more.
- The ESC current limit is the speed controller's, not the flight controller's. It is unrelated
  to the battery alerts under *Setup* → *Power* → *Alerts*, which are the radio's: they are
  kept in the same file on the card as these settings, checked by the suite on the radio, and
  nothing of them is written to the flight controller.
- An ESC load reading above 100 % is not an error: it means the controller is being asked for
  more than its configured limit, which is the condition worth seeing.

## Related

- [SmartFuel page](smartfuel.md) — the estimate the flight controller computes, and its tuning
- [Custom telemetry sensors](../../../reference/telemetry-sensors.md) — what `SmFt` and `SmCp` hold
- [Rotorflight documentation: SmartFuel](https://doc.rotorflight.org/setup/smartfuel/)
- [Dashboard themes](../../../developer/dashboard-themes.md) — the `esc_load` box source, its
  unit and a sensible gauge range.

*Documented against RFSuite 0.1.7.*
