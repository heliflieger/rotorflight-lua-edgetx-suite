---
title: System Status
sidebar_label: System Status
sidebar_position: 57
---

# System Status

The two packed status sensors of the flight controller, decoded: *System Status* (CRSF `STAT`,
S.Port `5140`) carries the live state -- armed, airborne, failsafe, rescue, governor state and
more -- and *System Config* (CRSF `SCFG`, S.Port `5141`) the slower configuration -- the three
profiles, unsaved changes, which sensors the board has, the governor mode. The page to open when a
value the suite takes from these sensors looks wrong, or to see whether the two sensors arrive at
all.

## Where to find it

*System* → *Tools* → *Diagnostics* → *System Status*

Available without a connection to the flight controller: the page reads the radio's telemetry
sensors and sends nothing. Read-only while armed, like the other diagnostics pages: the tool
pauses its pages while the model is armed, so a page left open keeps the values of its last read
until the model is disarmed. The flight controller sends the two sensors from MSP API 12.10 on,
when they are in its telemetry sensor list.

## What it shows

The page has no settings. It reads the sensors twice a second while it is open, and the values
change in place.

**For each of the two sensors:**

| Row | What it shows |
| --- | --- |
| System Status / System Config | *Receiving* while values arrive; *Not current* once the sensor has stopped arriving or the link is down (the last value stays on the page); *Not received* when the model has the sensor but no value has arrived since the model was loaded; *No sensor* when the model has no such sensor. |
| Sensor | The name of the radio sensor that is read: `STAT` / `SCFG` on CRSF, `5140` / `5141` on S.Port. |
| Raw value | The 32-bit value as it arrived, in hexadecimal. |

**How the values are packed.** Each of the two sensors is one 32-bit number made of bit fields.
A *flag* is one bit and reads *Yes* (1) or *No* (0). A *number* field holds a small integer, and
the page shows it as the name the flight controller gives that value; a number the page has no name
for is shown as the number itself. Bits not listed below are reserved and read 0. The layout is the
firmware's own (`src/main/telemetry/status.h` in the Rotorflight firmware).

### System Status (`STAT` / `5140`)

The live state of the craft.

| Row | Bits | Kind | What it means |
| --- | --- | --- | --- |
| Armed | 0 | flag | The flight controller is armed. |
| Airborne | 1 | flag | The flight controller considers the craft in the air. |
| Motors running | 2 | flag | A motor is being driven. |
| RX link up | 3 | flag | The flight controller is receiving the radio's signal. |
| Failsafe phase | 6-8 | number | Where the flight controller's failsafe stands, see below. |
| GPS fix | 9-10 | number | 0 *None*, 1 *Fix*, 2 *Fix and home* (a fix, and the home position is set). |
| GPS healthy | 11 | flag | The GPS module is talking to the flight controller. |
| Spooled up | 12 | flag | The rotor has reached its spooled-up state. |
| Battery state | 14-16 | number | The battery monitor's verdict, see below. |
| Control saturated | 17 | flag | Cyclic, yaw or collective hit a mixer limit within the last half second. |
| Gyro overflow | 18 | flag | The gyro reported an overflow. |
| ACC not calibrated | 19 | flag | The board has an accelerometer and it has never been calibrated. |
| Override active | 20 | flag | A servo, motor or mixer override from the Configurator is on. |
| Rescue state | 21-23 | number | Where the rescue mode stands, see below. |
| Blackbox logging | 24 | flag | The Blackbox is writing a log. |
| Governor state | 25-28 | number | The governor's state, see below. |

**Failsafe phase**

| Value | Shown as | Meaning |
| --- | --- | --- |
| 0 | Idle | No failsafe; the signal is good. |
| 1 | RX loss detected | The signal has been lost long enough to start the failsafe procedure. |
| 2 | Landing | The auto-landing failsafe procedure is running. |
| 3 | Landed | The failsafe procedure has finished and the craft is disarmed. |
| 4 | RX loss monitoring | The signal is back; the flight controller waits for it to stay good before it allows arming again. |
| 5 | RX loss recovered | The signal has recovered and the failsafe is over. |
| 6 | GPS rescue | The GPS rescue failsafe procedure is running. |

**Battery state.** The worse of the voltage verdict and the charge verdict.

| Value | Shown as | Meaning |
| --- | --- | --- |
| 0 | OK | Neither the voltage nor the charge has reached its warning level. |
| 1 | Warning | The voltage has stayed at or below the warning level for the set time, or the charge has dropped to the warning percentage. |
| 2 | Critical | The voltage has stayed at or below the critical level for the set time, or the charge is used up. |
| 3 | Not present | No battery is detected. |
| 4 | Init | The battery monitor is starting up, or re-evaluating the battery after a battery profile change. |

**Rescue state**

