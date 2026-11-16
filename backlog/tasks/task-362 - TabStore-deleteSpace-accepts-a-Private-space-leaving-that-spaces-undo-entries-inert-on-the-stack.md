---
id: TASK-362
title: >-
  TabStore: deleteSpace accepts a Private space, leaving that space's undo
  entries inert on the stack
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - spaces
  - incognito
  - undo
dependencies: []
references:
  - Detour/Browser/TabStore.swift
priority: low
type: bug
ordinal: 443000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-357's agent. The UI never offers deleting a Private space, but TabStore.deleteSpace allows it; that space's older undo entries then stay on the stack (inert after TASK-357's guards, but still there).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 deleteSpace on a Private space is refused, or drops that space's undo entries like removeIncognitoSpace does
- [ ] #2 A test covers it
<!-- AC:END -->
