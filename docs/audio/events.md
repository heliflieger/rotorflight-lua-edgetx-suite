---
title: Audio Events
sidebar_label: Events
sidebar_position: 10
---

# Audio Events

The suite provides spoken voice alerts and tone callouts for flight telemetry, battery status, system state, and flight controller notifications. Audio events are configured under:

*System* → *Settings* → *Audio* → *Events*

The nine category pages share a common configuration table (`preferences.audio_events`), stored with the radio in `/SCRIPTS/TOOLS/rfsuite.user/preferences.lua` with model-specific overrides (such as the ESC temperature threshold) in each flight controller's own file beside it. See [Configuration files](../reference/configuration-files.md).

A save that cannot be stored reports *Save failed* with the reason: *the settings file could not be written to the SD card* where the card refused a file, and *model settings store not available* where the part of the suite that writes the model's own file could not be loaded.

---

## Categories & Settings

Every row on these pages has a `?` button beside its control, which opens a short explanation of that row. The `?` in the page header says what the page is for.

### 1. On Connect

What is said once when a model connects. On a quick connect the model's name and the pack check come on the first pass after the connection (the dashboard starts its announcements once the battery configuration has been read from the flight controller), the battery capacity one pass later, and the SmartFuel level last; on a slow connect the battery capacity can come before the pack check. The rows are listed in the quick-connect order.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Model Name | `model_announcement` | Off | Radio | Plays the sound file named after the model, `/SOUNDS/<name>.wav` (a name with spaces is also looked up with underscores), once when the model connects. The name is the craft name read from the flight controller when it is already known, otherwise the radio's model name. Nothing is said when the card has no such file. |
| Pack Not Full | `pack_not_full` | Off | Radio | Once when the model connects: a warning when the pack's voltage per cell is below the flight controller's *Max cell voltage* (*Setup* → *Power* → *Battery*) less the margin below. The voltage is spoken as set under *Voltage* → *Announce as*: the pack voltage by default, or the voltage per cell. Judged once per connection and then latched. |
| Margin (mV/cell) | `pack_not_full_margin` | 100 mV | Radio | How far below *Max cell voltage* a cell may be and still count as full (10 to 500 mV per cell). |
| Battery Capacity | `battery_profile` | On | Radio | Speaks the capacity of the active battery profile in mAh (e.g. "Battery 5000 mAh") when the model connects and whenever the battery profile changes; the profile number when that profile has no capacity set. Needs the Battery Profile sensor (97) or System Config (121); without either, nothing is spoken on connect. |
| SmartFuel | `initial_fuel` | On | Radio | Speaks the remaining SmartFuel percentage (e.g. "Battery 95%") once after the model connects. Independent of the *SmartFuel* switch on the SmartFuel page, which governs the descending callouts and the empty alarm. |

#### When the SmartFuel Level Is Spoken
To prevent spurious "Battery 0%" announcements at startup:
- **Telemetry Guard (`fuelTelemetrySeen`):** The announcement is held until valid fuel telemetry has been delivered by the flight controller or SmartFuel.
- **Dynamic Deferral Window:** When the model connects, the announcement is deferred for a window derived from the model's SmartFuel stabilization delay (`stabilize_delay`, defaulting to at least 8.0 seconds).
- **Carried-Over Reading Detection:** EdgeTX retains the last received sensor reading across disconnections. If a new connection reports a reading bit-identical to the previous session's disconnect value (`previousSessionFuel`), it is treated as a carried-over reading and held until the new pack's fresh reading arrives.
- **Immediate vs. Timed Callout:** As soon as a positive, fresh reading arrives (`fuel > 0` and different from the previous pack), the percentage is spoken immediately. If no positive reading has arrived by the end of the window, the reading at that moment is spoken, so a SmartFuel value that has not come up yet is announced as 0%.

A sound pack without the announcement's file (`evt/battery.wav` for an electric model, `stat/alerts/fuel.wav` for nitro) has nothing to play. Once the choice between the two files can no longer change (the model type is set explicitly, the battery configuration has been read from the flight controller, or the pack carries neither file), the announcement counts as made for that connection: nothing is spoken and one warning in the log says which file is missing. Until then it is tried again on every pass, because a model whose type is not yet known may still turn out to need the file the pack does carry.

### 2. Arming

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Arming flags | `arming_flags` | On | Radio | Announces arming ("Armed") and disarming ("Disarmed"). |

