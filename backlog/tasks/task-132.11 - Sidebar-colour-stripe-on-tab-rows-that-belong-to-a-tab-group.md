---
id: TASK-132.11
title: 'Sidebar: colour stripe on tab rows that belong to a tab group'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
labels: []
dependencies:
  - TASK-132.10
parent_task_id: TASK-132
priority: medium
ordinal: 143000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First visible form of tab groups (product decision: stripe first, header rows later). A member row carries a leading stripe in the group's colour, and the group title is discoverable (tooltip or equivalent). No header row, no collapse, no group drag yet. Must not change row heights or the list's layout, and must go through SidebarLayout / TabListItems rather than inline row maths.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each normal-tab row in a group shows a stripe in the group's colour; a split-group row shows it once for the pair
- [ ] #2 Changing the group's colour or title, or a tab joining or leaving, updates the rows without a reload flash
- [ ] #3 The group title is reachable from a member row
- [ ] #4 The stripe reads correctly in light and dark, on the selected row, and during hover and drag
- [ ] #5 Ungrouped rows look exactly as they do today
<!-- AC:END -->
