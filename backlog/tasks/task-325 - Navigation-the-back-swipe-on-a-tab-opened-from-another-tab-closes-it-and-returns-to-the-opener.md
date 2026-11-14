---
id: TASK-325
title: >-
  Navigation: the back swipe on a tab opened from another tab closes it and
  returns to the opener
status: To Do
assignee: []
created_date: '2026-11-14T06:21:00Z'
updated_date: '2026-11-14T06:44:00Z'
labels:
  - feature
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController.swift
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - Detour/Browser/TabCloseSelection.swift
  - wiki/platform/back-swipe-and-unhandled-scrolls.md
  - docs/harness/task325-wheel-spike.swift
  - docs/harness/task325-underlay-snapshot-spike.swift
priority: medium
ordinal: 396000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A tab opened from another tab (a target="_blank" link, Cmd+click, window.open) starts with no back history. The Back button and Cmd+[ already handle this: `navigateBackOrCloseChildTab` (c8cf180) closes the child and selects its opener (`tab.parentID`) when the tab cannot go back. The two-finger back swipe does not, because it is WebKit's built-in gesture (`allowsBackForwardNavigationGestures`), which only runs when the web view has a back item. So the swipe does nothing on exactly the tabs where Back is most useful: you read a linked page, swipe back to return, and nothing happens.

The swipe should do what the Back button does. Once the child tab has its own history, the swipe walks that history as it does now, and closes to the opener only from the first page. The gesture should feel like a back swipe (it tracks the fingers, can be cancelled midway, and shows where it is going) rather than a tab closing without warning.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 On a tab opened from another tab with no back history, a two-finger back swipe closes the tab and selects the tab that opened it, the same result as the Back button
- [ ] #2 A tab with back history still navigates back on the swipe; it closes to its opener only once it is on its first page
- [ ] #3 The swipe follows the fingers and can be cancelled: releasing it without completing it leaves the tab open and selected
- [ ] #4 With no opener to return to (no parentID, or the opener has been closed), the swipe on a tab with no back history does nothing, as today
- [ ] #5 A child tab in a split, a Peek, and Quick Detour behave as the Back button already does for them, and the decision for each is recorded in the task
- [ ] #6 The closed child tab can be reopened with Reopen Closed Tab like any closed tab
- [ ] #7 The rule for when a back swipe closes to the opener is covered by unit tests; the gesture itself is checked in the running app with /verify
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Research 2026-11-14 (no code yet). WebKit facts and the spike: wiki/platform/back-swipe-and-unhandled-scrolls.md, docs/harness/task325-wheel-spike.swift.

Why the swipe does nothing today: WebKit's swipe (allowsBackForwardNavigationGestures) starts only when the back list has an item (ViewGestureController::canSwipeInDirection). No SPI retargets it: _tryToSwipeWithEvent:ignoringPinnedState: still needs a back item, _alternateWebViewForNavigationGestures is iOS-only and navigates history, and the navigation-gesture delegate callbacks fire only for real swipes. So this has to be Detour's own swipe, and on completion it calls navigateBackOrCloseChildTab so close, selection and Reopen Closed Tab match the Back button.

Options considered:
A. (Recommended) Rely on the page's own verdict. While a tab has an opener (parentID resolves) and no back item: set allowsBackForwardNavigationGestures = false and exclude the left edge from _setRubberBandingEnabled: (bit mask 14; call it through its IMP, KVC throws). Implement the private WKUIDelegate _webView:didNotHandleWheelEvent: and feed those events to a small pending tracker (phase began, mostly horizontal, back direction, cumulative threshold, as WebKit's PendingSwipeTracker does). Once over the threshold, start NSEvent.trackSwipeEvent on the stored event, as WebKit does from its async path. The spike measured it: with the gesture off and left excluded, back-direction scrolls the page cannot use are reported, while an overflow-x scroller that can still scroll and a preventDefault wheel listener are NOT reported. Forward still rubber-bands. Put the gesture and rubber-banding back when the tab gains a back item, ideally before the next main-frame commit (decidePolicyFor / didStartProvisionalNavigation), because WebKit records the leaving page's snapshot in WebBackForwardList::addItem only while the gesture is on. pushState pages may still miss that snapshot (source reading, not measured).
B. Intercept first: BrowserWebView.scrollWheel checks _pinnedState and takes over before super, with the gesture left on. Simpler, but it steals the swipe from carousels and maps on the child's first page. In the spike, _pinnedState said "pinned left" (11) while an inner scroller was mid-scroll. Closing a tab by mistake is worse than a missed swipe, so this is the fallback only.
C. Rejected: a placeholder history entry so WebKit's swipe has a target. It breaks window.close() for opened tabs (WebKit allows it only with one history entry; sign-in popups, TASK-168), changes history.length, cannot be done for window.open tabs (WebKit loads them itself), and leaks into session restore.

