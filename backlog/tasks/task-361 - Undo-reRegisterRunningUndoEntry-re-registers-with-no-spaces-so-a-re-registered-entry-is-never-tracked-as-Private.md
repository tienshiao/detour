---
id: TASK-361
title: >-
  Undo: reRegisterRunningUndoEntry re-registers with no spaces, so a
  re-registered entry is never tracked as Private
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T10:36:00Z'
labels:
  - undo
  - incognito
dependencies: []
references:
  - wiki/architecture/browser-undo.md
priority: low
type: bug
ordinal: 442000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-357's agent. TASK-357 made registerUndo(actionName:in:handler:) take the spaces an action works in, so a Private window's entries can be dropped when it closes. reRegisterRunningUndoEntry passes `in: []`. Only Add Space and Delete Space use it today and neither is ever Private, so it is latent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A re-registered entry carries the spaces of the entry it replaces
- [x] #2 A test re-registers an entry in a Private space and checks it is dropped when the window closes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. reRegisterRunningUndoEntry takes the spaces of the entry it replaces (in:), and registers both the one-step bounce and the re-registered entry with them through registerUndo(actionName:in:), so a Private one is tracked (and dropped with its window) at every step; it puts nothing back for a Private space already gone, and the main-queue hop does not run the stack once the bounce's Private space has gone (it would run the entry below).
2. deleteSpaceFromUndoStack passes [space].
3. Test (PrivateWindowUndoTests): an undo in a Private space re-registers itself; after the hop the entry is back; closing the window drops it. Mutation check with in: [].
4. LinkRouteStoreTests for the real bounce path; wiki (browser-undo, link-routing-space-deletion); commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise confirmed in the code (in: [] at the only registration) and by the new tests against the old body of reRegisterRunningUndoEntry (mutation check: both new tests failed: the entry put back outlived its Private window and ran again; with the window closed before the hop, the entry was put back anyway).
Fix: reRegisterRunningUndoEntry(actionName:in:handler:) (internal for tests) registers both the one-step bounce and the entry put back through registerUndo(actionName:in:) with the replaced entry's spaces; registerUndo now returns whether it registered (@discardableResult), and nothing goes back (no hop) for a Private space already gone; the main-queue hop runs nothing if the bounce's Private window closed in between (it would run the entry under the dropped bounce) and takes the dropped entries off at once instead. deleteSpaceFromUndoStack passes [space].
Tests: PrivateWindowUndoTests 18 (2 new: testAnEntryPutBackOnTheStackGoesWithItsPrivateWindow, testAnEntryWhosePrivateWindowClosedBeforeTheHopIsNotPutBack, the latter in the redo direction so the hop's guard is what keeps the normal Close Tab from running) + LinkRouteStoreTests 42 (the real Add/Delete Space bounce path) = 60, 0 failures.
/code-review medium --fix: no correctness bug; applied: the window-closed-before-hop test rewritten in the redo direction (verified it fails with the hop guard removed); registerUndo returns Bool and shares spacesAreOpen instead of a duplicated pre-check. Skipped: a duplicate private Counter test helper (fourth in the tests).
Runtime: not applicable (no Private path uses the bounce in the app; latent).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
reRegisterRunningUndoEntry now takes the spaces of the entry it replaces and registers the bounce and the entry put back with them, so an entry in a Private space stays tracked and goes with its window; nothing is put back for a closed Private window, and the hop never runs the entry under a dropped bounce. Latent today (only Add/Delete Space use it). 2 new tests; 60 tests in PrivateWindowUndoTests + LinkRouteStoreTests pass. Wiki link-routing-space-deletion and browser-undo updated.
<!-- SECTION:FINAL_SUMMARY:END -->
