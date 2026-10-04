---
id: TASK-154
title: >-
  Session: a session save that fails is only a log line, and nothing is
  persisted until it stops failing
status: In Progress
assignee: []
created_date: '2026-10-04 08:53'
updated_date: '2026-10-04 10:23'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Database.swift
  - wiki/architecture/persistence.md
priority: medium
ordinal: 177000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Raised 2026-10-04 by the code review of TASK-149.

Since TASK-149 one TabStore.saveNow() is one transaction (AppDatabase.saveSessionSnapshot), so a failure in any record fails the whole save. saveNow discards the result. A failure that repeats (a foreign-key or uniqueness violation in one row, as the pinned-folder order bug fixed in TASK-149 was) makes every debounced save and the save at termination roll back: the user sees nothing, quits, and loses every session change since the last good save. Before TASK-149 the other sections of the save were still written.

Decide what the app should do when a session save fails: for example retry with the failing section isolated, keep the last good state and tell the user once, or fall back to per-section saves. Never observed; the known cause was fixed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The intended behaviour on a failed session save is decided and recorded in the task
- [x] #2 A save that fails is detected by TabStore (the result is not discarded) and handled by the decided rule; a test with an injected failure covers it
- [ ] #3 A failure that repeats does not silently lose the whole session: either the unaffected parts are persisted or the user is told, by the decided rule
- [x] #4 Session rows that cannot be made valid (a pinned folder whose parent is missing, a parent cycle) are repaired or dropped with a log line instead of failing every save; a test covers each
- [x] #5 wiki/architecture/persistence.md is updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Decision (AC #1), recorded in the notes: repair what can be repaired before the save; on a constraint failure fall back to a save that isolates the failing unit and still writes the others, in one transaction; on any other error keep the last good state. No user-facing message.
2. Red: SessionSaveFailureTests, driven through TabStore.saveNow() and the database only so the file runs against the code before the change: (a) one test per invalid-row class (pinned folder with a missing parent, parent cycle, pinned entry in a missing folder) asserting the save goes through and a relaunch sees the repaired tree; (b) a constraint failure on one row of one space (SQLite trigger with a WHEN clause) asserting the other space, the profiles and the favourites are written and the failing space keeps its last saved rows; a relaunch loads it.
3. Green: AppDatabase.SessionSnapshot.repairingInvalidRows() (pure, returns the repairs made); saveSessionSnapshot throws instead of logging; saveSessionSnapshotIsolatingFailures writes each space (row, tabs, pinned folders and entries), the profiles and each profile's favourites in its own savepoint of ONE transaction and returns the units that failed; TabStore.saveNow() runs repair -> strict save -> isolating save, logs, and keeps the outcome (lastSaveOutcome).
4. Outcome and pure-function tests (new API): saveNow reports saved / savedExcept / failed; SessionSnapshotRepairTests per class.
5. SessionSaveAtomicityTests: the injected failure becomes a non-constraint error (a throwing SQL function called from a trigger), which is the case that must still leave the complete previous state.
6. Targeted suites: SessionSaveFailureTests, SessionSnapshotRepairTests, SessionSaveAtomicityTests, AppDatabaseTests, TabStoreTests, PinnedTabMoveTests (one xcodebuild at a time).
7. wiki/architecture/persistence.md (+ session-database.md conventions line), wiki-lint, wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
DECISION (AC #1), 2026-10-04. A session save that cannot be written as it stands is handled in three layers:
1. Repair first. TabStore.saveNow() runs the pure AppDatabase.SessionSnapshot.repairingInvalidRows() on the snapshot: a pinned folder whose parent is not among its space's folders, the first folder (in the store's order) of each parent cycle, and a pinned entry whose folder is missing are moved to the root of their space, after what is already there. Only the saved rows change; the store is not mutated. Each repair is logged at error level when the set of repairs changes (not once a save).
2. A row the database refuses all the same (SQLITE_CONSTRAINT: foreign key, uniqueness, NOT NULL, a raising trigger): saveSessionSnapshot now throws, and saveNow falls back to AppDatabase.saveSessionSnapshotIsolatingFailures. That is still ONE transaction; inside it each unit is written in its own savepoint: each space (space row + its tabs + its pinned folders and entries), the profiles, each profile's favourites. A unit that fails is rolled back to its savepoint, so it keeps exactly what the last good save wrote (a space never saved before is absent); every other unit is written. Logged at error level per unit.
3. Any other error (disk full, I/O, locked or damaged file) is not about a row: the unit-by-unit save is not attempted (or, if the error comes up during it, the whole transaction rolls back), nothing is written, the last good save stays, logged at error level.
saveNow() returns the outcome (.saved / .savedExcept([failures]) / .failed(reason)) and keeps it in lastSaveOutcome. No user-facing message.

