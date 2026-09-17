---
title: Pages
sidebar_label: Pages
---

# Configuration pages

For the shared Save action, read [Saving configuration](../reference/saving.md).

One file per page, at the path of the page under `src/rfsuite/app/pages/` with `.md`
appended: the page `setup/power/smartfuel/page.lua` is documented in
`docs/pages/setup/power/smartfuel.md`. Menu entries that only open a submenu have no file.

**Status:** 93 reachable pages, 13 written. 74 of them carry an in-app help text behind the
`?` in the header, which is the text to start a page file from; the others start from the
page source.

The *Conditions* column names what hides, greys out or locks a page; the sentences to use in
a page file are in [_template.md](../_template.md), and the mechanics are explained in
[reference/](../reference/README.md) (`hidden-and-locked-pages.md`, to write).

## Configuration → Flight Tuning

| Page | File | In-app help | Conditions | Status |
| --- | --- | --- | --- | --- |
| PIDs | `flight_tuning/pids.md` | yes | read-only while armed | to write |
| Rates | [flight_tuning/rates.md](flight_tuning/rates.md) | yes | read-only while armed | written |
| Governor | `flight_tuning/governor.md` | yes | read-only while armed, needs MSP API 12.09 | to write |
| Advanced → Filters | `flight_tuning/advanced/filters.md` | yes | read-only while armed | to write |
| Advanced → PID Controller | `flight_tuning/advanced/pid_controller.md` | yes | read-only while armed | to write |
| Advanced → PID Bandwidth | `flight_tuning/advanced/pid_bandwidth.md` | yes | read-only while armed | to write |
| Advanced → Autolevel | `flight_tuning/advanced/autolevel.md` | yes | read-only while armed | to write |
| Advanced → Main Rotor | `flight_tuning/advanced/main_rotor.md` | yes | read-only while armed | to write |
| Advanced → Tail Rotor | [flight_tuning/advanced/tail_rotor.md](flight_tuning/advanced/tail_rotor.md) | yes | read-only while armed | written |
| Advanced → Rescue | `flight_tuning/advanced/rescue.md` | yes | read-only while armed | to write |
| Advanced → Rates (Advanced) → Advanced | `flight_tuning/advanced/rates_advanced/advanced.md` | yes | read-only while armed | to write |
| Advanced → Rates (Advanced) → Cyclic Behaviour | `flight_tuning/advanced/rates_advanced/cyclic_behaviour.md` | yes | read-only while armed | to write |
| Advanced → Rates (Advanced) → Rate Table | `flight_tuning/advanced/rates_advanced/table.md` | yes | read-only while armed | to write |

## Configuration → Setup

