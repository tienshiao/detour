---
id: TASK-180
title: 'Sidebar: pinning a hover-revealed sidebar with Cmd+S leaves the page under it'
status: In Progress
assignee: []
created_date: '2026-10-23 05:05'
updated_date: '2026-10-23 05:17'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController.swift
  - Detour/Browser/Window/SidebarVisibilityState.swift
  - wiki/sidebar/visibility-and-auto-hide.md
priority: medium
ordinal: 202000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-22. With the sidebar in auto-hide mode, hover the left edge to reveal it, then press Cmd+S (Toggle Sidebar) to pin it. The sidebar stays (correct) but the web view is not resized: it stays full width and the sidebar keeps covering its left part. Pressing Cmd+S twice more (hide, show) fixes the layout.

Suspected cause (from reading the code): in auto-hide mode the content split item has automaticallyAdjustsSafeAreaInsets = true (macOS 26), so a hover-revealed sidebar floats over the content instead of resizing it. Toggling a hover-revealed sidebar emits only setSafeAreaAdjusts(false) — no setCollapsed, since it is already expanded — and nothing makes the split view lay the content item out again for the new value.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Pinning a hover-revealed sidebar (Cmd+S, the menu item, or the sidebar button) resizes the page so the sidebar no longer covers it, with no extra toggles
- [ ] #2 Hover reveal in auto-hide mode still overlays the page without resizing it, and the other toggle paths (pinned to hidden, hidden to pinned) still lay out correctly
- [ ] #3 The cause is confirmed at runtime and recorded; the wiki's auto-hide page is updated
- [ ] #4 Covered by a test where one is practical (BrowserWindowSidebarModeTests drives a real window), otherwise the reason is stated
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-22 investigation on macOS 26.7 (25G229), epic-claude-extension branch:
- Mechanism confirmed: in auto-hide mode the content item has automaticallyAdjustsSafeAreaInsets = true, so a hover-revealed sidebar overlays the page (content item, contentAreaView, container and web view all x=0 w=1600; safeAreaInsets.left = 228). Pinning a hover-revealed sidebar emits only setSafeAreaAdjusts(false), no setCollapsed.
- On 26.7 setting the flag marks the split view needsLayout, and within 0.1 s the content moves beside the sidebar (x=228 w=1372, web view too). Not reproduced: settled reveal, and Toggle Sidebar 0.05/0.1/0.2 s into the reveal animation all ended correct (harness docs/harness/task180-harness.patch, screenshots matched).
- User: may depend on the site, or may have been seen on the next macOS version (not this machine). Likely the newer AppKit no longer re-lays out the split view when automaticallyAdjustsSafeAreaInsets changes without a collapse change.
- Added BrowserWindowSidebarModeTests.testPinningAHoverRevealedSidebarMovesThePageBesideIt / testShowingAHiddenSidebarPutsThePageBesideIt: pass on 26.7 (they do not fail before a fix here).

Handoff 2026-10-22: the user will reproduce and fix on the machine running the newer macOS.
- First, on that machine: run BrowserWindowSidebarModeTests (the two TASK-180 tests should fail there if the cause is the missing re-layout) and the harness (docs/harness/task180-harness.patch, applies on main and on the epic branch). Bug present = after the toggle, the container and web view stay at x=0 while the sidebar is shown.
- If the frames are right but the page still looks covered, the problem is in WebKit (safe-area insets or a site using env(safe-area-inset-left)), not the split view layout.
- Proposed fix if the frames are wrong: in handleSidebarEvent, when setSafeAreaAdjusts is applied without a setCollapsed, mark the split view for layout and lay it out; if the content still overlaps the sidebar, collapse and expand it without animation (what the user's hide/show workaround does).
<!-- SECTION:NOTES:END -->
