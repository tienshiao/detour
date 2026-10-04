---
id: TASK-153
title: >-
  Extensions: chrome.history.search with empty text scans every visit of the
  profile
status: To Do
assignee: []
created_date: '2026-10-04 08:53'
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
- [ ] #1 A benchmark in the HistoryBenchmarkTests style (gated by a TEST_RUNNER_ variable) measures searchURLs with empty text and with a typed query on a large history (hundreds of thousands of visits across several profiles), and the numbers are recorded in the task
- [ ] #2 The omitted-startTime default is decided and recorded (keep no lower bound, or Chrome's 24 hours), with tests for the chosen rule
- [ ] #3 The empty-text search stays within a stated time budget on the benchmark history, or the task records why the measured cost is acceptable
- [ ] #4 A long extension history query does not block the palette's main-thread history reads for longer than a stated bound, or the task records the measured wait
- [ ] #5 wiki/architecture/history-database.md and wiki/extensions/polyfill-layer.md are updated
<!-- AC:END -->
