---
id: TASK-395
title: >-
  Content blocking: a rules change during a split list's refresh attaches a mix
  of its new and old chunks
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:43:00Z'
labels:
  - content-blocking
dependencies: []
references:
  - Detour/Browser/ContentBlocker/ContentRuleStore.swift
  - wiki/features/content-blocking-chunks.md
priority: low
type: bug
ordinal: 476000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-369, its code review); read from code, not measured; pre-existing. A filter list over WebKit's 150,000-rule cap compiles as several chunks (TASK-145). `ContentRuleStore.compileChunks` records each chunk in `compiledLists` as WebKit finishes it (`recordCompiled`), and `cachedLists(forList:)` reads `compiledLists` by chunk identifier, so while a refresh of a split list is inside WebKit the store holds some new chunks beside the old ones. TASK-369 added `completedLists` so Clear Cache keeps the last completed set rather than that mix, but a rules change posted in that window (another list's compile, a switch flipped in Settings) makes `ContentBlockerManager.reapplyRuleLists()` attach the mix to every live page (TASK-368's pass) and `ruleLists(for:in:)` give it to new pages. A mix can put a block rule and the exception that undoes it in different generations (TASK-155's cross-chunk concern). No shipped list is over the cap yet (urlhaus-filter was at 73% on 2026-11-15, TASK-370), so it affects nothing today; it will once a list splits, or with custom lists (TASK-301). Wiki: wiki/features/content-blocking-chunks.md, wiki/features/content-blocking-clear-cache.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 While a split list compiles, pages are given its last completed set of chunks until the new set is complete, never a mix
- [ ] #2 A ContentRuleStoreThreadingTests case that holds back one chunk of a refresh shows a rules change posted meanwhile attaches the old set
<!-- AC:END -->
