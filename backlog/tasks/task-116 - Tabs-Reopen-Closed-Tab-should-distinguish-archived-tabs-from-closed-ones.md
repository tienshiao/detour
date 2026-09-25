---
id: TASK-116
title: 'Tabs: Reopen Closed Tab should distinguish archived tabs from closed ones'
status: To Do
assignee: []
created_date: '2026-09-25 05:57'
updated_date: '2026-09-25 06:46'
labels:
  - tabs
dependencies:
  - TASK-115
  - TASK-117
references:
  - Detour/Storage/Database.swift
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Models/ClosedTabRecord.swift
priority: low
ordinal: 116000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Archived tabs (timer sweep in TabStore.archiveStaleTabs, and the sidebar Archive menu items once TASK-115 lands) go on the same closed-tab stack as Cmd+W closes. Reopen Closed Tab (Database.popClosedTab / TabStore.closedTabStack) ignores ClosedTabRecord.archivedAt, so Cmd+Shift+T can bring back a tab the archive timer took hours ago instead of the one the user just closed. Archive sweeps also share the 100-entry cap (Database.closedTabCap and the in-memory trim in TabStore.closeTab), so one large sweep can evict every recently closed tab.

Decision to make first: whether Reopen Closed Tab skips archived records entirely, or only prefers explicit closes. Recommendation: skip them, and keep archived tabs recoverable some other way (at minimum they stay in history; ideally a future Archived Tabs list backed by the same records). Skipping must not make archived tabs unrecoverable without a follow-up task for that list.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The skip-vs-deprioritize behavior is decided and recorded in the task notes
- [ ] #2 Cmd+Shift+T after closing a tab reopens that tab even if an archive sweep ran after the close
- [ ] #3 Archived records no longer evict explicitly closed tabs under the cap (e.g. separate caps, or eviction that prefers archived records)
- [ ] #4 Space-scoped behavior (popClosedTab(spaceID:)) and incognito exclusion are unchanged
- [ ] #5 Records written before this change (archivedAt NULL for manual archives) keep working
- [ ] #6 Unit tests cover reopen ordering with mixed closed and archived records, and cap eviction
- [ ] #7 closedTab gains a closedAt column (migration), set on every closed-tab record — plain close, manual archive, timer archive; existing rows backfill from archivedAt where present, else stay NULL and sort by id
- [ ] #8 Ordering in the reopen path is unaffected by the column (still newest-first); closedAt is available for time-based retention and display
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decisions (AC #1): Reopen Closed Tab SKIPS archived records (archivedAt IS NOT NULL). Archived tabs stay reachable via history now, via Edit > Undo right after a manual archive (TASK-115), and via the native Archived Tabs panel (TASK-119). archivedAt stays the archive marker (its value doubles as the flag); no reason column now. closedAt is the close timestamp on every row.
1. Migration v16 (after TASK-117's v15): ALTER TABLE closedTab ADD COLUMN closedAt DOUBLE; UPDATE closedTab SET closedAt = archivedAt WHERE archivedAt IS NOT NULL. Rows left NULL sort by id as before.
2. ClosedTabRecord and ClosedTabSummary gain closedAt: Double?. Every write sets it: closeTab uses (archivedAt ?? now) so a manual archive's two stamps coincide; closeSplitGroup uses now; insertClosedTabs (Delete Space undo) preserves the saved value.
3. closedTabSummaries(spaceID:includeArchived:) — the reopen scan and canReopenClosedTab pass includeArchived: false (SQL 'AND archivedAt IS NULL'); listings (closedTabRecords(in:)) keep both. Ordering stays id DESC (AC #8).
4. Cap (AC #3, kept since TASK-118 is on hold): closedTabCap applies per kind — after an insert, count rows whose 'archivedAt IS NULL' matches the inserted row's and delete the oldest of that kind beyond 100. An archive sweep can no longer evict plain closes, and a run of closes never evicts archived rows (which TASK-119 will list). Same trim in insertClosedTabs.
5. Pre-change rows: manual archives recorded before TASK-115 carry archivedAt NULL and behave as plain closes — accepted, noted in docs.
6. Tests: mixed ordering (close A, archive B, close C → reopen yields C then A, never B; canReopenClosedTab false when only archived rows remain; space-scoping and incognito unchanged); per-kind cap (100 archived + 1 close keeps the close; 101 closes evict only the oldest close); closedAt set on plain close, manual archive, timer archive; migration backfill if AppDatabaseTests has a migration-test pattern, else closedAt via the write path plus a note.
7. docs/data-model.md: closedAt column, per-kind cap wording, v16 row.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
closedTab currently has no close timestamp: order comes only from the autoincrement id, and only timer-archived rows carry a time (archivedAt). With closedAt present, consider whether archivedAt should become a flag / archive-reason column instead of a second timestamp.
<!-- SECTION:NOTES:END -->
