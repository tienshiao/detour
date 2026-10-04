---
id: TASK-153
title: >-
  Extensions: chrome.history.search with empty text scans every visit of the
  profile
status: Done
assignee: []
created_date: '2026-10-04 08:53'
updated_date: '2026-10-04 10:23'
labels:
  - extensions
  - performance
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
  - wiki/architecture/history-database.md
priority: medium
ordinal: 176000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Raised 2026-10-04 by the code review of TASK-138; not measured.

HistoryDatabase.searchURLs (Detour/Storage/HistoryDatabase.swift), which chrome.history.search now calls, aggregates per-URL counts and titles from the calling profile's historyVisit rows. With empty text and no startTime it runs a ROW_NUMBER() window over every in-scope visit, plus a NOT EXISTS probe per title-less visit; the query it replaced was an indexed ORDER BY lastVisitTime LIMIT. chrome.history.search({text: ''}) is a common call (new-tab pages, history sidebars). The query runs off the main thread, but history uses one serial DatabaseQueue, so the palette's synchronous main-thread reads (recent history on Cmd+T / Cmd+L) wait behind it.

Chrome defaults an omitted startTime to 24 hours ago; Detour treats it as no lower bound (unchanged by TASK-138). Adopting Chrome's default would bound the common call and is a behaviour change to decide here.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A benchmark in the HistoryBenchmarkTests style (gated by a TEST_RUNNER_ variable) measures searchURLs with empty text and with a typed query on a large history (hundreds of thousands of visits across several profiles), and the numbers are recorded in the task
- [x] #2 The omitted-startTime default is decided and recorded (keep no lower bound, or Chrome's 24 hours), with tests for the chosen rule
- [x] #3 The empty-text search stays within a stated time budget on the benchmark history, or the task records why the measured cost is acceptable
- [x] #4 A long extension history query does not block the palette's main-thread history reads for longer than a stated bound, or the task records the measured wait
- [x] #5 wiki/architecture/history-database.md and wiki/extensions/polyfill-layer.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Benchmark first (AC #1): HistoryURLSearchBenchmarkTests, gated by TEST_RUNNER_HISTORY_SEARCH_BENCH=1. A temp-file history of 300,000 visits over 40,000 URLs, three profiles (five spaces), built in batched transactions. Measures searchURLs with empty text (unbounded, last 24 h, small and large limit, big and sliver profile) and typed queries, and the wait of a palette read (recentHistory / searchHistory, as the main thread makes them) issued while an empty-text search holds the serial queue. Record the baseline before touching the query.
2. Decide the omitted-startTime default (AC #2) against Chrome's schema and history_api.cc; implement it where the extension's arguments become the range (ExtensionPolyfillHandler), with an injected clock; parser, handler and real-context tests first.
3. Empty-text path (AC #3): a failing scaling test first (VM work for a 10-row listing must not grow with the size of the scope), then a listing path that walks the scope's visits newest first and stops at maxResults distinct URLs instead of windowing over every in-scope visit; a differential test against the windowed select keeps TASK-138's rows, counts, titles and times identical. State the budget, re-run the benchmark, record before/after.
4. AC #4: record the measured palette wait before and after, and the bound that follows from the budget.
5. Wiki: architecture/history-database.md, extensions/polyfill-layer.md (not the favicon rows: TASK-152), wiki-lint --fix, log.md. API Explorer: let the history search ask for all time.
6. One commit on batch2-task-153. Code review and the runtime check happen at batch integration, not here.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Result (2026-10-04)

An omitted startTime now means the 24 hours before now (Chrome's rule), and an empty-text search walks the scope's visits newest first and stops at maxResults URLs instead of windowing over every in-scope visit. Status left In Progress: code review and the runtime check happen at batch integration, not in this stream; nothing was launched here.

## Benchmark (AC #1)

DetourTests/HistoryURLSearchBenchmarkTests, gated by TEST_RUNNER_HISTORY_SEARCH_BENCH=1 (about 50 s). Debug build, median of 5, machine under heavy load (load average 33-46, other streams building): read the numbers as orders of magnitude. Run once before the change and twice after; the two after runs agree within 10%.

History: 300,000 visits of 40,000 URLs over 90 days in a temp-file database built in 25,000-row transactions (no per-visit arrays), three profiles / five spaces: A = A1+A2 (155,327 visits, the profile measured), B = B1 (99,286), C = C1+C2 (45,387, the sliver). 12% of a URL's visits come from another profile; one URL (an inbox, A1 only) has 5,225 visits, 396 of them without a title; the oldest fifth of all visits has no title of its own (pre-TASK-91). 'all' = no lower bound, '24h' = the last day of the history.

| searchURLs, limit 100 unless stated | before, ms | after, ms |
|---|---|---|
| empty text, all, profile A | 2157 (2119-2228) | 12.7 / 11.7 |
| empty text, all, profile C | 126 | 4.9 / 4.5 |
| empty text, 24h, A | 15.1 | 12.5 / 12.3 |
| empty text, 24h, C | 6.0 | 4.9 / 4.9 |
| empty text, all, limit 1,000, A | 2165 | 59 / 62 |
| empty text, all, limit 10,000, A | 2440 | 367 / 392 |
| empty text, all, no limit (26,333 rows), A | 2648 | 776 / 777 |
| text 'site137' (URL token), all, A | 48 | 49 / 48 |
| text 'dashboard' (title word), all, A | 171 | 170 / 178 |
| text 'dashboard', 24h, A | 15.2 | 16.3 / 15.9 |
| text 'example' (every URL), all, A | 2281 | 2251 / 2254 |
| text 'example', 24h, A | 33.7 | 34.2 / 33.5 |
| text miss, all, A | 44 | 43 / 43 |
| text 'example', all, B (control, added after the change) | - | 352 |
| text 'example', all, C (control) | - | 164 |

The text path is unchanged, as intended: only the empty-text path was in scope.

## Decision (AC #2): an omitted startTime is 24 hours before now

Adopted Chrome's rule, checked against Chrome's sources rather than from memory:
- chrome/common/extensions/api/history.json, search.query.startTime: 'If property is not specified, it will default to 24 hours.'
- chrome/browser/extensions/api/history/history_api.cc, HistorySearchFunction::RunAsyncImpl: options.SetRecentDayRange(1); options.max_count = 100; then start_time, end_time and max_results each overwrite their own field when the query gives them. SetRecentDayRange(1) is end = now, begin = now - 1 day (components/history/core/browser/history_types.cc).

So in Chrome the default lower bound does not depend on text, maxResults or endTime, and an explicit startTime: 0 is the Unix epoch, i.e. all history.

As implemented in ExtensionPolyfillHandler.historySearchQuery(from:now:), the place that turns the extension's arguments into the range (clock is a parameter; handler.now is the test seam):
- startTime absent or null: now - 24 h, for empty and typed text alike, whatever maxResults and endTime say.
- startTime given: taken as given. A value <= 0 becomes 'no lower bound' rather than a bound of 0: the same rows, and the statement stays the one that was measured without a bound.
- endTime absent: still no upper bound. Chrome's is 'now'; they differ only for a visit dated in the future. Not changed.

Reasons: it is what extensions written for Chrome expect, with startTime: 0 as the documented way to ask for everything; it bounds the common call (search({text: ''}) from new-tab pages and history sidebars) to a day of visits; it is one line to undo. Behaviour change for extensions: a call that named no startTime used to get all history and now gets the last day. Rejected: keeping 'no lower bound' (differs from Chrome, and leaves the common call on the expensive range). The unbounded query still has to meet the budget on its own, because startTime: 0 reaches it.

## Empty-text path (AC #3)

Budget: an empty-text search for Chrome's default 100 results takes at most 50 ms on the benchmark history in a Debug build, whatever the range. Measured 12.7 / 11.7 ms for all history (2157 before), 12.5 / 12.3 ms for the last day. Past the default size the cost follows the rows asked for, about 30-60 us per row: 59 ms for 1,000, 367 ms for 10,000, 776 ms for all 26,333 URLs of the profile (2165 / 2440 / 2648 before). Those larger calls are outside the 50 ms budget and are recorded, not bounded.

How: HistoryDatabase.searchURLs with no text goes to listedURLEntries. newestVisitPerURL opens one cursor per space of the scope (WHERE spaceID = ? [window] ORDER BY visitTime DESC, id DESC, straight off the (spaceID, visitTime) index), merges them in Swift by (visitTime, id), keeps the first visit of each URL and stops at limit URLs. The kept visits are then described, 500 at a time, by the same outer select as the text path (urlEntriesSelect): URL, extensionTitleExpression for that visit, and the aggregates over the scope's visits of the URL. The whole thing is one read. The merge is in Swift because SQLite cannot read an index in order across spaceID IN (...).

TASK-138's guarantees: the scope filter, the window, extensionTitleExpression and the aggregate join are the same SQL as before, applied to the representative visits only. testTheListingAgreesWithTheWindowedSelect compares the listing with the windowed select (kept as windowedURLEntries, internal for this test) on 10 random histories x 3 scopes x 7 ranges x 4 limits: rows, order, counts, typed counts, times and titles equal.

Where the old cost came from (inferred from the numbers, the URL was not removed to isolate it): besides the window over 155k rows, extensionTitleExpression's NOT EXISTS probe ran for every title-less in-scope visit and walks all visits of a URL no other profile visited: 396 title-less x 5,225 visits of the inbox URL. Controls: the every-URL text query costs 352 ms in B and 164 ms in C (about 3.6 us per in-scope visit, which would be about 560 ms for A) against 2254 ms in A.

## Palette wait (AC #4)

Palette reads made from the test's main thread, space A1, issued 1 ms after an extension search started on another thread (the read's whole duration, wait included):

| read | alone | behind empty/all/limit 100 | behind empty/24h/limit 100 | behind empty/all/no limit | behind text 'example'/all |
|---|---|---|---|---|---|
| recentHistory, before | 142 | 2416 | 160 | 2849 | 2477 |
| recentHistory, after | 151 / 148 | 164 / 162 | 167 / 167 | 919 / 918 | 2399 / 2515 |
| searchHistory('a'), before | 216 | 2433 | | | |
| searchHistory('a'), after | 219 / 224 | 226 / 247 | | | |

Bound: a default-size empty-text search holds the queue for at most the 50 ms budget (measured 12-13 ms), so a palette read waits at most that much longer than its own cost; with the default range the same holds for the common call. Measured and not bounded: 919 ms behind an extension asking for the whole history in one call (startTime 0 and no limit), and about 2.4-2.5 s behind a text search over all history that matches every URL. Nothing in this task shortens those two; the structural fix would be a reader connection of its own for the main thread (history is one serial DatabaseQueue).

## Tests

Red run, seams only (historySearchQuery takes now:, searchURLs split into windowedURLEntries, no behaviour change): HistoryURLSearchTests + ExtensionHistoryScopeTests, 35 tests, 19 failures in 5 tests:
- testQueryParserAppliesChromesDefaults (1) and testQueryParserReadsAnOmittedStartTimeAsTheLastDay (7): startTime nil instead of now - 24 h; 0 and -1 kept as bounds.
- testHandlerReadsAnOmittedStartTimeAsTheLastDay (5): the visit older than a day came back (injected clock; a visit exactly 24 h old is inside, one a second older is not).
- testAnOmittedStartTimeCoversTheLastDayFromBothTransports (5): the same from an extension page and from the service worker, promise and callback form.
- testListingTheNewestURLsDoesNotWalkTheWholeScope (1): 10 rows of a 15,000-visit history took 917,030 SQLite VM steps against 94,280 for a 1,500-visit one (9.7x; the test allows 2x). Counted with sqlite3_progress_handler, so it is deterministic, not timed.
The other new listing tests (merge order across spaces, limit counts URLs not visits, order across the 500-row batches, the differential) passed against the old query, as they should: they pin what must not change.

After the change: the same two suites plus the benchmark, 36 tests, 0 failures. Then HistoryURLSearchTests 18, ExtensionHistoryScopeTests 17, HistoryDatabaseTests 128, HistoryDeletionIntegrationTests 63, HistoryTitleIndexTests 12, HistoryTimeRangeTests 18, HistoryTitleUpdateTests 26, ExtensionPolyfillTests 172, ExtensionPolyfillIntegrationTests 26, and the two gated benchmarks skipped: 482 tests, 2 skipped, 0 failures. The full suite was not run here (it runs at integration).

API Explorer: the History section has an 'All time (startTime: 0)' checkbox; unchecked, the search shows the last 24 hours.

## Not verified

- No /code-review and no /verify in this stream; the app was not launched. The API Explorer change was only syntax-checked (node --check), not clicked.
- Timings are Debug-build numbers on a loaded machine; no Release-build run.
- The last edit after the final test run was a three-line doc comment in HistoryDatabase.swift (swiftc -parse passes).

## Noticed, out of scope

- The palette's own reads are slow on a history this size: recentHistory 142-151 ms and searchHistory('a') 216-224 ms alone, on the main thread, per Cmd+T and per keystroke. recentHistory groups every visit of the space.
- The text path of searchURLs has the quadratic title-rule probe described above (2.25 s for a query matching every URL over all history in profile A). Only reachable with an explicit old startTime now. A fix would evaluate the guarded title for the representative rows only, and once per URL in the matcher.
- A long read on the history queue blocks main-thread reads behind it (the History page's search has the same shape). A second, read-only connection for the main thread would bound all of these.
- .derived is not ignored on main's .gitignore in this worktree; it was kept out of the commit by adding files by path.

Integrated on branch bugfix-batch-2 (worktree .claude/worktrees/bugfix-batch-2), 2026-10-04. Full DetourTests suite on the integrated tree: 2081 tests, 10 skipped (gated legs), 0 failures; after the review fixes 2083 tests, 10 skipped, 1 failure — ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed in 10 rounds'), a garbage-collection timing test outside this batch that passed in the first run and passes alone (26/26). Code review of the range a98904c..HEAD run with --fix (high).
Review: nothing found in the listing path or the default range.
Runtime check (harness build, isolated profile, API Explorer page): chrome.history.search({text: ''}) in the profile that had just visited https://www.wikipedia.org/ returned that URL, and with startTime: 0 one row; the same calls in a second profile returned nothing. Only a one-visit history: the timings are the benchmark's, not the running app's.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.history.search with no startTime now covers the last 24 hours, as in Chrome (startTime 0 is still all history), and an empty-text search walks each space's visits newest first and stops at maxResults instead of windowing over every in-scope visit. On the 300,000-visit benchmark history (Debug) the default call went from 2,157 ms to about 13 ms and a palette read issued behind it from 2,416 ms to about 164 ms; larger limits and the text path are measured and recorded, not bounded. A differential test holds the new listing equal to the windowed select.
<!-- SECTION:FINAL_SUMMARY:END -->
