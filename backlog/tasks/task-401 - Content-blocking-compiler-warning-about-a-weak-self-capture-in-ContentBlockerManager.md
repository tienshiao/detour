---
id: TASK-401
title: >-
  Content blocking: compiler warning about a weak self capture in
  ContentBlockerManager
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:44:00Z'
labels:
  - content-blocking
  - build
dependencies: []
references:
  - Detour/Browser/ContentBlocker/ContentBlockerManager.swift
priority: low
type: chore
ordinal: 482000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported 2026-11-16 by the lead of the second two-lane batch (during TASK-370's builds): the compiler warns about a weak capture in `Detour/Browser/ContentBlocker/ContentBlockerManager.swift`, around line 488. Not reproduced here (no build), and the warning's text was not recorded. The line there is `self.ruleStore.compile(identifier: list.identifier, rules: result.rules) { [weak self] outcome in` in `loadAndCompileFromCache(list:onMiss:)`: it sits inside `parseQueue.async { [weak self] in guard let self else { return } ... }`, so `self` is already a strong local when the inner closure captures it weakly. Line 587 in `fetchAndCompile(list:conditional:refresh:)` has the same shape and may warn too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A Debug build shows no warning from ContentBlockerManager.swift; the compile completions still do not keep the manager alive
- [ ] #2 The content-blocking suites pass
<!-- AC:END -->
