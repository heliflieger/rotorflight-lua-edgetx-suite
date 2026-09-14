---
title: Configuration files
sidebar_label: Configuration files
---

# Configuration files

Everything you change in the suite is kept in two files on the radio's SD card, under
`/SCRIPTS/TOOLS/rfsuite.user/`:

| File | What is in it |
| --- | --- |
| `preferences.lua` | The settings that belong to the transmitter: the announcements, the units and language, the preview switches, the logging level, which dashboard theme is shown. |
| `<mcu id>.lua` | The settings that belong to one flight controller, named after the board's own id — the battery, the per-model theme override and its configuration, the in-flight tuning setup, what the setup assistant has been told about the machine. One file per board. |

You do not have to touch either of them. They are written when you press *Save*, and reading
them is all the suite needs at startup.

## They are Lua, not INI

Both files are a small Lua program that returns a table, so the radio can read one without
picking it apart line by line:

```lua
-- RFSuite preferences. This file is Lua data, not an INI: strings keep their
-- quotes, booleans are true or false, and the return line stays. Rewritten whole on save.
return {
  general = {
    debug_level = "off",
    save_confirm = true,
  },
  localizations = {
    temperature_unit = 0,
  },
}
-- generation 7 ......
```

That matters for what a widget costs. The dashboard re-reads the settings whenever they change,
inside a call the radio stops at a fixed instruction count — and taking a file apart line by
line is by far the most expensive thing it did there. Reading a real 88-key settings file used
to cost about half of everything one dashboard call is allowed; it now costs a sixteenth of it,
and it no longer grows meaningfully with each setting a release adds.

### Editing one by hand

It is a text file and you may edit it, with the radio switched off or the tool closed. Three
rules, and they are the ones Lua enforces:

- **Text needs quotes**: `debug_level = "info"`. A bare word is read as a name and there is
  nothing for it to name.
- **Yes and no are `true` and `false`**, without quotes. Numbers are written plainly: `30`,
  `3.2`.
- **Keep the frame**: the `return {` at the top, the `}` at the bottom, and a comma after every
  entry.

The file is rewritten whole on the next save, so a comment you add to it does not survive and a
setting the suite does not know about is dropped. The `-- generation` line at the end is the
suite's own; it changes on every save so that the dashboard can see that something was written.

**If a hand edit breaks the file**, nothing is lost and nothing crashes: the suite falls back to
its built-in defaults for that file, writes the reason and the line number to the log, and the
next save replaces the file with a correct one. The one thing to know is that the settings that
were in it are then gone — so keep a copy before editing.

## Coming from an earlier release

Earlier releases kept the same settings in `preferences.ini` and `<mcu id>.ini`, and the model
names in `model_name_restore.ini`. The files are **brought across the first time the
configuration tool is started**, or by the [background telemetry
decoder](background-decoder.md) on a radio that runs it. Until one of those has happened, the
former file is read exactly as it was before and nothing is written — so a radio that is
switched on and flown without opening the tool behaves as it always did, and the settings are
there either way.

What the migration does:

- the values are read out of the `.ini` and written into the `.lua` beside it,
- the `.ini` is kept, renamed to `.ini.bak`, for one release,
- settings that no longer exist in the suite are not carried over — that is deliberate, and it
  is what stops a file from growing for ever. A whole section that no longer exists goes the
  same way: an older `preferences.ini` may still carry `[audio_switches]` and `[audio_timer]`,
  and neither is written into the new file,
- a `preferences.luac` left behind by an earlier loader is deleted, because the radio would
  prefer that stale compiled copy to the file you can read.

There is nothing to do and nothing to confirm. You can delete the `.ini.bak` files once you are
happy; the suite never reads them again.

The dashboard widget does not do the migration itself, and that is deliberate: the radio stops
a widget after a fixed amount of work, and reading a settings file in the old format is more
than that allowance — so a widget that tried would be stopped half way, every time, and never
finish. The tool and the background decoder are not stopped that way.

## The other files beside them

- `reload.req` — a few bytes the tool writes when you save, so the dashboard widget knows to
  re-read the settings. Unchanged by the move to Lua files. Do not delete it while the suite is
  running.
- `model_name_restore.lua` — the model names the suite has renamed while a craft was connected
  and has to put back afterwards, one entry per model of the radio, named after the model file
  it belongs to. The same Lua data as the two above, written and read the same way, and a card
  from an earlier release has its `model_name_restore.ini` brought across on the first read with
  the same `.ini.bak` left beside it. It is a file of its own rather than a section of
  `preferences.lua` because it is written while you fly, and every write to `preferences.lua`
  makes the dashboard re-read its settings.
- `preferences.lua.tmp`, `<mcu id>.lua.tmp` or `model_name_restore.lua.tmp` — a save that was
  interrupted, by a power cut at exactly the wrong moment. The next read finishes it; you should
  never see one for long. If a write fails or the card is full, the temporary file is removed
  immediately and the existing configuration is kept intact.

## Related

- [Background telemetry decoder](background-decoder.md)
