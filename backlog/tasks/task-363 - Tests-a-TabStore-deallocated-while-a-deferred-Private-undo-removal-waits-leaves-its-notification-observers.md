---
id: TASK-363
title: >-
  Tests: a TabStore deallocated while a deferred Private undo removal waits
  leaves its notification observers
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - undo
  - tests
dependencies: []
references:
  - Detour/Browser/TabStore.swift
priority: low
type: chore
ordinal: 444000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-357's agent. dropUndoEntries(ofPrivateSpace:) waits for the open undo group to close via UndoManager notifications; if the store is deallocated first (only in tests), its observers are never removed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Observers are removed when the store goes away (or are held weakly and removed on fire)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Red first: a test keeps a weak reference to one of the observers a deferred removal installs, releases the store (precondition: the store is gone), and expects the observer gone; on the old code NotificationCenter keeps it.
2. Fix: an isolated deinit on TabStore removes droppedUndoEntryObservers (the repo's isolated-deinit pattern); the observers stay [weak self].
3. The observer list becomes private(set) for the test. Wiki browser-undo; review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise confirmed by a failing test against the code without the fix: a fixture store released (it does deallocate) while a dropped Private entry's removal waited for its open undo group left its __NSObserver registered with NotificationCenter (weak reference to the token stayed non-nil).
Fix: TabStore gets an isolated deinit (the repo's pattern) that removes droppedUndoEntryObservers through the shared removeDroppedUndoEntryObservers(); the observers stay [weak self]. droppedUndoEntryObservers is private(set) so the test can reach a token.
Tests: new testAStoreGoneWhileARemovalWaitsTakesItsObserversAlong; PrivateWindowUndoTests 20, TabStoreTests 40, UndoAfterDeleteSpaceTests 8, ProfileDeletionUndoTests 13, WindowCloseReleaseTests 21, PrivateSessionResetTests 6 = 108, 0 failures; PrivateWindowUndoTests re-run after the review edit: 20/0.
/code-review medium --fix: no correctness bug; applied a shared removeDroppedUndoEntryObservers() helper. Skipped (reported to the lead): a released test store's repeating archiveTimer (300 s) is not invalidated either (same kind of leftover, out of this task's AC); the test leaves its undo group open (harmless, the manager dies with the store).
Runtime: not applicable (tests only).

Follow-up filed 2026-11-16: TASK-386 (the archive timer is never invalidated).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A TabStore released while a Private undo removal waits for its undo group now removes the waiting NotificationCenter observers in an isolated deinit (before, they stayed registered for the life of the test process; confirmed by a failing test). Only tests release stores. 1 new test; 108 tests across 6 suites pass. Wiki browser-undo updated. Possible follow-up: a released test store's archiveTimer is not invalidated.
<!-- SECTION:FINAL_SUMMARY:END -->
