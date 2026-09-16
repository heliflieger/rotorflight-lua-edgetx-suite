# Development

Everything in this file is about working on RFSuite. If you only want to install and use it,
the [README](README.md) is the whole story.

The project conventions the sources follow — module loading, UI helpers, logging, memory
handling and the i18n rules — are in [GEMINI.md](GEMINI.md).


## Repository layout

| Path | What it is |
| --- | --- |
| `src/main.lua` | The tool entry point, deployed as `SCRIPTS/TOOLS/rfsuite.lua` |
| `src/rfsuite/` | The core package, deployed as `SCRIPTS/TOOLS/rfsuite-core/` |
| `src/rfsuite/app/` | Menu manifest, registry and the configuration pages |
| `src/rfsuite/core/` | Viewport abstraction and the per-radio display profiles |
| `src/rfsuite/layouts/` | The Border, Grid and Flow layout engines |
| `src/rfsuite/ui/` | Screens and the shared controls in `controls.lua` |
| `src/rfsuite/lib/` | Logging, preferences, sensors and other supporting libraries |
| `src/rfsuite/tasks/` | MSP transport, the MSP API modules and the background event tasks |
| `src/rfsuite/widgets/` | Dashboard runtime, objects and themes |
| `src/rfsuite/i18n/` | Locale bundles, one Lua file per language |
| `src/widgets/rfsuite/` | The dashboard widget, deployed as `WIDGETS/rfsuite/` |
| `src/widgets/rfsuitesvc/` | The background service widget, deployed as `WIDGETS/rfsuitesvc/` |
| `docs/` | The user-facing reference, one file per page, and the contributor guides; see below |
| `bin/package/` | The installation ZIP builder |
| `bin/accounting/` | The instruction-budget accounting that gates every pull request; its own notes are in `bin/accounting/README.md` |
| `bin/sensors/` | The simulator sensor tool |
| `simulator/` | The SD card root the EdgeTX simulator is pointed at; see below |
| `.vscode/` | Deploy and simulator tasks, and the i18n build scripts |

The deployed layout — on the simulator's SD card, on a radio and inside the release archive
alike — is:

```
SCRIPTS/TOOLS/rfsuite.lua        tool entry point
SCRIPTS/TOOLS/rfsuite-core/      core package
SCRIPTS/TOOLS/rfsuite.user/      user settings, model preferences, user themes
WIDGETS/rfsuite/                 dashboard widget
WIDGETS/rfsuitesvc/              background service widget
SOUNDS/rf/                       announcement pack, one folder per language
```


## The `simulator/` folder

`simulator/` is a checked-in SD card root for the EdgeTX simulator: a radio configuration, one
model, and the SD card version markers the firmware expects. It exists so that a fresh clone
can run the suite without hand-building a card, and it is a development aid only — nothing in
it ships to users, and the release archive does not contain it.

The deploy task copies the sources into this folder, and the simulator tasks start
`simulator.exe` with `--sd-path` pointing at it. `.gitignore` excludes `simulator/*`, so the
deployed `SCRIPTS`, `WIDGETS` and `SOUNDS` folders stay out of the repository; only the card
files themselves are tracked.


## Running it

The `.vscode` folder carries run configurations and tasks for the usual loop.

| Run configuration | What it does |
| --- | --- |
| `RFSuite: Deploy to Simulator` | Copies the sources into `simulator/` |
| `RFSuite: Deploy to Radio` | Copies the sources onto a mounted radio SD card |
| `RFSuite: Build Radio Install ZIP` | Builds the installation archive |
| `RFSuite: Deploy + Run Simulator (TX16S MK3)` | Deploys, then starts the simulator |
| `RFSuite: Deploy + Run Simulator (TX16S)` | as above, for the TX16S |
| `RFSuite: Deploy + Run Simulator (TX15)` | as above, for the TX15 |
| `Sensors: Run Tool` | Starts the simulator sensor tool |
| `Sensors: Build + Run Tool` | Rebuilds the sensor tool first |

The simulator tasks pass one of the radio targets `edgetx-tx16smk3`, `edgetx-tx16s` or
`edgetx-tx15`. The matching `RFSuite: Start EdgeTX Simulator (…)` tasks start the simulator
without deploying first.

### Simulator path

The simulator executable is taken from the `rfsuite.simulatorPath` setting, so no task
definition has to be edited when a Companion release moves. Set it once in your **User
Settings** (`Ctrl+Shift+P` → `Preferences: Open User Settings (JSON)`):

