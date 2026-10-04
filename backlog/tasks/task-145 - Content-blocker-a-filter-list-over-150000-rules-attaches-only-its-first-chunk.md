---
id: TASK-145
title: >-
  Content blocker: a filter list over 150,000 rules attaches only its first
  chunk
status: Done
assignee: []
created_date: '2026-10-04 02:29'
updated_date: '2026-10-04 08:46'
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
- [x] #1 The task records each bundled list's current rule count against the cap, so the real exposure is known
- [x] #2 Every chunk of a split list is attached to web views, removed when the list is disabled or whitelisted, and cleaned up when the list shrinks to fewer chunks; a test with a rule set over the cap fails before the fix
- [x] #3 The Settings rule count and compiled state reflect all chunks
- [x] #4 docs/content-blocking.md and wiki/features/content-blocking.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. AC #1: count each list's rules from the cached copies (parser output) and from the app's recorded counts; record against the 150,000 cap.
2. Red: make the cap injectable (ContentRuleStore(storage:maxRulesPerList:)) and add the list-level API as thin shims with today's behaviour (base identifier only), plus ContentRuleListChunkTests: pure chunk arithmetic (ContentRuleListChunks: chunk count, identifiers, rule ranges, stale identifiers given the previous chunk count) and store tests with a cap of 2 and 5 tiny rules in a private temporary rule list store. Expect failures: only the first chunk is cached, counted, found by a new store and applied to a profile; a shrunk list keeps its stale chunks; a rule in the last chunk does not block in a web view.
3. Green: ContentRuleStore tracks a chunk count per list (defaults key ContentBlocker.<id>.chunkCount, written only when above 1), compile() compiles every chunk, records the count, removes stale chunks from WKContentRuleListStore, memory and defaults, and completes with all chunks; lookUpList finds every chunk at launch; cachedLists(forList:), compiledRuleCount(forList:) (sum), isCompiled(list:); invalidateAll clears chunk bookkeeping.
4. ContentBlockerManager: applyRuleLists adds ruleLists(for:in:) (every chunk of every enabled list); compiledRuleCount / isCompiled go through the list-level API; initialize uses lookUpList. Disabling a list and the per-site switch need no chunk-specific code (removeAllContentRuleLists + re-apply; _setContentBlockersEnabled covers every rule list) but get web view tests.
5. Docs: docs/content-blocking.md, wiki/features/content-blocking.md, wiki log + lint.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AC #1, rule counts against the 150,000 cap. No list is bundled: all four are downloaded at first launch and cached as text under <data dir>/ContentBlocker/. Counted with the current EasyListParser (a standalone swiftc build of EasyListParser.swift, parse only) on two cached copies:
- copies fetched 2026-10-04 (test data directory): easylist 75,661 (50.4% of the cap), easyprivacy 56,158 (37.4%), easylist-cookie 25,010 (16.7%; 25,008 compile, 2 are stripped as invalid), urlhaus-filter 9,605 (6.4%).
- copies fetched 2026-10-02 (the installed app's cache): 74,973 / 56,146 / 25,002 / 9,571, identical to the ruleCount values the installed app recorded in its defaults (compiledRuleCount 74,973 / 56,146 / 25,000 / 9,571).
The same 2026-10-04 numbers are printed by ContentBlockerTests.testCompile*. So the real exposure today is none: the largest list is at half the cap and no list is split. ignore-previous-rules rules per list: 755 / 847 / 429 / 0.

Change:
- ContentRuleListChunks (pure, in ContentRuleStore.swift): chunkCount, identifier(forList:chunk:), identifiers(forList:chunkCount:), ruleRanges, staleIdentifiers(forList:previousChunkCount:chunkCount:).
- ContentRuleStore: the cap is injectable (init(storage:maxRulesPerList:), default ContentRuleStore.defaultMaxRulesPerList = 150,000). compile(identifier:rules:) compiles every chunk, records the list's chunk count (memory + defaults key ContentBlocker.<id>.chunkCount, written only when above 1, so an unsplit list keeps exactly the keys it had), removes the chunks a longer previous compile left (WebKit store, memory, compiledRuleCount defaults key) and completes with ALL chunks (signature now ([WKContentRuleList]) -> Void; empty = nothing compiled, list left as it was). New list-level API: cachedLists(forList:), compiledRuleCount(forList:) (sum over chunks), isCompiled(list:), lookUpList(identifier:) (launch path; replaces lookupOrCompile, whose only caller passed no rules). invalidateAll now also forgets rule counts and chunk counts. compileSplit and getCachedList are gone.
- ContentBlockerManager: applyRuleLists adds ruleLists(for:in:) (static, testable: every chunk of every enabled list, none when the master switch is off); compiledRuleCount(for:) and isCompiled(identifier:) go through the list-level API, so Settings needs no change; initialize uses lookUpList.
- Disabling a list and the per-site switch needed no chunk-specific code (the window calls removeAllContentRuleLists and re-applies; _setContentBlockersEnabled:NO covers every rule list). Both have web view tests.

Tests first (DetourTests/ContentRuleListChunkTests.swift, 20 tests; cap injected as 2, rule sets of 1 to 5 rules, a private temporary WKContentRuleListStore and defaults suite per test; nothing compiles a real list). Run against a shim with today's behaviour (injectable cap, list-level API answering from the base identifier only, chunk functions stubbed): 14 of 20 failed with 37 assertion failures, for the intended reasons:
- testEveryChunkOfASplitListIsCompiledCachedAndCounted, testOneListsChunksAreNotAnotherLists: cachedLists was [easylist] instead of 3 chunks, count 2 instead of 5.
- testEveryChunkOfEveryEnabledListIsApplied: a profile got [easylist, easyprivacy, urlhaus-filter] instead of the six chunks.
- testARuleInTheLastChunkBlocksInAWebView: only the first chunk's image was blocked in a real WKWebView.
- testANewStoreFindsEveryChunkOfACompiledList, testANewStoreKnowsAShrunkListsChunkCount: a fresh store found one chunk.
- testAListThatShrinksLosesItsStaleChunks: easylist-2 / easylist-1 stayed in WebKit's store (timed out waiting for removal).
- testInvalidateAllRemovesEveryChunk: the rule count survived invalidateAll.
- the six pure-function tests (stubs).
Passing before and after (guards, not red tests): testADisabledListContributesNoChunk, testAListAtTheCapIsOneRuleList, testAListThatDidNotShrinkHasNoStaleChunks, testLookingUpAListThatWasNeverCompiledFindsNothing, testDisablingAListDetachesEveryChunkFromAWebView, testAWhitelistedNavigationIsNotBlockedByAnyChunk.

Suites run on the fix (49 tests, 0 failures): ContentRuleListChunkTests 20, ContentBlockerTests 11, ContentBlockerWhitelistTests 18.

Design choices beyond the task text:
- Best effort on a partial failure: if some chunks compile and one does not (even after bisection), the list is active with what compiled, isCompiled is true and the count is the sum of the compiled chunks (lower than the parsed count). A failed chunk keeps what an earlier compile left under its identifier. The alternative, all-or-nothing, would leave a split list with one uncompilable chunk blocking nothing.
- Stale chunks are derived from the recorded previous chunk count, not by listing WebKit's store. A chunk compiled by a build before this change has no recorded count: it is not attached and not cleaned up. No list has been near the cap, so no install is expected to have one.

Found, out of scope, NOT changed: exceptions do not cross chunks. WebKit evaluates each rule list on its own, so an ignore-previous-rules rule only cancels blocks in its own chunk, and rules are chunked in list order. If a list ever crosses the cap, @@ exceptions that land in a later chunk than their block rule stop applying, which can break sites. Attaching all chunks (this task) makes a split list block more, with that limit. Fixing it means repeating the exception rules in every chunk and is a parser/compile design change; worth its own task before any list gets near the cap.

Docs: docs/content-blocking.md (new section Lists Over the Rule Cap, pipeline, apply, Settings, cache locations), wiki/features/content-blocking.md (new section, gotchas, state table, tests), wiki/log.md. wiki-lint: 0 errors, 0 warnings.

Not verified: a real list over 150,000 rules (by design: memory), the Settings pane on screen with a split list, and the app at runtime. No /code-review or /verify run by this agent.

Integrated on branch bugfix-batch; full DetourTests suite there: 1970 tests, 11 skipped (gated measurement legs), 0 failures. Code review of the batch range run with --fix.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
No list is near the cap today (easylist 75,661 rules of 150,000). A list over the cap is compiled in chunks and every chunk is now attached, counted in Settings, removed when the list is disabled or shrinks (ContentRuleListChunks holds the arithmetic; the cap is injectable for tests). Tests with a small cap failed before the fix. Not verified: a real list over 150,000 rules. Known limits recorded in the docs: an exception rule in a later chunk than its block rule does not apply, and chunks compiled by an older build are not found.
<!-- SECTION:FINAL_SUMMARY:END -->
