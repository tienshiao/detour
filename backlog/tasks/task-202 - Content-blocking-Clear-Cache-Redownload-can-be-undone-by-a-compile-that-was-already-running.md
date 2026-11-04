---
id: TASK-202
title: >-
  Content blocking: Clear Cache & Redownload can be undone by a compile that was
  already running
status: Done
assignee:
  - '@claude'
created_date: '2026-10-25 09:39'
updated_date: '2026-10-27 08:50'
labels:
  - bug
  - content-blocker
dependencies: []
priority: low
ordinal: 238000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-200 code review 2026-10-25 (finding 1; predates TASK-200, whose per-list compile queue widens the window). ContentRuleStore.invalidateAll (Clear Cache & Redownload) does not cancel compiles waiting in waitingCompiles or already in flight. They complete afterwards and record their chunks and compiled counts, and the manager records rulesFormat, all from text that was just deleted.

Scenario: at launch the TASK-199 recompile from cache is running; the user clicks Clear Cache & Redownload; invalidateAll clears the store; the old compile completes and repopulates compiledLists and rulesFormat. If the redownload then fails (offline), the list the user cleared is back and marked current-format while its cached text, ETag and lastFetch are gone.

Fix direction: a per-list generation (or cancellation token) bumped by invalidateAll and by removing a list (filter list disabled); a compile records its result only if its generation is still current, otherwise removes what it compiled. Decide what a cancelled compile reports to the manager: an empty result triggers onMiss and a full download, so it probably needs a distinct 'superseded' outcome. Related: the drop branch for a superseded download compile never clears refreshingIdentifiers (review finding 2, practically unreachable today).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A compile that started or was queued before Clear Cache & Redownload (or before its list was disabled) does not record its lists, counts or rulesFormat afterwards; tested with an injected slow compile
- [x] #2 A superseded compile has its own outcome, distinct from 'no cached text', so it doesn't trigger an extra download; refreshingIdentifiers is always cleared
- [x] #3 Checked at runtime: Clear Cache & Redownload during the launch recompile, offline, leaves no list attached and no stale rulesFormat
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Findings: nothing removes a single list from ContentRuleStore (disabling a filter list in a profile only detaches it; the compiled list is global and other profiles may use it), so invalidateAll is the only invalidation; the 'list disabled' half of AC1 has no path to guard. The race has two layers: compiles already handed to the store (queued in waitingCompiles, encoding, inside WebKit, in the bad-rule search) and compiles the manager has not handed over yet (a launch cache parse running on parseQueue whose ticket check comes after the clear).

Plan (TDD):
1. ContentRuleStore: a generation bumped by invalidateAll; compile() captures it when called; a compile whose generation is stale records nothing (compiledLists, counts, chunkCount, stale-chunk removal) and stops at the next main-queue step: when dequeued, after encoding, in a chunk's WebKit callback (removes the chunk WebKit just wrote and waits for the removal before completing, so the next compile of the list cannot be overtaken), in the bad-rule search and before/after the cleaned recompile. lookUpList ignores results after a bump.
2. compile completes with CompileOutcome: .compiled(lists) / .failed / .superseded.
3. Injectable WebKit compile (RuleListCompiler) so a test can call invalidateAll while WebKit compiles; plus the gated encoder for the queued/encoding cases.
4. FilterListCompileOrder.supersedeTicketsTaken(): Clear Cache refuses every ticket taken before it (a cache parse in flight).
5. Manager: cache compile .superseded -> nothing (no onMiss, so no extra download); refreshing state tracked per refresh (FilterListRefreshes begin/end token) so every end path, including the dropped-download branch and a superseded compile, clears its own refresh but never a newer one's.
Tests in ContentRuleStoreThreadingTests (red first). Runtime: harness with lists served locally, slow launch recompile, Clear during it, offline redownload -> no list compiled, no rulesFormat.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
TDD: 8 new tests in ContentRuleStoreThreadingTests written first (store with an injected WebKit compile, CompileHook, that calls invalidateAll while WebKit compiles or at the first bad-rule probe; compiles queued/encoding when cleared; a look-up answered after the clear; FilterListCompileOrder.supersedeTicketsTaken; FilterListRefreshes). Red run: all 8 failed (23 assertions), e.g. the cleared compile recorded 5 rules and left easylist-1/-2 in WebKit's store (invalidateAll's own removal of 'easylist' landed after the in-flight compile on WebKit's serial work queue). Green after the fix: 17/17.

