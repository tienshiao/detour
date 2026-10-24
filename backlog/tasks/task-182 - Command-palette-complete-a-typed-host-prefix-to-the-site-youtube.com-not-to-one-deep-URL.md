---
id: TASK-182
title: >-
  Command palette: complete a typed host prefix to the site (youtube.com), not
  to one deep URL
status: Done
assignee: []
created_date: '2026-10-24 08:03'
updated_date: '2026-10-24 08:25'
labels:
  - command-palette
  - feature
dependencies: []
priority: medium
ordinal: 204000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
With many YouTube video tabs open, typing `youtube` after Cmd+T only offers the video tabs: the top hit and inline completion take the first open tab whose display URL starts with the query (`youtube.com/watch?v=…`), so getting to https://youtube.com/ means typing the whole domain.

Firefox-style origin completion: while the query could still be a host (no whitespace, `/`, `?` or `#`), complete to the matching **host** rather than a URL. Open tabs first (their host), else the space's history ranked by host frecency (the bestURLCompletion weights, summed per host). The top-hit row opens the site root: an open tab already at the root is offered as Switch to Tab, otherwise the root URL (the space's own visit of it when there is one, for title and favicon). Up to two more matching visited hosts follow the verbatim row. Once the query has a path (`youtube.com/`) completion is URL-level as today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Typing a host prefix with only deep-URL tabs open completes the field to the host and the top row opens the site root
- [x] #2 A tab already showing the site root is offered as the top hit (Switch to Tab)
- [x] #3 History host completion ranks hosts by summed frecency, scoped to the space
- [x] #4 Other visited hosts matching the prefix appear as rows (at most two) after the verbatim row
- [x] #5 A query containing a path keeps URL-level completion
- [x] #6 The instant (tab-only) pass and SuggestionProvider share one top-hit rule
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Firefox-style origin completion: SuggestionProvider.isHostQuery decides host vs URL completion; a shared static tabTopHit (used by the view's instant pass and localSuggestions) completes to the first matching tab's host; HistoryDatabase.bestHostCompletions ranks the space's hosts by summed frecency and resolves each root; up to two more hosts as rows after the verbatim row.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: a query with no whitespace, '/', '?' or '#' completes to a host (displayHost: displayURL up to the first /?#, lowercased). Top hit order unchanged in spirit: open tabs first (first http(s) tab whose host matches; the current tab may name the host but is never switched to; a non-current tab at the root becomes Switch to Tab, otherwise the root URL as a navigating historyResult), else the best history host. When the tab-named host is also in history, the row takes the history root's title/favicon. Other hosts (max 2) follow the verbatim row, also with autocomplete off. Rejected: completing to the host only when the top URL hit is deep; adding a host row without changing the completion.

SQL: history_display_host(url) registered with the other functions; perURL CTE (frecency per URL, host) → topHosts CTE (ranked, LIMIT) → sample URL and favicon per kept host (review moved the correlated subqueries after the LIMIT); then a labelled root lookup per host over the four scheme/www variants. Frecency SQL and the four LIKE patterns factored out of bestURLCompletion (unchanged behaviour).

Found on the way: the LIKE prefix patterns never used the url index (EXPLAIN QUERY PLAN: SCAN historyURL), contrary to the code comment and the wiki; comment and wiki corrected. Benchmarks (55k visits, Debug, visits shifted into the 90-day window — the fixture's 1970 timestamps made every completion leg measure an empty result): bestURLCompletion 23 ms / bestHostCompletions 36 ms for 's', ~15 ms each for 'site13'. In host mode the host query replaces the URL query.

Code review (/code-review --fix): correlated subqueries per host before LIMIT (fixed), a host row duplicating an open-tab row at that root (fixed), two predicate simplifications.

Tests: SuggestionProviderTests 30/30 (12 new host cases; the existing two open-tab top-hit tests now type a path to keep their URL-level meaning). HistoryDatabaseTests 128, Palette* and CommandPaletteFocusTests, AddressInputClassifierTests all pass; HistoryBenchmarkTests run with TEST_RUNNER_HISTORY_BENCH=1.

Runtime (/verify): harness docs/harness/task181-182-harness.patch, three sleeping www.youtube.com/watch?v=N tabs + a typed visit to yourstore.example: Cmd+T, 'you' → field youtube.com (tube.com selected), rows: youtube.com (https://www.youtube.com/), verbatim 'you', Your Store, Video 1–3. Not verified: pixels; a real YouTube history.

Correction: SuggestionProviderTests gained 11 host cases (not 12); 30 tests in the suite.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Typing a host prefix in the command palette now completes to the site (youtube.com) instead of the first open video tab: the top row opens the site root (or switches to a tab already there), and up to two other visited hosts matching the prefix follow the verbatim row. History hosts rank by frecency summed over their pages, scoped to the space. A query with a path keeps URL-level completion. Verified with 11 new SuggestionProviderTests, benchmarks, and a runtime harness in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
