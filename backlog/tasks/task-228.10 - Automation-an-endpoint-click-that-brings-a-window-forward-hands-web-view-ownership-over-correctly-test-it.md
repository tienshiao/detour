---
id: TASK-228.10
title: >-
  Automation: an endpoint click that brings a window forward hands web view
  ownership over correctly (test it)
status: To Do
assignee: []
created_date: '2026-11-15T07:30:00Z'
labels:
  - automation
  - windows
dependencies: []
references:
  - TASK-228.8
  - Detour/Automation/AutomationInput.swift
  - wiki/architecture/browser-window-controller.md
parent_task_id: TASK-228
priority: low
type: task
ordinal: 421000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-228.8. Since a left press on a control goes through NSWindow.sendEvent, a routed click in a window that is not key makes that window key while Detour is active, as a person's click does; direct delivery never did. Between two browser windows showing the same tab this moves web view ownership (the owning window shows the live web view, the other a snapshot). Nothing tests that path, and an agent's click causing an ownership hand-off the person did not expect is a behaviour to confirm, not assume.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test with two browser windows showing the same tab: an endpoint click on a control in the non-owning window moves ownership exactly as a person's click would (or is deliberately kept from doing so), and both windows end consistent (one live web view, one snapshot)
- [ ] #2 With Detour in the background the click does not activate Detour or change the key window
- [ ] #3 The decision (agent clicks may or may not bring a window forward) is recorded in the automation wiki
<!-- AC:END -->
