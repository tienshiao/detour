---
id: TASK-351
title: >-
  Content blocking: a filter list's $removeparam line compiles into a block rule
  for the whole host
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:37:00Z'
updated_date: '2026-11-16T07:57:00Z'
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
- [x] #1 Which of the built-in content-blocking lists contain $removeparam lines is measured and recorded
- [x] #2 A $removeparam rule (and its @@ exception) never produces a block or exception content rule
- [x] #3 EasyListParser tests cover $removeparam with and without a value, combined with other options, and as an exception
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Failing-first tests in ContentBlockerExceptionTests: $removeparam bare/valued/combined/pattern-less/escaped-comma/$-in-value, @@ exception must not unblock; regressions for domain=, redirect=, csp=, example.com/hit$value.
2. EasyListParser: isSupportedOption allow-list (knownOptions + domain=/rewrite=/redirect=/csp=); parseLine leaves out any network rule (block or @@) with another option; separator detection reworked (isOptionList: an unsupported option-shaped name=value or a listed bare modifier ends the check).
3. rulesFormatVersion 3 -> 4.
4. Before/after rule diff of the four built-in lists (TASK-359 copies of 2026-11-15) with standalone parsers; expect only the two easyprivacy lines ($method=POST, $redirect-rule).
5. Wiki filter-conversion + content-blocking hub, lint, log; code review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Failing first (pre-fix, 2026-11-15): the four new tests failed on the unchanged parser (51 assertion failures): every $removeparam form compiled to one rule; @@||ads.example^$removeparam=utm_source unblocked ||ads.example^; $method=, $redirect-rule, $removeheader=, $permissions=, $header=, $replace=, $jsonprune=, $urltransform=, $cookie, $hls=, $stealth, $denyallow= each added a rule. The supported-options regression test passed before the fix.

AC #1 measured (2026-11-15, TASK-359's copies of the four lists): 0 $removeparam lines in easylist, easyprivacy, easylist-cookie (fanboy-cookiemonster) and urlhaus-filter. Option survey: the only options outside the supported set are easyprivacy's ||void.nicopr.fr/rec$method=POST and @@||google-analytics.com/analytics.js$redirect-rule,script,domain=mond.how. Rule diff, old vs new parser built standalone with swiftc, every rule dumped as sorted-key JSON: easylist 73,252 / easylist-cookie 25,109 / urlhaus-filter 109,083 identical, in order; easyprivacy 56,555 -> 56,553 parsed (106 -> 108 skipped), exactly those two rules gone (a block rule for every method on void.nicopr.fr/rec; a literal-pattern exception that matched nothing).

Fix: EasyListParser.isSupportedOption (allow-list: knownOptions, ~ forms, domain=/rewrite=/redirect=/csp=); parseLine leaves out any network rule, block or @@, with another option. Separator detection (isOptionList): an unsupported option ends the check if it is name=value with an option-shaped name or a bare name in unsupportedModifiers (removeparam, removeheader, permissions, header, replace, jsonprune, urltransform, cookie, hls, stealth, redirect-rule), so escaped-comma values ($removeparam=/^(a|b)\,c/) are covered; any other bare word keeps the $ in the pattern (example.com/hit$value). rulesFormatVersion 3 -> 4, so installed lists recompile from cache at the next launch.

Chosen by Claude (not yet confirmed by the user): $method=POST rules are left out (||void.nicopr.fr/rec no longer blocked); alternative: allow `method` as an ignored option and keep blocking every method.

Tests: ContentBlockerExceptionTests + ContentBlockerTests + ContentBlockerDomainListTests + ContentRuleStoreThreadingTests + TrackingParameterFilterTests: 117 run, 0 failures, 1 skipped (pre-existing skip in TrackingParameterFilterTests). The cached real lists still compile through WebKit (ContentBlockerTests). Not verified at runtime: the launch-time recompile of format-3 lists to format 4 (the mechanism is TASK-199's, covered by testACompiledListIsReusedOnlyWhenItsFormatIsCurrent); no UI change, so no /verify launch.

Code review (/code-review medium --fix, 7 findings). Fixed by the review: isOptionList now splits at unescaped commas (splitAtUnescapedCommas) and needs every token to read as an option, so it no longer stops at the first unsupported one (that had made ||site.example/banner$id=1,2$image lose its rule; regression case added); parseLine computes optionTokens once. Left as they were: the hand-kept unsupportedModifiers list (bare uBO aliases $1p/$3p/$xhr and modifiers such as $urlblock or $jsinject still stay literal patterns that never match; out of scope); isRewritingOption repeating rewrite/redirect/csp (code this task did not touch); ~ handling repeated in two helpers; $match-case ignored (behaviour from before this task). After the review: the list diff is unchanged (only easyprivacy's two rules), and the test suites ContentBlockerExceptionTests 33, ContentBlockerTests 11, ContentBlockerDomainListTests 16, ContentRuleStoreThreadingTests 17, ContentRuleListChunkTests 35, TrackingParameterFilterTests 40 ran 152 tests: 0 failures, 1 skipped (a skip that was already there).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
EasyListParser now leaves out every network rule, block or @@, that carries an option it does not support (isSupportedOption allow-list: resource types, third-party, domain=, important, match-case, all, the @@ options, badfilter, and the options whose rules are skipped on purpose). Before, $removeparam=x compiled into a block rule for the whole host and its @@ form into an exception that unblocked it. Separator detection also recognises bare non-blocking modifiers ($removeparam, $cookie, $stealth, $redirect-rule, ...) and values whose commas are escaped. rulesFormatVersion 3 -> 4, so installed lists recompile from cache. Measured on the 2026-11-15 lists: none has a $removeparam line; only easyprivacy changed, by two rules ($method=POST block rule, a dead $redirect-rule exception). Leaving out $method=POST is Claude's choice, to confirm. Tests: 4 new parser tests failed before the fix; 152 content-blocker tests pass. Not checked at runtime: the launch-time recompile from format 3.
<!-- SECTION:FINAL_SUMMARY:END -->
