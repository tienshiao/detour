---
id: TASK-48
title: >-
  Peek: a cross-host link clicked in the unfocused pane of a pinned split
  bypasses the Peek intercept
status: To Do
assignee: []
created_date: '2026-09-13 06:15'
labels:
  - peek
  - split-tabs
dependencies: []
priority: low
ordinal: 48000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The cross-host Peek intercept in BrowserWindowController+Navigation.decidePolicyFor anchors on selectedTab and requires webView === tab.webView. In a pinned split (two pinned backing tabs hosted as panes), a link activated in the unfocused pane fires from a web view that is not selectedTab.webView, so the intercept falls through to .allow and the pinned tab navigates off its home host. The Shift and Option branches in the same function already resolve the firing tab with tab(owning:) for exactly this reason. A fix must resolve the anchored tab from the firing web view and focus that pane (window.makeFirstResponder(webView), as the Shift branch does) before showPeekOverlay, because showPeekOverlay anchors on selectedTab. Rated PLAUSIBLE by the TASK-42 code review: an ordinary mouse click normally moves first responder before the policy decision, so the reproduction may need a synthetic click (anchor.click()) or a selection change that does not move first responder. Confirm the reproduction first; if it cannot be reproduced with real clicks, note that and close.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A cross-host link activated in either pane of a pinned split opens a Peek attached to the clicked pane's tab, with that pane focused, instead of navigating the pane away
- [ ] #2 Same-host links in either pane still navigate in place
- [ ] #3 Cmd/Shift/Option modifier precedence is unchanged
- [ ] #4 A test covers the anchor resolution from the firing web view's tab (PeekAnchor or a sibling helper), including the unfocused-pane case
<!-- AC:END -->
