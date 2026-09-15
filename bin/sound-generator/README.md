# The announcement pack

Every file under `src/rfsuite/audio/<language>/` is synthesised, not recorded. This folder holds
the word lists it is built from and the script that builds it, so a new announcement is a line of
text in a reviewable file rather than a binary somebody has to produce by hand.

The generator is the one from the Ethos suite (`bin/sound-generator/generate-googleapi.py` there),
adapted in three places: it writes into this tree's layout, it adds the conversion this radio's
firmware needs, and it gained a `--check` mode that needs no credentials.

## The lists

`json/en.json` is the master. Each entry is one file:

```json
{ "file": "stat/alerts/lq.wav", "english": "Link Quality", "translation": "Link Quality", "needs_translation": false }
```

`file` is the path below `src/rfsuite/audio/<language>/`, which is also the path `lib/audio.lua`
asks for. Adding an announcement means adding one entry to `json/en.json` and running

```
python bin/sound-generator/update-missing-translations.py
```

which gives every other language the same entry with `translation: null` and
`needs_translation: true`, keeping the translations that are already there. It writes the lists
back sorted and with a fixed indent, so a change to one line stays a one-line diff.

An entry whose `translation` is `null` is not skipped -- it is spoken in English by that
language's own voice. That is deliberate (an announcement that says the wrong language is better
than one that says nothing), and `--check` lists them so it does not go unnoticed.

## Check

```
python bin/sound-generator/generate-googleapi.py --check
```

Needs nothing but Python, and is the mode to run when reviewing a change to the lists. It reports
three things per language and exits non-zero on the first two:

- **MISSING** -- declared in the list, no file on disk. The pack cannot say it.
- **UNDECLARED** -- a file on disk with no entry. Nobody can rebuild it, and nobody knows what it
  says.
- **NO TEXT** -- an entry with no translation, so it will speak English.

## Build

```
python bin/sound-generator/generate-googleapi.py --lang en --only-missing
python bin/sound-generator/generate-googleapi.py --dry-run          # what would be built, and where
```

`--dry-run` needs no credentials either and is worth running first: it prints every destination
path, so a mistake in a `file` entry shows up before anything is synthesised.

Building for real needs three things:

- `pip install google-cloud-texttospeech sox`
- the `sox` binary on the path
- Google Cloud credentials in the environment, for a project with the Text-to-Speech API enabled

`--cache <dir>` keeps every synthesised line keyed on its text and voice, so re-running after
adding one entry costs one API call.

## The voices, and why they are not a parameter

| Language | Voice |
| --- | --- |
| `en` | `en-US-Wavenet-F` |
| `de` | `de-DE-Wavenet-E` |

They are a table in the script rather than a command-line default, because changing one
re-renders that whole language and the result will not match the files already in the tree.
`--voice` overrides it for a run, which is what building a new language starts with.

## The audio chain, and why the A-law step is not redundant

1. Google Cloud Text-to-Speech, `LINEAR16` at 16 kHz mono.
2. SoX to **G.711 A-law**, mono 16 kHz, with the trailing silence trimmed
   (`reverse silence 1 0.1 0.1% reverse`).
3. SoX again to signed 16-bit PCM, which is what the firmware plays.

Step 2 looks pointless next to step 3 and is not: A-law quantises to 255 levels, and that
quantisation is audible as the pack's character. Every file shipped today carries it -- their
sample values all sit on the A-law decode grid -- so a file rendered straight to clean 16-bit PCM
sits noticeably brighter than the ones around it. The step is there to keep a new file sounding
like its neighbours.

Files written by this script carry SoX's own header rather than the writer tag on the files
shipped today. The audio is what matters; the differing tag is not a defect.
