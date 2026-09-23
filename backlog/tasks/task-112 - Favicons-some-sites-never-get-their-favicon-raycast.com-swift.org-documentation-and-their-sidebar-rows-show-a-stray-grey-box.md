---
id: TASK-112
title: >-
  Favicons: some sites never get their favicon (raycast.com,
  swift.org/documentation) and their sidebar rows show a stray grey box
status: To Do
assignee: []
created_date: '2026-09-23 07:59'
updated_date: '2026-09-23 08:02'
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
- [ ] #1 Root cause identified for each of the two pages
- [ ] #2 Both pages show their real favicon when opened in the background and when selected
- [ ] #3 The stray grey box on rows is explained and fixed, or shown to be something else
- [ ] #4 Regression test covers the fixed path (loader format handling or late <link rel=icon>)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
More data (Sep 23 2026, 2x demo captures): the grey box also appears on docs.github.com/en (title still the URL), Reddit and youtube.com rows. Every affected row is a page that had not finished loading in its never-hosted background web view, and fetchFavicon only runs on the isLoading true->false edge. Leading hypothesis: the grey box is the row's loading state and both symptoms are 'background load never completes (or completes very late) until the tab is shown'. Check whether selecting the tab once fixes both.

Confirmed: after selecting each affected tab once (hosting it in the window), every row got its real title and favicon and the grey boxes disappeared. So both symptoms belong to background web views that never finish loading until first shown.
<!-- SECTION:NOTES:END -->
