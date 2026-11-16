---
id: TASK-367
title: >-
  Undo: typing in a page's prompt() dialog (and other alert sheets with a text
  field) cannot be undone
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - undo
  - webkit
dependencies: []
references:
  - wiki/platform/page-key-equivalents-and-undo.md
priority: low
type: bug
ordinal: 448000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-349's review. AppKit disables actions aimed at a window with a sheet attached, so Cmd+Z in an NSAlert accessory field (a page's prompt() in a browser or Quick Detour window) reaches nothing. TASK-349 solved the same problem for Settings' sheets with per-sheet responders.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Cmd+Z / Shift+Cmd+Z in a prompt() field undo and redo its typing, never TabStore's list
- [ ] #2 A test covers it
<!-- AC:END -->
