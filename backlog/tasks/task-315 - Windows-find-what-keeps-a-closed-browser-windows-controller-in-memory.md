---
id: TASK-315
title: 'Windows: find what keeps a closed browser window''s controller in memory'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-09T17:50:00Z'
updated_date: '2026-11-10T09:29:00Z'
labels:
  - window
  - memory
  - bug
dependencies: []
references:
  - TASK-314
  - Detour/Browser/Window/BrowserWindowController.swift
  - docs/harness/task314-harness.patch
priority: low
type: bug
ordinal: 377000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found under TASK-314 (2026-11-09). In the user's production app (0.4.2 build 10), a browser window they had closed was still in memory hours later. Its controller was alive and its window was still in NSApp.orderedWindows. A link placement then showed it again. TASK-314 stops closed windows from being picked, so this is now a leak of one window (its controller, sidebar, palette and views), not a functional bug.

What we know:
- A plain closed window is freed. Harness mode 'leak' (TASK-314 patch) keeps only a weak reference: the controller is gone within 1 s of performClose, and 'leaks --traceTree' finds nothing at its address.
- RoutedOpenRecord holds its windows weakly, so it isn't the holder.
- A closed-but-alive NSWindow keeps its window number and stays in CGWindowList as off-screen, so a running app can be checked for retained closed windows without a debugger (CGWindowListCopyWindowInfo with .optionAll, layer 0, onscreen false, browser-window size).
- The retained window's known history: it was one of two browser windows restored at launch, the two windows sometimes showed the same space and tab, and it received a quarantine Open in. When and how the user closed it is not known.

Candidates to replay, each followed by close + weak-ref check + leaks --traceTree: two windows sharing a selected tab (web view ownership hand-over, script message handlers added by the owning window: releaseOwnedWebViewHandlers only acts when the window owns the web view at close), Peek, find bar, command palette open at close, extension popovers, a Quick Detour or quarantine Open in into the window, Combine sinks or closures capturing self strongly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The holder is found by replaying a history in the Debug build where a closed window stays alive; leaks --traceTree names the retain path
- [x] #2 Fixed so that every replayed history frees the window after close, with a test that closes a window after that history and asserts a weak reference to its controller becomes nil
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. WindowCloseReleaseTests: replay histories in real windows, close, assert a weak ref to the controller goes nil; on a leak, run leaks --traceTree on the test host and print the retain tree.
2. Fix the two holders found: removeContentViews also strips the handlers from the picture-in-picture container it keeps parented; webViews(in:) takes the container's hosted page web view, not the first WKWebView child (a docked inspector comes first).
3. Register the window's handlers through WeakScriptMessageHandler (moved to Browser/Shared), so no handler left on a web view can keep a closed window alive.
4. AppDelegate.observeWindowClose keeps its observer token and removes it when the window closes.
5. Tests for the stale handlers (page-side typeof window.webkit.messageHandlers.linkHover after PiP / docked inspector), the affected suites, /code-review --fix, /verify, wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Also found in review (2026-11-09): AppDelegate.observeWindowClose discards the token from addMainObserver (`_ =`), so each browser window leaves a NotificationCenter block observer registered for the life of the app (filtered on its window object). The block captures AppDelegate weakly, so it doesn't retain the window controller, but it is a small per-window leak. Keep the token and remove it in the block.

