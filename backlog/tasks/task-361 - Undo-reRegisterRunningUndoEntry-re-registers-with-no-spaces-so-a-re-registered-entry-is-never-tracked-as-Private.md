---
id: TASK-361
title: >-
  Undo: reRegisterRunningUndoEntry re-registers with no spaces, so a
  re-registered entry is never tracked as Private
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
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
- [ ] #1 A re-registered entry carries the spaces of the entry it replaces
- [ ] #2 A test re-registers an entry in a Private space and checks it is dropped when the window closes
<!-- AC:END -->
