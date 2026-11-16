---
id: TASK-363
title: >-
  Tests: a TabStore deallocated while a deferred Private undo removal waits
  leaves its notification observers
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - undo
  - tests
dependencies: []
references:
  - Detour/Browser/TabStore.swift
priority: low
type: chore
ordinal: 444000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-357's agent. dropUndoEntries(ofPrivateSpace:) waits for the open undo group to close via UndoManager notifications; if the store is deallocated first (only in tests), its observers are never removed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Observers are removed when the store goes away (or are held weakly and removed on fire)
<!-- AC:END -->
