---
id: TASK-132.18
title: >-
  Extensions: windows.create({type: 'popup'}) opens a chromeless window at the
  requested size
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: low
ordinal: 150000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude extension opens sidepanel.html?mode=window with windows.create({type: 'popup', width: 500, height: 768, left, top, focused}) for scheduled tasks. openNewWindowUsing currently builds a full browser window with a sidebar and reports type normal.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A popup-type window shows only the page, at the requested frame, with no tab sidebar
- [ ] #2 windows.get reports its type as popup, and windows.remove and closing it by hand both work
- [ ] #3 A normal-type create is unchanged
<!-- AC:END -->
