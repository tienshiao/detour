---
id: TASK-325
title: >-
  Navigation: the back swipe on a tab opened from another tab closes it and
  returns to the opener
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T06:21:00Z'
updated_date: '2026-11-16T05:54:00Z'
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
- [x] #1 On a tab opened from another tab with no back history, a two-finger back swipe closes the tab and selects the tab that opened it, the same result as the Back button
- [x] #2 A tab with back history still navigates back on the swipe; it closes to its opener only once it is on its first page
- [x] #3 The swipe follows the fingers and can be cancelled: releasing it without completing it leaves the tab open and selected
- [x] #4 With no opener to return to (no parentID, or the opener has been closed), the swipe on a tab with no back history does nothing, as today
- [x] #5 A child tab in a split, a Peek, and Quick Detour behave as the Back button already does for them, and the decision for each is recorded in the task
- [x] #6 The closed child tab can be reopened with Reopen Closed Tab like any closed tab
- [x] #7 The rule for when a back swipe closes to the opener is covered by unit tests; the gesture itself is checked in the running app with /verify
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure rules (Browser/Window/NavigationSwipe.swift): when a tab is in the own-swipe mode (normal tab, opener resolves as the Back button resolves it, no back item; held off while a main-frame navigation is provisional, and switched on only after WebKit's own swipe has ended), the rubber-band mask (14, or 10 with a forward item), what a completed swipe does to the tab that received it (close to opener / go forward / nothing; nothing while a Peek is over it), WebKit's pending-swipe threshold (began phase after the mode came on, mostly horizontal, 15 pt), the momentum filter, and the opener-underlay LRU. Unit tests for all of it.
2. Window integration (BrowserWindowController+NavigationSwipe.swift): apply the mode on every claim (in place of wireOwnedWebView's gesture line) and on canGoBack/canGoForward/isLoading of every hosted pane, store changes, provisional start/commit/failure, WebKit's navigation-gesture callbacks; reset it when a web view leaves the window. SPI behind responds(to:), original mask restored.
3. Own swipe: private WKUIDelegate _webView:didNotHandleWheelEvent: feeds the pending tracker; over the threshold, NSEvent.trackSwipeEvent behind a small tracker seam. A veneer (snapshot card over an underlay) in the content area, kept through the completing selectTab. Completion re-runs the rule for the same tab and calls the Back button's core (navigateBackOrCloseChildTab split into a variant that takes the tab), or goForward. Cancel on navigation start, tab removal, ownership loss, resize.
4. BrowserWebView: swipe(with:) for three-finger swipes; scrollWheel swallows momentum after a completed own swipe.
5. Underlay: full-size 1x snapshot of an opener with an open child, taken in stampDeselected, LRU 4, dropped on reselect / last child closed; fallback the switcher preview, else a plain background. Forward and split panes: plain background (PROVISIONAL).
6. WebKitDelegateReachabilityTests rows for the private selectors; window-level tests for mode switching and the completion path; DEBUG-only automation tool to read the mode and run the completion for /verify.
7. Wiki (back-swipe page, ownership/split notes), notes for the hand swipe the user owes.
<!-- SECTION:PLAN:END -->

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

Implementation 2026-11-14 (branch task-325), option A as decided.

What was built:
- Pure rules in Detour/Browser/Window/NavigationSwipe.swift: the mode (own swipe for a normal tab whose opener resolves as the Back button resolves it, with no back item; held off while a main-frame load is provisional; entered only after WebKit's own swipe has ended), rubber-band edges (view's own mask minus left, minus right too with a forward item: 14 / 10 from the default 15), the outcome of a completed swipe for the tab that received it (back: go back / close to opener / nothing; forward: go forward / nothing; nothing under a Peek), WebKit's pending-swipe rules (began after the mode came on, |dy| < |dx|/2, 15 pt), the momentum filter, the opener-picture LRU (4), and the tracker seam (SystemNavigationSwipeTracker = NSEvent.trackSwipeEvent with WebKit's bounds and consume-mouse-events bit; ScriptedNavigationSwipeTracker for tests and the Debug tool).
- Window wiring in BrowserWindowController+NavigationSwipe.swift: mode applied after every claim (wireOwnedWebView now resets WebKit's gesture instead of only setting it), reset when a view leaves the window (removeContentViews, window close); re-evaluated on canGoBack/canGoForward/isLoading of every hosted pane, store changes, didStartProvisionalNavigation (gesture back on before commit), commit/failure, _webViewDidBeginNavigationGesture: / _webViewDidRemoveNavigationGestureSnapshot: (5 s watchdog). _webView:didNotHandleWheelEvent: feeds the pending tracker. A swipe is cancelled by a navigation start, a history change, the tab closing, content replacement or a resize; completion re-decides for the same tab id.
- navigateBackOrCloseChildTab split into a core taking the tab (the Back button passes the selected tab, the swipe the pane that received it). The core now selects the opener before closing (settlingSelectionForClose), so the close no longer selects a neighbour (and wakes it) first; same end result.
- BrowserWebView: swipe(with:) (three-finger, discrete, same outcome) and scrollWheel (momentum swallowed for up to 2 s after a completed swipe).
- Veneer (NavigationSwipeOverlayView): never moves live views. Back: cacheDisplay picture of the pane sliding right over the opener's picture (dimmed, shadowed). Kept through the completing selectTab, lifted over the opener, faded 0.15 s; selecting any other tab removes it at once. Opener picture: takeSnapshot at 1 px per point in stampDeselected, only when a normal tab opened from it is open, with its frame; split openers come back as their panes; fallback switcher preview, else plain background. An opener that was asleep: veneer held until its load commits (or 1 s).
- WebKitDelegateReachabilityTests: test for the three private selectors.
- Debug-only automation tool navigation_swipe (state / begin at a progress / finish complete or cancel), runs the trackpad swipe's completion code with a scripted tracker. docs/harness/task325-swipe-checks.py drives it.

Decisions per case (AC #5):
- Child in a split: the pane that received the swipe closes and its opener is selected (user decision 2 with the pane-focus correction). When the opener is the partner it stays selected and goes back to single hosting. Underlay: plain background (the close re-tiles the window).
- Peek: the Peek's own web view keeps WebKit's gesture (its history only), as Back acts on the Peek; the tab under an open Peek starts nothing (the overlay also swallows scrolls). Checked at runtime.
- Quick Detour: unchanged. Its Back is goBack only (QuickDetourWindowController.goBack), its window has no unhandled-wheel hook, its tab has no opener.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): a pinned tab or favourite that still carries a parentID keeps WebKit's gesture and is never swiped closed (TabStore.closeTab closes normal tabs only, so the Back button on a pinned child selects the opener without closing it; mirroring that by swipe looked wrong); alternative: allow it and select the opener as Back does (flip isNormalTab out of NavigationSwipeRules.wantsOwnSwipe/outcome).
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): forward underlay is option (b), a plain card that slides in from the right and stays until the forward page commits (or 1 s); alternative: (a) picture the page as the user leaves it going back to page 1 (at _webViewDidBeginNavigationGesture: and at the Back button's back/forward policy decision).
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): a split pane's underlay is a plain background; alternative: the opener's picture laid out as the post-close layout.

Not verified / owed by the user (hand swipe on a real trackpad; synthetic events cannot drive trackSwipeEvent). Build: task-325 branch, Debug. With System Settings > Trackpad > More Gestures > Swipe between pages = "Scroll left or right with two fingers":
1. On a page, Cmd+click or click a target=_blank link, select the new tab. Two-finger swipe right slowly: the page should follow the fingers, the opener's picture underneath; release past halfway: the tab closes, the opener is selected; Shift+Cmd+T reopens it. (AC #1, #6)
2. Same, release before halfway: the page springs back, the tab stays open and selected. (AC #3)
3. In the child, follow a link to page 2, swipe back: WebKit's own swipe goes to page 1 (not a close). Then, in a new gesture, swipe back again: it closes to the opener. Check that the first swipe (and its momentum) never closes the tab. (AC #2, the one-gesture-two-actions hazard)
4. On page 1 after coming back, swipe left (forward): a white card comes in from the right, page 2 loads.
5. A page with a horizontal carousel or a map on the child's first page: swiping inside it scrolls it, not the tab; at its left end a fresh swipe closes the tab.
6. Fast flick (short, quick swipe) and a swipe that starts vertical then turns horizontal: neither should close by mistake.
7. After a close, the momentum must not scroll the opener.
8. Option-click a link to open a split, focus the left pane, swipe back over the right (child) pane: the right pane closes, the left stays.
9. Three-finger swipe (Swipe between pages = three fingers): on the child's first page it closes to the opener at once.
10. A tab with no opener, and a pinned tab: swiping on the first page does nothing; left edge bounce is unchanged on such tabs.
Watch for: the left edge of a child's first page no longer rubber-bands (by design); any lag at the start of the swipe (a cacheDisplay of the pane is taken when tracking starts).

Out-of-scope findings (not changed):
- Navigate > Back (Cmd+[) with the page focused reaches WKWebView's own goBack: action first, which is disabled on a page with no back item, so Cmd+[ does not close a child while the page has the keyboard (the sidebar's button and mouse button 4 do).
- The Back button on a pinned tab that still has a parentID selects the opener without closing it (closeTab ignores pinned tabs).
- Reopen Closed Tab restores a child without its parentID, so the reopened tab no longer closes back to its opener.
- Review finding left: an opener leaving the screen now gets two snapshots (480 px switcher preview + full size); merging them touches the switcher pipeline.

Review (/code-review medium --fix): 9 findings, 7 fixed (WebKit-gesture flag no longer cleared on a re-claim; watchdog refreshes the window hosting the view; selecting another tab removes a finishing veneer (finishingSelectionID); pinned-entry insert re-evaluates the mode; underlayRequests pruned; Debug tool begin after a cancelled held swipe; one hostedPane(showing:) helper). Left: two snapshots per opener leave (switcher pipeline, out of scope); the closing child gets a switcher preview when the opener is selected first (matches the other close paths).

Tests (Debug, -derivedDataPath .derived):
- NavigationSwipeTests 37 + WebKitDelegateReachabilityTests 3: 40 passed, 0 failed (after the review fixes).
- 28 affected suites (window, split, Peek, switcher, automation, MCP schema, link routing, ownership/focus, release): 363 passed, 49 failed. All 49 are "timed out waiting for the page to load" in InPageLinkRoutingTests (17), PageOpenedWindowTests (11), WindowCloseReleaseTests (19), QuickDetourOpenInWindowTests (2): new web views loading a loopback page. The screen was locked during that run (CGSSessionScreenIsLocked true, checked right after), the known cluster where the GPU process stops taking new web processes. Not rerun on an unlocked screen: owed (those four suites, or the full suite).

Runtime (/verify via docs/harness/task325-swipe-checks.py, Debug build, isolated DetourVerify325-* data dirs, Detour in the background): all 15 checks passed (on the build before the review fixes; the screen was locked afterwards, so not rerun): no opener = WebKit's gesture, edges 15; target=_blank child = own mode, gesture off, edges 14, opener pictured; cancelled swipe leaves it open and selected; page 2 gives WebKit the gesture (edges 15); Back to page 1 = own mode with forward (edges 10); forward swipe goes forward; completed back swipe closes the child and selects the opener; Reopen Closed Tab brings it back; the sidebar's Back button still closes a child; Open Link in Split View child closes from its own pane (back to one pane); nothing starts under a Peek. Screenshots of the veneer half-way (back over the opener's picture, forward card, split pane) looked right. Not verified: the real trackpad gesture (trackSwipeEvent cannot be driven by synthetic events) — see the hand checks above.

Follow-up 2026-11-14 (after the first commit):
- Correction to the test note above: the 49 failures were NOT shown to be the locked screen. Shown instead: they are an order-dependent cluster that predates this change. The same four suites (InPageLinkRoutingTests, PageOpenedWindowTests, QuickDetourOpenInWindowTests, WindowCloseReleaseTests) run together give 52 passed / 20 failed on this branch AND on a baseline build of the parent commit 410d1a1 (same 20 tests: 19 WindowCloseReleaseTests after its first test, plus QuickDetourOpenInWindowTests.testCmdOMovesThePageIntoTheWindowShowingTheSpace; all 'timed out waiting for First loads'). Run alone on this branch, WindowCloseReleaseTests passes 20/20 (its release assertions ran, so the new subscriptions, work items and snapshot closures let closed windows go), and CommittedLoadFailureTests 2/2. InPageLinkRoutingTests 24/24 and PageOpenedWindowTests 11/11 passed in the four-suite run. A full-suite run on an unlocked screen is still the lead's.
- NavigationSwipeTests + WebKitDelegateReachabilityTests: 40 passed, 0 failed on the final source.
- Runtime: docs/harness/task325-swipe-checks.py rerun on the final build (review fixes and the diagnostic logging included): all 15 checks passed.
- The swipe-tracking option bit (1 << 2) is NSEventSwipeTrackingConsumeMouseEvents as WebKit's pal/spi/mac/NSEventSPI.h defines it (checked).
- Diagnostics for the hand check: every unhandled scroll in the own mode logs at debug level (phase, momentum, deltas, whether it began before the mode was armed, the pending tracker's answer), and a swipe that does not start logs at info. Watch with: /usr/bin/log stream --level debug --predicate 'subsystem == "com.detourbrowser.mac" AND category == "NavigationSwipe"' (sandbox off). Mode changes, swipe begin/complete/cancel log at info.
- Cmd+[ finding reworded: observed (Navigate > Back disabled on a child with no back item while the page has the keyboard); likely cause WKWebView's own goBack: action (declared in WKWebView.h) ahead of the window controller in the responder chain; not checked on a baseline build.
- Behaviour change to the Back button itself: its core now selects the opener before closing the child (settlingSelectionForClose), instead of closing first (which selected a neighbour, possibly waking it) and then selecting the opener. Same end state; the activation order differs and the closing child gets a switcher preview as it leaves.
- Left on disk: four WebKit website-data-store folders from the first runtime runs (12:29-12:31, before the check script cleaned its stores); later runs clean up after themselves.

2026-11-15: the user checked the back swipe by hand on a real trackpad and reports it works well (the owed hand check for ACs #1-#3 and #7).

2026-11-15, the user's decisions on the three provisional choices: a split pane's plain background underlay and 'a pinned tab or favourite is never swiped closed' are confirmed as built; the forward swipe should show a picture of the page as it was left instead of a blank card (follow-up TASK-355).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Detour's own back swipe for a tab opened from another tab with no back history (option A). While a hosted pane is a normal tab whose opener resolves and it has no back item, its web view's back/forward gesture is off and the left edge does not rubber-band; scrolls the page does not use (_webView:didNotHandleWheelEvent:) go through WebKit's pending-swipe rules into NSEvent.trackSwipeEvent behind a tracker seam. A completed back swipe runs the Back button's core on the pane that received it (close, select the opener; Reopen Closed Tab works); forward goes forward in the mode. WebKit's gesture is restored before any main-frame commit and the own mode waits for WebKit's own swipe to end; three-finger swipes and momentum are handled. A veneer shows the opener's 1x picture taken as it left. Rules and window paths unit-tested (40 tests); runtime checked through a Debug-only automation tool that runs the completion code (15 checks). Owed: the hand swipe on a real trackpad (AC #1-#3, #7), the user's confirmation of three provisional choices (forward card, split-pane underlay, pinned tabs never swiped closed), and a full suite on an unlocked screen.
<!-- SECTION:FINAL_SUMMARY:END -->
