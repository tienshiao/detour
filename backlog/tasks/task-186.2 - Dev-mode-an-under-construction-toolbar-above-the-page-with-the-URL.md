---
id: TASK-186.2
title: 'Dev mode: an under-construction toolbar above the page with the URL'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:13'
updated_date: '2026-10-24 19:43'
labels:
  - dev-mode
  - ui
  - feature
dependencies:
  - TASK-186.1
parent_task_id: TASK-186
priority: medium
ordinal: 210000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Second part of TASK-186. Reference: docs/dev-mode/arc-dev-toolbar.png.

While the selected tab (or a split pane) is in dev mode, a toolbar sits across the top of that tab's web content: an "under construction" motif (Arc: faint diagonal stripes on a light bar), an info button, the page's URL, and a copy-link button on the right; the capture and inspector buttons are added by the sibling subtasks. The web view is laid out below it (not overlaid), per pane in a split.

Decide: whether clicking the URL opens the command palette in place (like the sidebar's faux address bar; recommended) or edits inline; what the info button shows (Arc: site info); behaviour with a Peek open, in fullscreen and when the docked Web Inspector is attached (WKWebView layout is frame-based because Auto Layout breaks the docked inspector — see wiki/tabs/split-tabs-hosting.md).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A dev-mode tab shows the toolbar above its web content and the page is laid out below it; a non-local tab has no toolbar
- [x] #2 The toolbar shows the current URL, follows navigation, and the copy button copies it
- [x] #3 Works per pane in a split, with a Peek open and with the docked Web Inspector; decisions recorded
- [x] #4 Checked at runtime (window capture), light and dark
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-24): (defaults taken) clicking the URL opens the command palette in place, like the faux address bar; the info button opens the site popover (TASK-186.5); no toolbar inside a Peek panel (the host's toolbar stays).

Design (2026-10-24, planning): the toolbar lives INSIDE the tab's WebViewContainerView, above the web view, frame-based. WebKit's docked inspector (WebInspectorUIProxyMac::inspectedViewFrameDidChange) preserves the inspected view's top edge (NSMaxY) on bottom/left/right docking and on detach ('so banners in Safari still work'), so lowering the web view's top by the toolbar height survives docking; side-docked inspectors span the full parent height, so the toolbar tracks the web view's frame (x, width) rather than the container's. Being in the container, ownership-transfer snapshots (snapshotImage(of: container)) include it. Pure layout function + tests first.

Built (2026-10-24, Opus subagent): pure DevToolbarLayout.frames (only the web view's top edge moves; toolbar takes the web view's x and width) + toolbarFrame for WebKit re-framing; WebViewContainerView gains hostedWebView (the inspector is also a WKWebView), a lazy DevToolbarView, updateDevToolbar(shown:url:), a web-view frame-change observer (follows inspector docking), a resizeSubviews re-layout, and corner masks (toolbar top, web view bottom, chosen with view.isFlipped: layer.contentsAreFlipped() read differently while a pane was re-hosted and rounded the wrong corners). BrowserWindowController+DevToolbar: refreshDevToolbars() at the end of every claimWebView, per pane DevMode.isActive(for: url, profileID: active space's profile),  subscriptions, SiteSettingsStore.didChangeNotification. URL click focuses that pane then openCommandPaletteInPlace(anchorFrame:) (extracted from the faux address bar path); info opens showSiteSettingsPopover(relativeTo:fromAddressBar: false); copy uses copyURL(_:) with the pane's URL ('URL copied' toast); addTrailingGroup(_:) is the hook for 186.3/186.4. Find bar's top constraint shifts by the toolbar height when a hosted toolbar lies under its spot (geometric). liveSnapshot pictures the container while it shows the toolbar. Window drag strip: new WindowDragPassThrough protocol so the strip's hitTest returns nil over the toolbar (an NSButton can't take the strip's synthesized mouseDown+mouseUp); the toolbar background drags the window itself. urlPasteboard seam for tests.

Decisions: Peek panels have no toolbar (host's stays under the overlay); window fullscreen keeps it; side-docked inspector: toolbar spans only the web view's width (Safari-banner style).

TDD: DevToolbarLayoutTests red 19/20 failing (the passing one is the no-toolbar no-regression case), DevToolbarHostingTests red 10/11 (remote-tab no-toolbar case passes by design); testAFlippedWebViewRoundsItsVisualBottomCorners was added after the runtime corner fix (no red run).

/code-review --fix: 7 findings, 4 fixed: focusPane now reports whether the pane took focus and URL/info stop if not; toolbar autoresizing mask emptied (it was moved twice per resize tick); updateFindBarPlacement returns early while hidden and uses hostedPaneTabs; CommandPaletteView.width shared instead of a copied 500. Skipped: always snapshotting the container (would change docked-inspector stand-ins: behaviour change), the find bar's fixed shift (deliberate, keeps the usual gap), a false positive on the profile used.

Tests after review: 289/289 pass (DevToolbarLayoutTests 21, DevToolbarHostingTests 11, DevModeTests 31, DevModeSiteOverrideTests 15, SplitTabTests 63, SidebarLayoutTests 41, TabStoreTests 40, CommandPaletteFocusTests 4, WebViewHandoffFocusTests 7, InitialWindowFocusTests 7, RecentTabSwitcherPeekTests 7, SplitDropZoneTests 16, PageOpenedWindowTests 11, ExtensionActiveTabTests 15).

Runtime (docs/harness/task186-2-harness.patch; run before the review and again after it, logs identical apart from timestamps and window numbers): local tab toolbar 30 pt with page innerHeight = container - 30; remote tab none (web view = container); navigation local->remote->local follows and updates the label; copy put the URL on the pasteboard with the toast; a posted click on the URL opened the palette in place; window resize keeps it at the top; split local|remote shows it only on the local pane with no corner notch, and the unfocused pane's URL/info focus that pane first; docked inspector bottom/right/left keeps the toolbar above the page and at the page's width, and closing restores the page; the per-site switch hides it in the same turn; Peek has none; find bar sits below it; dark single and split; a second window's snapshot lines up. WebKit writes the inspector dock side to the shared com.detourbrowser.mac defaults; the key (absent before) was deleted after each run. Not verified: window and element fullscreen, a real mouse drag on the toolbar background. Known cosmetic gap: split form/break veneers snapshot the bare web view, so a dev-mode pane shows no toolbar for that 0.22 s animation. WebKit quirk (wiki): a side-docked inspector stops ~66 pt below the window top (contentLayoutRect), with or without the toolbar.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Dev-mode toolbar (stripes, info, URL, copy) inside each dev-mode pane's container above the web view, frame-based so WebKit's docked inspector keeps it in place on every side; per pane in splits, follows navigation and the per-site switch; URL opens the palette in place, info opens the site popover. 289 tests pass; runtime harness clean before and after review, light and dark.
<!-- SECTION:FINAL_SUMMARY:END -->
