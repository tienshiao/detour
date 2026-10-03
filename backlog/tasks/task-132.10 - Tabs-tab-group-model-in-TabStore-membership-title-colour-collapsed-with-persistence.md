---
id: TASK-132.10
title: >-
  Tabs: tab group model in TabStore (membership, title, colour, collapsed) with
  persistence
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 142000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add tab groups for normal tabs: a group id on the tab and a group record on the Space (title, colour from Chrome's nine names, collapsed). This is the model the tabGroups extension API and the sidebar stripe build on; no user-facing way to create a group is required yet. Decide and enforce the invariants alongside split groups: a split pair is wholly inside or outside a group; whether members must be contiguous (Chrome's are) and, if so, snap insertions and move blocks the way split groups do. Pinned tabs and favourites are never grouped (Chrome ungroups on pin).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A tab can be added to a new or existing group and removed from it; a group with no members left is removed
- [ ] #2 Group title, colour and collapsed state can be read and changed
- [ ] #3 Closing, archiving, pinning, making a favourite, moving to another space or detaching a member updates membership and never leaves a split pair half in a group
- [ ] #4 Undo of a close or move restores the tab's group membership when the group still exists
- [ ] #5 Groups and membership survive a relaunch; a database from before the migration loads with no groups
- [ ] #6 Observers are notified of group creation, change and removal
- [ ] #7 Unit tests cover the invariants; docs/data-model.md describes the model
<!-- AC:END -->
