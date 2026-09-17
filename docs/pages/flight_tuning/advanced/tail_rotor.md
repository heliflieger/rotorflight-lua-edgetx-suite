---
title: Tail Rotor
sidebar_label: Tail Rotor
sidebar_position: 60
---

# Tail Rotor

Fine-tunes the yaw axis: stop acceleration, feedforward precompensation from cyclic and collective inputs, inertia precompensation, and motorized-tail torque assist.

## Where to find it

*Configuration* → *Flight Tuning* → *Advanced* → *Tail Rotor*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Yaw stop gain (CW / CCW) | Higher stop gain makes the tail stop more aggressively upon releasing the yaw stick. Adjust CW and CCW independently to make clockwise and counter-clockwise yaw stops symmetric. Range: 0 to 250. |
| Precomp Cutoff | Frequency filter cutoff for yaw precompensation actions. Range: 0 to 250 Hz. |
| Cyclic FF gain | Tail precompensation gain for cyclic stick movements. Counteracts main-rotor torque changes caused by cyclic inputs before yaw error develops. Range: 0 to 250. |
| Collective FF gain | Tail precompensation gain for collective pitch changes. Counteracts main-rotor drag changes caused by collective pitch changes. Range: 0 to 250. |
| Inertia Precomp (Gain / Cutoff) | *MSP API 12.08 and later.* Precompensation for rotor inertia during rapid headspeed or load transients. Range: Gain 0 to 250, Cutoff 0.0 to 25.0 Hz. |
| Collective Impulse FF (Gain / Decay) | *MSP API 12.07 and earlier.* Impulse precompensation at the onset of sudden collective stick movements. Range: Gain 0 to 250, Decay 0 to 250. |
| Tail Torque Assist (Gain / Limit) | *MSP API 12.09 and later.* Assists motorized tails by temporarily raising main-rotor headspeed to produce counter-torque. Gain sets the response strength; Limit caps the maximum headspeed boost (0 to 100%). Active only when the governor mode is enabled. |

## Notes

- Editing Tail Torque Assist writes to the flight controller's governor profile (`MSP_SET_GOVERNOR_PROFILE`), while the remaining settings write to the active PID profile (`MSP_SET_PID_PROFILE`).
- If the governor profile cannot be read from the flight controller during page load, the Tail Torque Assist controls are disabled to protect unread governor settings from being overwritten with default values.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)

*Documented against RFSuite 0.1.7.*
