---
id: TASK-351
title: >-
  Content blocking: a filter list's $removeparam line compiles into a block rule
  for the whole host
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:37:00Z'
labels:
  - content-blocking
  - filter-lists
dependencies: []
references:
  - Detour/Browser/ContentBlocker/EasyListParser.swift
  - wiki/features/content-blocking.md
  - TASK-329
priority: medium
type: bug
ordinal: 431000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in the wiki content lint. EasyListParser.isKnownOption accepts any option containing '=', and isRewritingOption / typesWithoutBlockRules skip rewrite, redirect and csp but not removeparam, so a line such as ||host^$removeparam=x reaches parseBlockingRules and becomes a {block} rule for every load from that host instead of a parameter strip. Read from the code only; not reproduced, and not checked whether the subscribed lists contain such lines (uBlock/AdGuard-style lists do; the AdGuard URL Tracking list is consumed by TrackingParameterFilter, not by this parser, since TASK-329). wiki/features/content-blocking.md records 'no handling found'.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Which of the built-in content-blocking lists contain $removeparam lines is measured and recorded
- [ ] #2 A $removeparam rule (and its @@ exception) never produces a block or exception content rule
- [ ] #3 EasyListParser tests cover $removeparam with and without a value, combined with other options, and as an exception
<!-- AC:END -->