### 3. Governor

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Governor state | `governor_state` | On | Radio | Spoken announcements when the governor transitions between operating states (Idle, Spool-up, Recovery, Active, Throttle off, Lost headspeed, Autorotation, Bailout, Bypass). A state is spoken once it has held for a moment. Individual states can be toggled independently. |

### 4. Voltage

Monitors the main pack voltage and the model's power supply.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Voltage alert | `voltage_alert` | On | Radio | Voice alert when the pack voltage drops below the warning threshold, the flight controller's warning cell voltage times the cell count. The voltage the alert fired at is spoken with it, as set under *Announce as*. |
| Hold | `voltage_hold` | 2 s | Radio | How long the reading has to stay below the warning threshold before the alert speaks (0 to 10 s). A hold of 0 announces on the first reading below the level, which is the behaviour before this setting existed. |
| Reset (mV/cell) | `voltage_reset` | 100 mV | Radio | How far above the warning threshold the pack has to come back, in millivolts per cell, before the alert counts as cleared (50 to 500 mV per cell, in steps of 50). Editable while *Voltage alert* is on. |
| Main power lost | `main_power_lost` | Off | Radio | Announces that the main pack has gone while the flight controller is still alive on a BEC or a backup battery, with the BEC voltage spoken. |
| Announce as | `voltage_announce` | Pack | Radio | How a flight pack voltage is spoken: *Pack* says the pack voltage with one decimal, *Cell* the voltage per cell with two. It applies to the voltage alert, to the pack coming back after *Main power lost*, and to *Pack Not Full* on the *On Connect* page. The BEC voltage spoken with *Main power lost*, and the BEC / receiver alerts of *Setup* → *Power* → *Alerts*, are not flight pack readings and are spoken as they are. Where no cell count is known, the pack voltage is spoken. |
| Repeat | `voltage_repeat` | Until cleared | Radio | How often an alert on this page speaks while its condition holds -- see *Repeat and Haptic* below. |
| Haptic | `voltage_haptic` | On | Radio | Transmitter vibration alongside the voltage, main power and BEC / receiver alerts. |

#### Sag Under Load, and a Pack That Is Genuinely Gone
- **Warning threshold:** it is not set on this page. It is the flight controller's own `vbatwarningcellvoltage` times the cell count, so the alert and the flight controller judge the same pack.
- **Hold (`voltage_hold`):** a hard collective pull drags the reading under that line for a moment, and a pack that sags is not a pack that is down. The alert waits for the hold time, then repeats every 10 seconds while the voltage stays low.
- **Reset (`voltage_reset`):** the alert counts as cleared -- which starts a fresh *Repeat* count -- only once the pack is back above the warning threshold plus this margin per cell. The margin is per cell because the threshold is: 100 mV per cell is 0.3 V on a 3S pack and 1.2 V on 12S. Before this setting the margin was a fixed 0.5 V for any pack, which is 0.17 V per cell on 3S but 0.04 V on 12S, so on a 12S pack the recovery after a sag could end the episode and a *Repeat* of *Once* speak again at every sag. Announcements stay at least 10 seconds apart either way.
- **Announce as (`voltage_announce`):** the voltage per cell reads the same on every pack, so a pilot who flies several pack sizes hears one number to judge. It is the pack voltage divided by the cell count the warning threshold uses -- the flight controller's configured cell count, or the detected one where the configuration says auto -- not a separate sensor.
- **Main Power Lost (`main_power_lost`):** for a setup with a backup guard or a separate receiver battery. It needs the pack to have read a real voltage since the connection began, to read as gone rather than merely low, and a BEC voltage beside it -- without one there is nothing left to say anything is still powered. It repeats every 10 seconds while the pack stays away, and announces once more, with the pack voltage as set under *Announce as*, when the pack comes back. Those three tests are also what the dashboard publishes as `state.mainPowerLost` for a theme to draw ([dashboard themes](../developer/dashboard-themes.md)) -- one definition, so a screen and the announcement cannot disagree. The switch on this page governs the announcement alone; a theme drawing the condition does so whether or not anything is spoken.

### 5. Profiles

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| PID profile | `pid_profile` | On | Radio | Announces the PID profile index when switched (e.g. "Profile 1"). |
| Rate profile | `rate_profile` | On | Radio | Announces the rate profile index when switched (e.g. "Rate 1"). |

