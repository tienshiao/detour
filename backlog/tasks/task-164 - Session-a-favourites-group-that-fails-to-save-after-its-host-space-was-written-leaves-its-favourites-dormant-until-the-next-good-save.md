---
id: TASK-164
title: >-
  Session: a favourites group that fails to save after its host space was
  written leaves its favourites dormant until the next good save
status: To Do
assignee: []
created_date: '2026-10-04 18:41'
labels:
  - bug
dependencies: []
references:
  - Detour/Storage/Database.swift
  - DetourTests/SessionSaveFailureTests.swift
  - wiki/architecture/persistence.md
priority: low
ordinal: 187000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-04 by the code review of TASK-154; documented there, not repaired. Never observed: it needs a session save in which the database refuses a favourite row.

When a session save hits a row the database refuses, AppDatabase.saveSessionSnapshotIsolatingFailures writes each unit (each space with its tabs and pinned rows, the profiles, each profile's favourites) in its own savepoint of one transaction, and a unit that fails is meant to keep exactly what the last good save wrote. For a favourites unit that is not quite true. Writing a space deletes its space row and re-inserts its rows, and the cascade sets favorite.tabID to NULL for favourites whose live backing tab is in that space. If the profile's favourites unit then fails and rolls back to its savepoint, the favourite rows it keeps are the old ones with tabID already cleared: after a relaunch those favourites are dormant (no live tab, state reloaded from the favourite's URL) rather than as last saved, until a later save writes the unit. The doc comment and wiki/architecture/persistence.md state this exception.

Possible repairs: write a profile's favourites in the same savepoint as the spaces hosting their tabs; re-point the kept rows' tabID after a favourites unit fails, when the backing tab row was written; or order the units so the cascade cannot touch rows a later failure keeps. Decide by what keeps the units independent (see TASK-154's notes on why per-section transactions and row-level isolation were rejected).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test in SessionSaveFailureTests fails before the fix: a refused favourite row in a profile whose live favourite is backed by a tab in a space that saves; after a relaunch the profile's other favourites are live with their saved backing tabs, not dormant
- [ ] #2 A favourites unit that fails keeps what the last good save wrote, including which favourites are live, or the task records why the exception stays and what the user would see
- [ ] #3 The other guarantees of the unit-by-unit save are unchanged: one transaction, a non-row error writes nothing, SessionSaveFailureTests and SessionSaveAtomicityTests pass
- [ ] #4 wiki/architecture/persistence.md and the doc comment on saveSessionSnapshotIsolatingFailures are updated
<!-- AC:END -->
