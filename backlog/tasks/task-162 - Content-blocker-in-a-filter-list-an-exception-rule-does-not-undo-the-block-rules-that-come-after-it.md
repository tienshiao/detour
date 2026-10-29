---
id: TASK-162
title: >-
  Content blocker: in a filter list, an exception rule does not undo the block
  rules that come after it
status: Done
assignee:
  - '@claude'
created_date: 2026-10-04 18:41
updated_date: '2026-10-29T00:47:00Z'
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
- [x] #1 A test with a real WKContentRuleListStore and a web view shows a block rule placed after its exception still blocking the exempted URL today (it fails before the fix), or the task records that WebKit does not behave that way and closes with the docs corrected
- [x] #2 The task records whether a shipped list is affected: at least one exception in the cached EasyList that precedes a block rule matching a URL it exempts, with the URL
- [x] #3 An exception applies to the block rules of its list whatever their order in the file, for lists within the cap and split lists alike, through one layout rule
- [x] #4 Element-hiding rules and their exceptions behave as before; a test covers a hiding rule and its exception in both orders
- [x] #5 Rule lists compiled under the old order are recompiled after the update rather than reused (ContentRuleStore finds existing lists by identifier)
- [x] #6 docs/content-blocking.md and wiki/features/content-blocking.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Finding: TASK-199 (dbc412a, rulesFormatVersion 2) already orders the parser output block rules → network exceptions → $document → $important for every list, and ContentRuleListChunks carries the exceptions for split lists. Remaining work is evidence and coverage:
1. Web view test: raw rules in file order (exception, then a block rule it exempts) compiled through WKContentRuleListStore still block the URL — confirms WebKit's earlier-rules-only behaviour.
2. Web view test: the parser's output for the same two lines leaves the URL unblocked and still blocks a control URL; check it fails with the TASK-199 section order reverted.
3. Tests: a hiding rule and its $elemhide/$generichide exception in both file orders give the same output and the same result in a web view.
4. Scan the cached EasyList for an exception that precedes a block rule matching a URL it exempts; record the URL.
5. AC5 is covered by the TASK-199 format bump (testACompiledListIsReusedOnlyWhenItsFormatIsCurrent); record it.
6. Update docs/content-blocking.md and wiki/features/content-blocking.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-28: the fix itself shipped in TASK-199 (dbc412a): EasyListParser orders its output by Section (hiding, cosmetic exceptions, block rules, network exceptions, $document, $important), so every network exception follows every block rule in every list; split lists carry the exceptions per chunk (TASK-155) on the same output. rulesFormatVersion went to 2 then (3 since TASK-201), so a list compiled in file order is recompiled at launch (ContentBlockerManager.shouldReuseCompiledList, testACompiledListIsReusedOnlyWhenItsFormatIsCurrent).
Evidence added:
- testWebKitDoesNotApplyAnExceptionToALaterBlockRuleOfItsList: raw rules [exception, block] compiled through WKContentRuleListStore block http://exempt.example/jquery.popunder.js in a web view; [block, exception] do not. WebKit behaves as the task said.
- testAnExceptionAboveItsBlockRuleInTheFileExemptsTheURLInAWebView: parsed '@@||exempt.example/jquery.popunder.js' above '/jquery.popunder.js' leaves the script unblocked on exempt.example, still blocked on other.example. With the blocking and exceptions sections swapped (the file-order behaviour) it fails ('blocked: [http://exempt.example/jquery.popunder.js]'), as does the existing pure testANetworkExceptionAppliesToABlockRuleLaterInTheFile.
- testAHidingExceptionGivesTheSameRulesInEitherFileOrder (pure) and testHidingExceptionsAboveTheirHidingRulesInTheFileApplyInAWebView: $generichide/$elemhide exceptions above their hiding rules give identical output and the same web view result as below them (existing tests cover the other order).
- Shipped lists (27 Oct 2026 copies, standalone scanner = EasyListParser.swift + the tests' RuleListEvaluator, file order vs parser output for the URL each @@|| exception names): EasyList 571 checked, 10 affected — lines 63463-63472 '@@||thegay.com/assets/jwplayer-*/jwplayer.js|$domain=thegay.com' etc. above line 63474 '||thegay.com^$script,domain=thegay.com', e.g. https://thegay.com/assets/jwplayer-x/jwplayer.js on thegay.com was blocked in file order (the site's video player) until TASK-199. EasyPrivacy 849 checked, 0; EasyList Cookie 420, 0; urlhaus has no exceptions.
Tests: ContentBlockerExceptionTests 29/29 passed. No app code changed, so no /code-review or /verify run (tests and docs only).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
No code change needed: TASK-199 had already moved every network exception after every block rule (and bumped the rules format, so old compiles are redone). This task confirmed WebKit's earlier-rules-only behaviour in a web view, added web view and parser tests for exceptions above their block and hiding rules (verified to fail with the old order), and found the real case in EasyList: ten thegay.com player exceptions above a site-wide script block, i.e. that site's player was blocked before TASK-199. EasyPrivacy and EasyList Cookie were not affected. docs/content-blocking.md and the wiki page record the findings. Limit: the scanner approximates each exception's URL from its pattern, so it may miss cases.
<!-- SECTION:FINAL_SUMMARY:END -->
