---
id: TASK-126
title: 'Sidebar: the Downloads button''s left and bottom edges do not respond to clicks'
status: To Do
assignee: []
created_date: '2026-10-02 01:27'
labels:
  - sidebar
  - downloads
  - bug
dependencies: []
references:
  - Detour/Browser/Sidebar/TabSidebarViewController.swift
  - Detour/Browser/Shared/HoverButton.swift
  - Detour/Browser/Sidebar/SidebarComponents.swift
priority: medium
ordinal: 126000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Downloads button at the bottom-left of the sidebar is hard to click: the left side of the button and part of its bottom do not react to clicks, so only part of the visible button works.

Context: the button is a 24x24 circular `HoverButton` placed 8pt from the leading edge of the 32pt-high `bottomBar` (`DraggableBarView`, `mouseDownCanMoveWindow == true`) in `TabSidebarViewController`. It sits in the window's bottom-left corner, so likely suspects are the window's resize/corner hit region, the sidebar edge hover-reveal tracking zone, or another view overlapping the button — unconfirmed. The Add Space button at the bottom-right may be affected the same way and should be checked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A click anywhere inside the Downloads button's visible hover circle opens the downloads popover
- [ ] #2 The hover highlight appears over the same area that accepts clicks
- [ ] #3 Window resizing from the bottom-left corner and left/bottom edges still works
- [ ] #4 The Add Space button at the bottom-right is checked for the same problem and fixed if affected
- [ ] #5 The cause is identified and recorded in the task notes
<!-- AC:END -->