2026-11-10 replay results (WindowCloseReleaseTests, Debug test host): 15 histories free the controller after close: plain, hosted page, tab switches + navigation, space switches, two windows sharing a tab (taken over / closed while hosting / left on a snapshot), palette open, find bar open, Peek open, Peek opened and closed, split selected, Quick Detour Open in, quarantine Open in, Cmd+W then close. (Their NSWindow outlives the 3 s poll only in XCTest's per-test autorelease pool; it is freed once the pool drains.)

TWO HISTORIES LEAK, same retain path (leaks --traceTree): WKUserContentController (the page's) -> WebKit::WebScriptMessageHandler -> ScriptMessageHandlerDelegate -> BrowserWindowController, i.e. ucc.add(self, name:) for linkHover / editableFieldFocus left on a page the window no longer hosts. windowWillClose only strips the selected tab's page.
- Picture in picture: leaving a tab whose isPlayingAudio is true (unmuted) keeps its container parented as pipContentView; removeContentViews skips it and the delayed cleanup only removes it from its superview, never the handlers. The window then lives as long as that page (a playing tab never sleeps).
- Docked Web Inspector: the page's container lists [WKInspectorWKWebView, BrowserWebView, DevToolbarView]; webViews(in:) takes the first WKWebView child, the inspector, so the tab switch strips the inspector's controller and leaves the page's. Closing the inspector later does not help.
Which one the user's window went through is not known; both fit a daily developer's use (video, dev mode).

FIX (uncommitted, 2026-11-10):
- BrowserWindowController registers linkHover/editableFieldFocus through WeakScriptMessageHandler (moved from QuickDetourWindowController.swift to Browser/Shared/WeakScriptMessageHandler.swift): no handler left on a page can keep a closed window alive.
- removeContentViews strips the handlers from the picture-in-picture container it keeps parented (releaseScriptHandlers(of:)).
- webViews(in:) reads the page through pageWebView(in:) = WebViewContainerView.hostedWebView, not the first WKWebView child (a docked inspector comes first).
- AppDelegate.observeWindowClose keeps its token in windowCloseObservers and removes it when the window closes.

Tests: WindowCloseReleaseTests (19): 17 histories close a window and assert the controller is freed (leaks --traceTree printed on failure), plus testThePageLeftForPictureInPictureNoLongerReportsToTheWindow / testThePageLeftWithADockedInspectorNoLongerReportsToTheWindow (page-side typeof window.webkit.messageHandlers.*). Against the unfixed BrowserWindowController.swift all 4 new tests fail; with the fix 19/19, and 57/57 over -test-iterations 3. Affected suites (WebViewHandoffFocus, QuickDetourOpenInWindow, QuickDetourWindow, QuickDetour, QuarantineWindow, SplitTab, SplitOpening, DevToolbarHosting, ClosedPeek, PeekHistory, PeekWindowCommands, RecentTabSwitcherPeek, ExternalLinkRouting, InPageLinkRouting, TabHoverCard, CommandPaletteFocus, BrowserTabWake, AutomaticPictureInPicture, WebKitDelegateReachability, FavoriteSpaceHandoff, InitialWindowFocus): 353 tests, 0 failures.

Seen once, in the UNFIXED baseline run only: a test host crash (EXC_BAD_ACCESS in objc_msgSend from BrowserWindowController.snapshotImage(of:) <- tabStoreDidRemoveTab <- TabStore.closeTab <- closeCurrentTab) during testAWindowThatClosedATabIsFreed, before any leaking test had run; Detour-2026-11-10-004707.ips. Not reproduced in 4 fixed runs. Unexplained: the observer that had the closed tab selected was not the closing window (its closeTab settles selection first).

Wiki: architecture/browser-window-controller.md, platform/web-inspector-control.md, platform/appkit-gotchas.md, log.md.
Not done yet: /code-review --fix, /verify, full suite.

/code-review --fix (2026-11-10): 9 findings, 6 fixed by the reviewer.
- Regression in my change, fixed: a PiP page re-selected within the 0.5 s capture hold had lost its handlers in removeContentViews, and claimSingleWebView's refresh branch did not re-wire them (no status bar, isEditingWebContent stuck). It now re-wires when container === pipContentView. New test testThePageReselectedWithinThePictureInPictureHoldReportsToTheWindowAgain fails without that.
- The PiP release runs only while the container is still inside this window (another window may have claimed it within the hold).
- pageWebView(in:) returns hostedWebView only while it is still the container's direct subview; no 'first WKWebView' fallback.
- linkHover ignores messages from a web view outside this window's content view.
- Comments: why assumeIsolated holds in the test's class tearDown; releaseOwnedWebViewHandlers no longer claims it breaks a strong reference.
Skipped: failing the suite from the class tearDown when an NSWindow outlives its controller (XCTest has no clean way; the wiki now says it only prints); observeWindowClose on a double registration (nothing registers twice); renaming loadedTab (cosmetic). Noted, outside this task: OffscreenDocumentHost.swift:152 still uses a strong add(self, name:).

/verify (2026-11-10, Debug, DETOUR_DATA_DIR=DetourVerify315a..d, harness docs/harness/task315-harness.patch): in a second window, plain / pip (a tab really playing a looped WAV, isPlayingAudio true from WebKit) / docked inspector (container [WKInspectorWKWebView, BrowserWebView, DevToolbarView]). Fixed build: the status bar shows the hovered link and isEditingWebContent turns true on focus (messages arrive through the weak handler); the page the window left has no handlers; all three controllers freed; the NSWindow goes with the next event through the queue (AppKit's event-loop autorelease pool; an idle run needs a posted event) and leaves CGWindowList. Unfixed BrowserWindowController.swift: pip and inspector LEAKED, handlers [linkHover, editableFieldFocus] left on the page, the closed window stays listed off-screen in CGWindowList (the production symptom); plain freed. Defaults keys of those runs deleted; their data dirs left in Application Support.

Follow-up for the one-off test host crash: TASK-317.

Full suite (2026-11-10, after the review fixes): 3931 tests, 0 failures, 18 skipped by their own gating, no host restart.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Cause: a browser window registers itself for the linkHover and editableFieldFocus script messages on every page it hosts, with WKUserContentController.add(self, name:), which retains it. Two paths left those registrations on a page the window had left, and windowWillClose only cleans the selected tab's page, so the closed window (controller, window, sidebar) lived as long as that page: (1) leaving a tab that plays audio (auto picture in picture) keeps its container parented as pipContentView, which removeContentViews skipped; a playing tab never sleeps. (2) With a docked Web Inspector the container lists [WKInspectorWKWebView, BrowserWebView, DevToolbarView], and webViews(in:) took the first WKWebView, the inspector. leaks --traceTree: WKUserContentController -> WebScriptMessageHandler -> ScriptMessageHandlerDelegate -> BrowserWindowController. A window leaked this way stays in NSApp.orderedWindows and CGWindowList (off-screen) until a link placement re-showed it (TASK-314), possibly hours after the close.

Fix: the window's handlers go through WeakScriptMessageHandler (moved to Browser/Shared); the PiP container's handlers are removed with the outgoing page's (only while it is still in this window) and given back if the page is re-selected within the hold; pageWebView(in:) reads the container's hostedWebView; linkHover ignores pages outside the window; AppDelegate keeps and removes each window's will-close observer token.

Verification: WindowCloseReleaseTests (20: 17 histories closing a window and asserting the controller is freed, printing leaks --traceTree on failure, plus 3 page-side handler checks); the new leak and handler tests fail against the unfixed controller. Affected suites 353/0, full suite 3931/0 (18 skipped). /code-review --fix: 9 findings, 6 fixed (one a regression of this change, with a test). /verify in the Debug app with real audio and a docked inspector: unfixed leaks with the closed window listed off-screen, fixed frees all three histories; link hover and field focus still reach the window.

Not verified: the user's own retained window (which path it took is unknown), the signed production build. Follow-up: TASK-317 (a one-off test host crash in snapshotImage(of:) seen in an unfixed baseline run). Noted, not filed: OffscreenDocumentHost still uses a strong add(self, name:).
<!-- SECTION:FINAL_SUMMARY:END -->
