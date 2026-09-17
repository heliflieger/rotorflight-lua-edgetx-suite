---
title: Session Logs
sidebar_label: Session Logs
sidebar_position: 60
---

# Session Logs

The suite keeps its most recent log lines in memory while it runs. This page shows them, so a
problem that has just happened can be read on the radio without taking the card out.

## Where to find it

*Tools* → *Diagnostics* → *Session Logs*

Always available. The page keeps following the log while the model is disarmed; while it is
armed it shows what it had when the model was armed and RELOAD is refused, as it is everywhere
else in the tool.

## What it shows

One line per log entry, oldest at the top and newest at the bottom:

```
[123.4] [rfsuite] some message
```

| Part | What it is |
| --- | --- |
| `[123.4]` | Seconds since the radio was switched on. Left out where the radio cannot give a time. |
| `[rfsuite]` | Which part of the suite wrote the line. |
| The rest | The message. |

A line that is wider than the screen is cut short and ends in `...`. As many of the newest lines
are drawn as fit on the page; there is nothing to scroll, so an older line that has been pushed
off the top cannot be brought back.

Each line is coloured by its level, and *debug* and *trace* lines are dimmed so that *error*,
*warn* and *info* stand out.

The page redraws itself whenever a new line arrives, so what is on screen is the current end of
the log. **RELOAD** draws it again and changes nothing else.

## Notes

**The list is short and it is only in memory.** It holds the last 60 lines and shortens a message
to 100 characters before storing it. It belongs to the script that is running — the configuration
tool has one, the dashboard widget has another — so this page shows the tool's, and it is empty
again the next time the tool is opened.

**Which lines reach it depends on the debug level.** *error*, *warn* and *info* are kept whatever
*Debug Level* is set to, including *OFF*. *debug* and *trace* lines are only kept once *Debug
Level* is raised to them, under *Developer* → *Settings*. That menu appears once *Developer Tools*
is switched on under *Settings* → *General*.

**For anything that has to survive the radio being switched off**, or that has to be attached to a
report, switch on *Log Session To Card* on the same Developer page. That writes the log to the
card, where it outlives the session.

## Related

- [Collecting logs for a report](../../../troubleshooting/collecting-logs.md) — which settings to
  turn on, where the files land, and which of them to attach.

*Documented against RFSuite 0.1.7.*