| Page | File | In-app help | Conditions | Status |
| --- | --- | --- | --- | --- |
| Configuration | `setup/configuration.md` | yes | read-only while armed | to write |
| Radio Config | `setup/radio_config.md` | yes | read-only while armed | to write |
| Telemetry | [setup/telemetry.md](setup/telemetry.md) | yes | read-only while armed | written |
| Accelerometer | [setup/accelerometer.md](setup/accelerometer.md) | yes | read-only while armed | written |
| Alignment | `setup/alignment.md` | yes | read-only while armed | to write |
| Ports | `setup/ports.md` | yes | read-only while armed | to write |
| Mixer → Swash | `setup/mixer/swash.md` | no | read-only while armed | to write |
| Mixer → Geometry | `setup/mixer/swashgeometry.md` | no | read-only while armed | to write |
| Mixer → Tail | `setup/mixer/tail.md` | no | read-only while armed | to write |
| Mixer → Trims | `setup/mixer/trims.md` | no | read-only while armed | to write |
| Servos → PWM Output | `setup/servos/pwm.md` | no | read-only while armed | to write |
| Servos → BUS Output | `setup/servos/bus.md` | no | read-only while armed | to write |
| Controls → Modes | `setup/controls/modes.md` | yes | read-only while armed | to write |
| Controls → Adjustments | `setup/controls/adjustments.md` | yes | read-only while armed | to write |
| Controls → Failsafe | `setup/controls/failsafe.md` | yes | read-only while armed | to write |
| Controls → Beepers → Configuration | `setup/controls/beepers/configuration.md` | yes | read-only while armed | to write |
| Controls → Beepers → ESC Beacon | `setup/controls/beepers/dshot.md` | yes | read-only while armed | to write |
| Controls → Blackbox → Configuration | `setup/controls/blackbox/configuration.md` | yes | read-only while armed | to write |
| Controls → Blackbox → Logging | `setup/controls/blackbox/logging.md` | yes | read-only while armed | to write |
| Controls → Blackbox → Status | `setup/controls/blackbox/status.md` | yes | read-only while armed | to write |
| Controls → Stats | `setup/controls/stats.md` | yes | read-only while armed | to write |
| Controls → In-Flight Tuning | [setup/controls/inflight.md](setup/controls/inflight.md) | yes | preview switch *In-flight tuning*, needs the flight controller, read-only while armed | written |
| Power → Battery | [setup/power/battery.md](setup/power/battery.md) | yes | read-only while armed | written |
| Power → Alerts | `setup/power/alerts.md` | yes | always available | to write |
| Power → Sources | `setup/power/sources.md` | yes | read-only while armed | to write |
| Power → SmartFuel | [setup/power/smartfuel.md](setup/power/smartfuel.md) | yes | read-only while armed, needs MSP API 12.09 | written |
| Power → Preferences | `setup/power/preferences.md` | yes | always available | to write |
| ESC & Motors → Throttle | `setup/esc_motors/throttle.md` | yes | read-only while armed | to write |
| ESC & Motors → Telemetry | `setup/esc_motors/telemetry.md` | yes | read-only while armed | to write |
| ESC & Motors → RPM | `setup/esc_motors/rpm.md` | yes | read-only while armed | to write |
| ESC & Motors → ESC Tools → AM32 | `setup/esc_motors/esc_tools/escmfg/am32.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → BLHeli_S | `setup/esc_motors/esc_tools/escmfg/blheli_s.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → Bluejay | [setup/esc_motors/esc_tools/escmfg/bluejay.md](setup/esc_motors/esc_tools/escmfg/bluejay.md) | no | read-only while armed, lit for one ESC telemetry protocol | written |
| ESC & Motors → ESC Tools → Flyrotor | `setup/esc_motors/esc_tools/escmfg/flrtr.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → Hobbywing V5 | `setup/esc_motors/esc_tools/escmfg/hw5.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → OMP | `setup/esc_motors/esc_tools/escmfg/omp.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → Scorpion | `setup/esc_motors/esc_tools/escmfg/scorp.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → XDFly | `setup/esc_motors/esc_tools/escmfg/xdfly.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → YGE | `setup/esc_motors/esc_tools/escmfg/yge.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → ZTW | `setup/esc_motors/esc_tools/escmfg/ztw.md` | no | read-only while armed, lit for one ESC telemetry protocol | to write |
| ESC & Motors → ESC Tools → ESC Configurator (the shared run page) | `setup/esc_motors/esc_tools/run.md` | no | read-only while armed | to write |
| ESC & Motors → Motor Override | `setup/esc_motors/motor_override.md` | yes | read-only while armed, needs MSP API 12.09 | to write |
| Governor → General | `setup/governor/general.md` | yes | read-only while armed | to write |
| Governor → Ramp Time | `setup/governor/time.md` | yes | read-only while armed | to write |
| Governor → Filters | `setup/governor/filters.md` | yes | read-only while armed | to write |
| Governor → Bypass Curve | `setup/governor/curves.md` | yes | read-only while armed | to write |
| Model | [setup/model.md](setup/model.md) | yes | needs the flight controller, read-only while armed | written |
| GPS | `setup/gps.md` | yes | read-only while armed | to write |

## Configuration → Wizards

| Page | File | In-app help | Conditions | Status |
| --- | --- | --- | --- | --- |
| Full initial setup (Complete run / Radio / Flight controller) | `setup_wizard.md` | yes | preview switch *Setup Assistant*, read-only while armed | to write |

## System → Tools

