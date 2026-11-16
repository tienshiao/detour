---
id: TASK-366
title: >-
  Undo: an extension popup shown from a Quick Detour window cannot undo its
  typing once its web view loses first responder
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - undo
  - extensions
  - quick-detour
dependencies: []
references:
  - wiki/platform/page-key-equivalents-and-undo.md
  - wiki/architecture/browser-undo.md
priority: low
type: bug
ordinal: 447000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-349's review. Browser windows got a central fallback (nonBrowserKeyWindow) so a popup whose window is its own first responder still answers Undo with its field's typing; QuickDetourWindowController has no equivalent, so there Cmd+Z is disabled and the popup's typing cannot be undone.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A popup shown from a Quick Detour window answers Undo/Redo with its own typing whatever has first responder in it
- [ ] #2 A test like SettingsAndPopupUndoTests' popup cases covers it
<!-- AC:END -->
