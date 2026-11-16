---
id: TASK-371
title: >-
  Content blocking: parser gaps — uBO aliases, bare modifiers that become
  never-matching rules, $match-case ignored
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - content-blocking
  - filter-lists
dependencies: []
references:
  - wiki/features/content-blocking-filter-conversion.md
priority: low
type: task
ordinal: 452000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-351's agent. (1) uBO aliases $1p, $3p, $xhr, $frame are read as part of the pattern (literal rules that never match); $from= is now skipped. (2) Bare modifiers not in unsupportedModifiers ($urlblock, $jsinject, $network, $popunder) also become literal never-matching rules, counted against the per-list cap and not as skipped. (3) $match-case is ignored, so such a rule matches more than intended. None appear in the built-in lists today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The aliases map to their ABP options
- [ ] #2 Unknown bare modifiers are skipped and counted
- [ ] #3 $match-case is honoured or the rule skipped
- [ ] #4 Parser tests cover each; rulesFormatVersion bumped if output changes
<!-- AC:END -->
