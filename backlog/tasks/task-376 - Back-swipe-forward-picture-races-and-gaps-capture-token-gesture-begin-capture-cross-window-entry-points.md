---
id: TASK-376
title: >-
  Back swipe: forward-picture races and gaps (capture token, gesture-begin
  capture, cross-window, entry points)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
updated_date: '2026-11-16T18:37:00Z'
labels:
  - tabs
  - navigation
  - gestures
dependencies: []
references:
  - wiki/tabs/back-swipe-to-opener.md
priority: low
type: task
ordinal: 457000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-355's review, left as findings. (1) The async capture has no request token: a narrow race can store a moments-old picture as unused. (2) Capturing at WebKit's gesture begin also snapshots forward and cancelled swipes; they are dropped later but can push another tab out of the 4-entry cache (_webViewWillEndNavigationGesture:withNavigationToBackForwardListItem: might be the better hook; reachability unchecked). (3) A tab moved to another window leaves its picture in the old window's cache. (4) Capture hooks sit at each back entry point, so a future back-history menu would get the plain card.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each item fixed or recorded as accepted on the back-swipe page
- [x] #2 Tests for what changes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Choke point (items 2 and 4): picture the page being left in the navigation delegate's back/forward check, which WebKit consults for every history traversal before the web process goes ahead (Back button/Cmd+[/mouse, a future go(to:) menu, WebKit's swipe at its end (completed swipes only), the three-finger swipe, the page's history.back()): public webView:shouldGoToBackForwardListItem:willUseInstantBack:completionHandler: (macOS 26) with the private _webView:willGoToBackForwardListItem:inPageCache: (macOS 15.4-15.x; WebKit calls it only when no should-variant is implemented) as fallback; only when the target is the back item and the back list has one item. Snapshot issued before answering, so the page process paints it before it navigates. Remove the three entry hooks (Back core, gesture begin, three-finger) and the cancelled-swipe drop at snapshot removal. Reachability rows.
2. Request token (item 1): a per-tab pending request (token, item, left flag) outside the LRU, revised with the history like the stored picture; a completion stores only when its token is the latest, the page is still current and was not left meanwhile (a picture that comes back after its page was left may show the next page: same-document backs). A new request drops the tab's stored picture. A seam holds the snapshot completion in tests to force the races (returned to the page before it came back; an older completion after a newer request).
3. Cross-window (item 3): on webViewOwnershipChanged from another window, hand this window's picture of the claimed tabs to the claiming window's cache and drop pending requests.
4. Tests (NavigationSwipeTests, WebKitDelegateReachabilityTests), rewrite the history.back() fallback tests (now pictured) with a resized pane; same-document back case measured.
5. Harness docs/harness/task325-swipe-checks.py: history.back() pictured; plain card after a window resize. /verify.
6. Wiki back-swipe page + snapshots page, log, Backlog notes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation 2026-11-16 (branch lane-b).

Items 2 and 4, one choke point: WebKit asks the navigation delegate before every move in a web view's history (HistoryController::goToItemShared -> WebPageProxy::shouldGoToBackForwardListItem -> NavigationState; source reading), whatever starts it: goBack()/go(to:) (Back button, Cmd+[, mouse back, a future history menu), WebKit's swipe at willEndSwipeGesture -> goToBackForwardItem (completed swipes only; a cancelled or forward swipe never asks for the back item), the three-finger swipeWithEvent:, the page's history.back(). For a cross-document move the web process asks asynchronously and waits, so a takeSnapshot issued in the callback before answering paints the page being left (checked by colour: Back button and the page's history.back(), tests and running app). Capture now lives only there: public webView(_:shouldGoTo:willUseInstantBack:completionHandler:) (macOS 26, in the WKNavigationDelegate conformance extension) and, for macOS 15, the private _webView:willGoToBackForwardListItem:inPageCache: (WebKit calls it only when neither should-variant is answered). Only a move to the back item when the back list has one item. Removed: the Back core's pre-goBack capture, the capture at _webViewDidBeginNavigationGesture:, the three-finger hook, and dropForwardPictureNotLeft at snapshot removal (no cancelled-swipe pictures any more, so the slow-commit trade-off from TASK-355's review is gone too). _webViewWillEndNavigationGesture:withNavigationToBackForwardListItem: was evaluated (runs before goToBackForwardItem with a nil item when cancelled) but not needed. Reachability: public method added to the WKNavigationDelegate expectations, the private selector to the private list. The reachability test caught the public method's first Swift signature (@MainActor @Sendable completion) not matching the SDK's plain (Bool) -> Void; the build gave no warning and WebKit silently used the private fallback.

