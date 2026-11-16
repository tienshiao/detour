---
id: TASK-360
title: >-
  Undo: Move Space's undo stores positions in the space list, which Private
  windows shift
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
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
- [ ] #1 Undo of Move Space restores the moved space's position whatever Private windows opened or closed in between
- [ ] #2 A test covers a Private window opened and one closed between the move and its undo
<!-- AC:END -->
