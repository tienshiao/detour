---
id: TASK-228.9
title: >-
  Automation: a left click on a sidebar row selects its tab, as a person's click
  does
status: To Do
assignee: []
created_date: '2026-11-15T07:30:00Z'
labels:
  - automation
  - sidebar
dependencies: []
references:
  - TASK-228.7
  - TASK-228.8
  - Detour/Automation/AutomationInput.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: bug
ordinal: 420000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-228.8. Through the endpoint a left click on a sidebar tab row does not select the tab, on both the old direct route and with TASK-228.8's window routing off; select_tab does. Sidebar rows delay window ordering, so TASK-228.8 keeps them on the direct route. A right click on the same row opens its menu since TASK-228.7.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The endpoint's left click on a sidebar tab row selects that tab in that window, with Detour active and in the background
- [ ] #2 Clicks on the row's close button, a folder's disclosure and a pinned entry behave as a person's clicks do
- [ ] #3 A test covers selecting by click; checked at runtime
<!-- AC:END -->