| Value | Shown as | Meaning |
| --- | --- | --- |
| 0 | Off | Rescue is not active. |
| 1 | Pull-up | Rescue is pulling the craft up. |
| 2 | Flip | Rescue is flipping the craft upright. |
| 3 | Climb | Rescue is climbing. |
| 4 | Hover | Rescue is holding a hover. |
| 5 | Exit | Rescue is handing control back to the pilot. |

**Governor state.** The names are the ones the suite already uses for its governor announcements.

| Value | Shown as | Firmware state | Meaning |
| --- | --- | --- | --- |
| 0 | Off | `THROTTLE_OFF` | Throttle is off. |
| 1 | Idle | `THROTTLE_IDLE` | Throttle is at idle. |
| 2 | Spool-up | `SPOOLUP` | The rotor is spooling up to the target headspeed. |
| 3 | Recovery | `RECOVERY` | A fast re-spool after a throttle hold or a fallback, which assumes the craft is in the air. |
| 4 | Active | `ACTIVE` | The governor holds the headspeed. |
| 5 | Throttle off | `THROTTLE_HOLD` | Throttle hold is on. |
| 6 | Lost headspeed | `FALLBACK` | The RPM signal is gone; the governor falls back and drops throttle on purpose, to warn the pilot. |
| 7 | Autorotation | `AUTOROTATION` | Autorotation. |
| 8 | Bailout | `BAILOUT` | An autorotation is being abandoned and the rotor spools back up. |
| 9 | Bypass | `BYPASS` | The governor passes throttle straight through, without its safeguards. |

### System Config (`SCFG` / `5141`)

Configuration and hardware state, which changes rarely.

| Row | Bits | Kind | What it means |
| --- | --- | --- | --- |
| PID profile | 0-2 | number | The active PID profile, counted from 1. |
| Rate profile | 3-5 | number | The active rate profile, counted from 1. |
| Battery profile | 6-8 | number | The active battery profile, counted from 1. |
| Unsaved changes | 12 | flag | Settings were changed on the flight controller and not saved yet. |
| Saving | 13 | flag | The flight controller is writing its settings right now. |
| Reboot required | 14 | flag | A changed setting takes effect only after a reboot. |
| Beeper on | 15 | flag | The flight controller's beeper is sounding, for example the lost-model alarm. |
| ACC present | 16 | flag | The board has an accelerometer. |
| Baro present | 17 | flag | The board has a barometer. |
| Mag present | 18 | flag | The board has a magnetometer. |
| GPS present | 19 | flag | A GPS is configured. |
| Blackbox full | 21 | flag | The Blackbox storage is full. |
| RPM source active | 22 | flag | Motor RPM telemetry is arriving at the flight controller. |
| Governor mode | 23-25 | number | The configured governor mode, see below. Unlike the governor state, this is a setting. |

**Governor mode**

| Value | Shown as | Meaning |
| --- | --- | --- |
| 0 | OFF | No governor. |
| 1 | LIMIT | Limit mode. |
| 2 | DIRECT | Direct mode. |
| 3 | ELECTRIC | Electric mode. |
| 4 | NITRO | Nitro mode. |

What each governor mode does is in the Rotorflight documentation.

**An example.** A raw System Status value of `0x00000008` has only bit 3 set: *RX link up* is
*Yes*, every other flag is *No*, and every number field is 0 -- failsafe *Idle*, GPS fix *None*,
battery *OK*, rescue *Off*, governor *Off*.

A field the firmware was built without (no GPS, no accelerometer) reads *No*, or its first value.

**Shared fields.** Five fields are also sent as sensors of their own: arm state (`ARM`), governor
state (`Gov`), PID profile (`PID#`), rate profile (`RTE#`) and battery profile (`BAT#`). Each is
shown twice, *Packed* as decoded from the packed sensor and *Own sensor* as its own sensor reads,
so the two sources can be compared on a real link. A value that disagrees reads *(differs)*; an
own sensor the model does not have, or that has not arrived, says so instead of a value. For
`ARM`, only its ARMED bit is compared: the sensor carries all arming flags, the packed sensor only
that one.

When neither packed sensor is received, the page says so in one line instead of the rows.

## Notes

- **A sensor the model does not have is not read.** The radio creates a telemetry sensor when the
  first value arrives while sensor discovery is on. If the flight controller sends both sensors and
  the page still says *No sensor*, run *Discover new sensors* on the model's telemetry page.
- **Which sensors the flight controller sends is set on the flight controller.** This suite's
  *Telemetry* page (*Configuration* → *Setup* → *Telemetry*) offers *System Status* and *System
  Config* on MSP API 12.10 and later.
- **Reload looks for every sensor again**, after one was discovered or deleted while the page was
  open. A sensor the model does not have is otherwise looked for again every two seconds.
- **Where the suite uses these sensors:** arm state, governor state and the three profiles are
  read from their own sensors, and from the packed sensors only when the own sensor is missing.
  This page shows both, whichever the suite uses.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.1.7.*
