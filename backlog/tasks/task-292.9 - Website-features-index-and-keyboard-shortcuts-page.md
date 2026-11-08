---
id: TASK-292.9
title: 'Website: features index and keyboard shortcuts page'
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 350000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Features without their own page (Find in Page, Dark Mode, Drag Handles, Web Inspector, Auto-Updates, Multi-Window, Downloads, Audio Controls, Session Restore, Hover Cards, Sidebar Auto-Hide, Liquid Glass) still need a home, and keyboard shortcuts are a page people search for and the Help menu opens. Shortcuts must come from the app (AppDelegate menus and key handlers), not memory.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 /features/ lists every feature with a one-line description, linking to its page where one exists
- [ ] #2 /shortcuts/ lists every keyboard shortcut grouped by menu, generated from or checked against the menus in the current release
- [ ] #3 Both pages are in the sitemap and linked from the nav or footer
<!-- AC:END -->
