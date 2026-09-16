---
title: Reference
sidebar_label: Reference
---

# Reference

Mechanics that span every page. A page file names the condition that applies to it and
links here for the explanation.

| File | What it will say | Start from | Status |
| --- | --- | --- | --- |
| `hidden-and-locked-pages.md` | The six reasons a tile is absent, greyed out or read-only: no flight controller yet, the model is armed, the firmware's MSP API is too old, a preview switch is off, developer tools are off, the ESC telemetry protocol does not match. | nowhere yet | to write |
| `preview-features.md` | What a preview feature is, the one-switch-per-feature rule, the confirmation when a switch goes on, and the features currently behind one. | in-app help of the General page | to write |
| `saving-and-reboot.md` | What happens on *Save*: the write, the EEPROM commit, the reboot where the firmware needs one, the reconnect and the read-back; which pages reboot; what each dialog and timeout means. | nowhere yet | to write |
| `user-folder.md` | Everything under `/SCRIPTS/TOOLS/rfsuite.user/`: `preferences.lua`, the per-model `<mcu id>.lua`, `model_name_restore.lua`, `reload.req`, user themes, the flight log files, session logs; what survives an update. The three store files have a page of their own — link to `configuration-files.md` rather than repeating it. | README, one sentence | to write |
| `configuration-files.md` | The two settings files the suite keeps on the card: that they are Lua data, how to edit one by hand, what a broken one does, and the one-time migration from the former `.ini` files — including that it is the tool or the background decoder that does it, never a widget. | written | written |
| `flight-statistics.md` | The record of each flight's extremes and its armed time: where it is published, which widget keeps it, what each field means, when a flight starts and ends, why the totals come from the flight controller and can fall by a short flight, and the deprecated field names a theme may still be reading. | written | written |
| `background-decoder.md` | The optional special-function script that decodes the flight controller's custom telemetry outside the widget: what it is for, that the suite installs it itself, how to switch it off, and why a model already running another background decoder does not get one. | written | written |
| `supported-firmware.md` | The MSP API versions the suite speaks (12.08, 12.09, 12.10), what a page that needs a newer one does, and the unsupported-API dialog. | README | to write |
