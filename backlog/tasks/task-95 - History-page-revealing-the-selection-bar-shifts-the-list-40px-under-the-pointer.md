---
id: TASK-95
title: >-
  History page: revealing the selection bar shifts the list 40px under the
  pointer
status: To Do
assignee: []
created_date: '2026-09-20 03:28'
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
