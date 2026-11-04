---
id: TASK-184
title: >-
  Command palette: the list changes height several times per keystroke, so the
  palette flickers while typing
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 08:52'
updated_date: '2026-10-24 10:50'
labels:
  - command-palette
  - bug
  - ui
dependencies: []
priority: medium
ordinal: 206000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-24: Arc's palette keeps one height while you type; ours visibly changes height, which reads as flicker.

Cause (from the code): `CommandPaletteView.updatePanelHeight` sizes the list to `min(rows, 6) * 36 pt` on every `updateSuggestions` / `appendSearchSuggestions`, and each keystroke rebuilds the list up to three times (see wiki/features/suggestion-pipeline.md, 'Two passes per keystroke'):
1. the instant main-thread pass (open tabs only: top hit, verbatim row, up to 3 tabs), often 1-2 rows;
2. the background history pass a few ms later, usually more rows;
3. network search suggestions ~150 ms later (debounced), more rows again.
So the box shrinks at every keystroke and then grows back in one to three steps. The TASK-181/182 runtime harness log showed it: after one Backspace the list went 4 rows -> 6 rows between two snapshots 0.7 s apart with no further typing. The box's top stays put (the centred position uses the maximum height), so it is the bottom edge and the rows below the first few that jump.

Options:
- A: fixed list height while the palette shows suggestions (six rows of space; rows not filled stay empty), as Arc appears to do. Simplest and steadiest; the box is taller for short lists.
- B: never shrink within one query's rebuilds and only re-fit when the query changes. Still moves once per keystroke.
- C: also keep the instant pass from replacing longer rows with fewer: carry the previous query's history rows until the background pass lands. Reduces row flicker, not only height.
Recommendation: A (decide whether the default list with nothing typed, and the no-suggestion state, also keep the fixed height), plus C if rows still visibly blink.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 While typing a query, the palette's height does not change from keystroke to keystroke or between the instant, history and search-suggestion passes
- [x] #2 Behaviour for the empty-field default list and for a query with no suggestions is decided and recorded
- [x] #3 Checked at runtime by logging the glass container's frame across keystrokes and passes (harness), before and after
- [x] #4 The list shows at least six rows whenever six exist across matches, search suggestions and the default list; filler rows never duplicate a match
- [x] #5 A late history or search-suggestion pass does not change the row the user has selected with the arrow keys
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Harness (docs/harness/task184-harness.patch): seed open tabs + history, Cmd+T, type a query key by key, sample the glass container's window frame at 60 Hz and log every change with the field text; also the empty-field default list and a query matching nothing but the verbatim row. Run before the change.
2. CommandPaletteView.updatePanelHeight: whenever the palette shows a list (default list or query, any row count), the scroll view is a fixed six rows (6 x 36 pt); rows not filled stay empty. Only an empty list (no rows at all, e.g. a fresh profile's empty default list) drops the list area. maxPaletteHeight reuses the same constant.
3. Re-run the harness after: one height across keystrokes and passes. Update wiki/features/command-palette.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, 2026-10-24): keep a fixed height — option A — for every state the palette shows a list in.

Decision (user, 2026-10-24, after the fixed height was built): like Arc, the palette should never show empty rows. Asked what to do when a query has fewer than six matches anywhere (gibberish, offline, search suggestions off): pad with other rows (recent tabs/history from the empty-field list), so the height never changes. Plan amended:
- Rows for a query = matches (local passes) + search suggestions filling the room below six (at least the usual 4) + filler from the default list (deduplicated by URL) up to six. Pure function PaletteRows, tests first.
- While the new query's search suggestions are pending, the previous query's suggestions that still prefix-match the new text stay (no blank-then-refill at the bottom).
- A late pass (history, network) never changes rows under a row the user has arrowed to: applied keeping the selection if the rows up to it are unchanged, otherwise skipped.
- The list area stays a fixed six rows; only a profile with nothing to pad with (no tabs, no history) shows blank space.

Implemented (2026-10-24):
- PaletteRows (new, pure): compose(matches:searchSuggestions:filler:), carriedSearchSuggestions(_:to:), latePassOutcome(old:new:selectedRow:initialRow:). 11 tests in PaletteRowsTests, written first (red against a stub, then green).
- CommandPaletteView: list area fixed at PaletteRows.visibleRows x 36 pt; each pass updates matchRows / searchSuggestionTexts and showQueryRows composes them with the default list as filler; a late pass (history, network) goes through latePassOutcome; the history pass's inline completion is not applied once the user has arrowed to a row.
- Decided for AC #2: the empty-field default list keeps the fixed height (12 rows from recent history fill it); an empty default list (no history, no tabs) drops the list area. A query with no matches is padded from the default list (user decision).
- Runtime (harness docs/harness/task184-harness.patch, isolated profile): before 9 height changes, 78-258 pt; fixed height alone 0 changes but blank rows; final 0 height changes, 0 samples with fewer than 6 rows; zqxw shows its row and 5 recent pages (screenshot); Down x2 right after typing yo: the selected row and field unchanged 1.5 s later.
- Tests: PaletteRowsTests, PaletteSelectionTests, PaletteTabScopeTests, CommandPaletteFocusTests, SuggestionProviderTests, AddressInputClassifierTests: 67 passed, 0 failed.
- Wiki: command-palette.md (view structure: composition, carried suggestions, late-pass rule), suggestion-pipeline.md (row table, passes feed compose), log.

Code review (/code-review --fix, 2026-10-24): 8 findings, 4 fixed. (1) Down then Up back onto row 0 counted as untouched, so a late pass could replace it: now a selectionMovedByUser flag (set by arrow keys, cleared by a list rebuild that resets the selection) drives latePassOutcome(selectionMoved:) and the inline-completion guard; new test testALatePassDoesNotReplaceTheFirstRowOnceTheUserArrowedBackToIt. (2) A skipped late pass now retries on the next arrow key under the same rule. (4) the duplicated 'moved' check is gone. (5) a no-op clamp removed.
Not fixed, recorded:
- Mouse: a late pass can still replace the row under the pointer (now also the network pass, which replaces filler rows instead of appending). Clicking a filler row within ~150 ms + network latency of the last keystroke can hit a search suggestion instead. Before this change the history pass already replaced rows under the pointer. Not guarded by hover because a pointer resting over the palette would freeze the list; candidate follow-up if it shows up in use.
- No automated test for the view-level inline-completion guard: the rule it depends on (selectionMoved) is in PaletteRows and tested; the view wiring is timing-dependent (history queue + network) and was checked with the harness instead (Down x2 right after typing: field and selected row unchanged after the late passes).
- A shared SuggestionItem.url for PaletteRows.url(of:) and suggestionDisplayText: left as is (outside the change, small gain).
After the review: palette suites 60 passed / 0 failed (reviewer run); harness rerun on the reviewed code: 0 height changes, 0 short samples, arrowed-to row unchanged.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The command palette's list area is a fixed six rows and is always filled: matches, then search suggestions in the room below six, then rows from the empty-field list (no duplicate URLs). Previous search suggestions that still match stay while the new ones load, and a late history or network pass never changes a row the user arrowed to. Pure rules in PaletteRows (12 tests, test-first); harness: 9 height changes before, 0 after, never fewer than six rows. Wiki: command-palette, suggestion-pipeline.
<!-- SECTION:FINAL_SUMMARY:END -->
