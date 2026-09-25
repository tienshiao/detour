---
id: TASK-119
title: >-
  Tabs: native Archived / Closed Tabs panel to browse, search and restore
  closed-tab records
status: To Do
assignee: []
created_date: '2026-09-25 06:35'
updated_date: '2026-09-25 07:15'
labels:
  - tabs
dependencies:
  - TASK-116
  - TASK-117
priority: medium
ordinal: 119000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Once Reopen Closed Tab skips archived records (TASK-116), archived tabs are only recoverable through history. Build a NATIVE AppKit surface (not a detour:// page) modelled on Arc's Archived Tabs: a panel/window opened from the space (sidebar space header menu and a menu-bar item) that lists the space's closedTab records — Closed (archivedAt NULL) and Archived (archivedAt set) sections, newest first by closedAt, grouped by day, each row showing favicon, title, url host and relative time, with a search field filtering on title and url. Clicking a row restores it through the same path as Reopen Closed Tab (TabStore.reopenClosedTab's restoredTab, extension-page classification included) and removes the record; a context menu offers Restore and Delete. Uses NSTableView/NSOutlineView in the style of the existing sidebar cells (TabCellView, GlassContainerView). Longer term this panel is also the surface for synced closed-tab data (saved page text), so keep the listing query and the restore path in TabStore/AppDatabase rather than in the view controller.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A native panel lists the current space's closed and archived records separately, newest first, grouped by day
- [ ] #2 Search matches title and url and filters both sections live
- [ ] #3 Restore reopens the tab at its original position in the space and deletes the record; extension pages follow the TASK-24/28 rules; Delete removes the record without reopening
- [ ] #4 Records without closedAt (pre-TASK-116) still list, sorted by id, in an undated group
- [ ] #5 Incognito spaces never show the panel entry point and never appear
- [ ] #6 Unit tests cover the listing query, search filtering, restore and delete; the panel's row/section layout is pure and unit-tested like SidebarLayout
- [ ] #7 A 'Clear Archive' button in the panel and a matching menu item delete the space's archived (and closed) records after confirmation; the closed-tab table has no row cap, so this is the user's way to bound it
<!-- AC:END -->
