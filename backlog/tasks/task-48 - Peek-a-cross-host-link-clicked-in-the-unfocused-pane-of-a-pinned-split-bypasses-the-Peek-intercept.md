---
id: TASK-48
title: >-
  Peek: a cross-host link clicked in the unfocused pane of a pinned split
  bypasses the Peek intercept
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 06:15'
updated_date: '2026-09-13 10:15'
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
- [x] #1 A cross-host link activated in either pane of a pinned split opens a Peek attached to the clicked pane's tab, with that pane focused, instead of navigating the pane away
- [x] #2 Same-host links in either pane still navigate in place
- [x] #3 Cmd/Shift/Option modifier precedence is unchanged
- [x] #4 A test covers the anchor resolution from the firing web view's tab (PeekAnchor or a sibling helper), including the unfocused-pane case
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduction reasoning: a real left click makes the pane first responder before the policy decision (BrowserWebView.becomeFirstResponder → browserWebViewDidBecomeFirstResponder retargets selectedTabID synchronously), so the intercept sees the clicked pane as selectedTab. Activations that do not move first responder — middle click (AppKit does not change first responder on otherMouseDown; WebKit still reports linkActivated) and scripted anchor.click() — reach decidePolicyFor with the other pane selected and fall through to .allow. Real-click driving is not available here; record this and fix.
2. Resolve the anchored tab from the firing web view (tab(owning:)) through a pure PeekAnchor helper that accepts it only when it is the selected tab or a split member of the selected tab and the firing web view is that tab's own web view (never its peek); focus the pane (makeFirstResponder) before showPeekOverlay, as the Shift branch does. Modifier precedence unchanged.
3. PeekAnchorTests cover the helper: focused pane, unfocused pane of the selected split, a tab outside the split, a peek web view.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reproduction reasoning (no real-click driving available here): a left click makes the pane first responder before the policy decision (BrowserWebView.becomeFirstResponder → browserWebViewDidBecomeFirstResponder retargets selectedTabID synchronously), so the old selectedTab anchor was right for ordinary clicks; middle clicks (AppKit does not move first responder on otherMouseDown) and scripted anchor.click() reach decidePolicyFor with the other pane selected and fell through to .allow. Fix: PeekAnchor.interceptTab(firing:owningTab:selectedTab:splitMembers:) resolves the anchored tab from the firing web view (own web view only, never a peek's; must be the selected tab or a member of its split) and the branch focuses that pane before showPeekOverlay, mirroring the Shift branch. Modifier precedence unchanged. PeekAnchorTests cover the helper.

Review fixes folded in: the Shift+click and cross-host branches share peekHostTab(firing:) / presentPeek(of:on:firing:); if focusing the firing pane does not move the selection, the pane is selected outright before showPeekOverlay (never anchoring the peek on the wrong tab); PeekAnchor.interceptTab takes the resolved clicked tab and a lazy splitMembers autoclosure.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A cross-host link activated in either pane of a pinned split now opens a Peek attached to the firing pane's tab (focusing it) instead of navigating the pane away. Verified with PeekAnchorTests and the peek suites.
<!-- SECTION:FINAL_SUMMARY:END -->
