---
id: TASK-149
title: >-
  Session: TabStore.saveNow writes in several transactions, so a crash mid-save
  can lose pinned entries
status: In Progress
assignee: []
created_date: '2026-10-04 02:29'
updated_date: '2026-10-04 08:45'
labels: []
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Database.swift
  - wiki/architecture/persistence.md
priority: medium
ordinal: 172000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TabStore.saveNow (Detour/Browser/TabStore.swift) persists the session through separate AppDatabase calls, each its own write transaction: saveSession (which deletes every space row and re-inserts spaces and tabs), saveProfiles, then per space savePinnedFoldersAndTabs and per profile saveFavorites. Deleting the space rows cascades to their pinnedTab / pinnedFolder rows, which are only re-inserted by the later calls. If the app is killed or crashes between the first transaction and the later ones, the database is left with the spaces and tabs of the new state but without pinned entries, folders or favorites for some or all spaces, and the next launch restores that.

Read from the code while writing wiki/architecture/persistence.md; never observed. saveNow runs on a debounce after every mutation and on window close and termination, so the window is short but frequent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 One save is one database transaction: after an interrupted save the database holds either the complete previous state or the complete new one; a test that fails the save part-way (injected failure) shows pinned entries, folders and favorites intact, and fails before the fix
- [x] #2 The cost of a save does not regress noticeably (measured on a large session and recorded in the task)
- [x] #3 docs/data-model.md and wiki/architecture/persistence.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Red: add SessionSaveAtomicityTests at the TabStore level. Build state A (two spaces, pinned folders, live and dormant pinned entries, live and dormant favourites), save, dump the session tables; mutate to state B; inject a failure with a test-only SQLite trigger (RAISE(ABORT) on insert into pinnedTab / pinnedFolder / favorite, on write to profile); saveNow; assert every session table equals the state A dump. Fails on the current code because saveSession has already committed.
2. Green: AppDatabase.SessionSnapshot (spaces+tabs, lastActiveSpaceID, profiles, per-space pinned folders+entries, per-profile favourites) and AppDatabase.saveSessionSnapshot writing it in ONE dbQueue.write, in today's order (session, profiles, pinned per space, favourites per profile). The per-piece methods (saveSession, saveProfiles, savePinnedFoldersAndTabs, saveFavorites) keep their signatures and route through the same static write helpers, so the rows written are unchanged.
3. TabStore.saveNow builds the snapshot (same record construction, no mutation logic touched) and makes one call.
4. Round-trip test: a successful save restores the full state B in a fresh store.
5. AC #2: SessionSaveBenchmarkTests, gated by TEST_RUNNER_SESSION_SAVE_BENCH=1 (20 spaces, 2,000 tabs, 300 pinned entries, 60 folders, 200 favourites, on-disk database); run on the old and the new save path, record numbers here.
6. Update docs/data-model.md, wiki/architecture/persistence.md, wiki/architecture/session-database.md, wiki log + lint.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Change: TabStore.saveNow now builds one AppDatabase.SessionSnapshot (makeSessionSnapshot: the record-building code of the old saveNow, moved unchanged) and writes it with AppDatabase.saveSessionSnapshot in ONE dbQueue.write. The four steps (session, profiles, pinned folders+entries per space, favourites per profile) are private static functions taking the open transaction; saveSession / saveProfiles / savePinnedFoldersAndTabs / saveFavorites keep their signatures and call the same functions, so the rows written, their order and the deletes are unchanged (only tests still call the per-piece methods). No TabStore mutation logic was touched.

Tests first (DetourTests/SessionSaveAtomicityTests.swift), run against the unfixed code: 6 of the 7 tests then present failed (38 assertion failures), for the intended reason:
- testSaveFailingOnTabRowsKeepsPreviousState, ...OnProfileRows..., ...OnPinnedFolderRows..., ...OnPinnedEntryRows..., ...OnFavoriteRows...: the save was left half-applied (e.g. pinnedTab and pinnedFolder tables EMPTY after a failure on pinned rows, with the new spaces and tabs committed).
- testSaveNowCommitsOnce: 6 commits instead of 1 (fixture: 2 spaces, 2 profiles).
- testSuccessfulSaveRoundTripsFullState passed before and after.
The failure is injected by the test with a SQLite trigger (RAISE(ABORT) BEFORE INSERT on tab / pinnedFolder / pinnedTab / favorite, BEFORE UPDATE on profile), so the statement throws inside the save's transaction and no test-only hook exists in the app. Each test compares every row of profile, space, tab, pinnedFolder, pinnedTab, favorite and appState with the dump taken before the failed save, restores a fresh TabStore from the database and compares what it sees, then lets the save through and checks the new state landed. Added after the fix: testSnapshotSaveWritesTheSameRowsAsThePerPieceSaves (the snapshot write leaves exactly the rows the four per-piece saves leave, for a first save and for a save over a full database).
One test bug found on the way: restoring a store adds the built-in Private profile row, so the baseline dump is taken after the baseline restore.

