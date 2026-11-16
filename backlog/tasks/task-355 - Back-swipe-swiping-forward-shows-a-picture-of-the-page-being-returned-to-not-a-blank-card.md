---
id: TASK-355
title: >-
  Back swipe: swiping forward shows a picture of the page being returned to, not
  a blank card
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
updated_date: '2026-11-16T08:23:00Z'
labels:
  - tabs
  - navigation
  - gestures
dependencies: []
references:
  - TASK-325
  - wiki/tabs/back-swipe-to-opener.md
priority: low
type: feature
ordinal: 435000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's decision 2026-11-15 on TASK-325's provisional choice. After a back swipe out of a page that has a forward item, the forward swipe slides in a blank card (the window's background colour) until the forward page commits (max 1 s), because WebKit's own snapshot of the forward page is in a store Detour cannot read. The user chose the alternative: Detour takes its own picture of the page as the user leaves it going back, and slides that in on the forward swipe. The other two TASK-325 choices were confirmed as built (plain background under a split pane; a pinned tab or favourite is never swiped closed).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A forward swipe after a back swipe shows a picture of the page as it was left, not a blank card
- [x] #2 When no picture exists (e.g. after a relaunch, or the page was never left by a swipe) the blank card is the fallback
- [x] #3 NavigationSwipeTests cover the picture and the fallback; checked at runtime with a trackpad or the endpoint
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure rules (NavigationSwipe.swift): when to picture the page being left going back (a normal tab with an opener whose back list has exactly one item: the back lands on the first page, where Detour's own swipe runs with a forward item); ForwardPagePicture (the image, the back/forward item it pictures, the web view's size and frame in its pane) with the eviction rule (kept while its item is the current one and the back navigation has not left it yet, or the forward item; dropped once it is neither, or once it is current again after being left) and the use rule (only when it is the forward item and the web view's size still matches). Rename the generic LRU so both caches use it.
2. Capture (BrowserWindowController+NavigationSwipe): takeSnapshot at 1 px per point, issued before the navigation (IPC order paints the page first): in navigateBackOrCloseChildTab(_:) before goBack(), at _webViewDidBeginNavigationGesture: (WebKit's own swipe), and on a three-finger back swipe WebKit handles. Per window LRU of 4 keyed by tab id; pruned on store changes (closed tabs) and re-checked on every hosted pane's history/loading change.
3. Show: a forward swipe's card carries the picture at the web view's frame in the pane; without one (relaunch, history.back(), a forward list changed by navigation, a resized pane) the blank card as before. Card stays until the forward page commits (or 1 s), as before.
4. Tests in NavigationSwipeTests: the rules (capture, eviction, use), and in a window with real file:// back/forward items: Back from page 2 pictures page 2 (pixel colour checked), the forward card carries it; history.back()-style goBack gives the blank card; a navigation from page 1 drops it.
5. Debug tool: forward_picture in the pane JSON; task325-swipe-checks.py asserts the card's colour mid-swipe and the fallback.
6. Wiki (back-swipe-to-opener, snapshots cost note), log, Backlog notes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation 2026-11-16 (branch lane-b).

Design: Detour's own forward swipe runs only on a child's first page with a forward item (.ownSwipe(canGoForward: true)); everywhere else WebKit's swipe shows WebKit's own picture. So a picture is taken only when a back navigation lands on that first page: NavigationSwipeRules.picturesPageLeftGoingBack = normal tab, opener resolves, back list has exactly one item.
- When: just before the navigation, while the page is on screen. (1) navigateBackOrCloseChildTab(_:) before goBack() (sidebar Back button, Navigate > Back / Cmd+[, mouse back button). (2) _webViewDidBeginNavigationGesture: (WebKit's own swipe back from page 2; direction unknown then, so a cancelled or forward swipe takes a picture the next history change drops). (3) A three-finger back swipe WebKit handles (BrowserWebView.swipe(with:) -> handleDiscreteNavigationSwipe before super; WebKit's swipeWithEvent: goes back at once). A back the window does not start (the page's history.back(), a history-menu jump) takes none: fallback.
- How: takeSnapshot at 1 px per point (as the opener pictures), issued before goBack(): the request reaches the web process ahead of the navigation, so page 2 is painted. Verified by colour: in a test (page 2 green, page 1 red, sampled from the picture) and in the running app.
- Kept: ForwardPagePicture (image, the WKBackForwardListItem it is of, web view size) in a per-window SwipePictureCache (the TASK-325 opener LRU, renamed and given revise()), capacity 4, keyed by tab id; memory only (so after a relaunch: plain card). WKBackForwardListItem identity is stable (one wrapper per item; SameDocumentVisitTests rely on it).
- Dropped (ForwardPagePicture.stillApplies, re-checked on every hosted pane's canGoBack/canGoForward/isLoading change and at a forward swipe's start): kept while its item is still current (the back has not committed) and then while it is the forward item; a link followed from the first page (new forward list), a history jump, or returning to the pictured page (spent) drops it; store changes prune closed or pinned tabs.
- Shown: only when its item is the web view's forward item and the web view's size matches within 1 pt; drawn at the web view's frame inside the card, so a dev toolbar beside the page stays plain. Card still stays until the forward page commits (or 1 s), then fades 0.15 s.
- Debug tool navigation_swipe: pane field forward_picture; begin returns forward_picture for the held card.

Chosen by Claude (not yet confirmed by the user): a pane resized since the picture was taken (window, split divider, dev toolbar toggled) gets the plain card rather than a stretched picture; alternative: draw it scaled (one line in ForwardPagePicture.shows). Also chosen by Claude: 4 forward pictures per window (about 5 MB each at 1x for a 1500x950 pt pane, more on an ultrawide); alternative: fewer, or one per tab on the web view so it travels between windows (today a forward swipe in another window than the one the back happened in shows the plain card).

Review (/code-review medium --fix, 9 findings, 2 fixed):
- Fixed: a picture taken at the start of a WebKit swipe that was then cancelled stayed (its page still current, never left) and could later show a stale page 2 after a history.back(): webViewDidRemoveNavigationGestureSnapshot now drops a picture whose page is still current and not yet left (dropForwardPictureNotLeft). Trade-off: if WebKit removed its swipe snapshot before a slow back committed (its own watchdog), the card falls back to plain. Test testACancelledWebKitSwipeLeavesNoPicture.
- Fixed: the 'picture shows' lookup was duplicated in the Debug tool's state; one helper (shownForwardPicture) now.
- Left: (2) no request token on the async capture, so a picture whose completion arrives after the user already returned to its page is stored unspent (narrow race; a later history.back() could show it; the picture is of the same page, moments old). (3)(4)(7) the WebKit-swipe capture is at its begin, so forward and cancelled swipes on a child's page 2 also take a pane-sized snapshot (dropped at the swipe's end, but stored meanwhile and can push another tab's picture out of the 4-entry cache); the alternative is _webViewWillEndNavigationGesture:withNavigationToBackForwardListItem: (target item known, completed swipes only), a new private callback not verified to be reachable. (5) a tab moved to another window leaves its picture in the old window's cache until evicted or closed. (8) 1 px per point is blurry on Retina while the card is up (intentional, as the opener picture). (9) the capture hooks sit at each back entry point rather than one choke point; a future back-history menu would get the plain card.

Tests (Debug, -derivedDataPath .derived): NavigationSwipeTests 48 + WebKitDelegateReachabilityTests 3 + AutomationToolsTests 22 + MCPServerTests 14 = 87 passed, 0 failed (after the review fixes). New NavigationSwipeTests: capture rule, picture lifetime, new forward list / jump, resized pane, cache revise; in a window with loopback pages (red page 1, green page 2): Back pictures page 2 and the forward card carries it (pixel colour checked; so takeSnapshot issued before goBack() paints the page being left), going forward spends it; WebKit's swipe-begin callback pictures page 2; a cancelled WebKit swipe leaves none; webView.goBack() (as history.back()) leaves the plain card; a navigation from page 1 drops it; a tab with no opener takes none.

Runtime (/verify via docs/harness/task325-swipe-checks.py, Debug build of the final source, data dir DetourVerify-355, Detour in the background, cleaned up after): all 17 checks passed, among them the new ones: Back on page 1 reports a forward picture; the forward card held half-way shows page 2 (screenshot pixel (222, 244, 210) = page 2's #d8f5d0); after the page's own history.back() no picture and the card is plain white (255, 255, 255). Screenshots looked right (page 2's picture under the dev toolbar strip, which stays plain).

Not verified (owed by hand, real trackpad): WebKit's own two-finger swipe back from a child's page 2, then a two-finger swipe forward on page 1: the card should show page 2 (the capture at _webViewDidBeginNavigationGesture: is only exercised by calling the callback in a test). Also the three-finger back on page 2 (WebKit's swipeWithEvent:) then a forward swipe. A back that swaps web processes (cross-site page 2) was not measured for the snapshot-before-navigation ordering.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A forward swipe on a child tab's first page now slides in a picture of the page the user left going back, instead of a blank card. The picture is taken just before the back navigation (Back button core incl. Cmd+[ and the mouse button, WebKit's swipe begin, a three-finger back WebKit handles), only when the back lands on the first page of a normal tab with an opener; takeSnapshot at 1 px per point, kept with its WKBackForwardListItem in a per-window LRU of 4, dropped when the forward list changes, the page is returned to, a WebKit swipe is cancelled, or the tab closes; shown only while it is the forward item and the pane size matches. Fallback: the plain card (relaunch, history.back(), changed forward list, resized pane). Tests: 87 passed in the affected suites (NavigationSwipeTests 48, incl. colour-checked window tests); runtime: 17/17 endpoint checks incl. colour of the held card. Owed: hand check of WebKit's own trackpad swipe back then forward; Claude's choices (plain card on a resized pane, 4 pictures per window) to confirm.
<!-- SECTION:FINAL_SUMMARY:END -->
