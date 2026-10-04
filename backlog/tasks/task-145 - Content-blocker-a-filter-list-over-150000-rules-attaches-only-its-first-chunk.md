---
id: TASK-145
title: >-
  Content blocker: a filter list over 150,000 rules attaches only its first
  chunk
status: To Do
assignee: []
created_date: '2026-10-04 02:29'
labels: []
dependencies: []
references:
  - Detour/Browser/ContentBlocker/ContentRuleStore.swift
  - wiki/features/content-blocking.md
priority: medium
ordinal: 168000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ContentRuleStore.compileSplit (Detour/Browser/ContentBlocker/ContentRuleStore.swift) splits a rule set larger than maxRulesPerList (150,000) into chunks compiled as '<id>', '<id>-1', '<id>-2', … and completes with the first chunk only. ContentBlockerManager.applyRuleLists looks each enabled list up by its base identifier (ruleStore.getCachedList(identifier:)), and compiledRuleCount / isCompiled do the same, so chunks after the first are compiled but never added to a web view and never counted in Settings. A list that crosses the cap would silently block only its first 150,000 rules.

Read from the code while writing wiki/features/content-blocking.md; not observed. Whether any bundled list (EasyList, EasyPrivacy, the cookie list, URLhaus) exceeds the cap today has not been measured — that is the first thing to establish.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The task records each bundled list's current rule count against the cap, so the real exposure is known
- [ ] #2 Every chunk of a split list is attached to web views, removed when the list is disabled or whitelisted, and cleaned up when the list shrinks to fewer chunks; a test with a rule set over the cap fails before the fix
- [ ] #3 The Settings rule count and compiled state reflect all chunks
- [ ] #4 docs/content-blocking.md and wiki/features/content-blocking.md are updated
<!-- AC:END -->
