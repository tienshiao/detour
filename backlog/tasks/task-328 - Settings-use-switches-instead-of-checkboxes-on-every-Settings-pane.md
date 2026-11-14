---
id: TASK-328
title: 'Settings: use switches instead of checkboxes on every Settings pane'
status: To Do
assignee: []
created_date: '2026-11-14T19:55:00Z'
labels:
  - settings
  - ui
dependencies: []
references:
  - Detour/Browser/Settings/GeneralSettingsViewController.swift
  - Detour/Browser/Settings/QuickDetourSettingsViewController.swift
  - Detour/Browser/Settings/ProfilesSettingsViewController.swift
  - Detour/Browser/Settings/ExtensionsSettingsViewController.swift
  - wiki/features/settings.md
priority: low
type: feature
ordinal: 402000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user: Settings panes mix two controls for on/off settings, and they should be consistent, with switches (NSSwitch) everywhere.

As of Nov 14 2026: General uses checkboxes (NSButton checkboxWithTitle) for "Open links from pinned tabs and favorites in a Peek", "Let AI agents and scripts control Detour (MCP)" and "Allow agents to use Private windows". Quick Detour uses checkboxes for the global hotkey ("Open … from any app with" followed by the shortcut recorder on the same line) and for the Option-Command-click option. Profiles (suggestions, per-tab isolation, content blocker lists) and Extensions (enabled, allowed in Private, per-profile) already use NSSwitch, as does the sidebar settings popover.

A checkbox carries its label as its title, while a switch has no title. So each converted row needs a label beside the switch, laid out like the rows that already use switches (ProfileSettingsLayout / SettingsMetrics). The hotkey row, a sentence that continues into the recorder, needs its own layout. Windows outside Settings (the Arc import window) are not in scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every on/off setting in the Settings window (General, Quick Detour and any other pane) is an NSSwitch with a label, and no Settings pane uses a checkbox for an on/off setting
- [ ] #2 Converted rows line up with the existing switch rows in Profiles and Extensions (label and switch positions, spacing), checked in light and dark mode
- [ ] #3 Each converted setting still reads and writes the same stored value, and dependent controls still enable and disable as before (e.g. Private-windows access only while agent control is on; the shortcut recorder only while the hotkey is on)
- [ ] #4 Clicking a row label toggles its switch or is deliberately inert, consistently across the panes, and the switches keep accessible names (the label text) and their existing accessibility identifiers
- [ ] #5 Tests that address these controls (e.g. by accessibility identifier or as NSButton) are updated and pass; checked at runtime with /verify in both appearances
<!-- AC:END -->
