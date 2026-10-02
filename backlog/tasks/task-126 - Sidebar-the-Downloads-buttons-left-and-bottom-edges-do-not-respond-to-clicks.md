---
id: TASK-126
title: 'Sidebar: the Downloads button''s left and bottom edges do not respond to clicks'
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
- [x] #1 A click anywhere inside the Downloads button's visible hover circle opens the downloads popover
- [x] #2 The hover highlight appears over the same area that accepts clicks
- [x] #3 Window resizing from the bottom-left corner and left/bottom edges still works
- [x] #4 The Add Space button at the bottom-right is checked for the same problem and fixed if affected
- [x] #5 The cause is identified and recorded in the task notes
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Cause (confirmed with an in-app hit-test map of the bottom-left corner, 1 pt grid): the sidebar's edge hover strip (setupEdgeHoverTracking — a plain 20 pt wide NSView on top of the split view, there only to carry a tracking area) took every click in the window's leftmost 20 pt. On macOS 26 the sidebar is inset 8 pt, so the strip covered the Downloads button's left 4 pt (button x 16–40 in window coords, strip to x 20); clicks there hit the strip and moved the window. On top of that the 27 pt hover circle was wider than the 24 pt button, leaving a 1.5 pt dead rim each side. The window's resize region (mapped with NSThemeFrame._isInResizeRegion:) is only the bottom 3 pt and the rounded-corner cutout and does not reach the button, before or after.
Fix: the strip is now a ClickThroughView (hitTest → nil; tracking areas do not depend on hit-testing) — this also stops it swallowing clicks on the page's left 20 pt while the sidebar is hidden. Downloads and Add Space are 28 pt wide with the hover circle kept at 27 pt (circularPadding −1, inset 6), so the circle is inside the frame; the badge offset and the space-strip width budget are adjusted to keep the layout identical. Add Space had no overlapping view, only the same rim.
After the fix the map shows the button taking x 14–41, y 9–39 (circle 14.5–41.5, 11–38) with nothing over it; with the sidebar collapsed the page's left edge hits the web view.
NOT exercised with a real pointer: clicking the button edge, dragging the bottom-left corner / edges to resize (resize region is unchanged by the fix), and — the one real risk — the hover reveal of an auto-hidden sidebar still firing from the click-through strip.

Code review (Oct 1): the hover circle's 27 pt is now stated with HoverButton.fixedHoverSize (honoured in circular mode) instead of derived as frame height + circularPadding −1, which gave 27 only while AppKit's alignment insets keep the frame at least 28 pt tall. Re-ran the in-app hit-test map on the final code: Downloads frame 28x31 and Add Space 28x28, both with a 27x27 hover circle inside the frame and nothing over them. Still not exercised with a real pointer. Open from the review: the space-strip budget (−12) and badge offset (−11) are literals that depend on bottomBarButtonWidth / bottomBarButtonInset.
<!-- SECTION:NOTES:END -->
