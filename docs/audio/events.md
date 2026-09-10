---
title: Audio Events
sidebar_label: Events
sidebar_position: 10
---

# Audio Events

The suite provides spoken voice alerts and tone callouts for flight telemetry, battery status, system state, and flight controller notifications. Audio events are configured under:

*System* → *Settings* → *Audio* → *Events*

The ten category pages share a common configuration table (`preferences.audio_events`), stored globally in `/RADIO/rfsuite.ini` with model-specific overrides (such as the ESC temperature threshold) in each model's preference file.

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
| Repeat below zero | `fuel_repeat_below_zero` | 1 | Radio | Number of times the empty battery / fuel alarm repeats once fuel reaches 0% (1 to 10). |
| Haptic below zero | `fuel_haptic_below_zero` | Off | Radio | Activates transmitter vibration alongside the low-fuel voice alert. |

### 3. Voltage

Monitors main pack voltage, cell thresholds, and pre-flight pack charge level.

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Voltage alert | `voltage_alert` | On | Radio | Voice alert when cell or pack voltage drops below the warning threshold configured in the battery profile. |
| Pack not full | `pack_not_full` | Off | Radio | Spoken pre-flight warning on connection if the connected battery is not fully charged. |
| Margin | `pack_not_full_margin` | 100 mV | Radio | Allowed voltage delta below full charge (10 to 500 mV per cell). Default is 100 mV/cell. |

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

### 8. Link Quality

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Link alert | `lq_alert` | Off | Radio | Spoken warning when RC link quality drops below defined levels. |
| Warning level | `lq_warn` | 70% | Radio | First warning threshold (1 to 100%). |
| Critical level | `lq_critical` | 50% | Radio | Critical link alarm threshold (1 to 100%). |

### 9. Adjustments

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Adjustment events | `adjustment_events` | Off | Radio | Audio feedback when adjusting tuning parameters via in-flight switches or rotary knobs. |

### 10. Other

| Setting | Switch / Key | Default | Scope | Description |
| --- | --- | --- | --- | --- |
| Model announcement | `model_announcement` | Off | Radio | Plays a model-specific sound file (`/SOUNDS/<lang>/modelname.wav`) upon selecting the model. |

---

*Documented against RFSuite 0.1.7.*
