---
id: TASK-162
title: >-
  Content blocker: in a filter list, an exception rule does not undo the block
  rules that come after it
status: To Do
assignee: []
created_date: '2026-10-04 18:41'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/ContentBlocker/ContentRuleStore.swift
  - Detour/Browser/ContentBlocker/EasyListParser.swift
  - docs/content-blocking.md
  - wiki/features/content-blocking.md
priority: medium
ordinal: 185000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Raised 2026-10-04 by the code review of TASK-155. Read from the code and WebKit's model; not observed in a web view, and not checked against a real list.

A list within the per-list cap (150,000 rules; every shipped list today, EasyList being the largest at about 75,700) is compiled as one WKContentRuleList in file order. An '@@' exception becomes an ignore-previous-rules rule, and WebKit applies that only to rules EARLIER in the same list. In Adblock Plus syntax an exception applies whatever its position. EasyList is assembled from sections and has exception sections ahead of later block sections, so an exception can be followed by a block rule it is meant to exempt; that block would then still apply and the site the list means to leave alone is blocked. This could be affecting real lists today.

TASK-155 fixed the same defect for a list split into chunks (every chunk holds its block rules followed by all the list's exceptions, ContentRuleListChunks.chunks(of:maxRulesPerList:isException:)), which leaves the split and unsplit layouts treating exceptions differently; docs/content-blocking.md lists this under 'Limits that remain'. The likely fix is the same ordering for a list of any size: block rules first, exceptions after, in list order within each group. Check that reordering does not change anything else that depends on rule order (css-display-none rules, ignore-previous-rules for element hiding exceptions).

Exceptions not crossing lists (an EasyPrivacy exception cannot un-block an EasyList rule) is a separate limit and not part of this task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test with a real WKContentRuleListStore and a web view shows a block rule placed after its exception still blocking the exempted URL today (it fails before the fix), or the task records that WebKit does not behave that way and closes with the docs corrected
- [ ] #2 The task records whether a shipped list is affected: at least one exception in the cached EasyList that precedes a block rule matching a URL it exempts, with the URL
- [ ] #3 An exception applies to the block rules of its list whatever their order in the file, for lists within the cap and split lists alike, through one layout rule
- [ ] #4 Element-hiding rules and their exceptions behave as before; a test covers a hiding rule and its exception in both orders
- [ ] #5 Rule lists compiled under the old order are recompiled after the update rather than reused (ContentRuleStore finds existing lists by identifier)
- [ ] #6 docs/content-blocking.md and wiki/features/content-blocking.md are updated
<!-- AC:END -->
