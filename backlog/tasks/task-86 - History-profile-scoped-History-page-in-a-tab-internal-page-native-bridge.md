---
id: TASK-86
title: 'History: profile-scoped History page in a tab (internal page + native bridge)'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-19 16:50'
updated_date: '2026-09-19 19:39'
labels: []
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
  - Detour/Browser/Window/ErrorSchemeHandler.swift
  - Detour/Browser/BrowserTab.swift
  - Detour/Browser/TabStore.swift
priority: medium
ordinal: 86000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The browser has no History view. Add one as an internal web page shown in a normal tab (the Safari/Chrome model), so it inherits everything tabs already do (WebView ownership/snapshots, sleep/wake, splits, session restore by URL).

Scope is the PROFILE of the space the tab lives in: the page lists visits from every space that currently uses that profile, and opening an entry opens it in the tab's own space (hence the same profile).

Context found during analysis:
- There is no internal-page infrastructure today. The only internal page is browser-error:// (ErrorSchemeHandler): static HTML, no page-to-native bridge. This task adds an internal scheme (WKURLSchemeHandler, registered where BrowserTab/TabStore register the error + favicon handlers) plus a WKScriptMessageHandler(WithReply) bridge for querying and opening.
- The bridge is a privileged surface. It must answer only for the main frame of a document whose URL is on the internal scheme; web content, iframes, and extensions (content scripts, extension pages, tabs.update/tabs.create to the internal URL) must not be able to reach or drive it. Web pages must not be able to navigate to or embed the internal scheme. All history strings (titles, URLs) are attacker-controlled: render via textContent / escaped, never innerHTML, and ship a restrictive CSP on the page.
- historyVisit is keyed by spaceID; profileID lives on SpaceRecord in the separate session database, so no SQL JOIN. Scope with the profile's space IDs from TabStore: WHERE v.spaceID IN (...). Visits of deleted spaces are intentionally not shown (they age out via the 90-day expiry).
- historyURL is one global row per URL: its title/visitCount/lastVisitTime aggregate across ALL profiles. The page must derive visit times (and any counts) from historyVisit rows in scope, never from those aggregates, or it leaks cross-profile activity. Title is per-URL (no per-visit title) - acceptable.
- Existing FTS5 search (searchHistory / searchHistoryGlobal) is per-space or global; a profile-scoped, paginated variant is needed.
- Favicons: FaviconSchemeHandler already serves favicons by page URL; check whether the internal page can use it.

