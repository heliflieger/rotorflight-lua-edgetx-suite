---
title: No connection to the flight controller
sidebar_label: No connection
---

# No connection to the flight controller

The tool stays on its start screen, every tile is greyed out, and the dashboard shows no
values off the flight controller. This page is the order to check things in.

## What has to be true

- **The transport is CRSF.** The suite speaks MSP over CRSF (including ELRS) and over nothing
  else. A model bound over a protocol the radio cannot push CRSF frames on has no MSP link at
  all, and the log says `MSP transport unavailable`.
- **Telemetry is on for the model**, and the radio is receiving it. The suite treats the link as
  up while the receiver reports RSSI; with no telemetry there is nothing to report and nothing
  is sent.
- **The receiver forwards MSP to the flight controller.** A receiver passing telemetry but not
  MSP gives a link the suite considers up, on which nothing is ever answered. The tool then
  shows *No MSP reply from flight controller (cmd=1)*, and the log carries
  `API_VERSION read failed repeatedly`.
- **The firmware's MSP API version is one the suite speaks** — 12.08, 12.09 or 12.10. An older
  board raises the *Unsupported MSP API* dialog rather than staying silent.

## What the suite does when it connects

Two sequences run, and both have to finish before everything is available:

1. **The handshake**, in the MSP runtime: the API version (MSP 1), the firmware version (MSP 3)
   and the board's unique id (MSP 2). The link counts as connected only once the API version has
   been read and accepted, which is what the tool's start screen and the dashboard's connected
   state wait for. The unique id is what the per-model preferences file is keyed by.
2. **The connect tasks**, one per pass: the status, the telemetry configuration, the battery and
   governor configuration, the model name, the clock, and the rest. Most of them are one MSP
   round trip, so the sequence takes a few seconds on a healthy link.

## Arming during those few seconds

**Configuration traffic is not sent while the model is armed.** On the first armed pass the MSP
queue is emptied and nothing further is queued until the model is disarmed; the log says
`MSP paused while ARMED` and `MSP resumed after DISARM`.

If you arm while the two sequences above are still running, the requests that were in flight are
dropped. They are asked for again once you disarm, and the connection then completes normally —
there is nothing to do but land, and no need to power-cycle anything.

## Reading the log

Switch *Log Session To Card* on and set the debug level to *DEBUG* (see
[Collecting logs](collecting-logs.md)), then reproduce it. The lines worth finding, in order:

| Line | What it means |
| --- | --- |
| `MSP runtime initialized via crsf` | the transport was found. `via simulator`, or `MSP transport unavailable`, means it was not |
| `MSP link connected` | the receiver reports RSSI |
| `tx cmd=1 …` followed by `rx cmd=1 …` | the board answered the API version read; this is the one that has to happen |
| `API_VERSION read failed repeatedly (no MSP reply)` | the request went out and nothing came back: telemetry is up, MSP is not getting through |
| `Unsupported MSP API version …` | the board answered, and the suite refuses that version |
| `queue cleared client=ALL …` | something took the queued requests away — the armed gate above, or a page being closed |
| `completed task <name>` | one connect task finished |

## What to attach to a report

- The session file covering the power-up, from the card's log directory.
- The flight controller's firmware version and its MSP API version, if the tool got far enough
  to show them.
- The receiver, and whether it is CRSF or ELRS.
- Whether the model was armed at any point during the start.
