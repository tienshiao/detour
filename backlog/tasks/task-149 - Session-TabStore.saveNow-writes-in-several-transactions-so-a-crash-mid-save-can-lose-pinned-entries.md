---
id: TASK-149
title: >-
  Session: TabStore.saveNow writes in several transactions, so a crash mid-save
  can lose pinned entries
status: To Do
assignee: []
created_date: '2026-10-04 02:29'
labels: []
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Storage/Database.swift
  - wiki/architecture/persistence.md
priority: medium
ordinal: 172000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TabStore.saveNow (Detour/Browser/TabStore.swift) persists the session through separate AppDatabase calls, each its own write transaction: saveSession (which deletes every space row and re-inserts spaces and tabs), saveProfiles, then per space savePinnedFoldersAndTabs and per profile saveFavorites. Deleting the space rows cascades to their pinnedTab / pinnedFolder rows, which are only re-inserted by the later calls. If the app is killed or crashes between the first transaction and the later ones, the database is left with the spaces and tabs of the new state but without pinned entries, folders or favorites for some or all spaces, and the next launch restores that.

Read from the code while writing wiki/architecture/persistence.md; never observed. saveNow runs on a debounce after every mutation and on window close and termination, so the window is short but frequent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One save is one database transaction: after an interrupted save the database holds either the complete previous state or the complete new one; a test that fails the save part-way (injected failure) shows pinned entries, folders and favorites intact, and fails before the fix
- [ ] #2 The cost of a save does not regress noticeably (measured on a large session and recorded in the task)
- [ ] #3 docs/data-model.md and wiki/architecture/persistence.md are updated
<!-- AC:END -->
