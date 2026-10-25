---
id: TASK-203
title: 'Undo/redo: the Redo menu says ''Redo Add Space'' for a redo that deletes a space'
status: To Do
assignee: []
created_date: '2026-10-25 22:00'
updated_date: '2026-10-25 22:00'
labels:
  - undo
  - spaces
  - bug
dependencies: []
priority: low
ordinal: 239000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-191.1. After Delete Space is undone, Edit > Redo reads 'Redo Add Space', but that redo deletes the space again. Cause: deleteSpace's restore closure (the undo of Delete Space) registers the re-delete with actionName 'Add Space'. Registered while undoing, it lands on the redo stack, where it means 'redo Delete Space' and should be named 'Delete Space'. deleteSpaceFromUndoStack reuses the name when it puts a refused redo back (the TASK-191.1 bounce), so both must agree. Check the other space and profile undo registrations for the same mistake.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After Delete Space and Undo, the Redo menu item reads 'Redo Delete Space'; after Add Space, Undo reads 'Undo Add Space'
- [ ] #2 A redo refused because routes target the space (TASK-191.1) keeps the correct name when put back
- [ ] #3 Tested in the UndoAfterDeleteSpaceTests / LinkRouteStoreTests style (undoManager.redoActionName / undoActionName)
<!-- AC:END -->
