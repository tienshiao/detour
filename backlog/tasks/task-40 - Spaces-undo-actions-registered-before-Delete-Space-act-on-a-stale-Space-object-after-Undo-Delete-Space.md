---
id: TASK-40
title: >-
  Spaces: undo actions registered before Delete Space act on a stale Space
  object after Undo Delete Space
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 04:41'
updated_date: '2026-09-13 19:36'
labels:
  - spaces
  - undo
  - bug
dependencies: []
priority: low
ordinal: 40000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-35 work. TabStore.deleteSpace's undo rebuilds the space as a brand new Space object with the same id (Space(id: id, ...)) and re-inserts it. Undo actions registered before the delete (Close Tab, Move Tab, Pin/Unpin, Edit Space, pinned entry and folder actions, and anything else closing over a Space instance rather than looking it up by id) still capture the old, discarded Space object. After Delete Space -> Undo, undoing one of those older actions mutates the discarded object: the visible space does not change, observers are notified with an object the UI does not show, and the change may be saved or lost unpredictably. TASK-35 made profile deletion clear the undo stack, but this happens without any profile deletion. Fix by making undo closures resolve spaces by id at undo time (self.space(withID:)) and no-op when the space is gone, or by having Undo Delete Space re-insert the original Space object instead of a copy. Audit every registerUndo closure in TabStore for captured Space, PinnedEntry, PinnedFolder and BrowserTab instances that a rebuild can replace.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Close a tab in a space, delete the space, undo the delete, then undo the tab close: the tab reappears in the visible restored space
- [x] #2 Every registerUndo closure in TabStore resolves the objects it mutates in a way that survives Undo Delete Space (or the space is re-inserted as the same object); the audit list is recorded in the task notes
- [x] #3 Tests cover at least Close Tab, Edit Space and a pinned entry action across a Delete Space -> Undo, plus ordinary undo unchanged
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Fix: Undo Delete Space re-inserts the ORIGINAL Space object instead of a copy. deleteSpace keeps a strong reference to the space in its undo closure, empties its tabs / pinnedEntries / pinnedFolders after snapshotting (the tabs are torn down as today), and undo repopulates that same object from the snapshots and re-inserts it at the saved index. Every older undo closure that captured the Space instance then acts on the visible space again.
2. Audit all registerUndo closures in TabStore (about 40) for captured BrowserTab / PinnedEntry / PinnedFolder instances that a rebuild replaces with new objects of the same id; convert those to id lookups at undo time (no-op with a log when the object is gone). Closures that already use ids stay.
3. Tests (UndoAfterDeleteSpaceTests): close a tab in space A, delete A, undo twice: the tab is back in the space TabStore lists (same Space identity, tab found by id); pin a tab, delete, undo, undo: the pin undo acts on the listed space; undo of Delete Space after the profile was deleted still no-ops (TASK-35 behaviour).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fix: Undo Delete Space re-inserts the original Space object; deleteSpace empties tabs/pinnedEntries/pinnedFolders after snapshotting and the undo repopulates that instance. Audit of ~40 registerUndo sites: converted captured objects to ids in addTabInSplit (Open in Split), pinTab (Pin Tab), unpinTab (Unpin Tab), addPinnedFolder (New Folder); the rest already resolve by id or capture only the Space (now correct). Nothing else stores a Space (window activeSpace is computed from activeSpaceID). Test harness note: a test body never turns the run loop so UndoManager.groupsByEvent never closes the auto group; UndoAfterDeleteSpaceTests sets groupsByEvent = false and wraps each action in an explicit group. Review pass (ceda589): rehomeFavoriteTabs goes through deactivateFavorite, redundant clears dropped, shared sleepingTab helper. UndoAfterDeleteSpaceTests 8 cases; full suite 1104 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Undo Delete Space restores the same Space instance, so undo actions registered before the delete act on the visible space again; object-capturing undo closures now resolve by id. Verified by UndoAfterDeleteSpaceTests and ProfileDeletionUndoTests.
<!-- SECTION:FINAL_SUMMARY:END -->
