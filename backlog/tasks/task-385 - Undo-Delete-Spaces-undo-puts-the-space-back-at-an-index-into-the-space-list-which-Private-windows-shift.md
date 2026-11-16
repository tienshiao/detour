---
id: TASK-385
title: >-
  Undo: Delete Space's undo puts the space back at an index into the space list,
  which Private windows shift
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:41:00Z'
labels:
  - spaces
  - undo
  - incognito
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - wiki/architecture/browser-undo.md
priority: low
type: bug
ordinal: 466000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-360, its code review); read from code, not run. Delete Space's undo puts the space back at `savedIndex`, an index into `TabStore.spaces` (`deleteSpace`'s undo in `Detour/Browser/TabStore.swift`: `let savedIndex = index`, later `min(savedIndex, self.spaces.count)`). `spaces` also holds Private windows' spaces, so a Private window closing between the delete and its undo shifts that index. Example from the review: spaces N, P (Private), B, C; delete B; close P; Undo gives N, C, B instead of N, B, C. Pre-existing.

TASK-360 fixed the same drift for Move Space: its undo records the space's id and `stablePosition(of:)` (the number of normal spaces before it), and `moveSpace(id:toStablePosition:)` puts it back. The review suggested reusing those helpers here. Wiki: wiki/architecture/browser-undo.md, wiki/architecture/profiles-and-spaces.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Undo of Delete Space puts the space back at its place among the normal spaces whatever Private windows opened or closed in between (N, P, B, C: delete B, close P, undo gives N, B, C)
- [ ] #2 Tests (PrivateWindowUndoTests) cover a Private window closed, and one opened, between the delete and its undo, and the redo
<!-- AC:END -->
