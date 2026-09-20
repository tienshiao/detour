---
id: TASK-95
title: >-
  History page: revealing the selection bar shifts the list 40px under the
  pointer
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-20 03:28'
updated_date: '2026-09-20 03:51'
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
- [ ] #1 Selecting the first row and clearing the last selection do not change the header height or move any list row, at scroll top and when scrolled (assert row getBoundingClientRect before/after)
- [ ] #2 While a selection exists the selection controls (count, Delete, Cancel) occupy the search row; search, range and Clear History return unchanged (values, focus rules, URL state) when the selection ends
- [ ] #3 Keyboard paths from TASK-87 still work with the bar overlaid: Delete / forward-delete, Escape, Cmd+A in the list vs in the search field, Shift-click ranges; a failed-delete notice is still visible
- [ ] #4 Hidden controls are not focusable or reachable by Tab while overlaid; incognito (no range control) lays out correctly
- [ ] #5 Real-input runtime pass in light and dark: tick first row then immediately click the next row - the intended row toggles
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design (Fable): the selection controls share the search row's 52px slot instead of adding a 40px strip. #selection becomes an absolutely positioned overlay inside the (position: sticky) header, same .bar-inner geometry; while a selection exists the header carries a 'selecting' class and the main row's controls get visibility:hidden (keeps layout, removes them from hit-testing, Tab order and the AX tree) - the h1 stays. Entering selection closes the Clear History <details>. Anything that would focus the search field while selecting clears the selection first. Values/URL state of search, range, day are untouched, so they return as they were. Steps: 1 (Opus, worktree) implement + integration tests measuring row rects/header height before and after. 2 (Fable) /code-review, real-input runtime pass light+dark (tick first row, immediately click the next). 3 commit + merge.
<!-- SECTION:PLAN:END -->
