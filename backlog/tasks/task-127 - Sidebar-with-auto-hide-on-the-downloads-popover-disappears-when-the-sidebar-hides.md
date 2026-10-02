---
id: TASK-127
title: >-
  Sidebar: with auto-hide on, the downloads popover disappears when the sidebar
  hides
status: To Do
assignee: []
created_date: '2026-10-02 01:27'
labels:
  - sidebar
  - downloads
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
  - Detour/Browser/Window/BrowserWindowController.swift
  - Detour/Browser/Window/SidebarVisibilityState.swift
priority: medium
ordinal: 127000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When the sidebar is set to auto-hide, clicking the Downloads button opens the downloads popover, but as soon as the sidebar hides again the popover disappears with it, so the popover cannot be used.

Context: `tabSidebarDidRequestShowDownloads` (BrowserWindowController+TabSidebar.swift) shows a transient `NSPopover` anchored to the sidebar's download button. Moving the pointer from the hover-revealed sidebar into the popover leaves the sidebar tracking area, which schedules `.hoverHide` (BrowserWindowController.mouseExited); collapsing the sidebar removes the anchor view and the popover goes with it. Other popovers anchored in the sidebar (e.g. the settings popover from `tabSidebarDidRequestShowSettings`) probably behave the same way and should be checked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With the sidebar auto-hidden and revealed by hover, opening the downloads popover and moving the pointer into it keeps the popover open and usable
- [ ] #2 The popover stays open until the user dismisses it (click outside, Escape) or acts on it; it is not dismissed by the sidebar's auto-hide
- [ ] #3 After the popover closes, the sidebar auto-hides again as normal when the pointer is outside it
- [ ] #4 Behaviour with a pinned (always shown) sidebar is unchanged
- [ ] #5 Other sidebar-anchored popovers are checked for the same problem and fixed or ticketed
- [ ] #6 Tests cover any change to the sidebar visibility state logic
<!-- AC:END -->