AC #2, save cost (DetourTests/SessionSaveBenchmarkTests.swift, gated by TEST_RUNNER_SESSION_SAVE_BENCH=1; Debug build, on-disk database, 4 profiles, 20 spaces, 2,000 tabs with 4 KB interaction state each, 300 pinned entries (100 live), 60 folders, 200 favourites (40 live); 2,140 tab rows, 10.3 MB file; medians of 9 saves):
- before: rewrite 261.59 ms (min 257.14, max 282.11); save after a title change 263.30 ms (246.72 to 270.66); first save into an empty database 142.60 ms; 26 commits per save.
- after: rewrite 231.90 ms (226.78 to 258.85); after a title change 232.87 ms (223.86 to 241.39); first save 119.69 ms; 1 commit per save.
About 11% faster; no regression. Most of a save is building and inserting the tab rows, not committing. Measured once on this machine while other agents were building.

Behaviour change that follows from atomicity: a failure in any step now fails the whole save (logged by performWrite, retried by the next save), where before the failed step was skipped and the others were still written. I checked the one foreign key that looked reachable (a live favourite whose profile has no persistent space would write favorite.tabID for a tab row that is not saved): rehomeFavoriteTabs and updateSpace deactivate such favourites, so the snapshot does not contain that case.

Suites run on the fix (263 tests, 1 skipped, 0 failures): SessionSaveAtomicityTests 8, AppDatabaseTests 28, TabStoreTests 40, SplitTabTests 63, MoveTabToSpaceTests 31, ProfileDataRemovalTests 25, PinnedTabMoveTests 17, ProfileDeletionUndoTests 13, ExtensionPagePersistenceTests 10, FavoriteSpaceHandoffTests 8, UndoAfterDeleteSpaceTests 8, FavoritePeekPersistenceTests 5, FavoriteFaviconTests 4, TabRecordFactoryTests 2, SessionSaveBenchmarkTests 1 skipped (ungated).

Docs: docs/data-model.md (Persistence Strategy), wiki/architecture/persistence.md (write order, atomicity, measured cost), wiki/architecture/session-database.md (foreign-key notes), wiki/playbooks/build-and-test.md (SESSION_SAVE_BENCH gate), wiki/log.md. wiki-lint: 0 errors, 0 warnings.

Not verified: a real crash or kill mid-save (the tests fail a statement inside the transaction; a kill relies on SQLite's own atomic commit). No /code-review or /verify run by this agent; the supervisor does both.

Runtime check 2026-10-04, harness build of the batch branch at 822e798, isolated profile, SCREEN LOCKED (so no real key or mouse events; calls go through the app's own entry points).
Launch, tab and window changes, quit: browser.db held the session afterwards (1 space, 2 tabs, 2 profiles); no save error in the log. Full test suite on the integrated branch: 1970 tests, 11 skipped (gated legs), 0 failures.

Code review of the batch (5bc537c..822e798) found that the save inserted pinned folders in the store's array order, which is not parent-first (a folder dragged into one created later, Undo Delete Folder, a relaunch). pinnedFolder.parentFolderID is an immediate foreign key, so the child row is refused. Before this task that lost the space's pinned rows on such a save; as one transaction it failed the whole session save every time. Fixed: writePinnedFoldersAndTabs inserts through parentFirst(_:). Two new tests in SessionSaveAtomicityTests failed with the foreign-key error before and pass after; SessionSaveAtomicityTests, AppDatabaseTests, PinnedTabMoveTests and TabStoreTests: 95 tests, 0 failures.
Left open by the review, for a decision: TabStore.saveNow ignores the result of saveSessionSnapshot, so a save that keeps failing is only a log line while nothing is persisted.
<!-- SECTION:NOTES:END -->
