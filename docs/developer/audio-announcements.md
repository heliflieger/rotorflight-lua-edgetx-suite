---
title: Adding an announcement
sidebar_label: Audio announcements
sidebar_position: 70
---

# Adding an announcement

Everything the suite says out loud is decided in one file, `src/rfsuite/lib/audio.lua`, and
switched on from one settings page family, `src/rfsuite/app/pages/settings/audio/events/`. An
announcement is four things: the condition that fires it, the switch that allows it, the words in
both locales, and the WAV file. This page is the checklist for all four.

## Where the engine runs

`Audio.process(self, opts)` is called from two places, and they hand it the same shape:

| Caller | When |
| --- | --- |
| `widgets/dashboard/runtime.lua`, `processAudioEvents` | every logic tick while `startupComplete` |
| `ui/home.lua`, the audio block | every 200 ms while the tool has a connection |

`self` carries `audioState` (the engine's own memory), `preferences` (the radio's settings) and
`state` (the telemetry snapshot). **Both callers must supply the same fields under the same
names**, or an announcement works under the widget and is silently mute under the tool. That
symmetry is the reason the tool builds its `telemetryState` the way the widget's `readTelemetry`
does, rounding included; if you read a new field, check both sides write it.

`Audio.process` throttles itself to 0.25–0.60 s depending on the screen height, so it is cheap to
call and you do not need a throttle of your own. What you do need is a re-alert interval: every
repeating alert in the file uses **10 seconds**, kept in `audioState.lastAlertAt.<key>`.

`Audio.resetConnectionState(audioState)` runs when a connection goes down. Anything your
announcement latches — "already said once this session", "the threshold is currently breached" —
belongs in that function's clear list, or it will carry into the next flight.

## The switch

Every switch is one row in `CONFIG_SCHEMA` in
`app/pages/settings/audio/events/category_page.lua`. That one table is the single source of
truth: it says the key, the type, the default, the valid range and which page draws it.

```lua
{ key = "mcu_temperature", type = "bool",   default = false, section = "esc" },
{ key = "mcu_threshold",   type = "number", default = 80, min = 40, max = 150, section = "esc" },
```

Then one item in `SECTIONS[<section>].items` decides how it is drawn — `bool`, `number`,
`choice` or `subheader`, with `labelKey`/`labelFallback`, an optional `suffix`, and either
`enabledBy` (drawn always, editable only while that switch is on) or `requires` (not drawn at
all while that switch is off).

Nothing else is needed: the loading, clamping, saving and per-page split are generic. A field
marked `scope = "model"` is stored with the model rather than with the radio.

The engine reads the same keys through `prefEnabled(events, "key", default)`, and **the default
passed there must match the schema's**, because a settings file written before your key existed
has no value for it. `[audio_events]` is an open section of the radio-wide store
(`lib/preferences.lua`), so a key this page adds is kept without being declared a second time
there.

## The words

Two files, both required: `src/rfsuite/i18n/en.lua` and `de.lua`, under
`app.pages.settings_audio_events`. Add the row label, and any section header you introduced. The
page's own `help_message` lives beside it under `settings_audio_events_<page>` and has to be
updated in the same change — the page and its `?` button may not disagree.

Keys must be complete string literals. The precompiler cannot follow a key that is assembled at
runtime, and an unresolved key ships to the radio as a raw marker with nothing going red.

## The WAV file

Announcements play through `Audio.playEventFile(path)` or, inside the engine,
`tryPlayEventFile(audioState, now, path, opts)`. The path is relative to the pack root:
`evt/…`, `gov/…`, `adj/…`, `stat/alerts/…`.

`resolveEventPath` looks for `/SOUNDS/rf/<language>/<path>` first and `/SOUNDS/<language>/<path>`
second, and caches the answer — including a miss, so a probe for a file that is not there costs
one open per session. That makes an optional file cheap:

```lua
local soundFile = "stat/alerts/notfull.wav"
if not resolveEventPath(soundFile) then
  soundFile = "stat/alerts/voltage.wav"   -- every pack has this one
end
```

Prefer that shape to assuming a file exists. A pack the pilot installed months ago will not have
the file your announcement was written against.

To speak a number after the file, use the radio's own teller — `playNumber(value, unit, attribute)`
— rather than a spoken-number WAV. It follows the language set on the radio, which the pack does
not.

**The file itself is generated, not recorded.** Add one entry to `bin/sound-generator/json/en.json`,
run `update-missing-translations.py`, fill in the other languages, and build. See
[`bin/sound-generator/README.md`](../../bin/sound-generator/README.md). Until a pack carries the
file, the announcement is silent — which is why the fallback shape above is worth using.

## What the packager ships

`bin/package/build_package.py` copies, per language, exactly these folders out of
`src/rfsuite/audio/<language>/`: `adj`, `app`, `evt`, `stat`, `gov` — into `SOUNDS/rf/<language>/`
on the card. A new top-level folder would not be copied. The loose tones at the root of the audio
tree (`beep.wav`, `multibeep.wav`, `warn.wav`, `alarm.wav`) are copied into `SOUNDS/rf/`
separately; they are not part of the word lists and are not generated.

## A trap worth knowing before you audit anything

Several paths are **built by concatenation**, not written out: `"gov/" .. file` and
`"evt/" .. file` in `lib/audio.lua`, and `"adj/" .. words[i]` in
`tasks/events/telemetry_bg/adjustments.lua`. A search for `"gov/active.wav"` finds nothing and
the file is used on every flight. Any sweep for unused audio has to account for the constructed
paths, or it will report two thirds of the pack as dead.

## Checklist

1. `lib/audio.lua` — the condition, a re-alert interval of 10 s, the state cleared in
   `Audio.resetConnectionState`.
2. Check both callers supply the telemetry field you read.
3. `category_page.lua` — one `CONFIG_SCHEMA` row and one `SECTIONS` item; the same default in
   `prefEnabled`.
4. `i18n/en.lua` and `i18n/de.lua` — the label, any new header, and the page's `help_message`.
5. `bin/sound-generator/json/*.json` — the line to speak; `--check` must come back clean.
6. `docs/audio/events.md` — the announcement, its switch, its default and what fires it.
7. `Releases.md` — an entry under the active release header.
