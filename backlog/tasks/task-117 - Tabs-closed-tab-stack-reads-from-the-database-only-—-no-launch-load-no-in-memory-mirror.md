---
id: TASK-117
title: >-
  Tabs: closed-tab stack reads from the database only — no launch load, no
  in-memory mirror
status: Done
assignee:
  - '@claude'
created_date: '2026-09-25 06:07'
updated_date: '2026-09-25 07:00'
labels:
  - tabs
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Database.swift
priority: low
ordinal: 117000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TabStore.closedTabStack mirrors the whole closedTab table in memory. It is loaded at launch (TabStore.swift ~1026), including every interactionState blob (measured on a real profile: 100 rows, ~850 KB, largest 188 KB), and every mutation writes both copies, each with its own 100-row trim. None of its users needs that:
- canReopenClosedTab (menu validation) needs only spaceID/url/extensionID per record
- reopenClosedTab scans the space's records newest-first and needs interactionState only for the record it picks
- the launch filter that deletes records of uninstalled extensions duplicates what reopenClosedTab already does lazily (.unavailable -> delete)
- deleteSpace / its undo and the close-undo cleanups snapshot, restore or remove records the DB can query directly

Make the database the only store: small-column queries (no blob) for validation and the reopen scan, fetch interactionState for the chosen row only, an index on (spaceID, id). If menu validation proves too hot for a query, add a lazily filled per-space metadata cache without blobs, not a full mirror.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No closed-tab records (and no interactionState blobs) are loaded at launch
- [x] #2 Reopen Closed Tab, its menu enablement, extension-page skip/discard (TASK-24/TASK-28 behavior), Delete Space + undo, and close-undo all behave as before
- [x] #3 Only the reopened record's interactionState is read from disk
- [x] #4 closedTab has an index serving the per-space newest-first query
- [x] #5 closedTabStack (full mirror) is gone; tests that inspected it assert through the store or DB instead
- [x] #6 Existing tests covering reopen, split-tab close, Move to Space and extension-page closed tabs pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
AppDatabase (Database.swift):
1. Migration v15: index closedTab(spaceID, id).
2. New ClosedTabSummary (Storage/Models/ClosedTabRecord.swift): id, tabID, spaceID, url, title, faviconURL, sortOrder, archivedAt, extensionID — no interactionState. closedTabSummaries(spaceID: String? = nil) -> [ClosedTabSummary], newest first (nil = every space, for tests).
3. closedTab(id: Int64) -> ClosedTabRecord? (full row, the only blob read), deleteClosedTab(id:), closedTabs(spaceID:) -> [ClosedTabRecord] (full rows for the Delete Space snapshot), insertClosedTabs(_:) that inserts rows with their ORIGINAL ids so an undone Delete Space keeps the original reopen order (today's undo re-pushes newest-first and reverses it). Remove loadClosedTabs(). pushClosedTab/popClosedTab/deleteClosedTabs(spaceID:)/deleteClosedTab(tabID:) stay.
TabStore:
4. Delete closedTabStack, its launch load (and the uninstalled-extension filter — reopenClosedTab already discards .unavailable lazily and canReopenClosedTab treats it as not reopenable), and every mirror mutation/trim (closeTab, closeSplitGroup, both undo cleanups, deleteSpace/removeSpace, deleteSpace undo).
5. canReopenClosedTab: scan closedTabSummaries(spaceID:) with the same classification. reopenClosedTab: scan summaries; .unavailable -> deleteClosedTab(id:); first candidate -> closedTab(id:) full fetch, deleteClosedTab(id:), restore as before.
6. deleteSpace: snapshot = appDB.closedTabs(spaceID:) taken before deleteClosedTabs; undo = insertClosedTabs(snapshot).
7. Public closedTabRecords(in space: Space) -> [ClosedTabSummary] (tests now; TASK-119 listing later).
Tests: replace every closedTabStack assertion (SplitTabTests, ExtensionPageRehostTests, ExtensionPageUndoTests, ExtensionPagePersistenceTests, TabStoreTests) with closedTabRecords(in:) / closedTabSummaries(); add: launch does not load records (store built over a DB with rows has no in-memory copy — assert via summaries only), Delete Space + undo keeps reopen order, index exists (sqlite_master). docs/data-model.md: drop the mirror sentence, add the index and v15.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (Opus subagent). closedTabStack removed; AppDatabase gains closedTabSummaries(spaceID:) (blob-free, newest first), closedTab(id:), closedTabs(spaceID:), deleteClosedTab(id:), insertClosedTabs(_:) (keeps original ids so an undone Delete Space restores the original reopen order — the old undo re-pushed newest-first and reversed it), migration v15 index closedTab(spaceID, id). TabStore.closedTabRecords(in:) is the public listing (TASK-119 will use it). The launch-time purge of uninstalled extensions' records is gone: reopenClosedTab discards .unavailable lazily. Tests count reads via the DEBUG read labels: launch does 0 closed-tab reads, a reopen does exactly 1 full-row read. Targeted suites: 201 tests, 0 failures.

Review (/code-review --fix): no source findings; stale closedTabStack mentions in docs/architecture.md and docs/tab-lifecycle.md fixed. Validation: full DetourTests suite 1586 tests, 5 skipped, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The closedTab table is now the only closed-tab store: no launch load, no in-memory mirror. Menu validation and the reopen scan read blob-free ClosedTabSummary rows through the new (spaceID, id) index (v15); only the reopened record's full row is fetched. Delete Space undo re-inserts the saved rows with their original ids, which also fixes the previous order reversal. TabStore.closedTabRecords(in:) is the listing the Archived Tabs panel (TASK-119) will build on. Verified by read-count tests (0 closed-tab reads at launch, 1 full-row read per reopen), an undo-order test, an index test, and the full suite (1586 tests, 0 failures).
<!-- SECTION:FINAL_SUMMARY:END -->
