---
id: TASK-132.5
title: >-
  Extensions: tabs.create and windows.create with chrome://newtab open a blank
  new tab
status: To Do
assignee: []
created_date: '2026-10-03 23:07'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: medium
ordinal: 137000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude extension opens every agent tab with tabs.create({url: 'chrome://newtab', active: false}) and reports 'chrome://newtab/' as the tab URL. Detour has no mapping for it, so the tab would load an error page. Map Chrome's new-tab URL to Detour's blank tab in the openNewTabUsing / openNewWindowUsing delegate paths.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 tabs.create({url: 'chrome://newtab'}) and the trailing-slash form create a blank tab that shows no error page and can then be navigated with tabs.update
- [ ] #2 windows.create({url: 'chrome://newtab'}) opens a window with one blank tab
- [ ] #3 Other chrome:// URLs are still refused rather than loaded
- [ ] #4 Tests cover the mapped and refused cases
<!-- AC:END -->
