---
id: TASK-228.13
title: >-
  Automation: choose_menu_item and close_menu wait in the input order while the
  agent pointer is on
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-228.11
  - wiki/features/automation-endpoint-agent-pointer.md
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 437000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's decision 2026-11-15 on a question TASK-228.11's review left open. With the agent pointer on, the endpoint's clicks and keys are queued so each lands in the order sent; choose_menu_item and close_menu skip that queue, so 'click X, then choose menu item Y' can run Y before the click lands.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With the agent pointer on, choose_menu_item and close_menu run only after every earlier input call has been delivered
- [ ] #2 With the pointer off, behaviour is unchanged
- [ ] #3 A test covers a click followed by a menu choice in both modes
<!-- AC:END -->
