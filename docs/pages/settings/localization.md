---
title: Localization
sidebar_label: Localization
sidebar_position: 30
---

# Localization

The language RFSuite runs in, and the unit formats its readouts use. Left on *Automatic*, the
language follows the card or the radio instead of being pinned to one value.

## Where to find it

*System* → *Settings* → *Localization*

Always available.

## Settings

| Setting | What it does |
| --- | --- |
| Language | *Automatic* (the default) follows the card's own language on a packaged build, and the radio's language setting when the suite runs from source or in the simulator. *English* or *German* pins the language instead: the choice is stored on the radio and wins over the automatic resolution. |
| Temperature Unit | *Celsius* or *Fahrenheit* for every temperature the suite shows — the flight log's columns and the dashboard's gauges and text readouts. |
| Altitude Unit | *Meter* or *Feet*. Stored like the other two, but nothing reads it yet, so it changes no readout today. |

## Notes

- Only an explicit choice is written. *Automatic* is the **absence** of the `language` key in
  `preferences.ini`, which is what the resolution reads; choosing *Automatic* again removes the
  line and hands the decision back to the card or the radio. It is the only way back from this
  page, and saving the page for another reason — a unit change, say — never writes the key.
- A language takes effect immediately after saving rather than at the next boot: the tool, the
  dashboard themes and the audio folder all switch over.
- The two unit settings do not reach the flight controller; they are settings of this radio and
  apply to every model.

Related: [configuration-files.md](../../reference/configuration-files.md) for the file itself and
what the suite keeps in it.

*Documented against RFSuite 0.1.7.*
