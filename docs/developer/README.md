---
title: Developer guides
sidebar_label: Developer
---

# Developer guides

For contributors. [DEVELOPMENT.md](../../DEVELOPMENT.md) covers the workspace, the build
and CI; [GEMINI.md](../../GEMINI.md) the code conventions, logging and the reactive-closure
rule for the dashboard; `bin/accounting/README.md` the instruction budget. These files are
the "how do I add one of these" guides that none of the three carries, ordered by how often a
contributor needs them.

| File | What it will say | Start from | Status |
| --- | --- | --- | --- |
| `adding-a-page.md` | The three files a page is registered in (`app/pages/init.lua`, `app/manifest.lua`, the page folder with `page.lua`, `icon.png` and `help.lua`), the lifecycle hooks the host calls, every registry attribute and the condition keys behind them. | source | to write |
| `controls.md` | Every `Controls.append*` helper with its arguments and its returned row height, the display-profile metrics a page lays out against, and the `markDirty` versus `markValueChanged` rule for number fields. | GEMINI.md names three helpers | to write |
| `i18n.md` | The call forms the precompiler recognises, why a key must be a string literal, that a packaged install carries no locale bundle at all, and the CI gate behind it. | DEVELOPMENT.md, Localization | to write |
| `saving-and-reboot.md` | The three save paths (`SavePipeline`, the `eepromWrite` flag, preferences only) and how to pick one, the pipeline descriptor and its phases, the reboot policy table, and the armed lock. | the comment block in `tasks/msp/save_pipeline.lua` | to write |
| `msp-api-modules.md` | The flat module contract under `tasks/msp/api/`, `parse` returning `nil` for no data, the queue message record with its retry and client rules, and why `simulatorResponse` is not optional. | source, `bin/accounting/README.md` | to write |
| `dashboard-themes.md` | The `init.lua` key set, the phase-module shapes and their fallback chain, the layout and box vocabulary with the object types, the `configure.lua` factory and its key-prefix rule, and the budget row a shipped theme owes. | source | to write |
| [`audio-announcements.md`](audio-announcements.md) | That announcements live in `lib/audio.lua`, the schema in `settings/audio/events/category_page.lua` that generates every settings page, the WAV folders the packager copies, the word lists the pack is built from, and the checklist for one new announcement. | source | written |
| `preview-features.md` | The five-step recipe for putting an unfinished feature behind its own switch, and why the tile uses `visibleWhen` rather than `hideWhenDisabled`. | the comment in `settings/general/page.lua` | to write |
| `releases-and-versioning.md` | The `Releases.md` header grammar the release-notes extractor depends on, the `version.lua` bump, and the tag flows. | DEVELOPMENT.md, Continuous integration | to write |
| `background-tasks.md` | The `tasks/events/` runner: task module shape, the ordered manifests, the tool/widget context gate, and the arm and disarm edges. | source | to write |
