---
id: TASK-183
title: >-
  Command palette: Option+Backspace (and other delete commands) on a selected
  inline completion puts the same completion straight back
status: To Do
assignee: []
created_date: '2026-10-24 08:20'
labels:
  - command-palette
  - bug
dependencies: []
priority: low
ordinal: 205000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-181/182 code review; predates both. `control(_:textView:doCommandBy:)` treats only `deleteBackward:` specially while the completion suffix is selected (remove the completion, suppress autocomplete for the next change). `deleteWordBackward:`, `deleteToBeginningOfLine:`, `deleteForward:` and friends fall through: the field editor deletes the selected suffix, `controlTextDidChange` runs with autocomplete allowed, and the same completion is applied again, so the key appears to do nothing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Option+Backspace, Cmd+Backspace and Delete (forward) with the completion selected leave the field without the completion, and it does not reappear until the next typed character
- [ ] #2 Covered by PaletteReturnKeyTests-style tests through a real CommandPaletteView
<!-- AC:END -->
