---
id: TASK-169
title: >-
  Sidebar: a hover-revealed sidebar sometimes stays open instead of hiding again
  (seen after switching tabs and returning to CodeToaster)
status: To Do
assignee: []
created_date: '2026-10-10 07:08'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/SidebarVisibilityState.swift
  - Detour/Browser/Window/BrowserWindowController.swift
  - wiki/sidebar/visibility-and-auto-hide.md
priority: medium
ordinal: 192000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-10. On a smaller laptop the sidebar is kept hidden (auto-hide mode). After revealing it by hovering the left edge, using it to switch tabs, and eventually switching back to the CodeToaster tab, the sidebar sometimes does not hide again and stays stuck open. The user's guess is that CodeToaster (a web app with an xterm.js terminal) captures a mouse event the sidebar needs; that is not established, and it may only be where the user spends the most time.

Not reproduced yet. Candidates read from the code, to confirm or rule out:

1. The hide is driven only by a mouseExited from the sidebar's tracking area. An exit that arrives during the 0.5 s grace period after a reveal is dropped (sidebarHoverGraceActive) and nothing re-checks where the pointer is when the grace period ends, so a quick in-and-out leaves the sidebar open until the pointer enters and leaves it again.

2. AppKit does not always deliver mouseExited: while a mouse button is down (a click or drag that starts in the sidebar and ends over the page), when the view under the pointer changes without the pointer moving (selecting a tab swaps the web view; the sidebar itself animates in and out), when the tracking area is rebuilt (.inVisibleRect), or when the app or window stops being active (.activeInActiveApp) while the pointer is inside. Any of these leaves openedByHover true with no hide scheduled.

3. The popover hold never ends. heldOpen is released only by NSPopover.didCloseNotification; the wiki already records a popover that stayed up with no didClose, and a popover whose window goes away another way would leave the hold on, after which every hoverHide is ignored. An extension popup or the site settings popover opened from the revealed sidebar would be the trigger.

4. The mode was changed to pinned by something that is not the user: an expand the reducer attributes as external (collapsedChanged(false) while it expects collapsed) pins the sidebar. A hover reveal racing the collapse animation of a hover hide is one way to get there.

5. A web view that captures the pointer (xterm.js mouse reporting, pointer lock, or a drag selection in the terminal) changing which events AppKit delivers to the window.

The fix should not depend on one exit event: whatever the cause, a revealed sidebar whose pointer is elsewhere should end up hidden.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The stuck state is reproduced, or caught in the running app with enough logging to name it: the reducer's state (autoHides, openedByHover, heldOpen, expectedCollapsed), whether a hide was scheduled, and the event that was missed
- [ ] #2 The cause is recorded in the task, including which of the listed candidates were ruled out and how
- [ ] #3 A hover-revealed sidebar hides after the pointer has left it in each case found, including an exit during the reveal grace period and a tab switch made from the revealed sidebar
- [ ] #4 A hover-revealed sidebar still stays open while the pointer is in it and while a popover opened from it is showing (TASK-127), and Toggle Sidebar still pins it
- [ ] #5 The rule is in the pure reducer with tests in SidebarVisibilityStateTests that fail before the fix; anything that cannot be a reducer test has a stated reason
- [ ] #6 Checked in the running app with real pointer movement, on a page that takes mouse input (an xterm.js terminal with mouse reporting on); the wiki's auto-hide page is updated
<!-- AC:END -->
