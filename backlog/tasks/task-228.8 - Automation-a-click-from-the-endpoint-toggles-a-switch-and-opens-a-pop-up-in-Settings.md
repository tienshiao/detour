---
id: TASK-228.8
title: >-
  Automation: a click from the endpoint toggles a switch and opens a pop-up in
  Settings
status: To Do
assignee: []
created_date: '2026-11-15T05:14:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-228.7
  - TASK-338
  - Detour/Automation/AutomationInput.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: bug
ordinal: 416000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-338's runtime checks: in a test run, the endpoint's click on a Settings control hits the right view (hit_test and the click report NSSwitch / NSPopUpButton) but the switch does not toggle and the pop-up does not open. It behaved the same before TASK-338, so it is how the endpoint delivers clicks to controls that run their own tracking loop, not the form. TASK-228.7's runtime run reported a click on a Settings switch as completed; whether it toggled was not checked. Settings input stays test-run only (TASK-228.7); this is about making those test-run clicks real.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 In a test run, click on a Settings switch toggles it and click on a pop-up opens its menu (list_menu shows it), as a real click would
- [ ] #2 The fix is in the input path (how the press and release reach a control's tracking loop), not a special case for Settings, and browser-window controls (sidebar buttons, address bar buttons) still work
- [ ] #3 Settings input on the user's endpoint is still refused (gate_closed), and the Automation section still refused in test runs
- [ ] #4 Tests cover a switch and a pop-up; checked at runtime
<!-- AC:END -->
