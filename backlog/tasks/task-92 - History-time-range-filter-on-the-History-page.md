---
id: TASK-92
title: 'History: time-range filter on the History page'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-20 00:54'
updated_date: '2026-09-20 00:54'
labels: []
dependencies: []
references:
  - Detour/Browser/InternalPages/HistoryPageContent.swift
  - Detour/Browser/InternalPages/HistoryPageBridge.swift
  - Detour/Storage/HistoryDatabase.swift
priority: medium
ordinal: 92000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The History page (detour://history/) can only be narrowed by text search. Add a time-range filter next to the search field so the user can look at a period (today, yesterday, last 7 days, last 30 days, or one specific day) on its own or combined with a search. Scope rules from TASK-86/87 stand: the page never names a profile or space, and range bounds are computed natively from a symbolic range the page sends (never page-supplied timestamps).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A range control on the page offers All time, Today, Yesterday, Last 7 days, Last 30 days and a specific day (date picker limited to the 90-day retention window); choosing one reloads the list to visits inside that range, newest first, with paging still working
- [ ] #2 The range combines with search: a search result row is represented by the URL's latest in-scope visit INSIDE the range, and URLs with no in-range visit do not appear
- [ ] #3 Range bounds are computed natively (local calendar, half-open [start, end)) by a pure, unit-tested type; malformed or unknown ranges are rejected as malformed, and an out-of-window day yields an empty list rather than an error
- [ ] #4 The selected range is kept in the page URL alongside ?q= so reload and session restore come back to the same view; an invalid value in the URL falls back to All time
- [ ] #5 Deleting a search-mode row while a range is active deletes only that URL's in-scope visits inside the range (what the row stands for); list-mode deletes and Clear History are unchanged
- [ ] #6 The empty state names the period when a range is active and nothing matches; incognito hides the control
- [ ] #7 Unit tests cover the HistoryDatabase range parameters (list + search + ranged URL delete, boundaries, cursor paging) and integration tests cover the bridge (valid, malformed, cross-profile isolation unchanged)
- [ ] #8 Runtime pass with real input events in light and dark: picking each preset, a specific day, range + search, URL round-trip after reload
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design (Fable):
A. Wire format: history.query and history.delete take an optional 'range' param: {preset:'today'|'yesterday'|'week'|'month'} or {day:'YYYY-MM-DD'}; absent = all time. Anything else present = 'malformed'. The page never sends timestamps.
B. Pure type HistoryTimeRange (Detour/Browser/InternalPages/HistoryTimeRange.swift): init?(bridgeValue: Any?) + bounds(now:calendar:) -> (from: Double, until: Double?) half-open. today=[startOfDay, nil); yesterday=[startOfDay-1d, startOfDay); week=[startOfDay-6d, nil); month=[startOfDay-29d, nil); day=[startOfDay(day), +1 calendar day). Day arithmetic via Calendar.date(byAdding:) (DST-safe), never 86400. Day parsed strictly (yyyy-MM-dd, gregorian fields validated by round-trip).
C. HistoryDatabase: visits/searchVisits gain from:/until: (visitTime >= from AND visitTime < until). In searchVisits the bounds go INSIDE the inner select so ROW_NUMBER picks the latest in-range visit. deleteVisits(ids:spaceIDs:allVisitsOfURL:) gains from:/until: applied only to the allVisitsOfURL expansion (named ids are always deleted as before).
D. Bridge: parse range for query; for delete, range honoured only with allVisitsOfURL. Bounds computed per request (day-aligned, so stable across pages of one listing).
E. Page: <select id=range> in the bar (All time/Today/Yesterday/Last 7 days/Last 30 days/Specific day…) + <input type=date id=day hidden> with min=today-90d max=today. state.range captured per request like state.query; rows remember the range they were rendered under (dataset) so a URL-mode delete sends the range the row was read in. URL state ?q=&range=week | &day=YYYY-MM-DD. Empty state 'No history from <period>'. Hidden for incognito. No inline styles/scripts, textContent only.
Steps: 1 (Opus) implement B-E + tests. 2 (Fable) review, /code-review, real-input runtime pass light/dark. 3 merge.
<!-- SECTION:PLAN:END -->
