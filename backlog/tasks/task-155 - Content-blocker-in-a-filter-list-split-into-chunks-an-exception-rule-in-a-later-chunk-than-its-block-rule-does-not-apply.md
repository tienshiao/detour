---
id: TASK-155
title: >-
  Content blocker: in a filter list split into chunks, an exception rule in a
  later chunk than its block rule does not apply
status: To Do
assignee: []
created_date: '2026-10-04 09:14'
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
- [ ] #1 A test with a small injected cap shows an exception rule placed in a later chunk than its block rule not applying today (it fails before the fix)
- [ ] #2 Exceptions apply to the block rules of every chunk of the same list: for example each chunk carries the list's exception rules, with the rule count per chunk still under WebKit's limit
- [ ] #3 The Settings rule count does not count a repeated exception more than once, or the task records how it counts
- [ ] #4 docs/content-blocking.md and wiki/features/content-blocking.md are updated
<!-- AC:END -->
