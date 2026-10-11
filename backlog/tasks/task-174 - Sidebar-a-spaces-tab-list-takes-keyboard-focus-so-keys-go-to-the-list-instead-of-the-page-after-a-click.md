---
id: TASK-174
title: >-
  Sidebar: a space's tab list takes keyboard focus, so keys go to the list
  instead of the page after a click
status: To Do
assignee: []
created_date: '2026-10-11 07:21'
labels:
  - sidebar
  - focus
  - bug
dependencies: []
references:
  - Detour/Browser/Sidebar/SidebarComponents.swift
  - Detour/Browser/Sidebar/TabSidebarViewController.swift
  - wiki/sidebar/keyboard-focus.md
  - DetourTests/SidebarPageFocusTests.swift
priority: medium
ordinal: 197000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Clicking a row in the sidebar's tab list makes the list first responder and selectTab leaves it there ("focus held by a control stays", wiki/sidebar/keyboard-focus.md rule 2). After choosing a tab with the mouse, typing goes to the list — arrow keys walk rows, everything else is dropped — until the user clicks the page.

Decision (user, 2026-10-11): the sidebar's tab lists should not be able to hold keyboard focus. Choosing a tab there leaves the keyboard on the page. This reverses the TASK-128/130/131 choice to let the active list keep focus for arrow-key row walking; Cmd+Option+Up/Down and Control+Tab remain the keyboard ways to change tab.

Out of scope: text fields that need the keyboard keep it while in use — an inline rename, and the Archived Tabs page (search field and its list).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A space's tab list never becomes first responder, on screen or off
- [ ] #2 After a click on a tab row the selected tab's page (or its presented Peek) holds keyboard focus, whatever held it before, unless the click itself opened something that takes it (the command palette from New Tab, an inline rename)
- [ ] #3 Clicking the list while a row is being renamed ends the rename as it did before (commit)
- [ ] #4 Ending an inline rename with Return or Escape gives the keyboard to the page, not to the list or to nothing
- [ ] #5 A rebuild of the space pages does not leave the keyboard on nothing
- [ ] #6 The Archived Tabs page keeps its keyboard behaviour (search field, Down into the list, Return, Delete)
- [ ] #7 Focus tests are updated to the new rule; wiki/sidebar/keyboard-focus.md records the decision and what it replaced
<!-- AC:END -->
