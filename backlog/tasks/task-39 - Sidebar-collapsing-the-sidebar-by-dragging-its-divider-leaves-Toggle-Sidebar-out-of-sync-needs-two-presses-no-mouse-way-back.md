---
id: TASK-39
title: >-
  Sidebar: collapsing the sidebar by dragging its divider leaves Toggle Sidebar
  out of sync (needs two presses, no mouse way back)
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 03:31'
labels:
  - sidebar
  - window
  - bug
dependencies: []
priority: medium
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user. Dragging the sidebar/content divider far enough collapses the sidebar (sidebarItem.canCollapse = true in BrowserWindowController), but then (1) there is no mouse gesture to bring it back, and (2) View > Toggle Sidebar (Cmd+S) and the sidebar toggle button need two presses to show it.

Root cause (Detour/Browser/Window/BrowserWindowController.swift): the sidebar mode lives in a separate flag, sidebarAutoHides, which only toggleSidebarAutoHide() changes. A drag collapse sets sidebarItem.isCollapsed = true but leaves sidebarAutoHides = false. The first Toggle flips sidebarAutoHides to true and, because the sidebar is already collapsed, does nothing visible. The second flips it back to false and expands it. The edge-hover reveal (mouseEntered, zone 'edge') requires sidebarAutoHides, so after a drag collapse hovering the left edge does nothing either. The isCollapsed KVO observer (sidebarCollapseObservation) hides the traffic lights but does not update the mode. On macOS 26, contentItem.automaticallyAdjustsSafeAreaInsets is also only set by the toggle, so a drag-collapsed layout may differ from a toggle-collapsed one. The split view's autosaveName (BrowserSplitView) may also restore a collapsed sidebar at launch with sidebarAutoHides = false, the same mismatch.

Expected: a drag collapse is the same state as Toggle Sidebar hiding it. sidebarAutoHides (and the safe-area setting) follow isCollapsed when the collapse or expand did not come from hover, so one Toggle press shows the sidebar again and hovering the left edge reveals it like any auto-hidden sidebar. Hover-driven collapses and expands (sidebarOpenedByHover) must not flip the mode. Decide whether dragging the divider back out from the window edge should also be supported, and record the decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After collapsing the sidebar by dragging the divider, a single Toggle Sidebar (menu, Cmd+S or the sidebar button) shows it again
- [ ] #2 After a drag collapse, hovering the left window edge reveals the sidebar exactly as in the Toggle-hidden mode, and it auto-hides again on exit
- [ ] #3 Hover reveal/auto-hide does not change the sidebar mode; the traffic lights and (macOS 26) safe-area insets match between drag-collapsed and toggle-collapsed states
- [ ] #4 Launching with a split view autosave that restores a collapsed sidebar starts in the same consistent mode; the state logic is unit-tested (e.g. a pure mode reducer over collapse events with their source)
<!-- AC:END -->
