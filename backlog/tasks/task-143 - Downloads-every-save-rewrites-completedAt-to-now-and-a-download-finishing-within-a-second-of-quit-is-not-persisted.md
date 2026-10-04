---
id: TASK-143
title: >-
  Downloads: every save rewrites completedAt to now, and a download finishing
  within a second of quit is not persisted
status: In Progress
assignee: []
created_date: '2026-10-04 02:23'
updated_date: '2026-10-04 08:08'
labels: []
dependencies: []
references:
  - Detour/Browser/Downloads/DownloadManager.swift
  - wiki/features/downloads.md
priority: low
ordinal: 166000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two defects in DownloadManager's persistence (Detour/Browser/Downloads/DownloadManager.swift), found by reading the code while correcting docs/data-model.md (TASK-140); neither has been observed at runtime.

1. saveNow() builds each DownloadRecord with `completedAt: item.state == .completed ? Date() : nil`. It runs for every non-downloading item on every debounced save, so each completed download's completedAt is overwritten with the time of the latest save instead of keeping the time the download finished. Nothing in Detour/ reads the column today (DownloadItem(record:) ignores it), so the visible effect is nil for now, but docs/data-model.md documents it as 'when download finished' and anything built on it (ordering, expiry, chrome.downloads endTime in TASK-132.17) would be wrong.

2. scheduleSave() debounces by 1 s and saveNow() is private; applicationWillTerminate only calls TabStore.shared.saveNow(). A download that completes, fails or is cancelled less than a second before the app quits is never written: after relaunch it is missing from the list (or, if it had been saved earlier in another state, shows the stale one).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 completedAt is set once, when the download reaches the completed state, and later saves leave it unchanged; a test fails before the fix
- [x] #2 A state change pending in the debounce window is written before the app terminates; a test covers the flush
- [x] #3 DownloadItem carries the completion time across a relaunch (loaded from the record), or the task records why the column is dropped instead
- [x] #4 docs/data-model.md and wiki/features/downloads.md match the result
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Make DownloadManager testable: an internal init taking the AppDatabase, a clock (now) and a save scheduler (the 1 s debounce); shared uses AppDatabase.shared, Date() and a main-queue DispatchWorkItem. Route the WKDownloadDelegate terminal callbacks through one internal method so tests can drive a state change without a WKDownload.
2. Red: DownloadManagerTests (in-memory AppDatabase, fixed clock, manual scheduler) — completedAt is the completion time and a later save leaves it unchanged; it survives a reload through DownloadItem(record:); a change pending in the debounce window is written by flushPendingSave(); nothing is written when nothing is pending. Run against a behaviour-preserving refactor (saveNow still stamps now(), flush is a stub) and record which tests fail.
3. Green: DownloadItem.completedAt, set once when the item reaches .completed, written unchanged by saveNow, loaded from the record. flushPendingSave() writes only if a debounced save is pending; AppDelegate.applicationWillTerminate calls it.
4. Update docs/data-model.md and wiki/features/downloads.md (edge case and Tests), wiki lint, wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented on an agent worktree branch (review and finalization by the supervising session).

What changed
- DownloadManager is constructible for tests: init(database:now:scheduler:) (shared = AppDatabase.shared, Date(), a main-queue DispatchWorkItem). The two WKDownloadDelegate terminal callbacks now call downloadDidEnd(_:failure:), which tests call directly with a manual item.
- DownloadItem.completedAt is set once by markCompleted(at:) when the item reaches .completed; saveNow writes item.completedAt unchanged; DownloadItem(record:) loads it (only for a completed row). Failed and cancelled items have none.
- flushPendingSave() writes only when a debounced save is pending; AppDelegate.applicationWillTerminate calls it after TabStore.saveNow().
- Rows written by older builds keep their last-save time in completedAt (not recoverable); recorded in docs/data-model.md and the wiki.

TDD: DownloadManagerTests (new, 12 tests) was run first against a behaviour-preserving refactor (saveNow still stamping now(), markCompleted not recording, flushPendingSave an empty stub). 7 tests failed for the intended reasons: testCompletedAtIsTheTimeTheDownloadCompleted, testLaterSavesLeaveCompletedAtUnchanged (row moved from 08:00 to 09:00 on the later save), testMarkCompletedTwiceKeepsTheFirstTime, testCompletedAtSurvivesARelaunchAndTheNextSave, testFlushWritesAChangeStillInTheDebounceWindow, testFlushWritesACancelStillInTheDebounceWindow, testADownloadStillInFlightIsNeverWritten (it saves through the flush). The other 5 (debounce, burst, nil completedAt for failed/cancelled, flush with nothing pending, non-completed record) passed before and after.

Tests run: DetourTests/DownloadManagerTests, 12 tests, 0 failures (own DerivedData, DETOUR_DATA_DIR=DetourTests-downloads).

Not verified: nothing was run in the app. The one-line call in applicationWillTerminate has no test (the test covers flushPendingSave itself), and the delegate callbacks were not exercised with a real WKDownload. /code-review and /verify are left to the supervising session.

Docs: docs/data-model.md (completedAt column, save paragraph); wiki features/downloads, architecture/persistence, architecture/app-shell, log.
<!-- SECTION:NOTES:END -->
