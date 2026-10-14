---
title: Settings
sidebar_label: Settings
sidebar_position: 20
---

# Settings

The settings the dashboard themes themselves offer. The page is a grid of tiles, one per theme
that has settings, and a tile opens that theme's own page — the battery bounds it draws its
gauges against, the values it puts in its rows, the colours it uses. Nothing here is a setting
of the suite: what a tile opens is written by the theme, so two radios with different themes
installed see different pages.

Which theme a model actually shows is chosen on [*Design*](theme.md), and a theme keeps its
settings whether or not it is the one in use.

The theme tiles edit the **standard values**, which every model without settings of its own uses; the first
line of a theme's page reads *Standard values for all models*. A model with settings of its own changes
some of them for itself, on the *Per-Model Settings* tile.

## Where to find it

*System* → *Settings* → *Dashboard* → *Settings*

Always available. A theme appears here when it ships a settings module and does not declare
itself standalone; a theme with neither is configured nowhere, and one whose module offers
nothing opens a page saying so.

## Settings

| Setting | What it does |
| --- | --- |
| Per-Model Settings | The first tile, only while a flight controller is connected and per-model settings are on for its model (see [*Design*](theme.md)). Opens [the list of what that model changes](overrides.md), and from there the settings of each theme that model draws, for that model alone. |
| *(one tile per theme)* | Opens that theme's standard settings. What the page holds is the theme's own business; several of the shipped themes offer the battery voltage bounds their gauges are scaled to. |

A theme may split its settings into pages. Its tile then opens a second grid, one tile per
page, and each of those opens part of the theme's settings — the same settings, divided so a
page fits the screen. Themes that do not split show their settings directly.

## Notes

- Settings are stored per theme, so a theme copied into
  `/SCRIPTS/TOOLS/rfsuite.user/dashboard/` starts from its defaults rather than inheriting the
  original's values, and configuring the copy does not change the original.
- Where a value is stored follows the page, not the connection: a theme tile stores the radio's
  standard values whether or not a flight controller is connected, and a theme opened from
  *Per-Model Settings* stores the model's values — only those that differ from the standard. A
  model reads its own values only while per-model settings are on for it; switching them off on
  *Design* keeps the values and ignores them.
- A save says *Saved* only when its values reached the card. A theme opened from *Per-Model
  Settings* stores them in the model's own file, so the save reports that file: where the card
  refuses it, the page shows *Save failed: the settings file could not be written to the SD card*,
  the values on the page have not been stored for the model, and saving again once the card can be
  written stores them. A theme tile stores the radio's values, so the save reports the radio's
  file, and a card that refuses it shows the same sentence; the model's file, rewritten beside it
  while a flight controller is connected, holds none of those values and does not decide the
  answer.
- A card from an earlier version may hold per-model theme settings saved while a flight
  controller was connected. Such a model keeps using them, and they are listed under *Per-Model
  Settings*, until the switches on *Design* are saved off.
- A card from an earlier version may also hold, in the radio's own settings, a copy of a value
  that was saved for a model. Earlier versions removed that copy whenever the theme was saved for
  a model; this one does not, because such a copy cannot be told apart from a standard value set
  on purpose. It stays the standard for every model without values of its own until it is changed
  on the theme's tile. For the battery voltage bounds that means those models do not scale the
  bounds to the cell count they measure.
- A theme split into pages saves the page that is open. Leaving a page for another one of the
  same theme discards what has not been saved, so save before stepping across.
- Saving reloads the dashboard, so a change is visible on the widget as soon as the tool is
  closed.
- A theme's page that cannot be loaded says so under its first line, with the reason, and the
  same line goes to the log. A reason too long for the row is cut short with `...`; the log keeps
  it whole. *Reload* tries the load again. Opened from the dashboard, the tool runs under the dashboard's limit
  on the work one call may do, so a page whose opening needs more is stopped there with
  *CPU limit* while the same page opens from the radio's tool list.

## Related

- [Dashboard themes](../../../dashboard/README.md) — what the widget shows and which themes ship
  with the suite.
- [User themes](../../../dashboard/user-themes.md) — copying a theme onto the card and editing
  it, including the settings a copy carries.

*Documented against RFSuite 0.1.7.*
