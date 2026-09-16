---
title: SmartFuel
sidebar_label: SmartFuel
sidebar_position: 40
---

# SmartFuel

How the remaining fuel of the pack is estimated: from the current drawn, from the pack
voltage, or from whichever of the two is more pessimistic, and how quickly a voltage-based
estimate may fall and recover under load.

## Where to find it

*Configuration* → *Setup* → *Power* → *SmartFuel*

Needs MSP API 12.09; hidden on an older flight controller. Read-only while the model is
armed.

## Settings

| Setting | What it does |
| --- | --- |
| Firmware Source | Which estimate the flight controller computes: *OFF (LOCAL)*, *VOLTAGE*, *CURRENT* or *COMBINED*. Combined takes the more pessimistic of voltage and current. |
| Voltage drop rate | How fast the filtered voltage may fall in voltage mode, so that a brief sag under load does not pull the estimate down. 0 to 250 mV/s, default 10. |
| Charge drop rate | How fast the reported fuel may recover in voltage mode once the load is reduced. 0.00 to 2.50 %/s in steps of 0.01, default 0.50. |
| Sag gain | Strength of the load-sag compensation in voltage mode; higher compensates more aggressively. 0 to 100 %, default 40. |

The three tuning values are greyed out unless the source is *VOLTAGE* or *COMBINED*.

## Notes

- Saving writes the settings to the flight controller and keeps a copy in this model's
  preferences on the radio.
- The page also carries a *Local Source* selector (*CURRENT*, *VOLTAGE*, *COMBINED*) for a
  flight controller whose firmware has no SmartFuel. Such a flight controller does not show
  the tile at all, by the API-version rule above, so the selector is normally not seen.

## Related

- [Rotorflight documentation: SmartFuel](https://www.rotorflight.org/docs/setup/smartfuel)

*Documented against RFSuite 0.1.6.*
