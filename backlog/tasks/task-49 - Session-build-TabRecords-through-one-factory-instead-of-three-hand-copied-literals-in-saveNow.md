---
id: TASK-49
title: >-
  Session: build TabRecords through one factory instead of three hand-copied
  literals in saveNow
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 06:15'
updated_date: '2026-09-13 09:58'
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
- [x] #1 saveNow has one TabRecord construction path shared by normal, pinned backing, and favourite backing tabs
- [x] #2 Persisted output is unchanged for normal and pinned backing tabs (existing round-trip tests pass unmodified)
- [x] #3 The favourite backing record's handling of lastDeselectedAt and parentID is an explicit decision recorded in code comments, with a test pinning it
- [x] #4 A test asserts every TabRecord column is populated from the tab by the factory so a new column cannot be silently dropped at one site
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add one TabRecord factory (TabRecord.init(tab:spaceID:sortOrder:extensionID:) in an extension in TabStore or Storage/Models) mapping every persisted BrowserTab field once; normal tabs pass splitGroupID/splitFraction, backing tabs pass nil.
2. Decision recorded in the factory doc comment: favourite backing tabs persist lastDeselectedAt and parentID like pinned backing tabs (today nil): harmless on restore (restore ignores them for backing tabs) and it removes the last special case. Route all three saveNow sites through the factory.
3. Tests: existing round-trip tests unchanged; a test that the factory populates every TabRecord column from the tab (compare against a fully populated tab via Mirror or field-by-field) and one pinning the favourite backing record's lastDeselectedAt/parentID.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
TabRecord.init(tab:spaceID:sortOrder:profile:splitGroupID:splitFraction:) in Detour/Browser/TabRecord+BrowserTab.swift (Browser, not Storage/Models: Storage must not depend on BrowserTab) maps every persisted field once, including extensionID derived from the passed profile (review fix: the derivation was still hand-copied at the three sites). Split fields stay parameters because a pinned split lives on the entries. Decision: favourite backing rows persist lastDeselectedAt and parentID like every other row; restore reads neither for a backing tab. Tests: TabRecordFactoryTests (every column + a Mirror sweep that fails when a new nil-default column is not mapped; favourite row round trip pinning the decision).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
saveNow builds all three TabRecord kinds through one factory that maps every BrowserTab field, including the extension id, so a new column cannot be silently dropped at one site. Favourite backing rows now persist lastDeselectedAt/parentID like the others (documented in the factory). Verified with TabRecordFactoryTests and the existing round-trip suites.
<!-- SECTION:FINAL_SUMMARY:END -->
