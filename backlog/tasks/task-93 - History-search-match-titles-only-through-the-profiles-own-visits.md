---
id: TASK-93
title: 'History search: match titles only through the profile''s own visits'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-20 03:10'
updated_date: '2026-09-20 03:41'
labels: []
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
  - DetourTests/HistoryDatabaseTests.swift
priority: medium
ordinal: 93000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
History-page search (HistoryDatabase.searchVisits) matches through historySearch, an FTS index over historyURL(url, title). historyURL.title is one row per URL shared by every profile (the latest known title), so a query can match a URL through a title only ANOTHER profile's visit gave it (e.g. work profile's '(3) Inbox - you@work' making the URL findable in the personal profile). The row shows the profile's own title, but the match itself reveals the other profile's title text. Fix without a per-visit FTS index (no browser has one): keep FTS as the candidate generator and let a visit stand for a match only if the visit itself matches - by URL (FTS url column), or by carrying the matched URL-level title. Out of scope: the command palette / suggestions path (searchHistory, per-space, returns HistoryURL with the shared title) and chrome.history.search (global by design).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A URL whose URL-level title was set by an out-of-scope (other profile) visit is NOT returned for a query that only matches that title; the profile whose visit carries the title still finds it
- [x] #2 A query matching the URL text still returns the row in every profile that visited it, showing that profile's own visit title
- [x] #3 Visits recorded before per-visit titles (NULL title) keep matching through the URL-level title they already display
- [x] #4 Range filtering, keyset paging and URL-mode delete behave as before; existing HistoryDatabase and bridge tests pass unchanged
- [x] #5 Unit tests in HistoryDatabaseTests cover: cross-profile title (negative + positive), URL-column match across profiles, representative = latest matching visit, NULL-title legacy visit, title match combined with a range
- [x] #6 A search row is represented by the latest in-scope, in-range visit that itself matches: by URL text (FTS url column), or by its OWN title (legacy NULL-title visits: the URL-level title they display); a title-matched row always displays a matching title, and titles a page used to have are searchable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Final design (after two revisions): searchVisits qualifies a VISIT: in scope, in window, AND (v.urlID IN FTS 'url : (t1* OR ...)' OR ((title LIKE '%tok%' [OR ...] OR title GLOB '*[^ -~]*') AND history_title_matches(title, tokens))), title = COALESCE(v.title, h.title). history_title_matches is a GRDB DatabaseFunction over a pure Swift matcher reproducing the FTS semantics (case/diacritic folding, alphanumeric tokens, prefix terms, OR). ROW_NUMBER picks the latest qualifying visit. No schema change. Steps: Opus implemented, Fable reviewed + runtime check.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Revision history. v1 (title match = visit title EQUALS the matched URL-level title) was implemented and rejected: once another profile retitles a shared URL, this profile can no longer find its own 'Inbox' by title - worse than the leak. v2 matches the visit's OWN title by scan: correct but 380 ms on 50k visits (Debug) vs 8 ms before, all of it the per-row Swift function. v3 adds the LIKE/GLOB prefilter (strict superset of the matcher: for printable-ASCII titles folding is ASCII lowercasing and token-prefix implies substring; any other title bypasses LIKE through the GLOB term), a query-token cache and an allocation-free ASCII path: hit 40 ms, miss 18 ms, URL token 20 ms; worst case (every title non-ASCII, e.g. Cyrillic/CJK/accented profiles) 220 ms. Accepted because the bridge runs the query on a global queue and the page debounces input; the fallback if it ever bites is the per-visit FTS index (TASK-91 decision D). Deliberate test change: testAPreviousVisitTitleIsNotSearchable became ...IsSearchable (the limitation it pinned is lifted). testSearchVisitsAgreesWithTheMatcherOverANastyCorpus (42 titles x 32 queries) guards the superset property. Function registered in both initializers (prepareDatabase for the shared queue; directly on an injected queue). Validation: full suite 1427 tests, 4 skipped, 0 failures; runtime check in the real app (production registration path, which no test covers): title-only word 'ten' finds 'Ten days wiki' under Last 30 days, nothing under Last 7 days, survives reload. Palette twin filed as TASK-94 (stays space-scoped).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
History-page search no longer matches a URL through a title only another profile's visit gave it. URL text still uses the FTS index (url column only); titles are matched against each in-scope visit's own title by a SQL function behind a built-in LIKE/GLOB prefilter. Side effects: earlier titles of a page are searchable and a title-matched row always shows a matching title. No schema change. Verified by 1427 passing tests and a runtime check of the production path; search cost on 50k visits is 18-40 ms (220 ms worst case for all-non-ASCII titles, off the main thread and debounced).
<!-- SECTION:FINAL_SUMMARY:END -->
