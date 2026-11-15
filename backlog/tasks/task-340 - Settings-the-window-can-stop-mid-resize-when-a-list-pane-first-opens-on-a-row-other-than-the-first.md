---
id: TASK-340
title: >-
  Settings: the window can stop mid-resize when a list pane first opens on a row
  other than the first
status: To Do
assignee: []
created_date: '2026-11-15T05:14:00Z'
labels:
  - settings
  - ui
dependencies: []
references:
  - TASK-338
  - Detour/Browser/Settings/SettingsWindowController.swift
  - Detour/Browser/Settings/SettingsPaneHeight.swift
  - wiki/features/settings.md
priority: low
type: bug
ordinal: 415000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-338 (and present before it): opening a list + detail pane (Profiles, Spaces, Extensions, Links) for the first time with a row other than row 0 selected can leave the Settings window stuck at a height partway through its resize animation; the unconverted Profiles pane was left at 671 pt, short of its natural height. Likely two refits racing: the pane's first layout and the selection's detail rebuild.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is found and recorded
- [ ] #2 Opening each list pane on any row, first time or later, ends at the pane's natural height (within the screen cap), with or without animation
- [ ] #3 A test reproduces the race (fails before, passes after); checked at runtime
<!-- AC:END -->
