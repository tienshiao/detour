---
id: TASK-381
title: >-
  Extensions: a web page can make a tab load an extension's non-web-accessible
  page (window.open, then sleep/wake or Reload)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T10:32:00Z'
updated_date: '2026-11-16T11:11:00Z'
labels:
  - extensions
  - security
  - webkit
dependencies: []
references:
  - wiki/extensions/extension-pages.md
  - wiki/features/error-pages.md
  - TASK-372
priority: high
type: bug
ordinal: 462000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 by TASK-372's probe A (read the TASK-372 notes and docs/harness/task372/). On main: a web page calls window.open('webkit-extension://<id>/options.html'). WebKit refuses the main-frame load (no _requiredWebExtensionBaseURL; -1008), but the child tab's url stays on options.html; after sleep(force:) and wake() (and then Reload), BrowserTab.wakeConfiguration builds the tab from that extension's own configuration because tab.url is an extension page, and options.html loads with the extension's privileges. A page should never be able to choose an extension page, outside web_accessible_resources, for a tab to load. Not tried: a relaunch instead of a sleep (session restore likely rebuilds it the same way). TASK-372's parked fix would widen the same hole (a refused location.href would also leave tab.url on the extension page).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A tab whose extension URL was chosen by a web page (window.open, location, link, form) never loads that extension's non-web-accessible page after sleep/wake, Reload or a relaunch
- [x] #2 Extension pages opened by Detour or the extension itself (tabs.create, the popup/options entry points, runtime.openOptionsPage, restored extension tabs) still load and rehome as before
- [x] #3 Tests reproduce probe A and the relaunch case against the old code and pass after the fix; a runtime check through the endpoint
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Core rule (Chosen by Claude): tab.url never names a webkit-extension:// page its current web view cannot serve. BrowserTab records the origin host of the extension context whose configuration built its web view (wake via wakeConfiguration, addExtensionTab from the caller's context), cleared on release; every url write on a tab with a web view goes through one gated setter (init(webView:), restoreArchivedPage, URL observer, load, showErrorPage). Sleeping writes (restore, records, retarget) stay trusted because everything they carry derives from tab.url.
2. The existing extensionID column stays the persisted provenance (stamped from tab.url), so a relaunch cannot launder; rows saved before the fix are grandfathered (cannot be told apart).
3. Readers feeding retarget/options reuse use webView?.url ?? url: make the live branch require 'served' (showsExtensionPage, retargetExtensionPages, existingOptionsPageTab, cross-profile move).
4. Audit tile URLs not from tab.url (pinURL, addFavoriteFromEntry, pasteboard drops).
5. Tests (new suite): probe A window.open, location, link, cross-extension tabs.create, app load() path; sleep/wake + Reload; relaunch round-trip through the session DB with contexts reloaded; positive controls (tabs.create/options tab sleeps, wakes and loads). Confirm failing on old code. Run ExtensionPage*, NavigationFailureURLTests, MoveTabToSpace etc.
6. Check TASK-372's parked patch on top (probe B).
7. /verify through the endpoint with a fixture extension + loopback page; wiki (extension-pages, error-pages), log; commit on lane-b.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (2026-11-16, lane-b):
- Core rule (Chosen by Claude, not yet confirmed by the user): tab.url never names a webkit-extension:// page its current web view cannot serve. BrowserTab.servedExtensionOriginHost = origin host of the context whose configuration built the web view (set by wake from wakeConfiguration's pick, and by TabStore.addExtensionTab(in:url:context:), which now takes the context instead of a configuration; cleared on release). BrowserTab.mayAdopt gates every url write while a web view exists: URL observer, load(_:), showErrorPage, init(webView:), restoreArchivedPage. Sleeping writes (restore, records, tiles, retarget) stay trusted: they derive from url. currentPageURL (web view URL if adoptable, else url) replaces webView?.url ?? url in showsExtensionPage, Profile.retargetExtensionPages and existingOptionsPageTab, so a refused provisional URL lingering in webView.url is never rehomed.
- No new column: the existing extensionID column is stamped from url, so with url clean it is the provenance; a refused page saves with no id and is not rehomed at relaunch. Rows saved before the fix that hold a refused URL are grandfathered (cannot be told apart).
- What the tab shows instead (Chosen by Claude): the error page still names the refused URL, Reload retries it (lastAttemptedURL) and is refused again; url stays on the previous page, nil for a window.open child.
- Rejected: a provenance flag checked at wake and persisted (would need plumbing through closed-tab records, undo snapshots, pinned entries, favourites, Move to Space); reading _requiredWebExtensionBaseURL SPI from webView.configuration.
- Audit: no pasteboard/drag path creates a pinned entry or favourite from a URL (pinURL / addFavoriteFromEntry only convert existing tiles); peeks are always built from the space configuration; split-copy and duplicate paths load into space configurations, so they are gated by load(_:).
- Also found: another extension's URL passed to tabs.create (built from the caller's configuration) laundered the same way on the old code (init(webView:) seeded url from the provisional URL). An addExtensionTab tab has a plain WKWebView without the browser-error handler, so a refused load there shows a blank page (pre-existing).
- Tests: new ExtensionPageProvenanceTests (7): window.open child, a page-chosen URL the app loads (load path), a page navigating itself (script + link), another extension's tabs.create, relaunch round trip through an in-memory session DB with the context reloaded, and two positive controls (own options tab sleeps/wakes/reloads; navigation within the extension keeps its origin). With mayAdopt forced to true (the old behaviour) 4 fail (window.open, load, tabs.create, relaunch: 23 assertion failures, incl. 'Reload after the wake loaded the extension page'); the self-navigation test passes on the old code too (WebKit reverts webView.url), kept as a guard for TASK-372's fix. 7/7 pass with the fix.
- TASK-372 parked patch on top (applied with fuzz, then reverted): probes A and B end on the error page after sleep/wake/Reload (title stays the URL, url stays the previous page or nil); the patch's five tests then fail only on their tab.url == refused-URL assertion, which must become 'unchanged'. So the patch becomes safe on top of this fix once those assertions are adjusted.

