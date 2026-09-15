---
title: Dashboard widget
sidebar_label: Dashboard
---

# Dashboard widget

The *RFSuite* widget renders a theme from live telemetry and switches between a preflight,
an inflight and a postflight layout as the flight progresses. What the README says about it
is the starting point; these files carry the detail.

| File | What it will say | Start from | Status |
| --- | --- | --- | --- |
| `widget-setup.md` | Adding the widget to a screen, sizing it, and what it shows in each of the three flight phases. | README | to write |
| `themes.md` | The shipped themes (Default, RF Status, @AERC, @AERC Nitro, @RT-RC, @RT-RC Nitro, @SRB-RC) and choosing one under *System* → *Settings* → *Dashboard* → *Design*, per model and per flight phase. | in-app help of the Design page | to write |
| `theme-settings.md` | The per-theme settings page under *Dashboard* → *Settings*: the voltage range a theme's gauges span, stored per model. | theme `configure.lua` sources | to write |
| [user-themes.md](user-themes.md) | Copying a shipped theme into `/SCRIPTS/TOOLS/rfsuite.user/dashboard/`, editing it, box styling, named colors, dynamic thresholds, and why a copy keeps its own settings. | nowhere yet | written |
| `quick-menu.md` | The fullscreen quick menu: erasing the blackbox and picking the battery profile. | nowhere yet | to write |
| [inflight-tuning.md](inflight-tuning.md) | The in-flight tuning overlay: what the interlock switch brings up on the ground, in the air and after landing, and how it drives the flight controller's adjustment functions through two global variables. | the two settings pages and the overlay sources | written |
| `model-image.md` | Where the model picture comes from, the per-cell-count variant and the accepted file types. | README | to write |
| `service-widget.md` | What *RFSuite Service* keeps alive when the tool is closed, and where to place it. | README | to write |
