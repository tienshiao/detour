---
id: TASK-342
title: >-
  Settings: pop-ups, text fields and pickers have one accessible name, like the
  switches
status: To Do
assignee: []
created_date: '2026-11-15T07:30:00Z'
labels:
  - settings
  - accessibility
dependencies: []
references:
  - TASK-336
  - TASK-338
  - Detour/Browser/Settings/SettingsForm.swift
  - wiki/features/settings.md
priority: low
type: bug
ordinal: 418000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-336 and left out of scope there (it covered switches only); TASK-338's grouped form then named the controls inside its rows. Remaining at the time: some pop-ups and fields read their visible label twice or have no accessible name: Links' "Open other links in" pop-up, Quick Detour's idle pop-up, the Spaces emoji and colour pickers, Profiles' Name / Search engine / Archive and Sleep tabs after / Identify as, Spaces' Name and Profile, and Quick Detour's "Shortcut" label beside a recorder named "Quick Detour shortcut"; a shortcut recorder also exposes its shortcut both as its value and as a child text. Re-check each after TASK-338 before changing anything: some may already be fixed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every control in every Settings pane has an accessible name equal to its visible label (or a stated, more specific one), and no label is read separately from its control
- [ ] #2 A shortcut recorder exposes its shortcut once
- [ ] #3 Identifiers unchanged; the TASK-336 Accessibility-tree test covers every control type, not only switches; checked at runtime with the axsettings reader (docs/harness/task336)
<!-- AC:END -->
