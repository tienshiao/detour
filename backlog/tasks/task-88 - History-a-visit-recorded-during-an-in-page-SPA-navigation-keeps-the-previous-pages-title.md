---
id: TASK-88
title: >-
  History: a visit recorded during an in-page (SPA) navigation keeps the
  previous page's title
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-19 19:37'
updated_date: '2026-09-19 20:03'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Storage/HistoryDatabase.swift
  - Detour/Browser/BrowserTab.swift
priority: medium
ordinal: 88000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found via the History page (TASK-86), but the bug is in recording and predates it (the command palette reads the same titles).

Symptom: the user's History showed '(211) i baked for my neighbor :) - YouTube' dozens of times across two days. Read-only check of the real history.db: all of those rows are ONE url, https://www.youtube.com/ (68 visits, Jul 10 -> Sep 19), whose stored title is a video's title. The visits are real; the title is stale. Not a timezone or query issue.

Cause: TabStore records a visit when tab.isLoading goes false (the $isLoading sink near the end of TabStore.swift -> recordHistoryVisit), using tab.url and tab.title at that instant. On a single-page-app navigation (YouTube: video -> home) the URL changes and loading finishes BEFORE the site updates document.title, so the visit is written as the new URL with the previous page's title. Nothing updates it afterwards. HistoryDatabase.recordVisit upserts historyURL with title = excluded.title, and historyURL holds one title per URL, so the last (stale) write renames every visit of that URL. Other SPA-navigated pages are presumably mis-titled the same way (a video URL carrying the previous video's title).

Proposed fix (Chrome's SetPageTitle behaviour): when a tab's title changes after its visit was recorded, update the stored title of that URL - only when the tab is not loading, the title is non-empty, and tab.url is still the URL this tab last recorded (so the pending-navigation placeholder title from BrowserTab.updateTitle, or a title belonging to the next page, is never written). Needs HistoryDatabase.updateTitle(url:title:) (historySearch is an FTS5 table synchronized with historyURL, so the search index follows) and a per-tab 'last recorded URL'. Same exclusions as recording: http/https only, never incognito. Existing rows self-heal on the next visit; no data migration needed.

Out of scope: collapsing consecutive same-URL visits into one row on the History page (revisit once titles are right).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After an in-page navigation whose document.title changes after loading finishes, the history row for the new URL ends up with the new page's title, not the previous page's (test drives url change -> isLoading false -> title change)
- [ ] #2 A later title change on the same page (e.g. an unread counter '(211) YouTube' -> '(212) YouTube') updates the stored title without adding a visit or changing visitCount / lastVisitTime
- [ ] #3 A title is never written for a URL the tab did not record: not while the tab is loading, not the pending-navigation placeholder (the stripped URL), not an empty title, and not onto the previous URL after the tab has moved on (tests)
- [ ] #4 Incognito spaces and non-http(s) URLs (including detour:// internal pages) never write a title
- [ ] #5 The updated title is what FTS search returns (historySearch stays in sync) - covered by a HistoryDatabase test
- [ ] #6 Title updates are coalesced or otherwise cheap enough that a page rewriting its title repeatedly (marquee titles, counters) does not issue a database write per change
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. BrowserTab.lastRecordedHistoryURL: set by TabStore.recordHistoryVisit whenever the tab's current URL has a history row (recorded now, or skipped by the 30 s dedup).
2. HistoryDatabase.updateTitle(url:title:) - async write, UPDATE historyURL SET title WHERE url = ? AND title <> ?; never touches visitCount/lastVisitTime, adds no visit; FTS follows via the synchronized table.
3. TabStore: per-tab $title subscription (dropFirst, removeDuplicates, debounce ~1 s on the main run loop = the coalescing AC) -> updateHistoryTitle(tab). Guards, all required: tab not loading; title non-empty AND equal to webView.title (rules out BrowserTab.updateTitle's pending-navigation placeholder); tab.url == lastRecordedHistoryURL (never the previous URL, never a URL this tab did not record); http/https; space not incognito.
4. Tests: HistoryDatabase (title updated, counts/times untouched, FTS returns new title, unknown URL no-op); TabStore-level for the guards; a WKWebView test for the SPA sequence (pushState-style URL change -> load finishes -> document.title changes later).
5. Opus implements; Fable reviews; /code-review; runtime verify in an isolated instance; merge.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (uncommitted, branch task-88-history-titles):
- BrowserTab.lastRecordedHistoryURL (set only by TabStore.recordHistoryVisit, after the incognito/URL/scheme guards and *before* the 30 s dedup return, so it is set whenever the tab's URL has a historyURL row).
- HistoryDatabase.updateTitle(url:title:): fire-and-forget asyncWrite, UPDATE historyURL SET title = ? WHERE url = ? AND title <> ?. No visit row, visitCount/lastVisitTime untouched, no-op for an unknown URL; FTS follows via the synchronized historySearch table (tested).
- TabStore.updateHistoryTitle(for:) + HistoryTitleUpdatePolicy.urlToRename(...) (pure, at the end of TabStore.swift): requires space present, not incognito, not loading, non-empty title equal to webView.title (rules out the pending-navigation placeholder, an internal page's name, a restoring session's persisted title, and sleeping tabs), tab.url == lastRecordedHistoryURL, http/https.
- Per-tab subscription in subscribeToTab: tab.$title.dropFirst().removeDuplicates().debounce(for: .seconds(TabStore.historyTitleDebounce), scheduler: RunLoop.main) -> updateHistoryTitle. historyTitleDebounce is a static var (1.0 s in production, 0.05 s in tests).

Finding: a history.pushState does NOT toggle WKWebView.isLoading (probed with a real web view: url/webView.url move to the pushed URL, zero isLoading transitions). So a pure in-page navigation records no visit at all, and the fix's effect there is that the page the tab LEFT is never renamed by the next page's title. The stale-title write happens whenever something does record a visit while the URL has already moved (a load finishing after the in-page navigation, a session-restore reload, a back/forward); those rows are now corrected as soon as the document's title settles. Also observed: a visit recorded at didFinish can capture BrowserTab's stripped-URL placeholder when WebKit has not reported the title yet — the same correction repairs that a second later.

Tests: DetourTests/HistoryTitleUpdateTests.swift (15: 10 pure policy + 5 real-WKWebView/TabStore integration, incl. the pushState sequence and the recorded-then-retitled case) and 3 new HistoryDatabaseTests (title/counts/visits, unknown-URL no-op, FTS). Full suite: 1290 tests, 4 skipped, 0 failures.
<!-- SECTION:NOTES:END -->
