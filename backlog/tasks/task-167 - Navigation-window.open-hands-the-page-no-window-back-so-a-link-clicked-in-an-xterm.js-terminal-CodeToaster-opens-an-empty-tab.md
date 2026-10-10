---
id: TASK-167
title: >-
  Navigation: window.open() hands the page no window back, so a link clicked in
  an xterm.js terminal (CodeToaster) opens an empty tab
status: Done
assignee:
  - '@claude'
created_date: '2026-10-10 07:07'
updated_date: '2026-10-10 07:55'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - Detour/Browser/TabStore.swift
  - Detour/Browser/BrowserTab.swift
  - wiki/platform/wkwebview-delegate-order.md
priority: high
ordinal: 190000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-10. In CodeToaster (a web app with an xterm.js terminal) the terminal sometimes prints a link such as http://localhost:5173/. Clicking it opens a new tab, but the tab never loads the URL and the address bar stays empty.

Likely cause (read from the code, not yet reproduced): BrowserWindowController's createWebViewWith always returns nil. For a page's own window.open it creates an unrelated tab with TabStore.addTab(in:url:) and loads the request URL into it itself, so the page's window.open() call returns null and the new tab has no opener relationship with the page.

xterm.js's web-links addon opens a link in two steps: `const w = window.open(); w.opener = null; w.location.href = uri`, and when window.open() returns null it only logs 'Opening link blocked as opener could not be cleared'. In Detour the first step creates a tab for the empty/about:blank request and returns null, so the second step never runs: an empty tab with no URL, which is the report. The same shape (open a blank window, then navigate or write into it) is common outside xterm.js.

The fix direction is for a page-initiated new window to be a real WebKit child: a WKWebView created with the configuration WebKit passes to createWebViewWith, adopted by a new tab (TabStore.addTab(in:webView:) exists and is used by Peek's expand-to-tab) and returned to WebKit, which then performs the navigation itself. Things that must keep working and need deciding along the way: the Peek routing for pinned tabs and favourites (TASK-85), the refusal of internal pages and of data: URLs (TASK-86, TASK-159), the context menu's Open in New Tab / New Window actions that also arrive here, tab insertion next to the opener, extension tab lifecycle reporting for the adopted web view, the tab's profile/data store and content rules (the supplied configuration is the opener's), and noopener opens (window.open with 'noopener', rel=noopener links) where WebKit gives the page no handle either way.

