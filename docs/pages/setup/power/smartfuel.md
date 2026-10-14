---
title: SmartFuel
sidebar_label: SmartFuel
sidebar_position: 40
---

# SmartFuel

How the remaining fuel of the pack is estimated: from the current drawn, from the pack
voltage, or from whichever of the two is more pessimistic, and how quickly a voltage-based
estimate may fall under load.

## Where to find it

*Configuration* → *Setup* → *Power* → *SmartFuel*

Needs MSP API 12.09; hidden on an older flight controller. Read-only while the model is
armed.

## Settings

| Setting | What it does |
| --- | --- |
| Firmware Source | Which estimate the flight controller computes: *OFF (LOCAL)*, *VOLTAGE*, *CURRENT* or *COMBINED*. Combined takes the more pessimistic of voltage and current. |
| Voltage drop rate | How fast the filtered voltage may fall in voltage mode, so that a brief sag under load does not pull the estimate down. 0 to 250 mV/s, default 10. |
| Charge drop rate | How fast the reported fuel may drop in voltage mode once the model has been armed. 0.00 to 2.50 %/s in steps of 0.01, default 0.50. |
| Sag gain | Strength of the load-sag compensation in voltage mode; higher compensates more aggressively. Raise it if the estimate reads too low under load in flight. 0 to 100 %, default 40. |

The three tuning values apply to an estimate with a voltage track, and are greyed out
elsewhere: they can be edited with Firmware Source *VOLTAGE* or *COMBINED*, and with *OFF (LOCAL)*
when the local source under *Power* → *Preferences* is *VOLTAGE* or *COMBINED*.

## Notes

- Saving writes the settings to the flight controller and keeps a copy in this model's
  preferences on the radio. It waits until the page has read the flight controller's settings on
  this visit: until then what it shows may be an earlier read, or its own defaults with the source
  *OFF (LOCAL)*. Where that copy cannot be written, the notice says the model's
  settings were not saved and why — for example *the settings file could not be written to the
  SD card*.
- With *OFF (LOCAL)* the radio computes the estimate itself, from the local source set under
  *Power* → *Preferences*. Its voltage estimate (local source *VOLTAGE*) uses the same three
  tuning values.
- The radio's own estimate takes the cell count configured on the flight controller's *Battery*
  page. Where that is 0 (auto-detect), it takes the count the flight controller detected when the
  pack was plugged in (sensor `Cel#`), and infers one from the pack voltage only where neither is
  available.

## Related

- [Custom telemetry sensors](../../../reference/telemetry-sensors.md) — what `SmFt` and `SmCp` are, and what can read them
- [Rotorflight documentation: SmartFuel](https://doc.rotorflight.org/setup/smartfuel/)

*Documented against RFSuite 0.1.6.*