Things the implementation needs whatever the option:
- Three-finger "swipe between pages" arrives as swipe(with:), which WebKit ignores without a back item: BrowserWebView needs that override too (discrete, no tracking). Use scroll tracking only when NSEvent.isSwipeTrackingFromScrollEventsEnabled.
- Swallow the momentum events after a completed close, or they scroll the opener.
- While mode A is on, a page-1 tab that has a forward item (the user came back to it) has lost WebKit's forward swipe. Either the own tracker also handles forward (goForward on completion), or the mode is limited to tabs with no forward item, which loses the close on the common "follow a link, swipe back, swipe back again" path. Needs a decision.
- What shows under the swipe: the opener's switcherPreview is only 480 px wide, too low for a full-size underlay. Take a full-size snapshot of the opener instead (when the child is selected, or when the swipe starts), or host the opener's live web view if this window owns it. Never assume it is attached (sleeping, or another window owns it). Fall back to a plain background.
- New optional WebKit delegate method (_webView:didNotHandleWheelEvent:) needs a row in WebKitDelegateReachabilityTests.
- Split inconsistency to decide: navigateBackOrCloseChildTab closes to the parent without checking for a split, while webViewDidClose returns to the opener only outside a split. The AC asks for a decision on splits.

Not verified: that NSEvent.trackSwipeEvent started from didNotHandleWheelEvent tracks a real trackpad gesture in Detour. Synthetic events cannot drive trackSwipeEvent, so it needs a manual trackpad check. If /verify must drive it, the alternative is the sidebar's own phase tracking (handleSpaceSwipe plus a local monitor), which synthetic events can drive but which loses the system's spring and momentum feel. Why the view's gesture being on hides horizontal unhandled events, even with rubber-banding 0, was not found in the source.

Hazard (from review of the research, not measured): one gesture causing two actions. On page 2 the user swipes back with WebKit's own swipe and lands on page 1, so canGoBack becomes false and mode A switches on. If trailing changed or momentum events from that same gesture are then reported as unhandled, the own tracker could close the tab on a swipe that only meant to go back. Guards: start the own tracker only on a fresh began phase received after the mode switched on, and switch the mode on only after WebKit's gesture has ended (_webViewDidEndNavigationGesture:withNavigationToBackForwardListItem: / _webViewDidRemoveNavigationGestureSnapshot:). Toggling allowsBackForwardNavigationGestures while WebKit's swipe snapshot is still showing is untested. In the other direction: if a navigation starts while the own tracking runs, cancel the tracking rather than close the tab.

Next step to retire the main risk: a prototype that calls trackSwipeEvent on the event stored from didNotHandleWheelEvent and prints its progress, swiped by hand on a real trackpad (a variant of the spike, or a DEBUG-only path in the app).

Decisions (user, 2026-11-14): (1) While the tab is in the own-swipe mode (opener, no back item) the own swipe also handles forward: a completed forward swipe calls goForward. (2) The swipe behaves exactly like the Back button, splits included: it goes through navigateBackOrCloseChildTab unchanged. The webViewDidClose split check stays as it is; it is a different trigger (a page closing itself).

