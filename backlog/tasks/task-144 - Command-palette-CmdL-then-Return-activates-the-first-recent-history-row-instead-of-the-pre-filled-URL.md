---
id: TASK-144
title: >-
  Command palette: Cmd+L then Return activates the first recent-history row
  instead of the pre-filled URL
status: To Do
assignee: []
created_date: '2026-10-04 02:23'
labels: []
dependencies: []
references:
  - Detour/Browser/CommandPalette/CommandPaletteView.swift
  - wiki/features/command-palette.md
priority: medium
ordinal: 167000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Read from the code while correcting docs/command-palette.md (TASK-140); not yet reproduced in the running app, so the first step is to confirm it.

CommandPaletteView.show(initialText:) pre-fills the field with the current URL and calls loadDefaultSuggestions(), and updateSuggestions() ends with setKeyboardSelection(to: items.isEmpty ? nil : 0), so row 0 of the default list (SuggestionProvider.defaultSuggestions: the space's 12 most recent history entries, as .openTab when a tab has that URL) is keyboard-selected. On Return, control(_:textView:doCommandBy:) activates the selected row whenever there is one; textFieldSubmitted (which submits the field's text) only runs when no row is selected.

So Cmd+L followed by Return does not submit the pre-filled URL. It activates the space's most recent history entry. That is usually the current page, which hides the problem, but not when another tab in the space committed a navigation more recently, or when the current page records no history (an internal page, a Private window's page is separate, a failed load): then Return navigates the current tab to another page's URL, or switches to another tab. The same selection rule means Cmd+T followed by Return on an empty field opens the most recent history entry; decide whether that is wanted.

Expected: with a pre-filled, unedited field, Return acts on the field's URL (as other browsers reload/navigate to the address shown); arrowing to a row and pressing Return still activates that row.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The behaviour is reproduced (or refuted) in the running app first, with the result recorded in the task
- [ ] #2 Cmd+L then Return on an unedited field submits the pre-filled URL, whatever the default list's first row is; covered by a test of the selection/submit rule that fails before the fix
- [ ] #3 Arrow-key selection of a default row followed by Return still activates that row, and typed input keeps its current top-hit behaviour
- [ ] #4 The empty Cmd+T + Return behaviour is decided and recorded (kept or changed)
- [ ] #5 docs/command-palette.md and wiki/features/command-palette.md match the result
<!-- AC:END -->