```json
{
  "rfsuite.simulatorPath": "<the simulator executable shipped with EdgeTX Companion>"
}
```

That is `simulator.exe` in Companion's `bin` folder on Windows, and the `simulator` binary
beside Companion elsewhere. Backslashes have to be escaped in JSON.

### Radio SD card path

`RFSuite: Deploy to Radio` auto-detects mounted radio storage. If it picks the wrong volume, or
finds none, set the SD card root explicitly:

```json
{
  "rfsuite.radioSdPath": "<the mounted radio storage>"
}
```

This must be the root of the mounted storage — the folder that holds `SCRIPTS`, not `SCRIPTS`
itself.

### Deploy language

Deploys resolve their language from `rfsuite.deploy.language`, read from workspace settings,
the workspace file, user settings or a settings profile, in that order, and falling back to
`en`:

```json
{
  "rfsuite.deploy.language": "en"
}
```


## Building the installation archive

The archive builder is `bin/package/build_package.py`; `package.cmd` and `package.sh` are thin
local wrappers around it.

```bash
cd bin/package
./package.sh en 0.1.0-local        # or: package.cmd en 0.1.0-local
```

Both arguments are optional and default to `en` and `local-test`. The result is
`rfsuite-radio-install-v<version>_<lang>.zip` next to the script.

The build stages the deployed layout in a temporary folder, generates the dashboard theme index
from the themes it finds, resolves the i18n markers for the chosen language, and zips the
result. Bytecode (`.luac`) is never packaged.


## Localization

User-visible strings are never written into the code. A source carries an `@i18n(key)@` marker,
or calls `i18n.t(key)` at runtime, and the locale bundles in `src/rfsuite/i18n/` hold the text.
Every language present there is a language the packager can build.

Two scripts turn the markers into text at package and deploy time:

- `.vscode/scripts/precompile_i18n.py` collects the strings a page builds dynamically
- `.vscode/scripts/resolve_i18n_tags.py` substitutes the markers from one locale bundle

A key that has no entry in the chosen bundle survives into the package as a literal
`@i18n(...)@` marker and shows up that way on the radio, so check the resolver's output when
adding strings.


## Style

`.luacheckrc` is the style reference: `std = "lua54"`, `max_line_length = 140`,
`unused_args = false`, plus the globals the EdgeTX Lua environment provides. No CI job runs
`luacheck` at present.

Follow the indentation of the file you are editing and avoid reformatting untouched lines — a
whitespace-only diff buries the change a reviewer is looking for.


## Continuous integration

| Workflow | Trigger | What it produces |
| --- | --- | --- |
| `pr.yml` | pull request | The per-locale installation archives as a build check, plus the instruction-budget gate (`bin/accounting/measure.lua --check`), the i18n precompiler test, the documentation-rule check (`bin/docs/verify_documentation_rule.py`) and the translation-coverage report (`bin/i18n/check_translations.py`) |
| `push.yml` | push | The per-locale installation archives |
| `snapshot.yml` | tag `snapshot/*` | A snapshot release with the per-locale archives |
| `release.yml` | tag `release/*` | A GitHub release, with notes extracted from `Releases.md` |
| `testing.yml` | tag `testing/*` | A raw `src` artifact, then deletes the tag again |

A release tag of the form `release/<x>.<y>.<z>-<suffix>` is published as a Release Candidate;
without the suffix it is published as a Release. The version baked into the package itself
comes from `src/rfsuite/lib/version.lua`.


## Documentation

`docs/` holds the user-facing reference: one file per configuration page under `docs/pages/`,
mirroring the layout of `src/rfsuite/app/pages/`, plus the dashboard, audio, reference,
troubleshooting and developer sections. It is plain Markdown, versioned with the code, and it
is not part of the installation archive: the packager stages `src/` only, so nothing in
`docs/` reaches a radio.

Every change a pilot can observe is documented in the same pull request that makes it. The
rule is in [GEMINI.md](GEMINI.md) under *Documentation Maintenance* and in
`.agents/rules/documentation.md`, in the same shape as the rule for `Releases.md`. The page
template is `docs/_template.md`, and `docs/pages/README.md` lists every page with whether its
file is written yet.


## Sensor tool

`bin/sensors/` holds a small GUI that feeds telemetry into the simulator, so dashboard themes
and telemetry pages can be worked on without a flight controller. It writes per-sensor Lua
files into the simulator target and supports fixed values, sliders, dropdowns and random
variance. Its own notes are in `bin/sensors/README.md`; rebuild it with the
`Sensors: Build Tool` task.
