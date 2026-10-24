---
id: TASK-181
title: >-
  Command palette: Backspace after moving the caret off an inline completion
  deletes back to the typed prefix
status: To Do
assignee: []
created_date: '2026-10-24 08:03'
labels:
  - command-palette
  - bug
dependencies: []
priority: medium
ordinal: 203000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Typing `you` with a `youtube.com/watch?v=…` tab open inline-completes the field and selects the suffix. Moving the caret (Cmd+Right, End, a click) leaves the completion pending in `CommandPaletteView.inlineCompletionSuffix`, so the next Backspace takes the 'remove the completion' branch of `control(_:textView:doCommandBy:)` and resets the field to the typed prefix instead of deleting the character before the caret.

Fix: once the selection is no longer exactly the completion's range, the completion counts as accepted (it becomes typed text), so Backspace, Escape and Tab act on the field as it stands.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Typing a prefix that inline-completes, then Cmd+Right, then Backspace deletes the last character of the completed text
- [ ] #2 Backspace while the completion is still selected keeps removing only the completion
- [ ] #3 Covered by a test through a real CommandPaletteView (PaletteReturnKeyTests style)
<!-- AC:END -->