TASK-168 (sign-in popups) builds on this one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The cause is reproduced and recorded: what createWebViewWith receives for a bare window.open() and what the page gets back, in a test or a standalone spike
- [x] #2 window.open() with no URL followed by assigning location.href on the returned window opens one new tab that loads the assigned URL and shows it in the address bar (the xterm.js web-links sequence)
- [x] #3 window.open(url) returns a non-null window to the page and the new tab loads the URL once, not twice
- [x] #4 A window opened with noopener still opens a tab that loads its URL
- [x] #5 Peek routing for pinned tabs and favourites, the internal-page and data: refusals, and the context menu's Open in New Tab / Open in New Window still behave as before, covered by the existing tests
- [x] #6 The new tab is inserted next to its opener, uses the opener's profile, and is reported to extensions like any other new tab
- [x] #7 Tests in a real BrowserWindowController with a local fixture page cover the blank-then-navigate sequence and window.open(url)
- [x] #8 Checked at runtime with a page that reproduces the xterm.js link click; the wiki's delegate-order page records what was learned
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike (standalone WKWebView binary, docs/harness): what createWebViewWith receives for a bare window.open(), window.open(url), noopener, a popup and a _blank link, and what the page gets back when the delegate returns nil or a web view made from the supplied configuration.
2. Failing tests in a real BrowserWindowController against loopback fixture pages (PageOpenedWindowTests): blank-then-navigate, window.open(url) loads once, noopener, _blank link, a failed load shows the error page, placement next to the opener, an opener in a space the window is not showing.
3. createWebViewWith returns the new tab's web view for a page's own request: TabStore.addTab(in:openedWith:parentID:) builds the tab from the configuration WebKit supplies (the opener's data store and process), with a user content controller of the space's own. WebKit performs the navigation; the browser no longer loads the URL itself. The tab goes in the opener's space with the opener as parent. Peek routing, the internal-page and data: refusals and the context menu actions keep returning nil.
4. Run the affected suites, /code-review, /verify with a page that runs the xterm.js link sequence, wiki (delegate order, tab lifecycle).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Cause (AC #1), 2026-10-10

CodeToaster's terminal uses xterm.js's stock WebLinksAddon (src/frontend/Terminal.tsx: new WebLinksAddon(), @xterm/addon-web-links 0.12). Its default handler is: const w = window.open(); if (w) { w.opener = null; w.location.href = uri } else console.warn('Opening link blocked as opener could not be cleared').

Measured with a standalone WKWebView binary (docs/harness/task167-window-open-spike.swift, macOS 26):
- A bare window.open() reaches createWebViewWith with a non-nil, empty request URL. With the delegate returning nil, as Detour's did, the page gets null. Detour opened a tab for the empty URL and returned nil, so the handler's second half never ran: an empty tab with no URL, which is the report.
- With the delegate returning a web view made from the supplied configuration, the page gets a window; the child shows about:blank and the later location assignment is a navigation of the child.
- window.open(url): WebKit loads the URL in the returned child itself (opener set, postMessage arrives). noopener: the delegate is still called, WebKit loads the child, the page gets null either way. _blank links: decidePolicy on the opener, then createWebViewWith, then WebKit loads the child.
- The supplied configuration shares the opener's data store and the same WKUserContentController object. Swapping in a fresh controller before creating the child works.

## Change

- createWebViewWith returns the new tab's web view for a page's own request (TabStore.addTab(in:openedWith:parentID:)); WebKit performs the navigation and the tab learns its URL from the web view. The context menu actions, the Peek route and the internal-page and data: refusals still return nil.
- The tab gets a user content controller of the space's own (Space.makeUserContentController(), extracted from makeWebViewConfiguration): a window adds and removes its script message handlers on the controller of the web view it hosts, so a controller shared by opener and child would lose the opener's handlers when the child is unhosted.
- Placement: the opener's space, with the opener (a peek's host tab) as parent. Before, it was the window's active space and selected tab, which is the same thing whenever the opener is on screen. For an opener in a space the window is not showing, the tab now goes to that space unselected, since it shares that space's profile data.

## Status: NOT BUILT, NOT RUN

xcodebuild cannot run on this machine as of 2026-10-10: Xcode.app was replaced on Oct 9 and its first-launch components are not installed (xcodebuild -checkFirstLaunchStatus exits 69; every invocation fails with 'failed to load a required plug-in'). The install needs admin rights; the user has been asked. The code and DetourTests/PageOpenedWindowTests.swift (11 cases for TASK-167/168) are written but have not been compiled, the tests have not been seen failing or passing, and nothing was checked at runtime. No acceptance criterion other than #1 is checked.

## Built and run, 2026-10-10 (replaces 'NOT BUILT' above; the user ran Xcode's first-launch setup)

Red, then green. DetourTests/PageOpenedWindowTests (11 cases) run against the old code with the fix stashed: 8 failed, 3 passed (the 3 are guards for behaviour that already worked: a _blank link, a noopener open, a page that may not close a user's tab). With the fix: 11 pass.

Two things the first green run found:
- A window a page opened whose first load fails showed the error page for about:blank: the tab never called load, and the last URL its observer had from the web view was about:blank. BrowserTab.didFailProvisionalNavigation now takes the failed URL from the error (NSURLErrorFailingURLErrorKey) when the tab has no URL of its own (nil or about:blank). Covered by testAnOpenedWindowWhoseLoadFailsShowsTheErrorPageForItsURL. This is the dev-server-not-running case of the report.
- A test expectation of mine was wrong (a parentless tab is inserted at the top); the child is placed right after its opener.

Suites run: PageOpenedWindowTests, DataURLTabTests, PeekAnchorTests, BrowserTabUnclaimedNavigationTests, BrowserTabWakeTests, InternalPageIntegrationTests, InternalPageTests: 83 tests, 0 failures.

Runtime (/verify, Debug build in an isolated profile DetourVerify167, pages served from a loopback python server): a seeded tab loads a page that runs xterm.js's WebLinksAddon handler verbatim (window.open(); opener = null; location.href = uri). Observed through the server's request log and browser.db: 'window.open() returned a window', one GET of the target, a second tab titled Target with the target URL, parented to the opener, selected. Not exercised: a real pointer click on a link in CodeToaster's terminal (the page ran the handler on load), and the Peek route from a pinned tab at runtime (unchanged code, covered by PeekAnchorTests).

## Review (/code-review --fix) and final checks, 2026-10-10

Review findings and what was done:
- Fixed: a window opened by an extension page was built from the extension context's configuration (WebKit supplies a copy of the opener's: _requiredWebExtensionBaseURL set, CORS checks off for the extension's hosts). createWebViewWith now keeps the old path for such an opener (a tab of the space's own that the app loads; null for the extension page). ExtensionPageOpenedWindowTests covers it: passes with the guard; with the guard disabled the child carried the extension's base URL and never loaded the page.
- Fixed: the new tab never got its profile's user agent (init applies it before the tab has a space, and this path never calls load). addTab(in:openedWith:) applies it once the tab is placed. No test of its own.
- Not fixed, filed: TASK-170 (a page-started navigation that fails in an ordinary tab names the previous page on the error page; confirmed with a test, an existing bug), TASK-171 (window.close() from a Peek, pinned tab or favourite is ignored), TASK-172 (a web view no window hosts has no UI delegate; the background-space child's hand-set delegate is lost when that window closes).
- Not fixed: the failed-load test gets its dead port by stopping a loopback server; another process could take the port first. Low likelihood, same technique as the other suites.

AC #5: the Peek rule, the internal-page and data: refusals are covered by PeekAnchorTests, InternalPageIntegrationTests and DataURLTabTests, all passing; the context menu's Open in New Tab / New Window branches are unchanged code with no test of their own. AC #6: placement and the data store are asserted; reporting to extensions is by construction (the tab enters space.tabs through insertTab, the reporting point for every tab) and the window's claim-time assertion that a hosted web view is registered ran for every selected child in these tests.

Known limit, as before the change: an extension page that opens another page of its own extension gets no window back.

Tests on the final code: full DetourTests run, 2,095 tests, 0 failures, 11 skipped (366 s). /verify repeated on a build of the final code with the same two flows and the same observations.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A page's own new window (window.open, a target=_blank link) is now a real WebKit child: createWebViewWith returns the new tab's web view, built from the configuration WebKit supplies, and WebKit performs the navigation. Before, it returned nil and loaded the URL into an unrelated tab, so window.open() gave the page null; xterm.js's link handler (window.open(), then location.href on the result), which CodeToaster's terminal uses, was left with an empty tab.

The tab gets a user content controller of the space's own (Space.makeUserContentController), goes in the opener's space next to the opener, and takes a failed first load's URL from the error. A window an extension page opens keeps the old path. Cause confirmed with a standalone spike (docs/harness/task167-window-open-spike.swift) and CodeToaster's source.

Verified: PageOpenedWindowTests + ExtensionPageOpenedWindowTests (12 cases; 8 of the first 11 failed before the fix), full suite 2,095 tests 0 failures, and at runtime in an isolated profile with a page running the xterm.js handler verbatim. Not exercised: a real pointer click on a terminal link in CodeToaster. Follow-ups filed: TASK-170, TASK-171, TASK-172.
<!-- SECTION:FINAL_SUMMARY:END -->
