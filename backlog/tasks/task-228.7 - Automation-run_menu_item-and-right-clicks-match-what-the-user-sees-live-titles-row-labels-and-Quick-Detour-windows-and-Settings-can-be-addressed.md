---
id: TASK-228.7
title: >-
  Automation: run_menu_item and right clicks match what the user sees (live
  titles, row labels), and Quick Detour windows and Settings can be addressed
status: To Do
assignee: []
created_date: '2026-11-14T23:45:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-320
  - TASK-326
  - TASK-327
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 412000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 during the batch's runtime checks. (1) run_menu_item by path matched the title a shared item had at its last validation: "File > Unpin Tab" was refused while the item still read "Pin Tab" (TASK-320). (2) list_windows and run_menu_item cover browser windows only, so Quick Detour and quarantine windows could not be driven (TASK-320, TASK-326), and Settings could only be driven through Accessibility and posted key events (TASK-327, TASK-328). (3) A right click sent to a sidebar row's label or icon opens no menu, while one on the row's background does; a real right click on the label opens it (TASK-326).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 run_menu_item validates the menu (as AppKit does before showing it) before matching a path, so the title it matches is the one the user would see
- [ ] #2 list_windows lists Quick Detour, quarantine and Settings windows with their kind, and run_menu_item, screenshot and the input tools accept them (Private and quarantine rules as for browser windows)
- [ ] #3 A right click at a sidebar row's label or icon opens the row's menu as a real right click does
- [ ] #4 Tests cover each; the wiki tools table and traps are updated
<!-- AC:END -->
