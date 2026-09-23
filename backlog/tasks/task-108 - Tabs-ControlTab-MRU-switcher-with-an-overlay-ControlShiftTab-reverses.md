---
id: TASK-108
title: 'Tabs: Control+Tab MRU switcher with an overlay (Control+Shift+Tab reverses)'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-23 06:22'
updated_date: '2026-09-23 07:21'
labels:
  - tabs
  - keyboard
dependencies: []
priority: medium
ordinal: 108000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cmd+Tab-style most-recently-used tab switching: holding Control and pressing Tab shows an overlay of recent tabs (thumbnails/icons and titles), each press advances, Shift reverses, releasing Control commits; overlay items are mouse clickable. Needs a per-window MRU order. Follows the Cmd+Option+Up/Down task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Control+Tab shows an overlay of recent tabs and advances the highlight; releasing Control switches to the highlighted tab
- [x] #2 Control+Shift+Tab moves the highlight backwards
- [x] #3 Overlay items show a preview and title and can be clicked to switch
- [x] #4 MRU order is tracked per window and survives tab close / space switches sensibly
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decisions (user, Sep 22 2026): scope = the window's active space (normal + live pinned + its profile's live favourites; never switches space); overlay = horizontal thumbnail row with titles; membership = visited this session only (user) so every card has a preview.

1. MRU membership/order (pure, Sidebar/RecentTabSwitcher.swift): the current item first, then items whose tab has an in-memory BrowserTab.switcherPreviewAt (stamped with the preview when the tab is left this session), newest first. Never-visited-this-session tabs are not listed (after relaunch the list starts with just the current tab). Persisted lastDeselectedAt is NOT used (stays the sleep-policy clock). A split is one item (recency = newest member; commit focuses lastFocusedSplitMember, else the newest member). Dormant pinned entries and Peeks excluded; closed tabs drop out with their preview. Unit-tested.
2. Switcher state (pure): begin(forward/backward) starts at index 1 / last, advance/reverse wrap, commit/cancel. Unit-tested.
3. Keys: one NSEvent local monitor (AppDelegate) routed to the key BrowserWindowController — Ctrl+Tab begins/advances, Ctrl+Shift+Tab reverses (key repeat advances), Control released commits, Esc cancels, window resign/app deactivate cancels. Events are swallowed so web content and text fields never see them. Quick tap: overlay appears only after ~150 ms; releasing before that commits straight to the previous tab.
4. Previews: BrowserTab.switcherPreview + switcherPreviewAt (in-memory, downscaled ~320 px wide) captured from the outgoing pane at deselect (where stampDeselected runs; split: each member) and from the visible tab when the overlay opens. Sleeping keeps the preview. Never host or wake a hidden tab to get one (TASK-104). Favicon card only if a capture failed. Risk to check first: cacheDisplay on WKWebView vs WKWebView.takeSnapshot.
5. Overlay view (Browser/Window/RecentTabSwitcherView): GlassContainerView panel centred over the content area, cards (preview + favicon + title), highlight follows state; hover highlights, click commits, click outside cancels; cards shrink to fit the window then scroll to keep the highlight visible.
6. Commit goes through a shared selection helper with navigateTab (TASK-107) so splits/pinned/favourites select like a click.
7. Verify in-process (NSApp.postEvent Ctrl+Tab / flagsChanged) per the verify skill.
Later option (not in scope): persist previews to disk (never for Private) so the list survives relaunch.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: RecentTabOrder.swift (recentTabOrder + RecentTabSwitcherState, RecentTabOrderTests 9), RecentTabSwitcher.swift (local keyDown/flagsChanged monitor per window, 150 ms reveal delay, overlay view with glass panel + cards), BrowserWindowController+RecentTabSwitcher.swift (entries, split focus, preview capture). BrowserTab.switcherPreview/switcherPreviewAt/switcherPreviewRequest (in memory). Capture is taken in stampDeselected + at switcher begin.

Capture: synchronous cacheDisplay of a 1372x1100 web view measured 46-48 ms per call (would block every tab switch) -> switched to WKWebView.takeSnapshot (snapshotWidth 240 pt = 480 px): returns immediately, image in 16-57 ms, and still renders correctly after the view has left the window (hidden tab test). Stale completions dropped by a per-tab request counter; open overlay reloads previews on arrival.

Runtime harness (in-process NSApp.postEvent, isolated DetourVerify108, 4 real pages; patch in session scratchpad task108-harness.patch): A quick tap -> previous tab, no overlay; B hold + Tab/Shift+Tab/Tab -> expected tab; C Shift start -> oldest; D Esc cancels; E control-click on last card selects it (passed when the window was key; runs where another app had focus fail by design - resign key cancels / first click activates). Overlay render: 4 cards 200 pt, previews + favicons + titles, highlight on index 1. Not exercised at runtime: hover highlight, splits/pinned/favourites entries, many-tabs scrolling, dark mode. TASK-104: takeSnapshot on leave not measured for GPU IOSurface effect.

Code review fix: with nothing selected in the window (deselectAllTabs) entry 0 is not current, so RecentTabSwitcherState(hasCurrent: false) starts forward at index 0 and allows a single entry; Entry.isCurrent carries it. Test: testWithoutACurrentItemForwardStartsOnTheMostRecentTab.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Control+Tab MRU switcher, Cmd+Tab style: a per-window local event monitor takes Control+Tab / Control+Shift+Tab ahead of web content and text fields; the highlight moves through the active space's tabs visited this session (current first, then most recently left; pinned, favourites and splits as one item), releasing Control switches, Esc / losing key cancels, a quick tap flips to the previous tab without the overlay (150 ms reveal delay). Overlay: glass panel with preview cards (click to switch). Previews are taken asynchronously with WKWebView.takeSnapshot when a tab is left (a synchronous cacheDisplay cost ~47 ms per switch) and kept in memory only. Verified with RecentTabOrderTests + related suites and an in-process harness posting real key/mouse events (quick tap, hold/advance/reverse, Shift start, Esc, card click, overlay render). Review fix: no-selection windows start on the most recent tab. Untested at runtime: hover, split/pinned/favourite entries, scrolling, dark mode, GPU-surface effect of snapshots.
<!-- SECTION:FINAL_SUMMARY:END -->
