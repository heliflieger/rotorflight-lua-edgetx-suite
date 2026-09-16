---
title: Battery
sidebar_label: Battery
sidebar_position: 10
---

# Battery

The pack the flight controller is flying: which of its six battery profiles is selected, the
capacity stored in each of them, the cell count, the four per-cell voltage levels the alarms
are built on, and how much of the pack is held back as a reserve.

## Where to find it

*Configuration* → *Setup* → *Power* → *Battery*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Selected Battery | Which of the flight controller's six battery profiles is active. Switching it here switches it on the board. |
| Battery 1 … Battery 6 | The capacity stored in each profile, 0 to 40000 mAh. All six are written on every save, so a capacity can be edited without selecting its profile. |
| Max cell voltage | The per-cell voltage above which the high-voltage alarm fires. 2.50 to 5.00 V, default 4.20. |
| Full cell voltage | The nominal voltage of a fully charged cell, which is what a full pack is measured against. 2.50 to 5.00 V, default 4.10. |
| Warn cell voltage | The per-cell voltage at which the low-voltage alarm starts. 2.50 to 5.00 V, default 3.50. |
| Min cell voltage | The minimum per-cell voltage, below which the low-voltage alarm is triggered. 2.50 to 5.00 V, default 3.30. |
| Cell count | Cells in the pack, 0 to 24. 0 lets the flight controller work it out from the pack voltage. |
| Consumption reserve | How much of the capacity is held back, so that the fuel reading reaches zero with that much of the pack left. 15 to 60 %, default 35. |

## Notes

- **The selected profile is sent only when it is changed here.** The page has no way to ask
  the flight controller which battery profile is active: `MSP_BATTERY_CONFIG` carries no
  profile field, and the `BatP` telemetry sensor that would answer is part of the custom CRSF
  sensor set, so it does not exist on a native CRSF link. Where there is no answer the combo
  shows the first profile, because it has to show something — and a save made in that state
  leaves the board's profile alone rather than switching it to the one on screen. Selecting a
  profile on this page always sends it.
- Saving writes the whole battery configuration to the flight controller and commits it to the
  board's own storage.
- The Consumption reserve is also kept in this model's preferences on the radio, and is written
  to the flight controller only when it is edited here. What it is used for is on the
  [SmartFuel](smartfuel.md) page.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/) — the battery profiles and the
  voltage levels themselves are the flight controller's

*Documented against RFSuite 0.1.7.*
