---
id: TASK-178
title: >-
  Navigation: a load that fails after the page committed replaces the working
  page with the full error page (YouTube Short, 'The request timed out')
status: Done
assignee:
  - '@claude'
created_date: '2026-10-13 06:06'
updated_date: '2026-10-13 06:31'
labels:
  - bug
  - navigation
dependencies: []
references:
  - Detour/Browser/BrowserTab.swift
  - Detour/Browser/Window/BrowserWindowController+Navigation.swift
  - wiki/features/error-pages.md
priority: medium
ordinal: 201000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-10-12 23:01 in the user's running browser: a YouTube Short was playing when the whole tab was replaced by the error page ('Looks like you took a Detour.' / 'The request timed out.'), and the sidebar row lost its title and favicon.

Cause, from the unified log of that process (pageProxyID=3953): the tab loaded www.youtube.com/shorts/7GcR0QmfutU at 23:00:11.6 and the navigation committed at 23:00:12.0. The page ran (subframes loaded, document title set at 23:00:37). The main resource itself (resourceID=12, the HTML response) never finished and timed out at 23:01:14.16, 62 s after commit: 'FrameLoader::checkLoadCompleteForThisFrame: Finished frame load with error (isTimeout = 1, errorCode = -1001)', then 'WebPageProxy::didFailLoadForFrame: isMainFrame=1, code=-1001', and in the same millisecond Detour's loadRequest for the browser-error:// page. That is webView(_:didFail:withError:) -> BrowserTab.didFailNavigation(error:) -> showErrorPage. WebKit finalises the document with what arrived (didFinishDocumentLoadForFrame followed the failure), so without Detour's load the page would have kept playing.

A failure after commit is not a failed request of the user's: there is a document on screen. The error page belongs to failures before anything committed (didFailProvisionalNavigation). Other browsers keep the partial document. Why the response stalled is not known (one occurrence in 12 h of logs; the other three committed failures in that window were -999 cancellations, already ignored).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test with a real server that sends part of a document and then drops the connection fails before the fix: the tab ends on the error page
- [x] #2 After a committed main-frame load fails, the web view stays on the committed document: no error page, tab.url, title and favicon unchanged
- [x] #3 The same holds for a web view a window owns and for one the tab is its own navigation delegate of
- [x] #4 A failure before commit still shows the error page (existing BrowserTabUnclaimedNavigationTests and BrowserTabWakeTests pass)
- [x] #5 wiki/features/error-pages.md states the rule and what was rejected
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Test first: LoopbackHTTPServer gains a 'truncated' route (head promises more than is sent; release closes the connection short), and CommittedLoadFailureTests loads it in an unowned tab and in a window's selected tab, waits for the page to show, drops the connection and asserts the tab is still on the page (URL, title, favicon, document). Run it red.
2. Fix: remove BrowserTab.didFailNavigation(error:) and the webView(_:didFail:withError:) implementations of both navigation delegates (BrowserTab's own and BrowserWindowController's). The provisional path is unchanged.
3. Run CommittedLoadFailureTests, BrowserTabUnclaimedNavigationTests, BrowserTabWakeTests, NavigationErrorClassificationTests, PageOpenedWindowTests.
4. wiki/features/error-pages.md (rule, evidence, rejected alternatives), wiki/platform/media-and-pip.md, wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fix: BrowserTab.didFailNavigation(error:) and both delegates' webView(_:didFail:withError:) are removed; a failure after commit is left to WebKit, which finishes the document with what arrived. The provisional path is unchanged. Decision and the two rejected alternatives (error page only for an empty committed document; ignoring only timeouts) are in wiki/features/error-pages.md.

Tests: LoopbackHTTPServer has a 'truncated' route (Content-Length 4096 bytes more than is sent; release closes the connection). CommittedLoadFailureTests (2 tests, unowned tab and a window's selected tab) was red before the fix: both ended on browser-error://…The network connection was lost, title back to the URL, favicon gone, document replaced. Green after. Also run and passing: BrowserTabUnclaimedNavigationTests 3, BrowserTabWakeTests 7, NavigationErrorClassificationTests 9, PageOpenedWindowTests 11 (32 tests with the new 2). SameDocumentVisitTests: testInPageNavigationsDuringALongLoadAreAllRecorded failed once in that run ('/a to be recorded' timed out; no load failure is involved in that test), then the suite passed 3 times in a row (54 of 54) — a flake, not filed.

Runtime (Debug build from this branch, DETOUR_DATA_DIR=DetourVerify178, a seeded selected tab on a Python server that sends the start of a page and closes the connection 8 s later): unified log of the launched process shows didCommitLoadForFrame, then 'Finished frame load with error' and didFailLoadForFrame isMainFrame=1 code=-1005, and no loadRequest after it (the user's log had the error page's loadRequest in the same millisecond). The window title was 'Partial' 3 s into the load and still 'Partial' 4 s after the drop.

Not done: /code-review --fix, the full test suite, and the commit (not asked for yet). Not verified: a real 60 s timeout (-1001) rather than a dropped connection (-1005) — both reach the same removed callback. Why YouTube's response stalled is not known.

Code review (/code-review --fix), 8 findings. Applied: wiki pages that still listed didFail among the tab delegate's callbacks (architecture/browser-tab.md, tabs/tab-lifecycle.md), a row for a response that ends short after commit in platform/wkwebview-delegate-order.md, generated.at on media-and-pip.md, the isIgnoredNavigationError and OffscreenDocumentHost.failLoad comments (the 204 half is now a backstop for tabs), and LoopbackHTTPServer's response head in one helper with truncated checked first in both respond and release. Skipped: an error page for an empty committed document (the rejected alternative; a response that commits on its headers and then dies leaves a blank page, and its visit is now recorded when isLoading goes false), and a shared window-test fixture (about 14 suites outside this change).

Full suite after the review's edits: 2182 tests, 11 skipped, 1 failure — BrowserWindowSidebarModeTests.testHoverRevealedSidebarHidesWithoutAnyExitEvent (a hide-delay timing assertion, 0.008 s against > 0.28 s); that suite then passed 3 times in a row (24 of 24). CommittedLoadFailureTests passed in the full run. The runtime check was made before the review's edits, which changed comments, wiki pages and the test server only.

Runtime check repeated on the final build (after the review's edits, dylib built 23:28): same result — commit, didFailLoadForFrame code=-1005, no loadRequest after it, window title 'Partial' before and 4 s after the drop.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A navigation that fails after it committed no longer raises the error page: BrowserTab.didFailNavigation and both navigation delegates' webView(_:didFail:withError:) are removed, so the committed document stays with its URL, title and favicon. Failures before commit are unchanged. Cause confirmed from the user's unified log (a YouTube Short's HTML response timed out 62 s after commit). CommittedLoadFailureTests (real server that drops the connection mid-response; unowned tab and a window's selected tab) fails without the fix; full suite 2182 tests with one unrelated flaky failure that passes on re-run; runtime check in a Debug build shows didFailLoadForFrame with no error-page load after it and the window title unchanged.
<!-- SECTION:FINAL_SUMMARY:END -->
