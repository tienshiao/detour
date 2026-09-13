---
id: TASK-39
title: >-
  Sidebar: collapsing the sidebar by dragging its divider leaves Toggle Sidebar
  out of sync (needs two presses, no mouse way back)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 03:31'
updated_date: '2026-09-13 04:38'
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
- [x] #1 After collapsing the sidebar by dragging the divider, a single Toggle Sidebar (menu, Cmd+S or the sidebar button) shows it again
- [x] #2 After a drag collapse, hovering the left window edge reveals the sidebar exactly as in the Toggle-hidden mode, and it auto-hides again on exit
- [x] #3 Hover reveal/auto-hide does not change the sidebar mode; the traffic lights and (macOS 26) safe-area insets match between drag-collapsed and toggle-collapsed states
- [x] #4 Launching with a split view autosave that restores a collapsed sidebar starts in the same consistent mode; the state logic is unit-tested (e.g. a pure mode reducer over collapse events with their source)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add Detour/Browser/Window/SidebarVisibilityState.swift: pure reducer (autoHides, openedByHover, expectedCollapsed) over events toggle / hoverReveal / hoverHide / collapsedChanged(Bool) / restored(isCollapsed:), returning actions (setSafeAreaAdjusts, setCollapsed, cancelAutoHide, startHoverGrace).
2. Source attribution by comparing KVO isCollapsed against the state the window last requested (expectedCollapsed): a match is its own toggle/hover change (no mode change), a mismatch is external (divider drag, autosave restore) and the mode follows it.
3. BrowserWindowController: route toggleSidebarAutoHide, mouseEntered/Exited and the isCollapsed KVO through the reducer; sync once after the split view loads (autosave restore).
4. Probe animated toggleSidebar / setPosition / autosave KVO timing; reducer unit tests for all ACs plus tests driving the real window controller split view.
5. Full DetourTests run, notes, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: SidebarVisibilityState reducer (Detour/Browser/Window/SidebarVisibilityState.swift). BrowserWindowController feeds events and applies actions; sidebarAutoHides/sidebarOpenedByHover are replaced by private(set) var sidebarVisibility.

Collapse-source attribution: the state keeps expectedCollapsed, set whenever the window itself requests a collapse/expand (toggle, hover reveal, hover auto-hide) BEFORE the toggleSidebar call. The isCollapsed KVO feeds .collapsedChanged(v): v == expectedCollapsed is our own change (no mode change; a collapse still ends a hover session), v != expectedCollapsed is external (divider drag, autosave restore) and adopts autoHides = v plus the macOS 26 safe-area setting. This is timing-independent: probed on this machine, toggleSidebar(nil) (animated) and splitView.setPosition(0, ofDividerAt: 0) both flip isCollapsed and fire KVO synchronously inside the call, but a later KVO would be attributed the same way (tested). No stale queue of pending flags to drift.

Re-entrancy: the KVO path never emits setCollapsed, so the observer cannot trigger toggleSidebar; nested reduce calls from a synchronous KVO see the already-updated expectedCollapsed and return no actions (asserted in the test harness).

Toggle: decided from what is visible (collapsed or hover-revealed -> pin and show; pinned -> hide), so one press always flips state. Toggling a hover-revealed sidebar pins it in place, as before.

Autosave restore: probed that NSSplitView applies the autosave when the split view controller's view loads (after the observer is registered), so a restored collapse arrives as an external .collapsedChanged. A .restored(isCollapsed:) sync after the view is added is a safety net, and also hides the traffic lights if collapsed.

Divider decision: no new affordance for dragging the collapsed sidebar back out from the window edge. After a drag collapse the sidebar is in auto-hide mode, so the mouse path back is the left-edge hover reveal (plus Toggle Sidebar / Cmd+S / the button). If AppKit does let the divider be dragged out, that expand is external and correctly adopts pinned mode.

Traffic lights unchanged (KVO still hides on collapse, shows on expand); the launch sync now hides them for a restored-collapsed sidebar too.

Verification: SidebarVisibilityStateTests (16 reducer tests covering AC1-AC4, delayed KVO, re-entrancy, drag-while-hovering, toggle-while-hovering); BrowserWindowSidebarModeTests drives a real incognito BrowserWindowController (autosaveName cleared so the shared com.detourbrowser.mac defaults are not touched): setPosition(0) collapses -> autoHides true + traffic lights hidden -> one toggleSidebarMode expands; direct isCollapsed sets adopt the mode; and a real NSSplitViewController autosave round trip (unique autosave name, removed afterwards) shows a restored collapse starts in auto-hide mode. Full DetourTests: 885 tests, 0 failures. Hover itself not driven live (synthetic mouse events are blocked for this shell); covered at reducer level.

Post-merge (2026-09-12): BrowserWindowSidebarModeTests.testAutosaveRestoreArrivesAsExternalCollapse was flaky in the merged full run (fixed 0.5 s wait for AppKit's deferred autosave; observer invalidated before a late restore; a closed window's delayed autosave rewrote the key after removal, poisoning the next run). Test now clears the key after the expanded layout settles, polls for the collapsed write, keeps the observer until the restore lands, lets the close-time write land before removing the key, and XCTSkips if AppKit writes nothing within 5 s. 20 iterations: 20 passed, 0 skipped; full suite 898 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The sidebar mode now follows the visible state. A collapse or expand that did not come from hover (divider drag, Toggle Sidebar, autosave restore at launch) sets auto-hide mode and the macOS 26 safe-area setting; hover reveal and auto-hide never change it. So one Toggle press shows a drag-collapsed sidebar, and edge hover reveals it. Logic is a pure SidebarVisibilityState reducer; KVO changes are attributed by comparing against the collapsed state the window last requested. No new drag-out-from-edge affordance: hover reveal is the mouse path. Verified with reducer unit tests, tests driving the real BrowserWindowController split view, and a full DetourTests run (885 passed, 0 failed).
<!-- SECTION:FINAL_SUMMARY:END -->
