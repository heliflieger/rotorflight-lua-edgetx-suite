---
title: Model
sidebar_label: Model
sidebar_position: 130
---

# Model

Settings the flight controller stores for this model: three parameters it applies to the
radio's timers or global variables on connect, and the radio-side features it asks for.
They are stored on the board, so they travel with the helicopter rather than with the radio,
and a second radio flying the same craft gets them too.

## Where to find it

*Configuration* → *Setup* → *Model*

Greyed out until the flight controller answers. Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Parameter 1 to 3 Type | What the slot sets on the radio when the flight controller connects: *None*, one of the radio's three timers (*Timer 1* to *Timer 3*), or a global variable (*GV1* to *GV9*). |
| Parameter 1 to 3 Value | The value written into that timer or global variable. -32000 to 32000; greyed out while the slot's type is *None*. |
| Synchronize Model Parameters | Whether this radio applies the three parameters on connect at all. Stored on this radio, for every model. |
| Set Model Name on the Radio | Whether the radio's model is renamed after the craft name the flight controller reports. From MSP API 12.09 the flight controller carries this decision and the switch writes it there; on older firmware the switch is a preference of this radio and applies to every model. Only one of the two is ever shown. |

## Notes

- Saving writes the parameters and the model-name flag to the flight controller; the two
  radio-wide switches are saved on the radio.
- The announcements at connect (the model name, the initial fuel) are switched under
  *System* → *Settings* → *Audio* → *Events*, not here.

*Documented against RFSuite 0.1.6.*
