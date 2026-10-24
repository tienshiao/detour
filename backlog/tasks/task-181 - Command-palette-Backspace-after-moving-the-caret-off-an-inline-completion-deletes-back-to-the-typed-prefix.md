---
id: TASK-181
title: >-
  Command palette: Backspace after moving the caret off an inline completion
  deletes back to the typed prefix
status: Done
assignee: []
created_date: '2026-10-24 08:03'
updated_date: '2026-10-24 08:24'
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
- [x] #1 Typing a prefix that inline-completes, then Cmd+Right, then Backspace deletes the last character of the completed text
- [x] #2 Backspace while the completion is still selected keeps removing only the completion
- [x] #3 Covered by a test through a real CommandPaletteView (PaletteReturnKeyTests style)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Treat the completion as pending only while it is exactly the field editor's selection; check before every doCommandBy command and fold it into the typed text when the caret has moved off it.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: Cmd+Right/End/Left/click move the caret through the field editor without reaching controlTextDidChange, so inlineCompletionSuffix stayed set and the next deleteBackward took the 'remove the completion' branch (setTextFieldQuietly(userTypedText)).

Fix: CommandPaletteView.acceptInlineCompletionIfDeselected(in:) runs at the top of control(_:textView:doCommandBy:). Selector-agnostic, so every movement key and a mouse click are covered. Selection ranges in the completion paths now use utf16 counts.

Code review (/code-review --fix): moveSelection's caret also moved to utf16. Review also found that Tab after moving off a completion fell through to the field editor and moved keyboard focus out of the palette; Tab is now always consumed (test added, fails without it). Option+Backspace / Cmd+Backspace / Delete on a selected completion put it straight back — older bug, filed as TASK-183.

Tests: PaletteReturnKeyTests 13/13 (4 new: Backspace after Cmd+Right, Backspace after placing the caret inside the completion, Backspace on the selected completion, Tab keeps focus; 3 of them fail on the old code, the selected-completion one documents unchanged behaviour). Also run: PaletteSelectionTests 14, CommandPaletteFocusTests 4, SuggestionProviderTests 30, HistoryDatabaseTests 128, PaletteTabScopeTests 8, PaletteTabScopeWiringTests 2, AddressInputClassifierTests 15 — 0 failures.

Runtime (/verify): Debug build in DETOUR_DATA_DIR=DetourVerify182 with docs/harness/task181-182-harness.patch, keys sent to the field editor's keyDown (real key bindings): you → youtube.com, Cmd+Right (caret 11), Backspace → youtube.co; youtube.com/w → youtube.com/watch?v=1, Backspace → youtube.com/w; Left then Backspace → youtube.com/atch?v=1. Not verified: a person's real keystrokes in an active app; pixels (cacheDisplay renders the glass palette blank).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Backspace after moving the caret off an inline completion (Cmd+Right, Left, a click) now deletes before the caret instead of resetting the field to the typed prefix: a completion counts as accepted once it is no longer the selection. Tab is always consumed by the palette. Verified with PaletteReturnKeyTests (3 new tests failing before) and in the running app through the field editor's key bindings.
<!-- SECTION:FINAL_SUMMARY:END -->
