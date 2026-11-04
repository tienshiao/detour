---
id: TASK-206
title: 'Find bar: check Escape closes it in browser windows'
status: To Do
assignee: []
created_date: '2026-10-26 04:22'
labels:
  - find
  - bug
dependencies: []
priority: low
ordinal: 242000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-193.1. In a Quick Detour window, Escape in the find field did not close the find bar until the window got its own cancelOperation handling. Browser windows share the find bar code (FindInPageSession) and were not checked. Verify, and fix if browser windows have the same problem.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Escape in the find field closes the find bar and returns focus to the page in a browser window, a split pane and a Quick Detour
- [ ] #2 Checked at runtime with real key input
<!-- AC:END -->
