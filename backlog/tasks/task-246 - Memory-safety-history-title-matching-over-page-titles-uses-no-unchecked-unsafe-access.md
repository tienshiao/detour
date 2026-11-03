---
id: TASK-246
title: >-
  Memory safety: history title matching over page titles uses no unchecked
  unsafe access
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
labels:
  - memory-safety
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
priority: low
type: chore
ordinal: 290000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-231.8, which audited CRX and native-messaging parsing. HistoryDatabase's title matcher (asciiMatch via withContiguousStorageIfAvailable, an UnsafeBufferPointer) runs over page titles, which come from websites; it is the next most exposed parser. See wiki/platform/strict-memory-safety.md for how to run the audit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The title matcher has no unchecked unsafe uses: each is replaced by a bounds-checked equivalent or marked unsafe with a comment saying why it is in bounds
- [ ] #2 Matching results are unchanged: existing history search tests pass, plus tests with non-ASCII, empty and very long titles
- [ ] #3 The history search benchmark shows no meaningful regression, or the cost is recorded
<!-- AC:END -->
