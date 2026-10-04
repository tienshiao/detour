---
id: TASK-144
title: >-
  Command palette: Cmd+L then Return activates the first recent-history row
  instead of the pre-filled URL
status: Done
assignee: []
created_date: '2026-10-04 02:23'
updated_date: '2026-10-04 08:46'
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
- [x] #1 The behaviour is reproduced (or refuted) in the running app first, with the result recorded in the task
- [x] #2 Cmd+L then Return on an unedited field submits the pre-filled URL, whatever the default list's first row is; covered by a test of the selection/submit rule that fails before the fix
- [x] #3 Arrow-key selection of a default row followed by Return still activates that row, and typed input keeps its current top-hit behaviour
- [x] #4 The empty Cmd+T + Return behaviour is decided and recorded (kept or changed)
- [x] #5 docs/command-palette.md and wiki/features/command-palette.md match the result
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decision (made by the supervising session, AC #4): the default list (shown while the user has typed nothing: Cmd+L's pre-filled field, Cmd+T's empty field) starts with NO keyboard-selected row. Return then submits the field's text: the pre-filled URL for Cmd+L; on Cmd+T's empty field Return does nothing (it no longer opens the most recent history entry). Down from that state selects the first row, and Return on an arrow-selected row activates it. Typed input is unchanged (top row selected, inline completion).

1. Reproduce first (AC #1), in-process: a real CommandPaletteView hosted in a window, pre-filled URL, default list whose first row is another URL, Return sent through the field editor's doCommand(by:) (the path a key press takes), assert what the delegate receives.
2. Extract the selection/submit rules into pure functions (PaletteSelection: initialRow, row(afterMoving:), returnAction, restoredFieldText) with the old behaviour, and write the unit tests: unedited pre-filled field + Return, empty field + Return, arrow selection + Return, typed query + Return. See them fail.
3. Fix: initialRow returns nil for the default list; the view calls the rules.
4. Check arrow keys from no selection (Down = row 0, Up = last row as today) and that mouse hover/click is untouched.
5. Update docs/command-palette.md and wiki/features/command-palette.md, wiki-lint, wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (branch worktree-agent-ab102709ae8060f37, on top of the TASK-137 commit).

AC #1, reproduction: REPRODUCED IN-PROCESS, NOT IN THE LAUNCHED APP (AC #1 is left unchecked for the supervising session's check of the launched app). PaletteReturnKeyTests hosts a real CommandPaletteView in an NSWindow over an in-memory history database whose default list is [https://newest.example.com/, https://older.example.com/], shows it with initialText https://current.example.com/ (what Cmd+L does), and sends Return as the field editor's doCommand(by: insertNewline:), the call a key press ends in. Before the fix the delegate received didSubmitInput(https://newest.example.com/), the default list's first row, not the pre-filled URL (testCmdLThenReturnSubmitsThePrefilledURL). The same run showed Cmd+T + Return on the empty field submitting newest.example.com. The reproduction ran with only two behaviour-preserving changes applied to the view: suggestionProvider made replaceable, and the selection rules extracted with their old results.

AC #4, decision (made by the supervising session): the default list (nothing typed: Cmd+L's pre-filled field, Cmd+T's empty field, a field the user cleared) starts with NO keyboard-selected row. Return then submits the field's text: the pre-filled URL for Cmd+L. On Cmd+T's empty field Return does nothing; the old behaviour (opens the most recent history entry) is CHANGED, not kept. Down selects the first row and Return on an arrow-selected row activates it. Typed input is unchanged (first row selected after every rebuild, inline completion).

Rules: new pure functions in Detour/Browser/CommandPalette/PaletteSelection.swift: initialRow(listIsDefault:rowCount:), row(afterMoving:from:rowCount:), returnAction(selectedRow:rowCount:fieldText:) -> activateRow / submitText / nothing, restoredFieldText(userTypedText:uneditedPrefill:). CommandPaletteView applies them; the default list is identified by suggestionsQuery == nil.

Design choices beyond the task text:
1. Return is now handled entirely in control(_:textView:doCommandBy:) (it returns true for all three outcomes). The field's target/action and textFieldSubmitted were removed: they were only reachable through 'return false' on Return.
2. Arrowing out of the list (past either end) used to restore userTypedText, which is empty for a pre-filled field, so Cmd+L, Down, Up left an empty field and a dead Return. With no row selected at the start that round trip is the obvious way back, so an unedited pre-filled field now gets its URL back, selected (uneditedPrefill, cleared on the first edit and by switchToCentered). Drop this if unwanted: it is restoredFieldText plus the uneditedPrefill property.
3. CommandPaletteView.suggestionProvider is an internal var (was private let) so the test can use an in-memory history database.

Arrow keys from no selection: Down selects row 0; Up wraps to the last row, as before (row(afterMoving:) is the old inline code moved, behaviour unchanged). Mouse: not touched. Hover is CommandPaletteRowView's own isHovered and click goes through tableRowClicked -> activateSuggestion(at: clickedRow); neither reads the keyboard selection. Not exercised by a test or at runtime.

TDD, red run (PaletteSelectionTests + PaletteReturnKeyTests, 23 tests, 11 failing):
- PaletteSelectionTests: testReturnOnAnUneditedPrefilledFieldSubmitsThePrefilledURL, testReturnOnAnEmptyFieldDoesNothing, testReturnAfterArrowingToADefaultRowActivatesThatRow (Down went to row 1), testLeavingTheListRestoresAnUneditedPrefill.
- PaletteReturnKeyTests: testCmdLThenReturnSubmitsThePrefilledURL, testCmdTThenReturnOnTheEmptyFieldDoesNothing, testCmdLThenDownThenReturnActivatesTheFirstDefaultRow, testCmdLThenDownTwiceThenReturnActivatesTheSecondDefaultRow, testCmdTThenDownThenReturnActivatesTheFirstDefaultRow, testCmdTThenUpWrapsToTheLastDefaultRow, testArrowingBackOutOfTheListRestoresThePrefilledURL.
- The typed-query cases (testReturnOnATypedQueryActivatesTheTopRow, testTypedQueryThenReturnActivatesTheTopRow, testTypingOverThePrefilledURLThenReturnSubmitsTheTypedText) passed before and after: they guard behaviour that must not change.

After the fix: PaletteSelectionTests 14/14, PaletteReturnKeyTests 9/9, PaletteTabScopeTests 8/8, PaletteTabScopeWiringTests 2/2, SuggestionProviderTests 19/19, CommandPaletteFocusTests 4/4 (56 tests, 0 failures).

Not verified: nothing in the launched app (real key presses, the row highlight being absent on open, mouse hover/click, the anchored address-bar entry, Peek). The typed-query view test checks only the instant list (the verbatim row); the background history pass re-selecting row 0 goes through the same initialRow call and is not separately tested. /code-review and /verify are left to the supervising session.

Docs: docs/command-palette.md (Default Suggestions, Activation, Keyboard Navigation), wiki/features/command-palette.md (keyboard section, tests, sources), wiki/features/suggestion-pipeline.md (one sentence), wiki/log.md.

Runtime check 2026-10-04, harness build of the batch branch at 822e798, isolated profile, SCREEN LOCKED (so no real key or mouse events; calls go through the app's own entry points).
AC #1, reproduced in the launched app on the commit before the fix (279c9ae): tab A on https://example.com/?a=1 selected, tab B committed a navigation more recently; focusAddressBar (Cmd+L's action) pre-filled A's URL, Return sent as the field editor's insertNewline: the window switched to the other tab (the default list's first row, an open-tab row for B). Same steps on the fix: A stays selected on its URL, the palette closes and the page has focus. Not done: a physical Cmd+L / Return key press.

Integrated on branch bugfix-batch; full DetourTests suite there: 1970 tests, 11 skipped (gated measurement legs), 0 failures. Code review of the batch range run with --fix.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The default list (nothing typed) no longer starts with a keyboard-selected row, so Return after Cmd+L submits the pre-filled URL instead of activating the most recent history row; Cmd+T then Return on the empty field now does nothing (decided: changed). Down still selects the first row and Return then activates it; typed input keeps its top hit. Rules are in PaletteSelection with unit and in-view tests failing before the fix. Reproduced in the launched app on the commit before the fix (the window switched to another tab) and checked fixed, with Return sent as the field editor's insertNewline rather than a physical key. Also changed: arrowing back out of the list restores an unedited pre-filled URL.
<!-- SECTION:FINAL_SUMMARY:END -->
