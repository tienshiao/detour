---
id: TASK-95
title: >-
  History page: revealing the selection bar shifts the list 40px under the
  pointer
status: Done
assignee:
  - '@claude'
created_date: '2026-09-20 03:28'
updated_date: '2026-09-20 07:15'
labels: []
dependencies: []
references:
  - Detour/Browser/InternalPages/HistoryPageContent.swift
priority: low
ordinal: 95000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On detour://history/, ticking the first checkbox reveals the selection bar ('N selected', Delete, Cancel): a 40px strip (.selection .bar-inner) inside the sticky header (.bar), under the search row. With the page scrolled to the top the header grows by 40px and every row moves down while the pointer stays put, so the row just ticked is no longer under the cursor and a quick second click lands on the row above; the reverse jump happens when the selection empties. Once scrolled, the sticky header overlays the list and nothing moves. Annoyance, no data risk. Found in the TASK-87 real-input pass. Proposed direction (agreed with the user): overlay the selection bar ON the search row - while a selection exists it replaces the search field / range control / Clear History in place (as Finder and Mail do), so the header height never changes. Rejected: permanently reserving 40px (wasted space), a bar floating at the window bottom. Keep the internal-page rules: no inline styles or scripts, textContent only, controls follow page state.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Selecting the first row and clearing the last selection do not change the header height or move any list row, at scroll top and when scrolled (assert row getBoundingClientRect before/after)
- [x] #2 While a selection exists the selection controls (count, Delete, Cancel) occupy the search row; search, range and Clear History return unchanged (values, focus rules, URL state) when the selection ends
- [x] #3 Keyboard paths from TASK-87 still work with the bar overlaid: Delete / forward-delete, Escape, Cmd+A in the list vs in the search field, Shift-click ranges; a failed-delete notice is still visible
- [x] #4 Hidden controls are not focusable or reachable by Tab while overlaid; incognito (no range control) lays out correctly
- [x] #5 Real-input runtime pass in light and dark: tick first row then immediately click the next row - the intended row toggles
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Final design (after four /code-review rounds): the selection controls live INSIDE the fixed-height (52px) search row and swap with the search controls through ONE switch, the 'selecting' class on the header (display:none rules that only ever add hiding, so the controls' own hidden attributes stay independent). The first design (absolute overlay + visibility:hidden + pointer-events) was dropped: the count could overlap the h1 at narrow widths and it needed two switches. While selecting, nothing REPLACES the list: deferWhileSelecting() at reload()/refresh() entry, refresh()'s reply and receive(replace); state.deferred = 'reload'|'refresh'|null; appends (load-more) still work; leaveSelection commits the search field and runs one reload or refresh. endSelectionAndReload() is the single 'end the selection and reload exactly once' path (failed delete, applyRange, clearHistory). Focus: the control that had focus is remembered (captured at primary mousedown, because a real press blurs the field before click) and given back on Cancel/Escape/untick unless the user focused something else; keyboard-initiated deletes never give it back (held key), button deletes only lose it when a success empties the selection; event.repeat ignored for Delete/Backspace.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
State 2026-09-19 late: implemented on branch task-95-history-selection-row (UNCOMMITTED in the main checkout; same diff in worktree agent-adc9464ef26794a2b). 25 new integration tests (row rects/header height equal across states at top, scrolled, narrow 360pt, incognito; display of controls; focus paths incl. simulated real press, right-click, no-click press; deferral of in-flight reply / refresh / load-more; failed delete = one query; key repeat). Tests observe bridge traffic through a postMessage-prototype wrapper (window.bridgeLog sent/settled/deletes) - no production hooks. Full suite on the branch: 1474 tests, 5 skipped, 0 failures. Signed-off behaviours: ticking a row makes Backspace/Delete act on the selection; a deferred reload (typed query) jumps to the top on Cancel, a deferred refresh does not; a dropped in-flight reply freezes paging until the selection ends. OWED before commit (AC #5): real-input pass light+dark on an UNLOCKED screen - harness at .claude/task95-harness.patch (apply in the checkout, build, run with DETOUR_DATA_DIR=DetourVerify87 DETOUR_VERIFY_DIR=<dir>); it ticks row 0 then at once clicks row 1's OLD position, Tabs, real Cancel, types a query, selects, Escape. Must also confirm the real-pointer focus claim: with Full Keyboard Access off, caret in the field -> real click on a checkbox -> Cancel => activeElement is #search again. Three attempts on 2026-09-19 failed only because the screen was locked (no events delivered, app exited).

2026-09-20 real-input pass DONE on an unlocked screen (NSApp.postEvent harness, isolated DetourVerify87 profile), light and dark identical: ticking row 0 then at once clicking row 1's OLD position selects [0,1]; header 53px and row tops [101,181,261] unchanged idle -> selecting -> after Cancel; search display none while selecting, back after; typed 'ten' -> 1 item, select, Escape keeps q=ten and returns focus to #search; real-pointer focus claim confirmed: caret in field -> real checkbox click (activeElement BODY) -> real Cancel => activeElement #search. Tab x4 while selecting stayed on BODY (Full Keyboard Access off), never on a hidden control. Harness needed a wait for the History document (first run poked the page before it loaded); updated patch at .claude/task95-harness.patch.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The selection controls (count, Delete, Cancel) now swap with the search controls inside the fixed-height search row via one 'selecting' header class, so ticking the first row or clearing the last never changes the header height or moves a row. List replacement is deferred while selecting (one reload/refresh on leaving), focus returns to the control that had it, and key-repeat deletes are ignored. Verified by 25 new integration tests (full suite 1474 tests, 5 skipped, 0 failures), four /code-review rounds, and a real-input runtime pass in light and dark. Commit e0b408f.
<!-- SECTION:FINAL_SUMMARY:END -->
