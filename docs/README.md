---
title: Documentation
sidebar_label: RFSuite documentation
---

# RFSuite for EdgeTX documentation

This folder is the reference for what the tool shows and does: one file per configuration
page, in the layout of the menu on the radio, plus the topics that are not a page. It is
plain Markdown, versioned with the code, and it is not part of the installation archive.

Installing and updating RFSuite, the two widgets, the audio pack and the model image are
described in the [README](../README.md); this folder does not repeat them. Working on the
code is [DEVELOPMENT.md](../DEVELOPMENT.md), and the conventions the sources follow are in
[GEMINI.md](../GEMINI.md).

## Map

| Folder | What it holds |
| --- | --- |
| [pages/](pages/README.md) | One file per configuration page, in the folder layout of `src/rfsuite/app/pages/`. Its index lists every page with its menu path and says whether the file is written yet. |
| [dashboard/](dashboard/README.md) | The dashboard widget: the shipped themes, the per-theme settings page, user themes, the quick menu, the model image, the service widget. |
| [audio/](audio/README.md) | Every announcement, what fires it and its default; the sound pack; the model name file. |
| [reference/](reference/README.md) | Mechanics that span pages: when a page is hidden or locked, preview features, the save and reboot sequence, the user folder, supported firmware. |
| [troubleshooting/](troubleshooting/README.md) | No connection, the unsupported-API dialog, a widget that draws nothing, collecting logs for a report. |
| [developer/](developer/README.md) | For contributors: how to add a page, a control, an MSP API module, a theme, an announcement or a preview feature. |

## How this folder is filled

The structure is complete; the content is not. Every index above lists its planned files
with a status, and the page index says for each page whether the tool's own in-app help
(the `?` in the page header) already carries the text to start from. A page file follows
[_template.md](_template.md).

Every change a pilot can observe updates the file that describes it, in the same pull
request. The rule is in [GEMINI.md](../GEMINI.md) under *Documentation Maintenance* and in
`.agents/rules/documentation.md`, in the same shape as the rule for `Releases.md`.

A pull request that changes `src/` and no file here has to say why in its body, on a line
beginning with `Documentation:`. The `Documentation rule` job in `.github/workflows/pr.yml`
checks for one or the other; what it cannot check, and does not try to, is whether the
reason is a good one.

## Conventions

- Plain CommonMark that renders on GitHub as it is: no MDX, no admonition syntax, no
  imports. A page written this way can be lifted to the Rotorflight website unchanged.
- A YAML front matter with `title`, `sidebar_label` and `sidebar_position`, the position in
  multiples of 10 in the order of the tiles on the radio. The website reads these; GitHub
  shows them as a small table.
- Relative links with the `.md` extension, for example `../reference/preview-features.md`.
- Menu paths in the words the radio shows: *Configuration* → *Setup* → *Ports*.
- Every page file ends with the release it was checked against, so a stale page can be told
  from a current one.
- Images, when a page needs one, go in an `img/` folder beside the page and are referenced
  relatively.
