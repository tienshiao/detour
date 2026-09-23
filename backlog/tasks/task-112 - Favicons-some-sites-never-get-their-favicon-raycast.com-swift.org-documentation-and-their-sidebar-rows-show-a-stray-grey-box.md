---
id: TASK-112
title: >-
  Favicons: some sites never get their favicon (raycast.com,
  swift.org/documentation) and their sidebar rows show a stray grey box
status: Done
assignee: []
created_date: '2026-09-23 07:59'
updated_date: '2026-09-23 21:17'
labels:
  - bug
  - favicons
dependencies: []
priority: low
ordinal: 112000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen while staging website screenshots (TASK-110, isolated DetourDemo profile, Sep 23 2026). Tabs opened with store.addTab in the background (not selected) and left to load for 12-20 s:
- https://www.raycast.com — row shows the generic globe. /favicon.ico is a 404; the page declares <link rel="icon" href="/favicon-production.png"> (200, image/png), so the post-load lookup in BrowserTab.fetchFavicon should have found it.
- https://www.swift.org/documentation/ (title 'Documentation') — globe as well, although https://www.swift.org/favicon.ico answers 200. The raw HTML has no <link rel=icon> (curl), so only the optimistic /favicon.ico path applies here, and it still failed.
In the same captures, those two rows (and only those) had a grey rounded box behind the start of the row (roughly the favicon + first part of the title), in both 1x and 2x captures, with no pointer over the sidebar. Other pages seeded the same way (figma.com, linkedin.com, github.com, wikipedia, apple.com, ...) got their icons.
Code: BrowserTab favicon pipeline — optimistic <scheme>://<host>/favicon.ico on the first URL per host, then fetchFavicon() on the isLoading true->false edge querying link[rel~='icon']; FaviconLoader.shared.load. Hypotheses to check: FaviconLoader rejects the swift.org .ico (format/size/redirect?) or the raycast PNG; the isLoading edge fires before a client-rendered <link rel=icon> exists (Next.js head) or is missed for a never-hosted background web view; the grey box may be the favicon placeholder/sleep badge or a hover/selection layer left on rows without an icon.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Root cause identified for each of the two pages
- [x] #2 Both pages show their real favicon when opened in the background and when selected
- [x] #3 The stray grey box on rows is explained and fixed, or shown to be something else
- [x] #4 Regression test covers the fixed path (loader format handling or late <link rel=icon>)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
More data (Sep 23 2026, 2x demo captures): the grey box also appears on docs.github.com/en (title still the URL), Reddit and youtube.com rows. Every affected row is a page that had not finished loading in its never-hosted background web view, and fetchFavicon only runs on the isLoading true->false edge. Leading hypothesis: the grey box is the row's loading state and both symptoms are 'background load never completes (or completes very late) until the tab is shown'. Check whether selecting the tab once fixes both.

Confirmed: after selecting each affected tab once (hosting it in the window), every row got its real title and favicon and the grey boxes disappeared. So both symptoms belong to background web views that never finish loading until first shown.

Investigation Sep 23 2026 (standalone swiftc spike, /tmp/claude-501/fav/main.swift: plain WKWebView, frame .zero, never in a window):
- Both pages finish loading in <2 s unparented (visibilityState 'hidden'), and the link[rel~=icon] lookup finds https://www.raycast.com/favicon-production.png and https://docs.swift.org/latest/favicon.ico. So WebKit itself does not stall never-hosted web views; the stall comes from something Detour-specific (config: extension controller/content scripts, content rule lists, data store, BrowserWebView, UA) or from opening many tabs at once. Not reproduced inside Detour yet.
- FaviconLoader is not the problem: swift.org's .ico decodes (64x64), and raycast's PNG is a valid 1024x1024 PNG.
- swift.org root cause: www.swift.org/documentation/ is a JS 'Redirecting…' page that sends you to docs.swift.org (another host). The optimistic www.swift.org/favicon.ico succeeds, then the URL observer sees the host change, clears the favicon and tries docs.swift.org/favicon.ico, which returns 404. The real icon is only reachable through the <link rel=icon> lookup, which runs when loading finishes.
- raycast root cause: /favicon.ico returns 404, so the icon also depends only on the lookup when loading finishes.
- Grey box = TabCellView's progress-bar loading indicator (loadingMode = .progressBar), drawn for rows still isLoading. Not a stray layer.
Next: reproduce in Detour (DEBUG harness) with the same seeding and log isLoading/estimatedProgress per background tab, then remove config pieces one at a time (extensions off, content blocker off). Possible hardening whatever the cause: also run fetchFavicon on didFinish of the main document / DOMContentLoaded (or on a title change) rather than only when isLoading goes false.

