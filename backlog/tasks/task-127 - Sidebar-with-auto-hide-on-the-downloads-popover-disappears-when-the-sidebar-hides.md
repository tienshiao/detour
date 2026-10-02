---
id: TASK-127
title: >-
  Sidebar: with auto-hide on, the downloads popover disappears when the sidebar
  hides
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-02 01:27'
updated_date: '2026-10-02 06:53'
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
- [x] #1 With the sidebar auto-hidden and revealed by hover, opening the downloads popover and moving the pointer into it keeps the popover open and usable
- [x] #2 The popover stays open until the user dismisses it (click outside, Escape) or acts on it; it is not dismissed by the sidebar's auto-hide
- [x] #3 After the popover closes, the sidebar auto-hides again as normal when the pointer is outside it
- [x] #4 Behaviour with a pinned (always shown) sidebar is unchanged
- [ ] #5 Other sidebar-anchored popovers are checked for the same problem and fixed or ticketed
- [x] #6 Tests cover any change to the sidebar visibility state logic
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fix: SidebarVisibilityState gains heldOpen with events holdBegan / holdEnded(pointerInSidebar:) and action scheduleAutoHide. While held, hoverHide is ignored (the hover session stays open); when the hold ends with the pointer outside the sidebar the hide delay is restarted, since no further exit event will come. BrowserWindowController observes NSPopover didShow/didClose and holds for any popover whose window is a child of this window — NSPopover does not expose its positioning view, and a popover opened while the sidebar is hover-revealed comes from the sidebar. That covers the downloads popover, the site settings popover and the extension popups without touching their call sites.
Verified in-app (auto-hide on, hover reveal and hover-hide injected through the reducer, real downloads popover via the button): held=true while the popover is up, sidebar stays expanded and the popover window stays; after the popover closes with the pointer outside, the sidebar collapses after the delay. Pinned sidebar: unchanged. 7 new reducer tests.
AC5 partly: the settings and extension popovers go through the same mechanism but were not exercised individually. Sidebar context menus (NSMenu) are not popovers and are not covered; untested whether auto-hide fires under an open menu. Known gap: opening an extension popup from the settings popover closes one popover before the next is shown; if that takes longer than the 0.5 s hide delay with the pointer outside the sidebar, the sidebar can still hide in between.
NOT exercised with a real pointer.

Code review (Oct 1), two gaps left open: (a) the hold starts at NSPopover.didShowNotification, so a hide already due can fire before a popover that is presented late (an extension popup waits for its page to load) — same class as the settings-to-extension-popup gap above; at willShow the popover window is not yet a child of the browser window, so there is no simple earlier hook. (b) the hold is released only by didClose; a standalone probe showed a .semitransient popover staying shown with no didClose when its sidebar is collapsed under it (Cmd+S), which would leave heldOpen set until that popover closes — not reproduced in the app. Re-ran the in-app harness on the final code: held while the downloads popover is up, sidebar stays through an injected hover-hide, collapses after the popover closes with the pointer outside.
<!-- SECTION:NOTES:END -->
