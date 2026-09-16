---
title: Accelerometer
sidebar_label: Accelerometer
sidebar_position: 40
---

# Accelerometer

Read and adjust the roll and pitch accelerometer trims, or calibrate the sensor on
the installed flight controller. The accelerometer measures the model's orientation
relative to the horizon for self-leveling and rescue.

## Where to find it

*Configuration* → *Setup* → *Accelerometer*

Read-only while the model is armed. Calibration also checks the flight controller's
arming status and accelerometer presence before sending the start command.

## Settings

| Setting | What it does |
| --- | --- |
| Roll | Roll trim, from -300 to 300 in the page's displayed degree units. |
| Pitch | Pitch trim, from -300 to 300 in the page's displayed degree units. |
| Save | Writes the edited trims to EEPROM. |
| Reload | Reads the trims from the flight controller again. |
| Star / Calibrate | Starts accelerometer calibration after confirmation. |

## Calibration

Disarm the model and place it level and still **before confirming**. Keep it still
until the completion notice appears. The start command's acknowledgement is only a
receipt; the page waits for the controller's calibration flag to become active and
then clear. The controller saves the result itself, so calibration sends no extra
EEPROM write. The page then reads the trims again.

Save, Reload and another calibration are blocked while the operation is pending.
An armed controller, a missing accelerometer or an already running calibration is
reported without starting another calibration.

The page first shows **Checking**, then **Starting** while awaiting the command's
acknowledgement, and **Calibrating** only after that acknowledgement. These displays
have no progress bar because the controller does not report a percentage.

Preflight status and the start request use the shared queue's reply timeout (two
seconds by default). After the start acknowledgement, each status request has one
attempt and a 0.5-second reply window. Missing or invalid samples leave monitoring
active; they cannot report success or end it on their own.
Preflight and the start request each have a separate five-second bound. The full
15-second completion window begins when the start acknowledgement arrives.

**Calibration not started** means this page did not request calibration: the check
was refused, no valid preflight status arrived, or the connection or calibration
support was unavailable before the start request.

**Calibration not confirmed** explains what was observed after requesting a start: a
missing start acknowledgement, connection loss, interrupted monitoring, no active
calibration seen, or an observed start without a confirmed finish. In the last case,
keep the model still, then reload the trims and verify calibration on the controller.
A missing calibration module or queue instead asks you to check the RFSuite installation.

These notices do not cancel calibration on the controller. Keep the model still
before checking its result or trying again. If the entire active interval passes
between status replies, the result stays unconfirmed: a clear flag alone cannot prove
a new calibration ran. Leaving the page stops its monitoring, not an operation already
started on the controller.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)
- [Issue 302](https://github.com/rotorflight/rotorflight-lua-edgetx-suite/issues/302)

*Documented against RFSuite 0.1.7.*
