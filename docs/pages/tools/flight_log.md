---
title: Flight Log
sidebar_label: Flight Log
sidebar_position: 30
---

# Flight Log

A line per flight, written to the card when the craft disarms: when it flew, on which model, on
which pack, how long it was armed, and what the flight's telemetry reached. The page lists those
lines, newest first, and opens one to show the flight in full.

## Where to find it

*Tools* → *Flight Log*

Hidden until *System* → *Settings* → *General* → *Preview* → *Flight Log* is on. Read-only while
the model is armed.

## Settings

The log itself is switched on under *Settings*, not here. This page only reads what has been
written.

| Setting | What it does |
| --- | --- |
| Log flights | Off by default. While it is off nothing is written, and this page stays empty. |
| Minimum flight | An arm shorter than this is a spool-up check rather than a flight, and is not logged. 30 s by default; 0 logs every arm. |

## What a line holds

The first five fields are always there: the date and time the craft armed, the model name, the pack
the flight was flown on, and the armed seconds.

Everything after them is the flight's own statistics, taken from the record the suite keeps while
the craft is armed. A field that was never recorded is left empty, so a line may carry all of them,
some of them or none.

| Column | What it is |
| --- | --- |
| `mah` | Capacity used, as the flight controller reported it |
| `vcel_min`, `vcel_max` | Lowest and highest pack voltage, per cell |
| `curr_min`, `curr_max` | Lowest and highest current |
| `tesc_min`, `tesc_max` | Lowest and highest ESC temperature |
| `vbec_min`, `vbec_max` | Lowest and highest BEC voltage |
| `hs1_min` … `hs3_max` | Headspeed per PID profile — not recorded yet, always empty |
| `sags`, `sag_min` | Voltage-sag events — not recorded yet, always empty |

Per-cell voltage needs a cell count, which comes from the flight controller's battery
configuration. On a model where that has not been read, the two per-cell columns stay empty rather
than being divided by a guess.

A flight that produced no statistics at all — telemetry gone for the whole armed window — is
written as the five-field line it has always been, rather than as a line of empty columns.

## Notes

The file is plain text, one flight per line, with a header naming every column. It is meant to be
opened on a computer as well as here; editing a line on the card changes what this page shows and
leaves the rest of the file alone.

The battery registry beside it is the same kind of file. A pack picked under *Batteries* goes into
the flight's line, and that pack's first flight of a session counts one cycle against it.

*Documented against RFSuite 0.1.7.*
