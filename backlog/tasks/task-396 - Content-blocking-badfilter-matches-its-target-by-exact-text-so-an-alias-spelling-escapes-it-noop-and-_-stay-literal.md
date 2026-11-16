---
id: TASK-396
title: >-
  Content blocking: $badfilter matches its target by exact text, so an alias
  spelling escapes it; $noop and $_ stay literal
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:43:00Z'
labels:
  - content-blocking
  - filter-lists
dependencies: []
references:
  - Detour/Browser/ContentBlocker/EasyListParser.swift
  - wiki/features/content-blocking-filter-conversion.md
priority: low
type: bug
ordinal: 477000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-371, its choices and code review); read from code and the task notes. TASK-371 made `EasyListParser` read uBlock Origin's and AdGuard's option aliases (`$1p`, `$3p`, `$xhr`, `$frame`, `$css`, `$doc`, `$beacon`, `$first-party`, `$from=`) as the Adblock Plus options they stand for, through `canonicalOption`. Two gaps were left as they were:

- `$badfilter` still names its target by its exact text, so `||x^$third-party,badfilter` does not disable `||x^$3p` (nor `||x^$3p,badfilter` the full spelling), although both now compile to the same rule. uBO compares the canonical form.
- `$noop` and `$_` (uBO's no-op option, used to pad or separate options) are not options to the parser: a rule using them stays a literal pattern that never matches.

None of the four built-in lists uses them today (they parsed byte-identically before and after TASK-371). A fix changes the output for the same text, so `rulesFormatVersion` is bumped (the rule on wiki/features/content-blocking-filter-conversion.md). Wiki: that page.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A $badfilter line disables its target whatever alias spelling either uses (||x^$third-party,badfilter disables ||x^$3p and the other way round)
- [ ] #2 A rule with $noop or $_ among its options compiles as the rule without them
- [ ] #3 Parser tests cover both, and rulesFormatVersion is bumped
<!-- AC:END -->
