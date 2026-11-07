---
id: TASK-132.24
title: >-
  Dev mode: a parked tab keeps the dev toolbar after it navigates away from a
  development URL
status: To Do
assignee: []
created_date: '2026-11-04T09:05:00Z'
labels:
  - bug
  - dev-mode
dependencies: []
parent_task_id: TASK-132
priority: low
ordinal: 308000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while merging main into epic-claude-extension (45f5da1, Nov 4 2026). Main's dev toolbar (TASK-186.2) shows above pages on development URLs such as 127.0.0.1. refreshDevToolbars only updates the hosted panes of a window. An automation-parked tab's container (TASK-132.3, AutomationParking) is not a hosted pane, so it keeps whatever toolbar it had when it was parked. If the parked page navigates from a dev URL to a normal site, the toolbar stays; if it navigates the other way, no toolbar appears. The toolbar also takes 30 pt, which changes the parked page's size; AutomationParkingWindowTests had to account for it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A parked tab's dev toolbar follows its current URL: added when it navigates to a development URL, removed when it navigates away
- [ ] #2 Parked page sizes stay correct when the toolbar comes or goes, covered by AutomationParkingWindowTests
- [ ] #3 Unparking hands the tab back with the toolbar in the right state
<!-- AC:END -->
