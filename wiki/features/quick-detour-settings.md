---
type: Feature
title: Quick Detour settings
description: "Settings > Quick Detour: the pane's Opening and Closing sections (the hotkey switch and Shortcut row, the ⌥⌘-click switch, the links-from-other-apps footnote, the idle pop-up), their defaults keys and how they take effect."
tags: [settings, window]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: settings-pane
    resource: ../../Detour/Browser/Settings/QuickDetourSettingsViewController.swift
    title: QuickDetourSettingsViewController.swift
  - id: task-328
    resource: backlog:TASK-328
    title: "Settings: use switches instead of checkboxes on every Settings pane"
  - id: entry-points
    resource: ../../Detour/Browser/QuickDetour/QuickDetourEntryPoints.swift
    title: QuickDetourEntryPoints.swift (the settings, the Opt-Cmd click, the routed link's profile, the idle rule)
---

Settings > Quick Detour (`QuickDetourSettingsViewController`) holds every Quick Detour setting, in two sections of a grouped form: Opening and Closing.

# Opening

- **Open Quick Detour from any app [switch]**
  (`QuickDetourHotKeyEnabled`), with "The launcher opens over the app in
  front; Escape or a click elsewhere closes it." It turns the [global
  hotkey](./quick-detour-hotkey.md) on and off.
- **Shortcut [⌥⌘N]**, the hotkey's recorder, with "The same shortcut is
  File > New Quick Detour Window while Detour is in front, also when the
  switch above is off." and the row's warning line (the recorder, the
  warnings and the defaults key are on the hotkey page, [The Settings
  control](./quick-detour-hotkey.md#the-settings-control)).
- **Open links and sidebar tabs in Quick Detour with ⌥⌘-click [switch]**
  (`QuickDetourOptionCommandClickEnabled`, on by default), with "A sidebar
  tab opens as a copy; the tab stays where it is." Off, Opt-Cmd is a
  Cmd+click again, on links and in the sidebar
  ([entry points](./quick-detour-entry-points.md)).
- A footnote: "To open links from other apps in Quick Detour, choose Quick
  Detour as a route's Open in, or as the Default, on the Links pane." — no
  switch ([links from other apps](./quick-detour-entry-points.md#links-from-other-apps-the-link-routes-quick-detour-target)).

# Closing

- **Close Quick Detour windows not used for [6 hours ▾]**
  (`QuickDetourIdleTimeout`, the raw value; anything unreadable is 6
  hours), with "They go to the archive, marked auto-closed, and reopen from
  there. The window in front, one playing sound and Private ones stay
  open." ([idle auto-close](./quick-detour-archive.md#idle-auto-close)).

# Where the pane sits

The ⌥⌘-click row, the footnote and the idle pop-up came with TASK-193.5,
after the hotkey's rows of TASK-193.2. They and the hotkey's were the last
section of the Links pane until TASK-211 moved them to a pane of their own
(user decision 2026-10-26), next to Links in the toolbar, scrolling as one
body. Since TASK-338 the pane is a grouped form with the Opening and Closing
sections above; since TASK-328 every on/off row is a switch. See
[Settings](./settings-panes.md#quick-detour).

# Storage

`QuickDetourSettings` keeps the ⌥⌘-click and idle settings in
`UserDefaultsScope.defaults` beside the hotkey's (`QuickDetourHotKeySettings`)
and posts `didChangeNotification`; both take effect at the next click or
check.

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Settings window](./settings-panes.md#quick-detour) — the pane in the window, the grouped form and switch rows.
- [Quick Detour hotkey](./quick-detour-hotkey.md#the-settings-control) — the hotkey switch, the recorder and its warning line.
- [Quick Detour entry points](./quick-detour-entry-points.md) and [archive and idle auto-close](./quick-detour-archive.md) — what the other rows govern.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.