| Page | File | In-app help | Conditions | Status |
| --- | --- | --- | --- | --- |
| Copy Profiles | `tools/copy_profiles.md` | yes | needs the flight controller, read-only while armed | to write |
| Select Profile | `tools/select_profile.md` | yes | needs the flight controller, read-only while armed | to write |
| Flight Log | `tools/flight_log.md` | yes | preview switch *Flight Log*, read-only while armed | written |
| Diagnostics → FBL Status | `tools/diagnostics/fblstatus.md` | no | needs the flight controller, read-only while armed | to write |
| Diagnostics → RF Status | `tools/diagnostics/rfstatus.md` | yes | needs the flight controller, read-only while armed | to write |
| Diagnostics → ELRS Link | [tools/diagnostics/elrs_link.md](tools/diagnostics/elrs_link.md) | yes | read-only while armed | written |
| Diagnostics → Validate Sensors | `tools/diagnostics/validate_sensors.md` | yes | needs the flight controller, read-only while armed | to write |
| Diagnostics → SmartFuel | `tools/diagnostics/smartfuel.md` | no | needs the flight controller, read-only while armed, needs MSP API 12.09 | to write |
| Diagnostics → Session Logs | [tools/diagnostics/session_logs.md](tools/diagnostics/session_logs.md) | yes | always available | written |
| Diagnostics → Info | `tools/diagnostics/info.md` | yes | read-only while armed | to write |

## System → Logs

| Page | File | In-app help | Conditions | Status |
| --- | --- | --- | --- | --- |
| Logs (the telemetry CSV browser) | `logs.md` | yes | always available | to write |

## System → Settings

| Page | File | In-app help | Conditions | Status |
| --- | --- | --- | --- | --- |
| General | `settings/general.md` | yes | always available | to write |
| Dashboard → Design | `settings/dashboard/theme.md` | yes | always available | to write |
| Dashboard → Settings (one page per configurable theme) | `settings/dashboard/settings.md` | yes | always available | to write |
| Dashboard → In-Flight Tuning | [settings/dashboard/inflight.md](settings/dashboard/inflight.md) | yes | preview switch *In-flight tuning* | written |
| Localization | `settings/localization.md` | yes | always available | to write |
| Audio → Volume | [settings/audio/volume.md](settings/audio/volume.md) | yes | always available | written |
| Audio → Events → Arming | `settings/audio/events/arming.md` | yes | always available | to write |
| Audio → Events → Governor | `settings/audio/events/governor.md` | yes | always available | to write |
| Audio → Events → Voltage | `settings/audio/events/voltage.md` | yes | always available | to write |
| Audio → Events → Profiles | `settings/audio/events/profiles.md` | yes | always available | to write |
| Audio → Events → ESC | `settings/audio/events/esc.md` | yes | always available | to write |
| Audio → Events → Adjustments | `settings/audio/events/adjustment.md` | yes | always available | to write |
| Audio → Events → Fuel | `settings/audio/events/fuel.md` | yes | always available | to write |
| Audio → Events → Battery | `settings/audio/events/battery.md` | yes | always available | to write |
| Audio → Events → Link | `settings/audio/events/link.md` | yes | always available | to write |
| Audio → Events → Other | `settings/audio/events/other.md` | yes | always available | to write |

## System → Developer

| Page | File | In-app help | Conditions | Status |
| --- | --- | --- | --- | --- |
| MSP Speed | `developer/msp_speed.md` | yes | hidden until *Developer Tools* is on, needs the flight controller, read-only while armed | to write |
| API Tester | `developer/api_tester.md` | yes | hidden until *Developer Tools* is on, needs the flight controller, read-only while armed | to write |
| MSP Experiments | `developer/msp_experiments.md` | yes | hidden until *Developer Tools* is on, needs the flight controller, read-only while armed | to write |
| Settings | `developer/developer_settings.md` | yes | hidden until *Developer Tools* is on | to write |

## Not documented on purpose

Page directories that exist in the source but cannot be reached from the menu, and therefore
get no file: `settings/shortcuts` (its entry is disabled and hidden), `settings/activelook`
and `settings/dashboard/page.lua` (not registered), and `tools/diagnostics/fblsensors` (its
entry is commented out in the manifest). If one of them is wired up, it gets a file then.
