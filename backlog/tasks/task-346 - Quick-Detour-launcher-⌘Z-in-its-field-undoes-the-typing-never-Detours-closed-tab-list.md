---
id: TASK-346
title: >-
  Quick Detour launcher: ⌘Z in its field undoes the typing, never Detour's
  closed-tab list
status: To Do
assignee: []
created_date: '2026-11-15T21:26:00Z'
labels:
  - keyboard
  - undo
  - quick-detour
dependencies: []
references:
  - TASK-345
  - Detour/Browser/QuickDetour/QuickDetourLauncher.swift
  - wiki/platform/page-key-equivalents-and-undo.md
priority: low
type: bug
ordinal: 425000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-345's code review, not fixed there (it predates the change and lives in another file). The Quick Detour launcher panel (the palette panel the Quick Detour hotkey opens) does not answer Edit > Undo/Redo, so ⌘Z typed in its field falls through to the main browser window's browserUndo: and can reopen a closed tab there instead of undoing the typing. Since TASK-345, browser windows and Quick Detour/quarantine windows answer Undo/Redo themselves; the launcher should too: its field's own undo, and never TabStore's list.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 ⌘Z / ⇧⌘Z and Edit > Undo/Redo in the launcher's field undo and redo the field's typing (or do nothing when there is none), and never run TabStore's undo
- [ ] #2 Menu titles and enabled state follow the field's own undo while the launcher is key
- [ ] #3 A test covers the launcher with a closed tab on TabStore's list; checked at runtime
<!-- AC:END -->
