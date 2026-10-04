---
id: TASK-155
title: >-
  Content blocker: in a filter list split into chunks, an exception rule in a
  later chunk than its block rule does not apply
status: In Progress
assignee: []
created_date: '2026-10-04 09:14'
updated_date: '2026-10-04 09:54'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/ContentBlocker/ContentRuleStore.swift
  - wiki/features/content-blocking.md
priority: low
ordinal: 178000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-04 while fixing TASK-145 (every chunk of a split list is now attached); read from the code and WebKit's model, not observed.

ContentRuleStore compiles a list over the per-list cap (150,000 rules) as several WKContentRuleLists, chunked in list order (ContentRuleListChunks). WebKit evaluates each rule list on its own, and an ignore-previous-rules action only undoes rules earlier in the same list. So an '@@' exception that lands in a later chunk than the block rule it exempts no longer exempts it: the block from the earlier chunk still applies. For a list that crosses the cap this can break sites the list means to leave alone.

No list is split today (easylist is the largest at about 75,700 rules, half the cap), so nothing is affected yet. docs/content-blocking.md and wiki/features/content-blocking.md record this as a known limit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test with a small injected cap shows an exception rule placed in a later chunk than its block rule not applying today (it fails before the fix)
- [x] #2 Exceptions apply to the block rules of every chunk of the same list: for example each chunk carries the list's exception rules, with the rule count per chunk still under WebKit's limit
- [x] #3 The Settings rule count does not count a repeated exception more than once, or the task records how it counts
- [x] #4 docs/content-blocking.md and wiki/features/content-blocking.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Failing test with a cap of 2: [block, block, exception] puts the exception in a later chunk than its block rule; a web view must not block the exempted URL.
2. ContentRuleListChunks.chunks(of:): a split list's chunks each hold a slice of the block rules followed by the list's exceptions; pure tests for the layout, the cap, and exceptions approaching the cap.
3. ContentRuleStore.compile uses it; the per-chunk count counts a repeated exception once (chunk 0 only).
4. docs/content-blocking.md, wiki/features/content-blocking.md, wiki-lint, log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Failing test first (AC #1), 2026-10-04

ContentRuleListChunkTests.testAnExceptionAppliesToABlockRuleOfAnEarlierChunk, cap 2, rules [block blocked-0, block blocked-1, exception blocked-0.example/allowed], compiled with a real WKContentRuleListStore and applied to a WKWebView. Before the fix the chunks were [b0, b1] and [x0], and WebKit reported http://blocked-0.example/allowed.png as blocked along with the two URLs that should be. After: only the two.

## What was built (AC #2)

ContentRuleListChunks.chunks(of:maxRulesPerList:isException:) (pure, generic over the rule type) replaces the plain rule ranges in ContentRuleStore.compile:

- a list within the cap is one chunk in list order, exactly as before;
- a longer list: the rules that are not exceptions are sliced in list order and every slice is followed by all the list's exceptions (ignore-previous-rules), so each chunk's exceptions come after that chunk's block rules. A slice holds the cap less the exceptions carried, so no chunk exceeds the cap (property-tested for caps 1...9 with 0...12 exceptions).

Decided for exceptions approaching the cap: the chunks carry at most half the cap of exceptions (maxCarriedExceptions, 75,000 at the real cap), the first in list order. Every chunk then keeps room for at least as many block rules and the chunk count at most doubles. Exceptions beyond that are left out of a split list and logged as an error (droppedExceptionCount). Reason: each carried exception costs a slot in every chunk, so without a bound a list with nearly a cap's worth of exceptions would compile into chunks of one block rule each; and failing the compile instead would turn the whole list off. No real list is near this (EasyList is 75,661 rules in all).

A split list of only exceptions compiles as one chunk of the carried exceptions (it undoes nothing, but the compile does not read as a failure).

## Rule count (AC #3)

Each chunk records Chunk.countedRuleCount, the rules it adds to its list's count: the repeated exceptions count in the first chunk only. compiledRuleCount(forList:), which Settings shows as Active, is therefore the number of distinct rules compiled; it equals In List for a split list that compiled whole, and is lower by the exceptions left out. The fallback that strips bad rules lowers a chunk's count only for stripped rules that were counted. The per-chunk defaults key keeps its name and now holds this number.

## Tests

ContentRuleListChunkTests 35/35 (20 before; 11 new pure tests for the layout, the cap, the count and the exception limit, and 4 with a real rule list store: an exception exempting a block rule of an earlier chunk and of a later one in a web view, the count of a split list in memory and after a relaunch, and the count with an exception left out), ContentBlockerTests 11/11 (compiles each cached real list through WebKit), ContentBlockerWhitelistTests 18/18.

## Review and runtime check

/code-review and /verify are not run here; they happen at batch integration. Nothing to look at in the running app: no real list is split (the largest is half the cap), so the change is not reachable at runtime without an injected cap.

## Docs (AC #4)

docs/content-blocking.md (What a Chunk Holds, the Settings rows, the limits) and wiki/features/content-blocking.md (What a chunk holds, limits, tests), wiki/log.md.
<!-- SECTION:NOTES:END -->
