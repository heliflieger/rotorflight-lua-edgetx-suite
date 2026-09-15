---
title: <Page title, as the tile reads>
sidebar_label: <Tile label>
sidebar_position: <order of the tile in its menu, times 10>
---

# <Page title>

<!-- One or two sentences: what the page configures and why a pilot opens it. The same
     explanation the ? button gives, no longer than the settings table needs. -->

## Where to find it

*Configuration* → *Setup* → *<Tile>*

<!-- Name every condition that makes the page absent, greyed out or read-only. Take them from
     the page's entry in src/rfsuite/app/manifest.lua and use these sentences:
       enabledWhen = "fblConnected"   -> Greyed out until the flight controller answers.
       lockedWhileArmed = true        -> Read-only while the model is armed.
       minApiVersion = { 12, 0, 9 }   -> Needs MSP API 12.09; hidden on an older flight controller.
       visibleWhen = "preview..."     -> Hidden until *System* → *Settings* → *General* → *Preview* → *<Feature>* is on.
       hideWhenDisabled = true        -> Not listed at all while its condition is off.
       enabledWhen = "escProto<n>"    -> Lit only while the flight controller reports this ESC telemetry protocol.
     Leave out the lines that do not apply. If none apply, write: Always available. -->

## Settings

<!-- One row per control, in the order they appear on the page. Say what the setting does, not
     what it is called a second time. Give the range, the unit and the default where the pilot
     needs them. A control that only appears under a condition says so in its row. -->

| Setting | What it does |
| --- | --- |
| <Label> | <What it does. Range, unit, default.> |

## Notes

<!-- Optional. Only what a pilot would otherwise get wrong: a save that reboots the flight
     controller, an interaction with another page, a safety point. Delete the section if
     there is nothing to say. -->

## Related

<!-- Optional. Link the Rotorflight documentation for the underlying feature instead of
     restating it. Delete the section if there is nothing to link. -->

- [Rotorflight documentation](https://www.rotorflight.org/docs/)

*Documented against RFSuite <version, from src/rfsuite/lib/version.lua>.*
