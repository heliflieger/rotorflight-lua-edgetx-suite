---
title: User themes
sidebar_label: User themes
sidebar_position: 40
---

# User themes

RFSuite loads dashboard themes from `/SCRIPTS/TOOLS/rfsuite/widgets/dashboard/themes/` and from the user folder at `/SCRIPTS/TOOLS/rfsuite.user/dashboard/themes/`. Themes placed in the user folder override shipped themes with the same name, or appear as standalone choices in the theme selector under *System* → *Settings* → *Dashboard* → *Design*.

## Structure of a theme

A theme is a folder containing an `init.lua` manifest and one module per flight phase:

- `init.lua`: theme metadata, name, author, supported display profiles, and optional configuration descriptor (`configure.lua`).
- `preflight.lua`: layout and boxes displayed before arming while telemetry is connected.
- `inflight.lua`: layout and boxes active during flight.
- `postflight.lua`: summary boxes shown after disarming.

Each phase module returns a table with `layout` options (margins, grid dimensions) and a list of `boxes`.

## Box types and text styling

Themes define objects such as gauges (`type = "gauge"`), telemetry text (`type = "text"`), clocks and timers (`type = "time"`), and battery/governor status indicators.

### Text colors

Text boxes configure their default font color via `textcolor`. This property accepts:
- Numeric 16-bit RGB values (e.g. from `lcd.RGB(r, g, b)`).
- EdgeTX theme color constants (e.g. `COLOR_WHITE`, `COLOR_BLACK`).
- Named color strings: `"white"`, `"black"`, `"red"`, `"green"`, `"blue"`, `"yellow"`, `"orange"`, `"cyan"`, `"magenta"`, and `"grey"`.

```lua
{
  type = "text",
  source = "rpm",
  label = "RPM",
  textcolor = "orange",
}
```

### Dynamic color thresholds

Both gauges and text boxes support a `thresholds` list. When telemetry values update, the box evaluates the thresholds and updates its text or accent color reactively:

#### Numeric thresholds
For numeric sources (e.g. `rpm`, `bec_voltage`, `temp_esc`, `altitude`, `flight_time`, `blackbox`), thresholds are specified as a table ordered by trigger values:

```lua
{
  type = "text",
  source = "bec_voltage",
  label = "BEC",
  thresholds = {
    { value = 6.5, textcolor = "red" },
    { value = 7.0, textcolor = "orange" },
    { value = 8.5, textcolor = "white" },
  }
}
```

Thresholds are evaluated in order (`value <= threshold.value`). Gauge fill thresholds use `fillcolor` (or `color`), while text and value labels use `textcolor` (or `color`). An entry can declare either or both. If no threshold matches, the default `textcolor` is used.

For temperature sources (`esc_temp`, `temp_esc`, `mcu_temp`, `temp_mcu`), threshold values are defined in Celsius (°C) in the theme and automatically converted when the radio is configured for Fahrenheit (°F).

#### Governor state thresholds
For governor status boxes (`type = "text"`, `source = "governor"`), thresholds can match against governor state labels:

```lua
{
  type = "text",
  source = "governor",
  label = "GOV",
  thresholds = {
    { value = "DISARMED", textcolor = "grey" },
    { value = "SPOOLING", textcolor = "orange" },
    { value = "ACTIVE", textcolor = "green" },
    { value = "RECOVERY", textcolor = "red" },
  }
}
```

Values match either translated labels or internal state names, ensuring custom color schemes function across all radio languages.

## Notes

- User themes in `/SCRIPTS/TOOLS/rfsuite.user/` are preserved across suite updates.
- If a theme includes a `configure.lua` file, configurable options (such as voltage ranges) are saved per-model in the model preferences file.

*Documented against RFSuite 0.1.7.*
