---
title: Audio Events
sidebar_label: Events
sidebar_position: 10
---

# Audio Events

The suite provides spoken voice alerts and tone callouts for flight telemetry, battery status, system state, and flight controller notifications. Audio events are configured under:

*System* → *Settings* → *Audio* → *Events*

The ten category pages share a common configuration table (`preferences.audio_events`), stored with the radio in `/SCRIPTS/TOOLS/rfsuite.user/preferences.lua` with model-specific overrides (such as the ESC temperature threshold) in each flight controller's own file beside it. See [Configuration files](../reference/configuration-files.md).

---

## Categories & Settings

### 1. Battery

Configures spoken callouts for battery capacity and initial pack charge when connecting to the model.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Battery profile | `battery_profile` | On | Radio | Announces the active battery profile number or battery capacity in mAh (e.g. "Battery 5000 mAh") when the profile is selected or on connection. |
| Initial fuel | `initial_fuel` | On | Radio | Announces the remaining battery percentage (e.g. "Battery 95%") once upon connecting. |

#### Initial Fuel Startup Gating & Telemetry Readiness
To prevent spurious "Battery 0%" announcements at startup:
- **Telemetry Guard (`fuelTelemetrySeen`):** The announcement is held until valid fuel telemetry has been delivered by the flight controller or SmartFuel.
- **Dynamic Deferral Window:** When the model connects, the announcement is deferred for a window derived from the model's SmartFuel stabilization delay (`stabilize_delay`, defaulting to at least 8.0 seconds).
- **Carried-Over Reading Detection:** EdgeTX retains the last received sensor reading across disconnections. If a new connection reports a reading bit-identical to the previous session's disconnect value (`previousSessionFuel`), it is treated as a carried-over reading and held until the new pack's fresh reading arrives.
- **Immediate vs. Timed Callout:** As soon as a positive, fresh reading arrives (`fuel > 0` and different from the previous pack), the percentage is spoken immediately. If the pack is genuinely empty (0%), the callout fires once the deferral ceiling expires.

### 2. Fuel

Configures recurring callouts and low-fuel alarms during flight based on the estimated remaining capacity or battery percentage.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Fuel alerts | `fuel_alerts` | On | Radio | Master switch for spoken remaining fuel percentage callouts and low-fuel alarms. |
| Callout step | `fuel_callout_percent` | 10% | Radio | Interval step for descending percentage callouts (options: 5%, 10%, 15%, 20%, 25%). |
| Repeat | `fuel_repeat_below_zero` | Once | Radio | How often the empty battery / fuel alarm speaks while fuel is at 0% -- *Until cleared*, or 1 to 10 announcements ten seconds apart. The descending percentage callouts are not repeated: each step is spoken once as it is passed. |
| Haptic | `fuel_haptic_below_zero` | Off | Radio | Transmitter vibration alongside the empty alarm. |

### 3. Voltage

Monitors main pack voltage, cell thresholds, and pre-flight pack charge level.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Voltage alert | `voltage_alert` | On | Radio | Voice alert when cell or pack voltage drops below the warning threshold configured in the battery profile. The pack voltage the alert fired at is spoken with it. |
| Hold | `voltage_hold` | 2 s | Radio | How long the reading has to stay below the warning threshold before the alert speaks (0 to 10 s). A hold of 0 announces on the first reading below the level, which is the behaviour before this setting existed. |
| Pack not full | `pack_not_full` | Off | Radio | Spoken pre-flight warning on connection if the connected battery is not fully charged. |
| Margin | `pack_not_full_margin` | 100 mV | Radio | Allowed voltage delta below full charge (10 to 500 mV per cell). Default is 100 mV/cell. |
| Main power lost | `main_power_lost` | Off | Radio | Announces that the main pack has gone while the flight controller is still alive on a BEC or a backup battery, with the BEC voltage spoken. |
| Repeat | `voltage_repeat` | Until cleared | Radio | How often an alert on this page speaks while its condition holds -- see *Repeat and Haptic* below. |
| Haptic | `voltage_haptic` | On | Radio | Transmitter vibration alongside the voltage, main power and BEC / receiver alerts. |

#### Sag Under Load, and a Pack That Is Genuinely Gone
- **Warning threshold:** it is not set on this page. It is the flight controller's own `vbatwarningcellvoltage` times the cell count, so the alert and the flight controller judge the same pack.
- **Hold (`voltage_hold`):** a hard collective pull drags the reading under that line for a moment, and a pack that sags is not a pack that is down. The alert waits for the hold time, then repeats every 10 seconds while the voltage stays low, and arms again once the pack has recovered by half a volt.
- **Main Power Lost (`main_power_lost`):** for a setup with a backup guard or a separate receiver battery. It needs the pack to have read a real voltage since the connection began, to read as gone rather than merely low, and a BEC voltage beside it -- without one there is nothing left to say anything is still powered. It repeats every 10 seconds while the pack stays away, and announces once more, with the pack voltage, when the pack comes back.

### 4. Arming

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Arming flags | `arming_flags` | On | Radio | Announces arming ("Armed"), disarming ("Disarmed"), and arm-disable reasons if arming is blocked. |

