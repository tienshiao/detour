---
id: TASK-163
title: >-
  History: a slow history read on the one serial queue blocks the main thread's
  palette reads (a text search matching every URL takes 2.3 s at 300,000 visits)
status: To Do
assignee: []
created_date: '2026-10-04 18:41'
labels:
  - performance
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
  - DetourTests/HistoryURLSearchBenchmarkTests.swift
  - wiki/architecture/history-database.md
priority: low
ordinal: 186000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Measured 2026-10-04 during TASK-153, out of its scope. Numbers are from DetourTests/HistoryURLSearchBenchmarkTests (TEST_RUNNER_HISTORY_SEARCH_BENCH=1): 300,000 visits of 40,000 URLs, three profiles, Debug build, loaded machine; read them as orders of magnitude. TASK-153's notes hold the full tables.

Three findings:

1. HistoryDatabase.searchURLs with text (the path chrome.history.search takes when the extension gives a query) costs 2.25 s for a query that matches every URL over all history in the large profile, against 352 ms and 164 ms in the two smaller ones. The cost is not linear in the scope: extensionTitleExpression's NOT EXISTS probe runs for every title-less in-scope visit and walks all visits of a URL no other profile visited (396 title-less visits x 5,225 visits of one inbox URL in the fixture). Inferred from the numbers; the URL was not removed to isolate it. Since TASK-153 an omitted startTime means the last 24 hours, so this needs an explicit old startTime (startTime: 0 is the documented way to ask for everything). Direction: evaluate the guarded title for the representative rows only, and once per URL in the matcher.

2. History is one serial DatabaseQueue, and the palette reads it synchronously on the main thread (recentHistory on Cmd+T / Cmd+L, searchHistory per keystroke). A read issued behind a long one waits for it: 2.4-2.5 s behind the text search above, 919 ms behind an extension listing the whole history in one call (startTime 0, no limit). The History page's search has the same shape. Direction: a read-only connection of its own for the main thread (or a DatabasePool), so a long read elsewhere cannot hold the palette.

3. The palette's own reads are slow at this size even alone: recentHistory 142-151 ms and searchHistory('a') 216-224 ms on the main thread. recentHistory's aggregation over every visit of the space is TASK-97 (measured there at 25-28 ms for 50,000 visits); this task adds the 300,000-visit numbers and covers searchHistory, which TASK-97 does not.

Normal profiles are far smaller than the fixture, hence low priority.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The benchmark's text-path legs and palette-wait legs are re-run first and the baseline recorded in the task
- [ ] #2 A text search that matches every URL of a profile costs time roughly proportional to the scope's visits: the large profile is no longer several times slower per visit than the small ones, with a deterministic scaling test (SQLite VM steps, as in TASK-153) that fails before the change
- [ ] #3 The text path returns the same rows, order, counts, times and titles as before; a differential test against the old select holds it
- [ ] #4 A palette read on the main thread does not wait for a long history read made elsewhere (an extension's search, the History page): the measured wait behind a multi-second read is recorded and within a stated bound, or the task records why a separate reader was rejected
- [ ] #5 searchHistory's cost alone at 300,000 visits is recorded with a decision: fixed here, split into its own task, or accepted
- [ ] #6 wiki/architecture/history-database.md is updated
<!-- AC:END -->