Item 1, request token: ForwardPictureRequest (token, item, hasBeenLeft) per tab, outside the 4-entry cache; revised with the history as a kept picture is (reviseForwardPicture), pruned with closed tabs, let go on another window's claim. A new request drops the tab's older picture. The completion counts only if its token is the tab's latest and its page is still current and never left meanwhile (ForwardPictureRequest.picture). Seam: NavigationSwipeWindowState.takeForwardPictureSnapshot (tests hold the completion). Failing first: with the old completion rule (fresh ForwardPagePicture + stillApplies, no token) both race tests failed (testAPictureThatComesBackAfterThePageWasReturnedToIsDropped stored an unspent picture; testAnOlderPictureComingBackLateDoesNotReplaceANewerOne kept the older one); restored, both pass.

Same-document back (a pushState page 2): measured, the snapshot asked in the callback comes back with the first page already current (WebKit asks synchronously; the async TakeSnapshot is handled after the move), so it is dropped: plain card. Accepted and recorded on the wiki (TASK-355's Back-core capture did picture this case; the rule keeps a wrong-page picture impossible).

Item 3, cross-window: handleWebViewOwnershipChanged hands this window's forward pictures of the claimed tab ids to the claiming window (before the selected-tab guard) and lets go of requests in flight. Both claim paths (single, split) post the notification. Chosen by Claude (not yet confirmed by the user): the picture is handed over to the claiming window, so a forward swipe there shows it; alternative: drop it (delete the store line in handOverForwardPictures).

Review (/code-review medium --fix, 6 findings, 2 fixed): fixed the forward-picture prune (one set of open tab ids for pictures and requests) and the completion's log line ("came back too late" only when the rule refuses, not for a nil image or a gone web view). Left: (1) a cross-document back whose commit beats the snapshot reply would get no picture: not reachable by ordering, since the old page's process sends the snapshot reply before it handles the go-ahead and before any message the navigation produces (its policy request comes on the same connection after the reply; a new process starts only after that), so the UI handles the reply first; a failure would only give the plain card. (2) the macOS 15 private path is checked only for reachability; this Mac runs 26.7, so the ordering there is unverified (a late call would get the plain card, never a wrong picture, by the same rule). (5)(6) the swipe-begin test and the same-document test are weak by necessity (no real WebKit swipe in a test; the same-document outcome is asserted as never the wrong page, the measured outcome was no picture).

Tests (Debug, -derivedDataPath .derived): NavigationSwipeTests 54 + WebKitDelegateReachabilityTests 3 = 57 passed, 0 failed (after the review fixes); BackForwardResponderTests + TabOpenerRuleTests + WebViewHandoffFocusTests + AutomationToolsTests = 54 passed, 0 failed (before the review's two small edits). New: request rule (pure), the page's history.back() pictured (colour), WebKit swipe begin/cancel takes nothing, only a back to the first page asks, held-snapshot races (returned before it came back; older after newer), same-document back, picture moves with the web view to another window (two regular windows, one space), resized window gives the plain card.

Runtime (/verify via docs/harness/task325-swipe-checks.py, Debug build of the source before the review's log/prune edits, data dir DetourVerify-376, Detour in the background, cleaned up): 18/18 passed, among them Back pictures page 2 and the held forward card is page 2's colour (222, 244, 210); the page's own history.back() now pictures page 2 too, card (222, 244, 210); after a window resize (set_window_frame, -120 pt) the card is plain (255, 255, 255). Screenshot checked.

Not verified: a real trackpad swipe back (WebKit's gesture) then forward, and the three-finger swipe (synthetic events cannot drive them; the shouldGoTo path they take is the one checked for goBack() and history.back()); macOS 15 (private fallback); a back that swaps processes.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The forward swipe's picture of the page a back leaves is now taken in one place: the navigation delegate's webView(_:shouldGoTo:willUseInstantBack:completionHandler:) (macOS 26; private _webView:willGoToBackForwardListItem:inPageCache: on macOS 15), which WebKit asks before every history move while the web process waits. That replaces the Back-core, swipe-begin and three-finger hooks (item 4), so cancelled and forward WebKit swipes take nothing (item 2) and the page's own history.back() is pictured too. Each capture has a token and a request kept outside the 4-entry cache, revised with the history; it counts only if it comes back with its page still current and never left (item 1; race tests failed on the old rule). A same-document back's snapshot comes back after the move (measured), so it gets the plain card (accepted, on the wiki). Another window claiming the web view takes the picture along (item 3; Claude's choice to hand over rather than drop, to confirm). The reachability test caught the public method's Swift signature not matching the SDK. Tests: 57 + 54 passed; runtime 18/18 endpoint checks. Owed: real trackpad and three-finger swipes by hand; macOS 15 unverified.
<!-- SECTION:FINAL_SUMMARY:END -->
