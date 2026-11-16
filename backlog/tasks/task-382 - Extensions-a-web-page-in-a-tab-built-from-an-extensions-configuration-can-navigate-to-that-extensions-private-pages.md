---
id: TASK-382
title: >-
  Extensions: a web page in a tab built from an extension's configuration can
  navigate to that extension's private pages
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T15:44:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - extensions
  - security
  - webkit
dependencies: []
references:
  - wiki/extensions/extension-pages.md
  - TASK-381
priority: high
type: bug
ordinal: 463000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 in TASK-381's review, read from WebKit's source and not measured. A tab whose web view was built from extension A's configuration (WKWebExtensionContext.webViewConfiguration, which sets _requiredWebExtensionBaseURL to A — e.g. A's options page opened by Detour) keeps that configuration when the page navigates to an ordinary web page (a link in the options page). That web page can then navigate the tab to A's non-web-accessible pages live, with no sleep or relaunch, because WebKit's extension scheme handler accepts A's pages in that configuration. TASK-381 closed the page-chosen-URL route through sleep, Reload and relaunch; this is the live route. Measure first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Whether a web page loaded in an extension-configured tab can load that extension's non-web-accessible page is measured and recorded
- [x] #2 If it can: such a navigation is refused (or the tab moves to a web configuration when it leaves the extension's origin), with tests; the extension's own navigation between its pages still works
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure rule ExtensionPageNavigationPolicy: a main-frame navigation to a page of the extension the tab's web view serves (servedExtensionOriginHost) is allowed only when the requesting frame (sourceFrame, by KVC) has that extension's origin, or is the main frame holding a document of Detour's own (initial about:blank / empty origin, the browser-error page), or there is no requesting frame (an app load). Everything else (a web, opaque or other-extension frame; a main frame holding a web page, should WebKit's gate ever go) is refused.
2. Apply it in BrowserTab.authorizesNavigation (the tab's own delegate) and in the window's decidePolicy for extension URLs (the window replaces the tab's delegate when it claims the web view).
3. Tests failing first: web iframe top.location in a selected tab (window delegate) and in a background tab (tab delegate); positive controls: the extension's own link, Back, tabs.update (loadURL(_:for:)), its own frame navigating top; pure table tests; a pin of WebKit's gate (an extension tab never loads a web page).
4. /verify through the endpoint with a fixture extension whose options page embeds a loopback frame; wiki (extension-pages, error-pages if needed), log, Backlog.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measurement (2026-11-16, macOS 26.7 25G229 per TASK-352's runtime; XCTest probe in ExtensionPageProvenanceTests + endpoint run on DetourVerify-382):
- The route in the description is NOT real. A tab built from an extension's configuration cannot leave the extension's origin for a web page at all. WebKit ignores every main-frame navigation in a web view with _requiredWebExtensionBaseURL whose URL is not that extension's (NavigationState.mm isUnsupportedWebExtensionNavigation, read from WebKit main; applied after the delegate's .allow). Measured: options page link click, location.href from the options page, webView.load(http) on the tab, a plain WKWebView from context.webViewConfiguration (fresh and after options), and at runtime the endpoint's trusted click on a link in the fixture's options page plus open_url in_place: the delegate allowed each, then no provisional load started, no failure was reported, the loopback server saw no page request (only Detour's own /favicon.ico guess for the in-place load), and the tab stayed on options.html. So no web page can be the main frame of such a tab.
- The narrower route IS real: a web iframe inside the extension's own page. A loopback iframe added to options.html whose script runs top.location = webkit-extension://<ext>/other.html (other.html not web-accessible), with no user gesture, loaded other.html in the tab (title Other, tab.url = other.html). sourceFrame for that navigation: subframe, origin http://127.0.0.1. A synthetic target=_top link click in the iframe instead arrived with a nil target frame (new-window path) and ended as a space tab on WebKit's -1008 error page.
- sourceFrame (read by KVC) in the extension tab: initial load = main frame, about:blank, empty origin; app loads and the extension page's own navigations = main frame, the extension's origin.

Implementation (2026-11-16): ExtensionPageNavigationPolicy (Detour/Extensions/Runtime) — a main-frame navigation to a page of the extension whose configuration built the tab's web view (servedExtensionOriginHost) is allowed only when the requesting frame (sourceFrame via KVC, WKNavigationAction.requestingFrame, now shared with the external-app origin check) has that extension's origin, or is the main frame holding Detour's own document (initial about:blank / empty origin, the browser-error page), or no frame is named. Applied in BrowserTab.authorizesNavigation (the tab's own delegate) and in the window's decidePolicy for extension URLs (a web view no tab owns is held to the rule as if it served the URL's extension). Refusal = cancel + a navigation-policy log line (protocol public, host private), no error page.
- Rejected: moving the tab to a web configuration when it leaves the extension's origin (it never leaves: WebKit drops the navigation; a replacement web view would lose history); arming Detour's loads like InternalPageNavigationPolicy (app loads already report the extension page or a Detour document as source).
- Chosen by Claude (not yet confirmed by the user): a web frame is refused even when the target page is web-accessible (keeps parity with space tabs, where WebKit refuses a WAR main frame with -1008); alternative: let through targets the extension's web_accessible_resources match for the frame's origin (e.g. a framed sign-in handing back to a WAR callback).
- Not covered: back/forward started by a web frame (top.history.back()) not measured, only reaches pages already in the tab's history; a Cmd-click on a target=_top link to the extension's page inside a web frame now does nothing (before: a space tab WebKit refused).

Verification (2026-11-16):
- Tests failing first: testAWebFrameInAnExtensionsPageCannotNavigateItsTabToTheExtensionsPages (window delegate) and testAWebFrameInABackgroundExtensionTabCannotNavigateItToTheExtensionsPages (tab delegate) failed on the old code (other.html loaded; 5 assertion failures) and pass with the fix. New: ExtensionPageNavigationPolicyTests (5, table cases), testAnExtensionsOwnNavigationBetweenItsPagesStillWorks (link, Back, its own frame's script sending top on, tabs.update via loadURL(_:for:), in a window and in the background), testAnExtensionsTabNeverLoadsAWebPageInItsMainFrame (pins WebKit's gate). Affected suites (27 classes: ExtensionPage*, BrowserTabUnclaimedNavigation, BrowserTabWake, CommittedLoadFailure, ExtensionOptionsPageEntry, ExtensionTabLifecycle, ExternalAppPermission, InternalPage*, LinkRoutingEligibility, MoveTabToSpace, NavigationFailureURL, PageOpenedWindow, QuickDetourExtension, WebKitDelegateReachability, WKExtensionIntegration, ExtensionEnabledState, ExtensionPolyfillProfileWiring, ExtensionUpdater, ExtensionWindowsCreatePrivate, ...): 445 tests 0 failures 13 skipped before review fixes; 457 tests 0 failures 13 skipped after.
- Runtime (/verify through the endpoint, DetourVerify-382, build 08:45): docs/harness/task382-endpoint-checks.py 6/6 — fixture options tab loads; a framed loopback page's top.location to the non-web-accessible other.html is refused (log line, tab stays on Opts, screenshot checked); the options page's link to a web page goes nowhere (no request); its own link opens other.html and Cmd+[ returns; tabs.update on its own tab loads options.html?updated=1. Not exercised at runtime: the background-tab delegate path (tests only), sleep/wake.
- /code-review medium --fix: 9 findings. Fixed: own-frame test step now runs from the frame's own script (jump.js) so the requester really is an extension-origin subframe; delegate asserted per test leg; authorizesNavigation skips the internal-page walk for non-internal URLs; shared requestingFrame accessor; window fails safe when no tab owns the web view; log host private. Left as decisions/reports: WAR targets refused (Chosen by Claude above), Cmd-click order, history traversal from a web frame.

User decisions 2026-11-16: confirmed: a web frame is refused even when the target page is web-accessible, as for space tabs (rather than letting through targets the extension's web_accessible_resources match for the frame's origin). Follow-up filed: TASK-392 (a plain link from an extension's options page to a website silently does nothing, WebKit's gate; open it in a new tab).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Measured: the filed route is not real — WebKit ignores every main-frame navigation off the extension in a web view built from its context's configuration (NavigationState.mm isUnsupportedWebExtensionNavigation, silently, after the delegate's .allow), so an extension tab never shows a web page. The real live route is a web frame the extension's page embeds: its top.location loaded a non-web-accessible page into the tab. ExtensionPageNavigationPolicy, applied by both navigation delegates through BrowserTab.authorizesNavigation, now refuses a main-frame navigation to the served extension's page unless the requesting frame is the extension's, or the main frame holds Detour's own document, or none is named. The extension's own links, Back, its frames, tabs.update and Reload keep working. Tests failing first + 457 affected tests pass; runtime 6/6 through the endpoint. Chosen by Claude: web-accessible targets are refused too (parity with space tabs). Reported: a plain link from an options page to a website silently does nothing (WebKit's gate).
<!-- SECTION:FINAL_SUMMARY:END -->
