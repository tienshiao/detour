---
id: TASK-115
title: >-
  Tabs: sidebar 'Archive Tab' / 'Archive Tabs Below' record the tab as archived
  (set archivedAt), not as a plain close
status: Done
assignee:
  - '@claude'
created_date: '2026-09-25 05:57'
updated_date: '2026-09-25 06:44'
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
- [x] #1 Archive Tab on an unselected tab writes a closedTab record with archivedAt set
- [x] #2 Archive Tab on the selected tab (closeTab(at:wasSelected:) path) writes a closedTab record with archivedAt set and selection moves as for a normal close
- [x] #3 Archive Tabs Below writes archivedAt on every archived tab's record, including a selected one in the range
- [x] #4 Manual archive remains undoable via Edit > Undo; the timer sweep still registers no undo
- [x] #5 Cmd+W / Close Tab still writes archivedAt = nil
- [x] #6 Incognito spaces still write no closedTab record
- [x] #7 Unit tests in TabStore tests cover archivedAt for manual archive, timer archive, and plain close, plus undo registration for each
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. TabStore.closeTab: add registersUndo: Bool = true; undo registration condition becomes 'undoable && registersUndo' instead of 'undoable && archivedAt == nil'. archiveStaleTabs passes archivedAt: now, registersUndo: false. undoable: false keeps its meaning (no record, no undo).
2. archiveStaleTabs(now: Date = Date()) becomes internal like sleepStaleTabs(now:) so tests can drive the sweep with a clock; cutoff derives from now.
3. BrowserWindowController.closeTab(at:wasSelected:) gains archivedAt: Date? = nil and forwards it to store.closeTab. The two sidebar delegate methods (Archive Tab, Archive Tabs Below) take one Date() per action and pass it on both the selected and unselected paths.
4. TabStoreTests: manual archive writes archivedAt and registers undo; timer archive writes archivedAt and registers no undo; plain close writes nil and registers undo; incognito writes no record.
5. docs/data-model.md: archivedAt row now 'set by the auto-archive timer and the sidebar Archive items'.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (Opus subagent + Fable review). closeTab gains registersUndo (default true); the undo condition is 'undoable && registersUndo', decoupled from archivedAt. archiveStaleTabs(now:) is internal for tests and passes archivedAt: now, registersUndo: false. closeTab(at:wasSelected:archivedAt:) on the window controller forwards the stamp; both sidebar Archive items take one Date() per action. Tests: TabStoreTests 'Archive vs close records' (manual archive, timer archive, plain close, incognito) — fixture uses manual undo grouping; the sweep test runs outside any group because an explicitly opened empty group still counts as canUndo. TabStoreTests: 32 passed.

Review (/code-review --fix): the undo closure's redo re-closed without archivedAt, turning a redone archive into a plain close — fixed (redo forwards the stamp; testRedoOfUndoneArchiveKeepsArchivedAt). Undo action name is now 'Archive Tab' for a manual archive, 'Close Tab' otherwise. Validation: TabStoreTests 33 passed, app build succeeded.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Sidebar 'Archive Tab' / 'Archive Tabs Below' now write closedTab records with archivedAt (both the selected-tab path through BrowserWindowController.closeTab(at:wasSelected:archivedAt:) and the direct store path), while the timer sweep is the only caller that skips undo (new registersUndo parameter, decoupled from archivedAt). Manual archive undoes as 'Undo Archive Tab' and a redo keeps the archive stamp. archiveStaleTabs(now:) is internal for tests. Verified with five new TabStoreTests (manual archive, timer archive, plain close, incognito, undo/redo) — 33/33 pass.
<!-- SECTION:FINAL_SUMMARY:END -->