Why, and what was rejected:
- Per-section saves each in its own transaction (the pre-TASK-149 shape, the supervisor's first suggestion): rejected after reading the schema. (a) The session section deletes every space row, which cascades to tab, pinnedTab and pinnedFolder; committed alone and followed by a failing pinned section it leaves that space with NO pinned rows, i.e. it drops parts the last good save held and reopens the crash window TASK-149 closed. (b) Spaces and tabs are one section there, so one bad tab row would still lose every tab change in every space. Savepoints in one transaction keep the atomic commit, and making the space (with everything that cascades from it) the unit means a failing unit keeps its last good rows instead of losing them.
- Row-level isolation (skip the refused row, keep the rest of its space): rejected. It commits a degraded copy over a good one (a refused space row would delete that space and everything in it from the database), and a failure that hits many rows would commit a near-empty session.
- Treating every error as isolatable: rejected. With a full disk every unit fails; only constraint failures are properties of a row.
- A toast or alert: not added. With the fallback the user loses at most the changes to the one affected space, there is nothing the message could tell them to do about a refused row, and TabStore has no UI seam (it would need a new observer callback and window code that this batch cannot check at runtime). Gap that remains, stated plainly: a save that fails for a non-row reason (case 3) still persists nothing and tells nobody; it is an error-level log line and lastSaveOutcome only.

Two details that keep the units independent: before a unit inserts its rows, copies of those primary keys held by units NOT written in this pass are deleted (a tab moved out of a failing space would otherwise collide with the row that space kept); and a favourite whose backing tab row was not written (its host space failed and the row is new) is saved dormant instead of failing its profile's favourites on favorite.tabID.

What the next launch loads after a partial save: every statement ran with foreign keys enforced, so the database is valid by the schema. restoreSession loads the failed space in its last saved state and the others in the new state (tests relaunch a fresh TabStore after each partial save). A space's selectedTabID or appState.lastActiveSpaceID may name a tab/space that is not there (a selected tab that moved out of a failing space; a new active space that could not be saved): neither is a foreign key, AppDelegate checks the space exists and BrowserWindowController.selectTab(id:) returns for an unknown id, as for any other stale selection.

IMPLEMENTATION, 2026-10-04.
Code: Detour/Storage/SessionSnapshotRepair.swift (new: SessionSnapshotRepair, SessionSnapshot.repairingInvalidRows()); Detour/Storage/Database.swift (saveSessionSnapshot throws instead of going through performWrite; SessionSaveFailure; isConstraintFailure; saveSessionSnapshotIsolatingFailures; deleteStaleRows; writeLastActiveSpaceID factored out of writeSession); Detour/Browser/TabStore.swift (SessionSaveOutcome, lastSaveOutcome, saveNow() returns the outcome, discardable; the one-step write path and makeSessionSnapshot are unchanged). No schema change, no migration.

What a failed save does now, in order: (1) saveNow builds the snapshot and repairs it; (2) saveSessionSnapshot, one transaction, as before; success -> .saved; (3) it throws a non-constraint error -> error log, .failed(reason), nothing written; (4) it throws a constraint error -> error log, then saveSessionSnapshotIsolatingFailures in one transaction: delete the spaces the store no longer has; per space, in a savepoint: delete the space row (cascade), delete copies of its rows' ids held by spaces not written in this pass, insert space, tabs, folders (parent-first), entries; upsert lastActiveSpaceID; profiles in a savepoint; per profile, favourites in a savepoint (a tabID with no tab row is cleared). A constraint failure inside a savepoint rolls that unit back and is recorded; any other error rolls the whole transaction back -> .failed; (5) failures empty -> .saved, otherwise one error log line per unit and .savedExcept(failures); (6) lastSaveOutcome is set. The next scheduleSave()/saveNow() repeats all of it.

Tests first. DetourTests/SessionSaveFailureTests.swift was written against the unchanged code using only saveNow() and the database, and run: 10 tests, 34 assertion failures, all 10 tests failing for the intended reason (the three invalid-row classes each failed the whole save, so the unrelated new tab row was missing; with one refused row nothing at all was written: Home space, profiles, favourites, lastActiveSpaceID all still the previous state; a deleted space was still there; a moved tab was still in its old space). After the change the same 10 pass; 2 more were added with the new API (a non-row error during the unit-by-unit save writes nothing; a non-row error is not retried unit by unit), and outcome assertions were added to the existing ones. DetourTests/SessionSnapshotRepairTests.swift (10 tests, pure function: valid tree untouched, missing parent, parent in another space, 2-cycle with a child hanging off it, a folder below a cycle listed first, self-parent, two cycles, entry in a missing folder, successive root orders, rest of the snapshot untouched).
AC #4 coverage, one test per class through TabStore plus the pure tests: testAPinnedFolderWhoseParentIsMissingIsSavedAtTheRoot, testAPinnedFolderParentCycleIsBrokenAndSaved, testAPinnedEntryWhoseFolderIsMissingIsSavedAtTheRoot.
SessionSaveAtomicityTests (TASK-149) changed deliberately: its injected failure was RAISE(ABORT) in a trigger, which is a constraint failure and is now isolated per unit, so it would no longer test 'the previous state stays whole'. It now injects SQLITE_FULL through a SQL function the trigger calls, asserts saveNow() returns .failed, and its five keeps-previous-state tests still compare every session table and a relaunched store. saveSessionSnapshot calls became 'try'.

Final run on the change (one xcodebuild, -derivedDataPath .derived): 287 tests, 1 skipped (SessionSaveBenchmarkTests, ungated), 0 failures: SessionSaveFailureTests 12, SessionSnapshotRepairTests 10, SessionSaveAtomicityTests 10, AppDatabaseTests 28, TabStoreTests 40, SplitTabTests 63, MoveTabToSpaceTests 31, ProfileDataRemovalTests 25, PinnedTabMoveTests 17, ProfileDeletionUndoTests 13, ExtensionPagePersistenceTests 10, FavoriteSpaceHandoffTests 8, UndoAfterDeleteSpaceTests 8, FavoritePeekPersistenceTests 5, FavoriteFaviconTests 4, TabRecordFactoryTests 2.

Docs: wiki/architecture/persistence.md (new section 'When a save cannot be written', write-order intro, atomicity bullet, where-it-lives, tests), wiki/architecture/session-database.md (the two throwing methods, the unit rule, the repaired foreign keys), wiki/tabs/pinned-tabs-and-folders.md (one bullet), docs/data-model.md (the sentence that said a failure is only logged), wiki/log.md. wiki-lint --fix: 0 errors, 0 warnings.

AC #3 is checked for the failure the task describes (a refused row that repeats): the other units are persisted. It is NOT met for a non-row error that repeats (full disk, I/O): nothing is persisted and the user is not told; error log and lastSaveOutcome only. Uncheck it if that case has to be covered here.

Not verified: no /code-review and no /verify by this agent, and the app was not launched; both happen at batch integration. The full DetourTests suite was not run (targeted suites only). The save cost was not re-measured: the one-step path is unchanged apart from the pure repair pass over the pinned rows; a save that keeps hitting a refused row costs roughly two saves (not measured). A real SQLITE_FULL / I/O error was not produced, only simulated from a SQL function. The log lines were not read in a running app. The stale-copy delete is exercised for tab rows (both orders), not for pinned folder, pinned entry or favourite rows moving between units.

Seen, out of scope, not changed: (a) the store's in-memory model is not repaired, so a folder with a missing parent stays invisible in the sidebar until relaunch and its repair is re-applied on every save (logged once); (b) the one-step save writes each profile's favourites as delete-then-insert per profile in order, so a favourite id that moved from a later-written profile to an earlier one would collide with the old row (I did not find a store mutation that moves a favourite between profiles); the unit-by-unit save handles it; (c) a space whose profile row is missing from the database fails as a unit until the profiles step of the same fallback save writes the row, after which the next save succeeds: writing profile rows before spaces would avoid the detour; (d) wiki/tabs/pinned-tabs-and-folders.md says a folder cycle would make flattenPinnedTree recurse forever; a cycle is not reachable from the root, so that claim looks wrong, not checked.

Integrated on branch bugfix-batch-2 (worktree .claude/worktrees/bugfix-batch-2), 2026-10-04. Full DetourTests suite on the integrated tree: 2081 tests, 10 skipped (gated legs), 0 failures; after the review fixes 2083 tests, 10 skipped, 1 failure — ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed in 10 rounds'), a garbage-collection timing test outside this batch that passed in the first run and passes alone (26/26). Code review of the range a98904c..HEAD run with --fix (high).
Left In Progress for AC #3. It is met for a refused row that repeats (the unit holding it keeps its last save, every other unit is saved). It is NOT met for a failure that is not about a row and repeats (a full disk, an I/O error): nothing is written and the user is not told — an error log line and TabStore.lastSaveOutcome only. To decide: accept that (the machine has bigger problems, and a message could not say what to do), or tell the user once (a toast from the window controller on .failed).
Review: one finding, documented rather than repaired. A favourites unit that fails after the space hosting its live favourites was written does not keep its last saved state: rewriting the space deleted the backing tab rows and the cascade set favorite.tabID to NULL, so the kept favourite rows are dormant until a later save writes the unit. The doc comment and wiki/architecture/persistence.md said 'exactly what the last good save wrote' and now state the exception.
Runtime check (harness build, isolated profile): saveNow() returned .saved after tabs, a second profile and space, two Private windows and an extension install; no save error in the app's output. The failure paths were not produced in the running app.
<!-- SECTION:NOTES:END -->