Underlay under the swipe (what shows as the child slides away), weighed 2026-11-14. Measured with docs/harness/task325-underlay-snapshot-spike.swift on a 1500x950 pt page, at a machine load average of about 250, so absolute times are inflated:
- Switcher preview (exists, 480 px): no new work or memory, always there once the opener has been left once. Upscaled about 3x on a 1x display and 6x at 2x, visibly blurry. Fallback only.
- Full-size snapshot taken when the opener leaves the screen (recommended): reliable, because it is taken while the opener is still on screen and in this window; afterwards it does not matter whether the opener sleeps, is owned by another window or is in a split. Simple: piggyback on stampDeselected / captureSwitcherPreview, which already captures every split member and the Peek at that moment. Cost: an async takeSnapshot painted by the web process, 15.6 ms at 1x (5 MB) and 64 ms at 2x (22 MB), off the app's main thread. Capture it only for a tab that has a child open (a parentID points at it), drop it when the opener is selected again or its last child closes, and keep at most a few (LRU). Capturing at 1x points on a Retina display cuts memory to about 5.4 MB with little visible loss while the image moves. Limits: stale if the opener changed while away (a small jump at the end, as Safari has), and no WebGL or video (software paint; see wiki/platform/wkwebview-snapshots.md).
- Snapshot taken later (at child selection or swipe start), once the opener has left the window: unreliable, because WebKit has dropped the hidden page to background priority. The same capture took a median of 240 ms and a maximum of 1449 ms in one run and 19.5 ms in another. None at all for a sleeping opener. Rejected.
- Live opener web view under the child: the most faithful picture and no image memory, but the least reliable and the hardest. It needs a web view (none when asleep), this window's ownership (another window would have to switch to its snapshot mid-gesture), split, dev-toolbar and Peek hosting for the opener, and integration with removeContentViews / selectTab so the end of the swipe does not rebuild hosting and flash. Every swipe also makes the opener visible to its page (visibilitychange, requestAnimationFrame, its process back to foreground), twice for a cancelled one, and it composites two live pages during the gesture. Rejected unless the staleness of the snapshot turns out to matter.

Correction to decision 2 (splits): "unchanged" does not hold. navigateBackOrCloseChildTab acts on selectedTab, the focused pane, while a two-finger scroll goes to the web view under the pointer and does not move pane focus (focus follows first responder). The swipe must act on the tab whose web view received it: the same result as the Back button, applied to the swiped pane (a variant that takes the tab, or focus that pane first).

Forward (decision 1), measured 2026-11-14 with the wheel spike: with the gesture off and the right edge excluded (mask 11), or both sides excluded (10), forward scrolls the page cannot use are reported. An overflow-x scroller that can still scroll forward is not. So in the mode, exclude the right edge too while the tab has a forward item (10). Exclude only the left (14) when it has none, so the right edge keeps its bounce.

Forward underlay: the opener's snapshot does not apply. The forward page's snapshot is in WebKit's own store, which Detour cannot read. Options: (a) capture the page yourself as the user leaves it going back to page 1, while it is still on screen: at _webViewDidBeginNavigationGesture: for WebKit's own swipe, or at the back/forward navigation's policy decision for the Back button and Cmd+[. One image per child tab in the mode, dropped when the tab leaves the mode. (b) A plain background that the forward page loads into. (a) matches the back side; (b) is the simplest.

Underlay sizing: a snapshot is content width x height x 4 bytes x scale squared. On a 1x ultrawide with a content area of about 3100 x 1350 pt that is about 17 MB; at 2x a 1500 x 950 pt area is 22 MB, or 5.4 MB if captured at 1x points. Further cases: an opener in a split shows the whole split after the close, so the per-member captures must be laid out as the split (with a dev toolbar if shown). After a relaunch parentID survives but in-memory snapshots do not, so the first swipe falls back to the hover card's disk thumbnail (TASK-190) or a plain background.
<!-- SECTION:NOTES:END -->
