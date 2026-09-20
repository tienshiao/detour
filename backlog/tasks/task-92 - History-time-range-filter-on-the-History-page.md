---
id: TASK-92
title: 'History: time-range filter on the History page'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-20 00:54'
updated_date: '2026-09-20 01:36'
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
- [x] #1 A range control on the page offers All time, Today, Yesterday, Last 7 days, Last 30 days and a specific day (date picker limited to the 90-day retention window); choosing one reloads the list to visits inside that range, newest first, with paging still working
- [x] #2 The range combines with search: a search result row is represented by the URL's latest in-scope visit INSIDE the range, and URLs with no in-range visit do not appear
- [x] #3 Range bounds are computed natively (local calendar, half-open [start, end)) by a pure, unit-tested type; malformed or unknown ranges are rejected as malformed, and an out-of-window day yields an empty list rather than an error
- [x] #4 The selected range is kept in the page URL alongside ?q= so reload and session restore come back to the same view; an invalid value in the URL falls back to All time
- [x] #5 Deleting a search-mode row while a range is active deletes only that URL's in-scope visits inside the range (what the row stands for); list-mode deletes and Clear History are unchanged
- [x] #6 The empty state names the period when a range is active and nothing matches; incognito hides the control
- [x] #7 Unit tests cover the HistoryDatabase range parameters (list + search + ranged URL delete, boundaries, cursor paging) and integration tests cover the bridge (valid, malformed, cross-profile isolation unchanged)
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Committed on task-92-history-range-filter (e9355a2 + 2acca1f); NOT merged. Deviations from the first plan, after /code-review: (1) one window per listing - the query reply reports window {from, until}, the page echoes it on load-more and on URL-mode deletes (delete takes 'window', no 'range'); page-supplied instants are acceptable because scope stays native and a window can only narrow a read or a delete fan-out (history.clear still computes its cutoff natively). (2) Days resolve in a Gregorian calendar with the user's time zone. (3) applyDeletion/deletedURLs are keyed by window so a ranged delete never hides rows of another period. (4) 'Specific day…' applies at once (last picked day, else today); an emptied field is put back. (5) No min on the date field (AC #1 wording: the 90-day expiry only runs at launch, so older days can exist; an old day lists nothing); max=today refreshed on reveal/focus. (6) Found at runtime: WebKit restores form values after the page script on reload/session restore, leaving the select out of step with the list - controls now follow state (autocomplete=off + sync on load/pageshow, test added). Validation: full suite 1418 tests, 5 skipped, 0 failures. Runtime with REAL posted input (unlocked): each preset chosen through the native popup with arrow keys + Return (counts 2/1/4/6 as seeded), ?range= in the URL, reload keeps range + query, empty state names the period, light/dark bar visuals OK. STILL OWED for AC #8 (screen re-locked): real input on the date field (arrow keys on a segment), ranged URL-mode delete checked against the DB, final light/dark pass after the review fixes. Harness saved untracked at .claude/task92-harness.patch; isolated data dir DetourVerify87 is seeded.
<!-- SECTION:NOTES:END -->
