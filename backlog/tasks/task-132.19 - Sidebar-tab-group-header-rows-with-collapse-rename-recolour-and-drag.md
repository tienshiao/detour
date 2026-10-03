---
id: TASK-132.19
title: 'Sidebar: tab group header rows with collapse, rename, recolour and drag'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
labels: []
dependencies:
  - TASK-132.11
parent_task_id: TASK-132
priority: low
ordinal: 151000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Second step of the tab group UI, after the stripe. A group gets a header row (colour, title) that collapses and expands its members, can be renamed and recoloured, and can be dragged as a block; tabs can be dragged into and out of a group; the user can create a group from the context menu. Row conversions go through SidebarLayout / TabListItems, and drops through the SidebarDragDrop resolver enums with tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A group shows a header row above its members; collapsing hides them and tabGroups reports collapsed
- [ ] #2 The header can be renamed and recoloured, and the change reaches tabGroups.onUpdated
- [ ] #3 Dragging the header moves the whole group; dragging a tab onto or out of the group changes its membership
- [ ] #4 A tab's context menu can add it to a new or existing group and remove it
- [ ] #5 Selecting a tab in a collapsed group (for example from an extension) expands the group or otherwise keeps the selection visible
- [ ] #6 SidebarLayoutTests and SidebarDragDropTests cover the new rows and drops
<!-- AC:END -->
