---
title: ELRS Link
sidebar_label: ELRS Link
sidebar_position: 30
---

# ELRS Link

The transmitter module and the flight controller each hold their own idea of how fast the link
runs and how much of it is telemetry, and nothing makes the two agree by itself. This page reads
both and, on request, writes one side to match the other.

## Where to find it

*Tools* → *Diagnostics* → *ELRS Link*

The menu entry is locked while the model is armed. The page needs a connected model on CRSF
telemetry; without one it says so and reads nothing.

## What it shows

| Row | What it is |
| --- | --- |
| Status | What the page is doing, or what it last did |
| Rotorflight | The flight controller's telemetry mode, link rate and link ratio, as they are stored on the board |
| ELRS Module | The packet rate and telemetry ratio the transmitter module is set to |
| Action | Which of the three buttons the last run was started with |

Opening the page reads the flight controller and then asks the transmitter module for its
parameters. The three buttons become available once that has finished.

## Settings

| Setting | What it does |
| --- | --- |
| Probe | Reads both sides again. Writes nothing. |
| RF -> ELRS | Sets the module's packet rate and telemetry ratio to the flight controller's link rate and ratio. |
| ELRS -> RF | Sets the flight controller's telemetry mode to *Custom* with the module's rate and ratio, and saves it to the board. |

Both write buttons ask first, and the question quotes the two sides as the rows above show them,
i.e. as the last probe read them.
Answering no writes nothing. Where the radio cannot put the question up, nothing is written either
and the Status row says so.

## Notes

The module the page writes to is the **ExpressLRS transmitter module**: it is identified by the
serial number ExpressLRS reports in its device information, or failing that by its name, and it
has to answer on the CRSF transmitter address as well. Another CRSF module in the bay answers the
same query and is ignored; the log names the device that was turned away.

*RF -> ELRS* changes a live radio link. The module applies the new packet rate immediately, so run
it with the model on the bench rather than in the air.

*ELRS -> RF* writes the flight controller's configuration and commits it to permanent storage, the
same as a save on any other page.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/) — the `crsf_telemetry_mode`,
  `crsf_telemetry_link_rate` and `crsf_telemetry_link_ratio` settings this page writes.
- [ExpressLRS documentation](https://www.expresslrs.org/) — what packet rate and telemetry ratio
  do to the link.

*Documented against RFSuite 0.1.7.*