Implemented:
- ContentRuleStore: generation bumped by invalidateAll; compile() keeps the generation it was called in. Superseded compiles record nothing (compiledLists, counts, chunkCount, stale-chunk removal) and stop at the next main-queue step: dequeued, after encoding, before/inside WebKit (the chunk's callback removes what WebKit wrote and completes only after the removal, so the next compile of the list, queued behind it, is never overtaken), in the bad-rule search (stops probing, no cleaned recompile). compile completes CompileOutcome .compiled(lists) / .failed / .superseded. Injectable RuleListCompiler (default: the store's compileContentRuleList) for the tests.
- Root detail seen in the red run: WebKit runs a store's compiles and removals on one serial work queue per store path, so invalidateAll's removal of 'easylist' ran after the in-flight compile had written it, and the in-flight compile's later chunks stayed on disk.
- Manager: FilterListCompileOrder.supersedeTicketsTaken() at the clear (a cache parse running at the clear is refused); a cache read that finds its file deleted after the clear skips the fallback download (isSuperseded(ticket:); found at runtime: 2 extra unconditional fetches in the first offline run). Cache compile .superseded -> nothing (no onMiss). refreshingIdentifiers now from FilterListRefreshes (begin/end token): every fetch path ends its own refresh (error, 304, bad response, dropped download, any compile outcome) and an older fetch ending never clears a newer refresh.
- 'Before its list was disabled' (AC1): nothing removes a single list from the store (disabling only detaches; compiled lists are shared by all profiles), so invalidateAll is the only invalidation; one store-wide generation.
- Not handled (pre-existing, noted in the wiki): web views keep already attached lists after the clear until the next rules change.

Code review (code-review high --fix, 7 findings): fixed 5 (by the review): a look-up answered after the clear now also removes the chunk it found from WebKit's store (invalidateAll only removes chunks in memory, so the next launch would find it), unless a newer compile of the list is running (I added: or has recorded the chunk); initialize tickets each look-up so a cleared one neither compiles from cache nor downloads; clearCacheAndRedownload comment corrected (a download whose response arrives after the clear is fresh text and compiles; behaviour kept); the look-up test also checks WebKit's store (not shown red first); doc comment and a parameter name. Skipped 2: changing the in-flight-download behaviour (fresh server text, correct result); the pass-through closure around WebKit's completion (bridges its handler annotations, negligible).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Clear Cache & Redownload now wins over every compile asked for before it. ContentRuleStore keeps a generation bumped by invalidateAll: a compile waiting for its list, encoding, inside WebKit or searching for bad rules records nothing afterwards, removes what WebKit wrote for it (before completing, so the redownload's compile is not overtaken) and completes CompileOutcome.superseded, distinct from .failed so no extra download follows; a launch look-up answered after the clear records nothing and removes what it found. The manager refuses text ticketed before the clear (FilterListCompileOrder.supersedeTicketsTaken), skips the fallback download when a cache read finds its file deleted by the clear, and tracks refreshes by token (FilterListRefreshes) so every fetch path ends its own refresh and never a newer one's.

Tests (final code): ContentRuleStoreThreadingTests 17 (8 new, red first: 23 assertion failures), ContentRuleListChunkTests 35, ContentBlockerExceptionTests 25, ContentBlockerDomainListTests 16, ContentBlockerWhitelistTests 22, ContentBlockerTests 11: 126 tests, 0 failures. The new store tests inject the WebKit compile and call invalidateAll while WebKit compiles or at the first bad-rule probe (no sleeps).

Runtime (docs/harness/task202-harness.patch, isolated data dirs, lists served by a URLProtocol, Settings > Content Blocking, Clear clicked 1.5 s after easylist's launch compile was handed to the store): online, the clear caught easylist and easyprivacy in WebKit, easylist-cookie encoding and urlhaus-filter parsing; each was superseded at that stage (os_log) and every list ended with the redownload's counts (71,319 / 56,313 / 25,082 / 102,778) and rulesFormat 3. Offline: nothing compiled, no rulesFormat, no rule list file, 'Not loaded', only the clear's 4 fetches; the same run on the code before the fix brought all four lists back Active with rulesFormat 3 and no cache text, with 8 fetches. Re-run offline after the review fixes: same.

Not verified: the first offline run used a real posted click; the screen then locked, so the later runs pressed the same button with performClick (logged) and took no screenshots (Settings texts logged instead). A clear during the launch look-ups (milliseconds at launch) is covered by a unit test only. The review's look-up removal test was not run red first.
<!-- SECTION:FINAL_SUMMARY:END -->