Step 1 results (Sep 23 2026):
- Reproduced inside Detour with an env-gated probe (store.addTab x10 in the background, DetourDemo profile copy, state logged every second for 30 s). Stuck at 30 s: raycast (readyState interactive, load never fired), docs.swift.org (DOMContentLoaded only at 30.1 s), youtube and reddit (readyState loading; reddit sat on a js_challenge URL). Every stuck page already had its <link rel=icon> in the DOM, so only the isLoading true->false gate kept the favicon off the row.
- Not specific to Detour. The plain swiftc spike (no extensions, no content blocker, default config) with the same 10 URLs opened together also leaves pages stuck: run 1 swift.org, reddit and youtube; later runs youtube in 5 of 6. With only 2 pages open, both finish in under 2 s (youtube in 1.7 s). Which pages stall varies from run to run; it happens when many hidden pages load at once.
- Hosting the web views doesn't help. The spike's no-window, off-screen-window and hidden-view-in-an-on-screen-window modes all report visibilityState 'hidden' and all leave youtube stuck. Keeping background tabs in a window (the way Safari does) is not a fix; only actually showing the tab (the selected tab, or visitall) unblocks it.
- Conclusion: a background load that stalls is WebKit behaviour for hidden pages and not a Detour bug. The fix belongs in Detour's favicon pipeline: find the icon without waiting for isLoading to go false (e.g. DOMContentLoaded or a <link rel=icon> mutation via a user script message, or a retry after commit). The progress bar is truthful (the page really is still loading); whether background rows should show it is a separate product call.

Fix (Sep 23 2026, uncommitted): new Detour/Browser/Shared/FaviconLinkBridge.swift. It adds a user script in a private WKContentWorld, injected at document start in the main frame only. A MutationObserver on the whole document reports <link rel=icon> hrefs (the same selector as fetchFavicon, now shared) as soon as the parser or a script inserts or changes one. A shared handler routes each report through a weak web-view-to-tab table (registered next to ExtensionPageHostRegistry) to BrowserTab.pageDidReportFaviconLink. That method ignores reports from an origin other than the page being shown, error pages and internal pages, and downloads under the current generation. The end-of-load fetchFavicon stays as a fallback. The /code-review --fix pass added declaredFaviconGeneration so an optimistic /favicon.ico that finishes late cannot replace the declared icon (the early report makes the two race), and switched the node test to localName for XHTML.
Tests: DetourTests/FaviconLinkBridgeTests (5). A stall:// scheme handler holds one image open, so the load never ends. Covered: an icon that arrives while loading, a link added by script, a changed href, a late optimistic guess, and the origin guard. With the bridge disabled, the 3 behaviour tests fail. The FavoriteFavicon, InternalPage(Integration), BrowserTabWake, HistoryDeletion, ExtensionPolyfill* and ExtensionPageRehost suites pass.
In-app check: probe build, 10 background tabs on a copy of DetourDemo. At t=3 s every tab has its real favicon, including raycast (favicon-production.png), docs.swift.org (latest/favicon.ico) and youtube, which were still loading. AC #3: the grey box is TabCellView's progress bar on rows that are still loading. It is truthful and left as is; whether background rows should show it is a separate product call.
<!-- SECTION:NOTES:END -->