Verification (2026-11-16):
- Tests: ExtensionPageProvenanceTests 7/7 (4 fail with mayAdopt forced true = old behaviour). Affected suites (33 classes: ExtensionPage*, ExtensionPolyfillIntegration/ProfileWiring, WKExtensionIntegration, MoveTabToSpace, PageOpenedWindow, NavigationFailureURL, BrowserTabWake, BrowserTabUnclaimedNavigation, CommittedLoadFailure, ExtensionOptionsPageEntry, ExtensionUpdater, ExtensionEnabledState, InternalPage*, SplitOpening, TabRecordFactory, AppDatabase, WebKitDelegateReachability, ...): 559 tests, 0 failures, 13 skipped (env-gated). After the review fixes: peek suites (ClosedPeek, FavoritePeekPersistence, PeekAnchor, PeekHistory, PeekState, PeekWindowCommands, RecentTabSwitcherPeek) + Provenance, MoveTabToSpace, ExtensionPageRehost/Persistence/Undo, HistoryTitleUpdate: 185 tests, 0 failures.
- Runtime (/verify through the endpoint, DetourVerify-381, build of this tree): docs/harness/task381-endpoint-checks.py 9/9 — fixture extension installed; its own options tab loads 'Opts'; a loopback page's trusted click on a window.open(options.html) button opens a child on the error page naming options.html with url nil; Cmd+R refused again; after Cmd+Q the session DB row of the child has url NULL and extensionID NULL while the options tab keeps its id; after relaunch the child, selected and reloaded, still shows the error page (screenshot checked) and the options tab is restored on the new origin and loads 'Opts'. Not exercised at runtime: sleep (no endpoint tool; covered by tests), a context reload/rehome.
- /code-review medium --fix: 8 findings. Fixed by the review: a peek's saved and moved URL (savePeekStateForPersistence, planMove) now use the gated currentPageURL; init(webView:) sets titledURL from the adopted url. Left: (1) records saved before the fix holding a refused URL are grandfathered (cannot be told apart; follow-up candidate); (2) a tab built from extension A's configuration that navigates to a web page keeps that configuration, so the web page can navigate it to A's non-web-accessible pages live (WebKit serves them; pre-existing, separate hole, follow-up candidate); (3) tabs.update from an extension to its own page in a web tab, and an extension page's own window.open of its own page, stay refused and no longer start working after a sleep (was refused live before too; typed webkit-extension:// input is a search, not a load); (6) context.webViewConfiguration built twice per addExtensionTab call (cost only); (8) addExtensionTab repeats addTab(in:webView:)'s two lines.

Follow-up checks (2026-11-16, after the review fixes): runtime check rerun on a rebuild of the post-review tree (dylib 03:10:32), 9/9 again (the first 9/9 run was on the pre-review build). Quick Detour/quarantine suites (15 classes incl. QuickDetourExtensionTests): 277 tests, 0 failures. Peek URLs: recordClosedPeek and the reopen paths take peek.url (gated); the open-time host.peekURL only ever rebuilds a Peek from the space configuration (refused again), and a Peek becomes a tab only through its live web view (init(webView:), gated), so no peek URL reaches makeTab(loading:)/restoredTab ungated. Wiki: the TASK-352 table row 'tab.url keeps the extension URL' corrected (now nil, from the code, not re-measured); the 'extension-config tab steered by a web page' claim labelled as read from WebKit source. 'Old behaviour' in the tests = mayAdopt forced to true, not a checkout of dc0fafa6.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A page-chosen webkit-extension:// URL that WebKit refuses no longer becomes the tab's url, so sleep/wake, Reload and a relaunch can no longer build it into the extension's configuration. BrowserTab tracks the origin host of the extension context its web view was built from (servedExtensionOriginHost, set by wake and TabStore.addExtensionTab(in:url:context:)) and gates every url write on a live tab (mayAdopt); readers that act on the live URL (rehoming, options-page lookup, peek save/move) use the gated currentPageURL. The existing extensionID column stays the persisted provenance. Closes the window.open hole (probe A), a page-chosen URL the app loads, another extension's URL via tabs.create, and the relaunch path; makes TASK-372's parked fix safe on top (its tests' tab.url assertions must become 'unchanged'). Chosen by Claude: the error page still names the refused URL and Reload retries it; url stays on the previous page (nil for a window.open child). Tests: new ExtensionPageProvenanceTests (7; 4 fail on the old behaviour), 559 + 185 affected tests pass; runtime check 9/9 through the endpoint. Follow-ups for the lead: rows saved before the fix are grandfathered; an extension-config tab that navigates to a web page can be steered to the extension's private pages live (pre-existing); tabs.update/window.open of an extension's own page in a web tab stays refused.
<!-- SECTION:FINAL_SUMMARY:END -->