### 5. Governor

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Governor state | `governor_state` | On | Radio | Spoken announcements when the governor transitions between operating states (Idle, Spool-up, Recovery, Active, Throttle off, Lost headspeed, Autorotation, Bailout, Bypass). Individual sub-states can be toggled independently. |

### 6. Profiles

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| PID profile | `pid_profile` | On | Radio | Announces the PID profile index when switched (e.g. "Profile 1"). |
| Rate profile | `rate_profile` | On | Radio | Announces the rate profile index when switched (e.g. "Rate 1"). |

### 7. ESC & MCU Temperature

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| ESC temperature | `esc_temperature` | Off | Radio | Alerts when ESC temperature exceeds the configured threshold. |
| ESC threshold | `esc_threshold` | 90 °C | Model | Maximum allowed ESC temperature (60 to 300 °C). Configured per model. |
| MCU temperature | `mcu_temperature` | Off | Radio | Alerts when the flight controller MCU temperature exceeds the threshold. |
| MCU threshold | `mcu_threshold` | 80 °C | Radio | Maximum allowed MCU temperature (40 to 150 °C). Global radio setting. |
| Repeat | `esc_repeat` | Until cleared | Radio | How often either temperature alert speaks while the reading stays at or above its threshold -- see *Repeat and Haptic* below. |
| Haptic | `esc_haptic` | On | Radio | Transmitter vibration alongside the ESC and MCU temperature alerts. |

### 8. Link Quality

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Link alert | `lq_alert` | Off | Radio | Spoken warning when RC link quality drops below defined levels. |
| Warning level | `lq_warn` | 70% | Radio | First warning threshold (1 to 100%). |
| Critical level | `lq_critical` | 50% | Radio | Critical link alarm threshold (1 to 100%). |
| Telemetry lost | `telemetry_lost` | Off | Radio | Announces that the model was lost while it was armed, and announces it again when it answers. |
| Repeat | `link_repeat` | Until cleared | Radio | How often the link quality alert speaks while it stays at a level -- see *Repeat and Haptic* below. |
| Haptic | `link_haptic` | On | Radio | Transmitter vibration alongside the link quality alert at its **critical** level, and alongside the lost telemetry announcement. |

#### What Telemetry Lost Covers, and What It Leaves to the Radio
Only a flight controller that stops answering while the radio link is still up is announced. A lost RF link is what the radio itself announces, and hearing the same event twice is worse than hearing it once. A drop while the model is disarmed is a normal power-off and stays silent. Both announcements need sound files a pack may not carry yet -- see *Sound Pack Files* below.

### 9. Adjustments

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Adjustment events | `adjustment_events` | Off | Radio | Audio feedback when adjusting tuning parameters via in-flight switches or rotary knobs. |

### 10. Other

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Model announcement | `model_announcement` | Off | Radio | Plays a model-specific sound file (`/SOUNDS/<lang>/modelname.wav`) upon selecting the model. |

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
| Fuel | `fuel_repeat_below_zero`, `fuel_haptic_below_zero` | The empty battery / fuel alarm below 0%. |

- **Repeat** is *Until cleared*, or a count from 1 to 10. Announcements are ten seconds apart
  either way; a count simply stops after that many and starts over once the condition has
  cleared. *Until cleared* is what every alert did before this setting existed, and is the
  default everywhere except Fuel, which kept the single announcement it already had.
- **Haptic** is the transmitter's vibration alongside the voice. It defaults to on for the
  three categories whose alerts already buzzed with no way of switching it off, and to off for
  Fuel, which already had this setting and keeps its value.
- **Two alerts have their own rule inside the category, and a setting does not overrule it.**
  The link quality alert buzzes at its *critical* level only, never at the warning level. The
  lost telemetry announcement says itself once per loss, so it takes the haptic and ignores the
  repeat.
- **The pack check is not in the table**, because it has no condition to hold: it speaks once
  when the model connects and is latched for the rest of that connection.

---

## Sound Pack Files

Announcements are played from the sound pack under `/SOUNDS/rf/<language>/`. Numbers and their units are spoken by the radio itself, so they follow the language set on the radio rather than the language of the pack.

Two announcements ask for files no pack ships yet, and stay silent without them:

| File | Announcement |
| --- | --- |
| `stat/alerts/telemetrylost.wav` | Telemetry lost |
| `stat/alerts/telemetryok.wav` | Telemetry recovered |

Three prefer a file of their own and fall back to one that ships, so they work today:

| Preferred file | Falls back to | Announcement |
| --- | --- | --- |
| `stat/alerts/mainpower.wav` | `stat/alerts/batteryempty.wav`, then `stat/alerts/lowvoltage.wav` | Main power lost |
| `stat/alerts/mainpowerok.wav` | `evt/battery.wav` | Main power back |
| `stat/alerts/notfull.wav` | `stat/alerts/voltage.wav` | Pack not full |

`stat/alerts/batteryempty.wav` is currently in the English pack only.

---

*Documented against RFSuite 0.1.7.*