### 6. ESC & MCU Temperature

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| ESC temperature | `esc_temperature` | Off | Radio | Alerts when ESC temperature exceeds the configured threshold. |
| ESC threshold | `esc_threshold` | 90 °C | Model | Maximum allowed ESC temperature (60 to 300 °C). Configured per model. |
| MCU temperature | `mcu_temperature` | Off | Radio | Alerts when the flight controller MCU temperature exceeds the threshold. |
| MCU threshold | `mcu_threshold` | 80 °C | Radio | Maximum allowed MCU temperature (40 to 150 °C). Global radio setting. |
| Repeat | `esc_repeat` | Until cleared | Radio | How often either temperature alert speaks while the reading stays at or above its threshold -- see *Repeat and Haptic* below. |
| Haptic | `esc_haptic` | On | Radio | Transmitter vibration alongside the ESC and MCU temperature alerts. |

Both thresholds are stored and compared in °C, the unit the flight controller reports. On a radio
set to Fahrenheit under [Localization](../pages/settings/localization.md) the page shows them in
°F -- each step is still one degree Celsius, so they move in steps of about 2 °F -- and the MCU
alert speaks the temperature in °F.

The ESC threshold is stored with the model while a flight controller is connected -- the row then
reads *Threshold [Model]* -- and is otherwise the radio-wide default that every model without a
value of its own reads. The MCU threshold is always radio-wide, because the same flight controller
is rated the same in every aircraft.

When the model's file cannot be written, *Save* reports the failure and the model goes on with the
threshold it had before. The page still shows the number that was entered, so saving again writes
it once the file can be written.

### 7. Adjustments

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Adjustment events | `adjustment_events` | Off | Radio | Audio feedback when adjusting tuning parameters via in-flight switches or rotary knobs. |

#### What an Adjustment Announcement Says
The new value, preceded by the name of the adjustment function whenever the pilot moves on to a different function than the last one adjusted, and on the first adjustment after a connect (when the [background decoder](../reference/background-decoder.md) makes the announcements, only after the first connect since the model was loaded). The name is built from the words in `adj/` (for example *Pitch RC Expo*, *Governor Idle Throttle*). Every adjustment function the firmware defines is named this way except the four profile switches (rate, PID, LED and OSD profile) and the battery profile, which the adjustment announcement does not speak at all. A rate or PID profile change is announced under *Profiles* and a battery profile change under *On Connect* (*Battery Capacity*), so announcing them here as well would say the same event twice; with those announcements switched off, such an adjustment is not spoken.

The flight controller reports an adjustment for three seconds after it was made, and nothing tells how long ago that was. So an adjustment still being reported when the announcements start is not announced: this happens when the configuration tool is opened, when the background decoder starts or the dashboard takes over from it -- where the part that stood before has usually announced it already -- and for an adjustment made while the suite is still connecting.

### 8. SmartFuel

Callouts of the SmartFuel level while the model is connected. The flight controller computes the value when SmartFuel is switched on there (*Setup* → *Power* → *SmartFuel*, MSP API 12.0.9 and later); otherwise the radio computes it from the local source chosen under *Setup* → *Power* → *Preferences*.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| SmartFuel | `fuel_alerts` | On | Radio | Master switch for the descending percentage callouts and the empty alarm. |
| Callout % | `fuel_callout_percent` | Every 10% | Radio | The steps at which the falling level is spoken, each once: *Only at 10%*, or every 5%, 10%, 20%, 25% or 50%. |
| Repeat | `fuel_repeat_below_zero` | Once | Radio | How often the empty battery / fuel alarm speaks while fuel is at 0% -- *Until cleared*, or 1 to 10 announcements ten seconds apart. The descending percentage callouts are not repeated: each step is spoken once as it is passed. |
| Haptic | `fuel_haptic_below_zero` | Off | Radio | Transmitter vibration alongside the empty alarm. |

