---
id: TASK-357
title: >-
  Private windows: their undo entries outlive the window and can rebuild a
  Private tab nobody sees
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
labels:
  - incognito
  - undo
  - privacy
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - wiki/architecture/browser-undo.md
  - wiki/architecture/incognito.md
priority: medium
type: bug
ordinal: 438000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 while writing wiki/architecture/browser-undo.md (read from the code, not run). TabStore's one undo stack is app-wide. Closing a Private window removes its space (removeIncognitoSpace) and tears its tabs down, but leaves that window's undo entries on the stack, so a later Undo Close Tab in a normal window could rebuild a live tab on the Private profile's store into the removed space, which no window shows. Privacy-relevant: Private browsing should leave nothing reachable after its window closes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Whether a closed Private window's undo entries can still run is established at runtime and recorded
- [ ] #2 After a Private window closes, no undo or redo action can recreate or reference its tabs, spaces or profile data
- [ ] #3 A test covers closing a Private window with undoable actions on the stack, then undoing from a normal window
<!-- AC:END -->
