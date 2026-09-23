---
id: TASK-107
title: >-
  Tabs: Cmd+Option+Up/Down selects the previous/next tab in the space's sidebar
  order
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-23 06:22'
updated_date: '2026-09-23 06:35'
labels:
  - tabs
  - keyboard
dependencies: []
priority: medium
ordinal: 107000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Keyboard navigation through a space's tabs in the order the sidebar shows them: pinned rows (entries and pinned splits, folders flattened, entries inside collapsed folders skipped) then normal items (a split group is one stop). Up = previous, Down = next; wraps at the ends. Selecting a stop behaves exactly like clicking its row (split rows focus the remembered pane; dormant pinned entries are activated). Menu items live in the Navigate menu next to Back/Forward.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Navigate menu has Previous Tab (Cmd+Option+Up) and Next Tab (Cmd+Option+Down)
- [x] #2 Order matches the sidebar: pinned rows then normal items; folder rows and entries hidden in collapsed folders are skipped; a split is one stop
- [x] #3 Wraps from last to first and first to last; with a favourite or nothing selected, Next goes to the first stop and Previous to the last
- [x] #4 Selecting a stop reuses the sidebar click path (remembered split pane, dormant pinned activation)
- [x] #5 Pure stop/target functions are unit-tested
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: pure tabNavigationStops/tabNavigationTarget in Sidebar/TabNavigation.swift (TabNavigationTests); BrowserWindowController.selectNextTab/selectPreviousTab reuse the didSelectTabAt/didSelectPinnedTabAt click paths and scroll the row into view; Navigate menu items with Cmd+Option+Up/Down, validated (disabled when there is no other stop). Targeted tests + app build pass. Not yet exercised by hand in the running app (web view focus, dormant pinned wake, split pane memory).

Code review fix: tabNavigationStops() drops dormant pinned tiles that dormantTileRefusal says cannot open (e.g. a disabled extension's page) — otherwise Cmd+Option+Down re-targets the refused tile forever and toasts each press.
<!-- SECTION:NOTES:END -->
