---
id: TASK-40
title: >-
  Spaces: undo actions registered before Delete Space act on a stale Space
  object after Undo Delete Space
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 04:41'
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
- [ ] #1 Close a tab in a space, delete the space, undo the delete, then undo the tab close: the tab reappears in the visible restored space
- [ ] #2 Every registerUndo closure in TabStore resolves the objects it mutates in a way that survives Undo Delete Space (or the space is re-inserted as the same object); the audit list is recorded in the task notes
- [ ] #3 Tests cover at least Close Tab, Edit Space and a pinned entry action across a Delete Space -> Undo, plus ordinary undo unchanged
<!-- AC:END -->
