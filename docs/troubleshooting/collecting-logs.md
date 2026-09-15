---
title: Collecting logs for a report
sidebar_label: Collecting logs
---

# Collecting logs for a report

The suite keeps its log in memory and shows it under *System* → *Tools* → *Diagnostics* →
*Session Logs*. That ring belongs to the script that holds it, so it is gone the moment that
script stops — which is exactly the case a report is usually about. Writing the log to the card
is what survives it.

## Switching it on

*System* → *Settings* → *General* → **Developer Tools**, which makes the *Developer* tile
appear, and then *System* → *Developer* → *Settings*:

| Setting | What to set it to |
| --- | --- |
| **Debug Level** | *INFO* for a first report. *DEBUG* for a problem that needs the steps in between, and it is also the level from which the background decoder keeps a record of its own. *TRACE* only when asked — it prints the decoded telemetry payloads and fills a file in seconds. |
| **Log Session To Card** | On. Nothing is written to the card while this is off, whatever the debug level says. |

**Both are needed, and neither alone does anything.** *Log Session To Card* decides whether the
card is written at all; the debug level decides what is worth writing. A report asked for with
one of them set comes back empty.

Switch both back off once the report is sent. The card write is small but it is permanent, and
*TRACE* left on costs a measurable part of every pass.

## Where the files land

`/SCRIPTS/TOOLS/rfsuite.user/logs/`, and there is one set per part of the suite that runs in a
script of its own:

| Prefix | Written by |
| --- | --- |
| `tool_` | The configuration tool, while it is open. |
| `widget_` | The dashboard widget and the service widget, which share a script. |
| `function_` | The background decoder special function, if the model runs it and the debug level is *DEBUG* or *TRACE*. |

Each of those writes **two files**, and they answer different questions:

- **`<prefix>_1.log` … `<prefix>_10.log`** — the log itself. Ten slots, reused in turn, so the
  last ten sessions are on the card and the eleventh overwrites the first. It is written every
  few seconds, so the last few seconds before a freeze can be missing from it.
- **`<prefix>_step.txt`** — one line, saying the last thing that was started and how much Lua
  memory was in use at that moment. It is rewritten and closed on the spot, so it is there even
  when the radio stopped without warning. Its timestamp is how far that part of the suite got.

`<prefix>_seq.txt` is only the counter that decides which slot is next.

## The two lines worth reading first

**`widget_step.txt` says what the dashboard was doing.** While the suite connects it names the
task it is on; afterwards it names the class of work of the last screen it built — *splash*,
*scene*, *menu* or one of the tuning surfaces. So a radio found stopped tells you which of those
it was in the middle of.

**`function_step.txt` says whether the dashboard is still running at all**, which is the one thing
the dashboard cannot say about itself. When a widget uses more than its share of a cycle the radio
stops calling it, and it cannot write down that this happened to it. The background decoder runs
outside the widgets and keeps watching, so its line reads:

```
dashboard widget silent 3.0 s, last pass 56 %
```

The percentage is what the dashboard's last cycle cost, out of what it is allowed. Near or above
100 is the reading that explains a dashboard that stopped drawing.

Both need the background decoder on the model and the debug level at *DEBUG* or above.

## What to attach

Take the card out and copy the whole `logs` folder. If that is too much, the useful minimum is:

- Every `*_step.txt` — they are one line each and they are the part that survives a freeze.
- The newest `.log` of the part that misbehaved, and the newest `tool_*.log` if the tool was
  open at the time.
- What you did, in the order you did it, and what the screen showed.

The first line of every `.log` names the radio, the screen size, the EdgeTX version and the
suite version, so that does not have to be written out separately.

## Notes

- **A file that is not there is an answer too.** No `function_*` file means either that the debug
  level was below *DEBUG* or that the background decoder was not running on that model — see
  [the background decoder](../reference/background-decoder.md). No `widget_*` file after a
  session with the dashboard on screen means the widget never got as far as writing one.
- **A widget that overran its instruction budget cannot report it.** The radio stops calling a
  widget that does, so the last thing in `widget_1.log` is the approach to the fault and never
  the fault. The background decoder's files are not affected: its script is paused and resumed
  rather than cut off.
- **Opening the configuration tool pauses the background decoder** for as long as the tool is
  open, so a gap in `function_*` over that stretch is expected.
- **A session file stops at 5000 lines** and says so on its last line, rather than dropping its
  middle. At *TRACE* that is reached in well under a minute.
