---
id: TASK-246
title: >-
  Memory safety: history title matching over page titles uses no unchecked
  unsafe access
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T18:51:00Z'
labels:
  - memory-safety
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
priority: low
type: chore
ordinal: 290000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-231.8, which audited CRX and native-messaging parsing. HistoryDatabase's title matcher (asciiMatch via withContiguousStorageIfAvailable, an UnsafeBufferPointer) runs over page titles, which come from websites; it is the next most exposed parser. See wiki/platform/strict-memory-safety.md for how to run the audit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The title matcher has no unchecked unsafe uses: each is replaced by a bounds-checked equivalent or marked unsafe with a comment saying why it is in bounds
- [x] #2 Matching results are unchanged: existing history search tests pass, plus tests with non-ASCII, empty and very long titles
- [x] #3 The history search benchmark shows no meaningful regression, or the cost is recorded
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure: HistoryBenchmarkTests (TEST_RUNNER_HISTORY_BENCH=1) before; strict memory safety warnings for HistoryDatabase.swift before (SWIFT_STRICT_MEMORY_SAFETY on the Detour target, temporarily).
2. Read the matcher's UTF-8 through a Span (bounds-checked in release too) instead of the UnsafeBufferPointer from withContiguousStorageIfAvailable; one unsafe marker with a comment where the span is made. UTF8View.span is macOS 26+, so not usable at the 15.4 target.
3. Tests: non-ASCII, empty, very long titles; bridged NSString with lone surrogates; invalid UTF-8 through the SQL function.
4. Measure after (benchmark + standalone -O microbenchmark of the matcher), audit after, revert project.yml.
5. /verify with a harness that seeds titled visits; /code-review --fix; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured (2026-11-03):
- Strict memory safety (SWIFT_STRICT_MEMORY_SAFETY: YES on the Detour target, temporarily; reverted): HistoryDatabase.swift 6 warnings before (lines 169, 180 x2, 186, 191, 195: all the matcher), 0 after. Target total 199 before (full build), so 193 after. No SQLite C-function warnings: GRDB wraps sqlite3_create_function and sqlite3_value_* reads.
- Fix: asciiMatch takes Span<UInt8>, made in the withContiguousStorageIfAvailable closure with unsafe Span(_unsafeElements:) and a comment; every read goes through Span's checked subscript. UTF8View.span needs macOS 26 (target 15.4), so not used.
- Standalone swiftc microbenchmark (55k ASCII titles ~80 bytes, query that matches none, best of 15): -O 3.6 ms before, 4.6 ms after (~18 ns/title); -Onone 183 ms before, 635 ms after. extracting()-per-run, token.indices compare and @_optimize(speed) did not recover it.
- HistoryBenchmarkTests (Debug, TEST_RUNNER_HISTORY_BENCH=1), before -> after: ascii/page/title-token 33.5 -> 66.2 ms (the matcher-heavy leg; the -Onone Span cost); nonascii/page/title-token 113 -> 127; ascii/page/own-title-token 7.9 -> 9.3; palette legs within noise (title-token 6.95 -> 7.51, own-title 0.96 -> 0.93). Load was 10 before, 16 after. Release pays ~1 ms per 55k rows.

After /code-review --fix (one finding applied: the ASCII check and token walk share one pass; also the history_fold result is now asserted, and the harness patch says to delete its defaults keys): standalone microbenchmark -O old 3.6 ms / one-pass Span 3.6 ms per 55k titles, -Onone 181 / 193 ms. HistoryBenchmarkTests (Debug) before -> after: ascii/page/title-token 33.5 -> 35.6, nonascii/page/title-token 113.3 -> 115.2, ascii/page/own-title-token 7.9 -> 8.7, palette legs within noise (title-token 6.95 -> 7.52, nonascii 14.19 -> 13.55, broad-a 22.2 -> 22.1). Load 7-11 for both runs.
Tests: HistoryDatabaseTests, HistoryTitleIndexTests, HistoryURLSearchTests, HistoryTimeRangeTests, HistoryTitleUpdateTests, ExtensionHistoryScopeTests, HistoryDeletionIntegrationTests, SuggestionProviderTests: 326 tests, 0 failures (incl. the 2 new: testTitleMatcherOverNonASCIIEmptyAndLongTitles, testTitleMatcherOverLoneSurrogatesAndInvalidUTF8).
/verify (docs/harness/task246-harness.patch, run on the final code): recordVisit seeded an ASCII, a folds-to-ASCII and a Cyrillic title in an isolated profile; searchVisits and searchURLs (history_title_matches) found each by a title word (roadm, REVIEW, resum, привет, мир) and nothing for zzznothing; the Cmd+T palette listed the titled visit for roadm, resum and привет. Not verified: the History page UI itself (its search backend was called in-process); the strict-memory audit was not re-run after the review's one-pass edit (it adds only Span subscripts).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The history title matcher (history_title_matches) reads page titles through a Span<UInt8>, bounds-checked in release builds, instead of the UnsafeBufferPointer from withContiguousStorageIfAvailable; one unsafe marker with a comment remains where the span is made. HistoryDatabase.swift strict-memory-safety warnings 6 -> 0 (target 199 -> 193). The ASCII check and token walk now share one pass, so the cost is at parity (-O 3.6 -> 3.6 ms per 55k titles). Matching results unchanged: 326 history/palette tests pass, plus new tests for non-ASCII, empty, megabyte-long titles, lone surrogates and invalid UTF-8 through SQL. Runtime check: titled visits found by the History-page and chrome.history search backends and by the palette.
<!-- SECTION:FINAL_SUMMARY:END -->
