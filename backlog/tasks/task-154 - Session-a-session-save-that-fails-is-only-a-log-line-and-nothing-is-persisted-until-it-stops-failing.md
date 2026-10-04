---
id: TASK-154
title: >-
  Session: a session save that fails is only a log line, and nothing is
  persisted until it stops failing
status: To Do
assignee: []
created_date: '2026-10-04 08:53'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Database.swift
  - wiki/architecture/persistence.md
priority: medium
ordinal: 177000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Raised 2026-10-04 by the code review of TASK-149.

Since TASK-149 one TabStore.saveNow() is one transaction (AppDatabase.saveSessionSnapshot), so a failure in any record fails the whole save. saveNow discards the result. A failure that repeats (a foreign-key or uniqueness violation in one row, as the pinned-folder order bug fixed in TASK-149 was) makes every debounced save and the save at termination roll back: the user sees nothing, quits, and loses every session change since the last good save. Before TASK-149 the other sections of the save were still written.

Decide what the app should do when a session save fails: for example retry with the failing section isolated, keep the last good state and tell the user once, or fall back to per-section saves. Never observed; the known cause was fixed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The intended behaviour on a failed session save is decided and recorded in the task
- [ ] #2 A save that fails is detected by TabStore (the result is not discarded) and handled by the decided rule; a test with an injected failure covers it
- [ ] #3 A failure that repeats does not silently lose the whole session: either the unaffected parts are persisted or the user is told, by the decided rule
- [ ] #4 Session rows that cannot be made valid (a pinned folder whose parent is missing, a parent cycle) are repaired or dropped with a log line instead of failing every save; a test covers each
- [ ] #5 wiki/architecture/persistence.md is updated
<!-- AC:END -->
