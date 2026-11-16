---
id: TASK-360
title: >-
  Undo: Move Space's undo stores positions in the space list, which Private
  windows shift
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - undo
  - spaces
  - incognito
dependencies: []
references:
  - wiki/architecture/browser-undo.md
  - Detour/Browser/TabStore.swift
priority: medium
type: bug
ordinal: 441000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-357's agent, read from the code. Move Space's undo records indexes into TabStore.spaces, which also holds Private spaces; opening or closing a Private window between the move and its undo shifts those indexes, so the undo can move the wrong space or do nothing. Pre-existing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Undo of Move Space restores the moved space's position whatever Private windows opened or closed in between
- [x] #2 A test covers a Private window opened and one closed between the move and its undo
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Failing tests first (PrivateWindowUndoTests): move a space past a Private window's space, close the Private window, undo -> old code restores the wrong order (index drift); also redo across a close, and a Private window opened then one closed between move and undo.
2. Fix: Move Space's undo/redo record the moved space's id and its stablePosition (normal spaces before it); moveSpace(id:toStablePosition:) puts it back before the normal space now at that position (or after the last one) and registers its own inverse the same way.
3. Wiki browser-undo (capture rules), profiles-and-spaces (Reorder row) + log; Backlog notes; /code-review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise CONFIRMED by failing tests against the old code (3 new tests in PrivateWindowUndoTests, all 3 failed on HEAD by wrong order): spaces N, P(Private), B, C; Move B to the front; close P; Undo gave N, C, B (expected N, B, C); the redo across a close gave C, N, B; in the opened-then-closed test only the 'closed' half failed: a Private window opening only appends to spaces, which never shifted the old indexes, so that half is a regression guard, not demonstrated drift.
Fix: moveSpace(from:to:) registers its undo with the space id + stablePosition(of:) (number of normal spaces before it); private moveSpace(id:toStablePosition:) re-inserts before the normal space now at that position, or after the last normal space, and registers its own inverse the same way. Settings still passes indexes into spaces (unchanged). Undo puts the normal order back exactly; a Private space may end up on the other side of the moved space (nothing reads the Private spaces' place among normal ones).
Tests: PrivateWindowUndoTests 16, SidebarPageFocusTests 27, SpaceJumpTests 15, TabStoreTests 40 = 98, 0 failures (after the review fix).
/code-review medium --fix: no correctness bug; applied stablePosition without a filtered copy. Not fixed (reported): Delete Space's undo re-inserts at an index into spaces (savedIndex), the same drift (N, P, B, C: delete B, close P, undo -> N, C, B); the exact Private-space placement on undo; the shared move tail.
Not verified at runtime: the automation endpoint has no way to reorder spaces (only the Settings pane's drag calls moveSpace), so the Move Space undo was checked by tests only.

Follow-up filed 2026-11-16: TASK-385 (Delete Space's undo has the same index drift).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Move Space's undo and redo recorded two indexes into TabStore.spaces, which also holds Private windows' spaces; a Private window closing between the move and its undo shifted them and the undo restored the wrong order (confirmed by failing tests). They now record the space's id and its place among the normal spaces (moveSpace(id:toStablePosition:)). 3 new tests; 98 tests across 4 suites pass. Wiki browser-undo and profiles-and-spaces updated. Not checked at runtime (no endpoint path to reorder spaces). Follow-up candidate: Delete Space's undo has the same index drift.
<!-- SECTION:FINAL_SUMMARY:END -->
