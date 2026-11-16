---
id: TASK-228.12
title: >-
  Automation: endpoint clicks select rows in the other table views (Archived
  Tabs list, Settings lists)
status: To Do
assignee: []
created_date: '2026-11-16T04:51:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-228.9
  - Detour/Automation/AutomationInput.swift
  - Detour/Browser/Sidebar/SidebarComponents.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: bug
ordinal: 430000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-228.9. NSTableView's mouseDown gives up on a press in a window that is not key unless it becomes a drag (_shouldAbortMouseDownAfterDragAttempt:), so an endpoint press, which never makes a window key in the background, does not select a row. TASK-228.9 fixed the sidebar's DraggableTableView (needsPanelToBecomeKey false while AutomationInput hands it the press); other tables such as the Archived Tabs page and Settings' lists (Shortcuts, Link Routes, Profiles, Spaces, Extensions) likely have the same problem. Check each first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each table view in the app is listed with whether an endpoint left click selects its row, in the background and with Detour active
- [ ] #2 Every one that does not is fixed the TASK-228.9 way (shared, not copied per class) or the reason it is left is recorded
- [ ] #3 A test covers one non-sidebar table; checked at runtime
<!-- AC:END -->
