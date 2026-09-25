---
id: TASK-115
title: >-
  Tabs: sidebar 'Archive Tab' / 'Archive Tabs Below' record the tab as archived
  (set archivedAt), not as a plain close
status: To Do
assignee: []
created_date: '2026-09-25 05:57'
labels:
  - tabs
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
  - Detour/Browser/TabStore.swift
priority: low
ordinal: 115000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sidebar context menu's Archive Tab and Archive Tabs Below (BrowserWindowController+TabSidebar.swift, tabSidebar(_:didRequestArchiveTabAt:) and didRequestArchiveTabsBelowIndex) call store.closeTab(id:in:) — or closeTab(at:wasSelected:) for the selected tab — without archivedAt, so their ClosedTabRecords are indistinguishable from a Cmd+W close. Only the timer sweep (TabStore.archiveStaleTabs) sets archivedAt today.

Thread an archive timestamp through both manual paths, including the selected-tab path in the window controller, so the closedTab row carries archivedAt.

Pitfall: TabStore.closeTab currently couples 'archivedAt != nil' with 'no undo registration' (the timer sweep must not pollute the undo stack). A user-initiated archive should stay undoable, so undo registration needs to be decided separately from archivedAt (e.g. undoable stays true for the menu paths; the sweep opts out explicitly).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Archive Tab on an unselected tab writes a closedTab record with archivedAt set
- [ ] #2 Archive Tab on the selected tab (closeTab(at:wasSelected:) path) writes a closedTab record with archivedAt set and selection moves as for a normal close
- [ ] #3 Archive Tabs Below writes archivedAt on every archived tab's record, including a selected one in the range
- [ ] #4 Manual archive remains undoable via Edit > Undo; the timer sweep still registers no undo
- [ ] #5 Cmd+W / Close Tab still writes archivedAt = nil
- [ ] #6 Incognito spaces still write no closedTab record
- [ ] #7 Unit tests in TabStore tests cover archivedAt for manual archive, timer archive, and plain close, plus undo registration for each
<!-- AC:END -->