Deletion is out of scope here (follow-up task).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 History menu item with Cmd+Y opens the History page in a new tab in the window's active space; if that space already has a History tab it is selected instead
- [x] #2 The page lists visits grouped by day, newest first, showing favicon, title, host/URL and time, and loads older entries incrementally (no unbounded query or DOM)
- [x] #3 Only visits from spaces that currently use the tab's profile are shown; times/counts come from in-scope historyVisit rows, never from historyURL aggregates (test: two profiles visiting the same URL do not see each other's visit times)
- [x] #4 A search field filters by title/URL via FTS, scoped to the same profile
- [x] #5 Clicking an entry navigates in the current tab's space; Cmd-click / middle-click opens a new tab in that same space
- [x] #6 The bridge replies only to the main frame of an internal-scheme document; tests cover the negative cases: a web page, an iframe, and an extension context cannot call it, and web content cannot navigate to or embed the internal URL
- [x] #7 History strings are rendered as text (no HTML injection from titles/URLs) and the page ships a restrictive CSP; covered by a test with a hostile title
- [x] #8 The History page itself is never recorded as a visit, shows a sensible title/icon in the sidebar and a readable faux address bar, and survives sleep/wake and session restore
- [x] #9 In an incognito space the page shows an explanatory empty state (incognito records nothing) rather than another profile's history
- [x] #10 The page reflects new visits on reload or refocus (live push not required)
- [x] #11 Unit tests cover the profile-scoped, paginated and search queries in HistoryDatabase
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design decisions (security core - Fable):
A. Scheme: detour://history (InternalPage enum: scheme, page parsing, URL building). Registered on every tab config in BrowserTab.makeWebView next to the error scheme. Resources are Swift string literals (no bundled web resources in this project).
B. Trusted navigation = explicit arming, never load(url). BrowserTab.loadInternalPage(_:) (and wake() when the persisted url is internal) arms the tab; plain load(url) - the entry point shared by extensions' tabs.create/update, Cmd+click, links from other apps - never arms. A pure InternalPageNavigationPolicy decides: internal URL allowed only in the main frame of an existing frame (nil targetFrame = new window -> deny) AND (armed page matches OR navigationType is backForward/reload). Used by BOTH navigation delegates (BrowserTab's unclaimed-tab delegate currently allows everything, BrowserWindowController's would otherwise hand the URL to the external-app prompt).
C. Scheme handler defence in depth: serves only when request.mainDocumentURL is itself internal (no iframes / subresource loads from web pages); sends CSP default-src 'none' with NO script-src, style-src/img-src limited to the internal scheme, no-referrer, nosniff.
D. Bridge lives in a private WKContentWorld: the page's app JS is a main-frame-only WKUserScript in that world that returns immediately unless location is the internal page; the WKScriptMessageHandlerWithReply is registered in that world only. Page-world JS (web pages, and anything injected into the history document) and extension content-script worlds cannot see the handler at all; the document itself runs zero page-world script (CSP). Handler still verifies the sender: main frame, frameInfo security origin + webView.url on the internal scheme, webView belongs to a known BrowserTab. Installation is guarded (adding a handler name twice throws; window.open children share the opener's userContentController).
E. The bridge API carries no scope identifiers: native derives space -> profile -> space IDs from the sending tab. Query-only in this task: history.query {search?, cursor?, limit<=200} -> {entries, nextCursor, incognito}. No 'open' message: entries are plain <a href> (http/https only), so click / Cmd-click / middle-click reuse the normal link policy and open in the tab's space.
F. Favicons served by the internal scheme handler (detour://history/favicon?pageUrl=), reusing FaviconSchemeHandler's loading; the detour-favicon extension permission gate is not loosened.

Steps:
1. (Opus, worktree, parallel) HistoryDatabase: profile-scoped keyset-paginated visit query + FTS search variant over a spaceID set, deriving time from in-scope historyVisit rows; unit tests incl. cross-profile isolation.
2. (Fable) InternalPage + navigation policy + scheme handler + content-world bridge + BrowserTab arming + both delegates; pure-function tests for the policy.
3. (Opus) Page HTML/CSS/JS (day grouping, incremental load, search, refocus refresh, incognito empty state, textContent-only rendering); History menu item + Cmd+Y with select-existing; tab title/icon/faux address bar for internal pages; command-palette typed detour://history; sleep/wake + session restore.
4. (Opus, reviewed by Fable) WKWebView integration tests: negative bridge cases (web page, iframe, page-world script, extension context), web content cannot navigate to / embed the internal URL, hostile title.
5. Runtime verification via the verify skill; /code-review; finalize.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Steps 1-2 landed on task-86-history-page: profile-scoped keyset queries + h3 (spaceID, visitTime) index; InternalPage/policy/scheme handler/content-world bridge/arming with InternalPageTests. Spike-verified: content-world user script runs under default-src 'none', handler invisible to page world, mainDocumentURL distinguishes embedded loads, session restore = .backForward, app load() is indistinguishable from script navigation in decidePolicy (hence arming). xcodegen/xcodebuild need the sandbox off.

Steps 3-4 landed on task-86-history-page (308602f, 9e93c2f, 36e3b6b): page document/CSS/script + detour://history/favicon route backed by the new shared FaviconPNGLoader (factored out of FaviconSchemeHandler, cache re-keyed by resolved favicon URL); Show All History (Cmd+Y) in the Navigate menu + TabStore.addTab(in:internalPage:); AddressInputClassifier + palette route typed detour://history through loadInternalPage; tab title/icon/faux address bar from InternalPage; BrowserTab's rebuild-from-URL init and Duplicate Tab now arm internal URLs (Reopen Closed Tab / Undo Delete Space / dormant pinned entry or favourite would otherwise be blank). New DetourTests/InternalPageIntegrationTests (12 real-WKWebView tests) plus a HistoryPageBridge.database seam. Favicons: Detour persists no favicon bytes anywhere, so a row's icon is a network fetch of the stored faviconURL — limited to rendered rows via loading=lazy and deduped per favicon URL. Full suite: 1270 tests, 4 skipped, 0 failures.

Review pass (ba10684): arming made single-use and back/forward/reload restricted to real session entries (a clicked entry could 302 back to detour://history/?q=...); wake arms only its own plain load; loadRecordedURL for favourite home / reload retry / rebuilds (keeps ?q=; error-page failedURL stays untrusted); extensions' tabs.create/update + popup open-URL refuse detour:// with an error; refresh no longer abandons an in-flight load-more; favicon loader passthrough + negative cache. Validation: full suite TEST SUCCEEDED; isolated-instance runtime run: open, 100->200 rows on scroll, search scoped to profile, hostile title inert, second Cmd+Y action selects existing tab, web->detour navigation refused, back returns to History, quit/relaunch restores (incl. ?q=), reload works, page never recorded. NOT hand-verified: physical Cmd+Y keystroke, click/Cmd-click/middle-click on a row (AC #5 - rides the existing link policy, no new code), dark mode, split pane / second-window snapshot, real favicons, incognito empty state in the app (covered by an integration test). Negative favicon results are cached for the session, including transient network failures.

AC #5 (click / Cmd-click rows) and the remaining hands-on items were covered by the user's own review of the running app on 2026-09-19; closed at their request. Follow-ups: TASK-87 (deletion), TASK-88 (stale titles after SPA navigation, found during that review).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
History page at detour://history/ in a normal tab, scoped to the tab's profile (visits of every space using it, times from in-scope historyVisit rows only). New internal-page infrastructure: tabs reach the scheme only via BrowserTab.loadInternalPage / loadRecordedURL (single-use arming; load(_:) refuses it; both navigation delegates + createWebViewWith enforce InternalPageNavigationPolicy), the scheme handler serves only internal main documents under a CSP with no script source, and the page script + query-only bridge live in a private WKContentWorld with per-message sender verification and natively derived scope. Keyset-paginated queries + h3 (spaceID, visitTime) index. Show All History (Cmd+Y) in the Navigate menu; detour://history typed in the palette; title/icon/address bar; survives sleep/wake, relaunch and tab rebuilds. Verified by InternalPageTests, InternalPageIntegrationTests, HistoryDatabaseTests, the full suite, and an isolated runtime run. Deletion is TASK-87.
<!-- SECTION:FINAL_SUMMARY:END -->
