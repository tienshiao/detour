---
id: TASK-88
title: >-
  History: a visit recorded during an in-page (SPA) navigation keeps the
  previous page's title
status: To Do
assignee: []
created_date: '2026-09-19 19:37'
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
