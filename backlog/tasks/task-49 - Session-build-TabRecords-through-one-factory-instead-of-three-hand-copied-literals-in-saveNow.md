---
id: TASK-49
title: >-
  Session: build TabRecords through one factory instead of three hand-copied
  literals in saveNow
status: To Do
assignee: []
created_date: '2026-09-13 06:15'
labels:
  - session
  - refactor
dependencies: []
priority: low
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TabStore.saveNow builds TabRecord in three positional literals: normal tabs, pinned backing tabs (sortOrder -1), and favourite backing tabs (sortOrder -2). The favourite literal drifted once already (peek columns written as nil, fixed in TASK-42) and still hard-codes lastDeselectedAt: nil / parentID: nil with the same provenance. Introduce a single TabRecord factory (e.g. TabRecord(tab:spaceID:sortOrder:extensionID:) or a TabStore helper) that maps every persisted BrowserTab field once, and route all three sites through it, passing only what genuinely differs (spaceID, sortOrder, splitGroupID/splitFraction for normal tabs). Decide explicitly whether favourite backing tabs should persist lastDeselectedAt and parentID (today they do not) and document the choice in the factory. Follow-up from the TASK-42 code review.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 saveNow has one TabRecord construction path shared by normal, pinned backing, and favourite backing tabs
- [ ] #2 Persisted output is unchanged for normal and pinned backing tabs (existing round-trip tests pass unmodified)
- [ ] #3 The favourite backing record's handling of lastDeselectedAt and parentID is an explicit decision recorded in code comments, with a test pinning it
- [ ] #4 A test asserts every TabRecord column is populated from the tab by the factory so a new column cannot be silently dropped at one site
<!-- AC:END -->
