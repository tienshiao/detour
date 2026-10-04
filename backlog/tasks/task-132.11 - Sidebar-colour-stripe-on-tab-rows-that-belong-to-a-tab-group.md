---
id: TASK-132.11
title: 'Sidebar: colour stripe on tab rows that belong to a tab group'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
updated_date: '2026-10-04 19:21'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User note (2026-10-04, verbatim): "I think the colored accent bars for a group should also? at least? be on the sidebar tab so the user can identify the groups without having to click into them." Reading (Claude's, not confirmed): the group's colour must be visible on the member rows in the sidebar itself, without selecting a tab — which is AC #1 of this task. If the colour is also shown somewhere else (in the content area, or on a later header row, TASK-132.19), the sidebar row stripe is the part that must not be dropped. Open question for the user: whether 'also' means a second place is wanted in addition to the row stripe.
<!-- SECTION:NOTES:END -->