### 9. Link Quality

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Link alert | `lq_alert` | Off | Radio | Spoken warning when RC link quality drops below defined levels. A receiver that reports no link quality stays silent: the value that arrives in its place is a signal strength in dBm, not a percentage. |
| Warning level | `lq_warn` | 70% | Radio | First warning threshold (1 to 100%). |
| Critical level | `lq_critical` | 50% | Radio | Critical link alarm threshold (1 to 100%). |
| Telemetry lost | `telemetry_lost` | Off | Radio | Announces a flight controller that stops sending telemetry while the model is armed and the radio link is up, and announces it again when its telemetry is back. |
| Repeat | `link_repeat` | Until cleared | Radio | How often the link quality alert speaks while it stays at a level -- see *Repeat and Haptic* below. |
| Haptic | `link_haptic` | On | Radio | Transmitter vibration alongside the link quality alert at its **critical** level, and alongside the lost telemetry announcement. |

#### What Telemetry Lost Covers, and What It Leaves to the Radio
Only a flight controller that stops sending while the radio link is still up is announced: the link statistics keep arriving and the radio stays connected, but the flight controller's telemetry frames have stayed away for 6 seconds. The radio cannot tell this case apart on its own until it reports each sensor as lost, 20 seconds later. A lost RF link is what the radio itself announces, and hearing the same event twice is worse than hearing it once, so a lost link stays silent here -- also when the flight controller's frames stopped with it. A drop while the model is disarmed is a normal power-off and stays silent too.

The loss is announced **once**. A model that stays silent keeps the announcement's recovery window open, and it is the return that speaks again -- not the silence, however long it lasts.

---

## Repeat and Haptic

An alert that reports a *condition* -- a voltage that is too low, a temperature that is too
high, a link that has fallen to a level -- keeps speaking while that condition lasts. Two
settings say how, and they belong to the **category page** rather than to one announcement:
the page that switches an alert on is the page that says how it behaves.

| Category page | Repeat / Haptic keys | The alerts they govern |
| --- | --- | --- |
| Voltage | `voltage_repeat`, `voltage_haptic` | Low pack voltage, Main power lost, and the BEC / receiver alert set up under *Setup* → *Power* → *Alerts*. |
| Link Quality | `link_repeat`, `link_haptic` | Link quality (warning and critical), Telemetry lost. |
| ESC & MCU Temperature | `esc_repeat`, `esc_haptic` | ESC temperature, MCU temperature. |
| SmartFuel | `fuel_repeat_below_zero`, `fuel_haptic_below_zero` | The empty battery / fuel alarm below 0%. |

- **Repeat** is *Until cleared*, or a count from 1 to 10. Announcements are ten seconds apart
  either way; a count simply stops after that many and starts over once the condition has
  cleared. *Until cleared* is what every alert did before this setting existed, and is the
  default everywhere except SmartFuel, which kept the single announcement it already had.
- **Haptic** is the transmitter's vibration alongside the voice: one short pulse per
  announcement. It defaults to on for the
  three categories whose alerts already buzzed with no way of switching it off, and to off for
  SmartFuel, which already had this setting and keeps its value.
- **Two alerts have their own rule inside the category, and a setting does not overrule it.**
  The link quality alert buzzes at its *critical* level only, never at the warning level. The
  lost telemetry announcement says itself once per loss, so it takes the haptic and ignores the
  repeat.
- **The pack check is not in the table**, because it has no condition to hold: it speaks once
  when the model connects and is latched for the rest of that connection.

---

## Sound Pack Files

Announcements are played from the sound pack under `/SOUNDS/rf/<language>/`. Numbers and their units are spoken by the radio itself, so they follow the language set on the radio rather than the language of the pack.

Every announcement has a file of its own in both packs. Two have no substitute and stay silent in an older pack that lacks theirs:

| File | Announcement |
| --- | --- |
| `stat/alerts/telemetrylost.wav` | Telemetry lost |
| `stat/alerts/telemetryok.wav` | Telemetry recovered |

Three have a file of their own in both packs, and fall back to another file in an older pack that lacks it:

| Preferred file | Falls back to | Announcement |
| --- | --- | --- |
| `stat/alerts/mainpower.wav` | `stat/alerts/batteryempty.wav`, then `stat/alerts/lowvoltage.wav` | Main power lost |
| `stat/alerts/mainpowerok.wav` | `evt/battery.wav` | Main power back |
| `stat/alerts/notfull.wav` | `stat/alerts/voltage.wav` | Pack not full |

`stat/alerts/batteryempty.wav` is in the English pack only, so a German pack that lacks `stat/alerts/mainpower.wav` falls back straight to `stat/alerts/lowvoltage.wav`.

---

*Documented against RFSuite 0.1.7.*
