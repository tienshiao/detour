---
id: TASK-231.3
title: >-
  Concurrency: content-blocker list parsing and rule compilation are
  compiler-checked across threads
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:07:00Z'
updated_date: '2026-11-03T01:17:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.2
references:
  - Detour/Browser/ContentBlocker/ContentBlockerManager.swift
  - Detour/Browser/ContentBlocker/ContentRuleStore.swift
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 270000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ContentBlockerManager parses lists on its own queue and ContentRuleStore compiles on a work queue. TASK-200 moved rule serialisation and the bad-rule search off the main thread, and ContentRuleStoreThreadingTests covers part of it. At the 2026-11-02 measurement: ContentBlockerManager 13 warnings, plus ContentRuleStore.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No concurrency warnings remain in Browser/ContentBlocker/
- [x] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [x] #3 Compiled rule lists and whitelist behaviour are unchanged: the ContentBlocker* suites and ContentRuleStoreThreadingTests pass
- [x] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Rules become `[ContentRule]`, `typealias ContentRule = [String: any Sendable]`, instead of `[[String: Any]]`: the parsed list crosses parse queue → main → rule-store work queue, and with Sendable values the compiler proves that is safe (no @unchecked box).
2. EasyListParser nonisolated + Sendable (it has no state); ContentRuleListChunks, EncodedChunk and ContentRuleStore.encodedRuleList nonisolated; RuleListEncoder @Sendable; offMain takes a @Sendable work closure and a @MainActor `then`, T: Sendable.
3. ContentBlockerManager: onMiss is @MainActor; the files log globals nonisolated.
4. Verify: ContentBlocker*/ContentRule* suites normally and under TSan; runtime launch on a fresh isolated profile, lists downloaded, parsed, compiled and applied (unified log).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done 2026-11-02.

Changes: `typealias ContentRule = [String: any Sendable]` replaces `[String: Any]` in EasyListParser and ContentRuleStore (no @unchecked box: the compiler proves the values Sendable; any Sendable has no runtime presence, so the JSON is unchanged and rulesFormatVersion needs no bump). EasyListParser is `nonisolated final class … : Sendable` (no state). ContentRuleListChunks, EncodedChunk (Sendable) and encodedRuleList nonisolated; RuleListEncoder @Sendable; offMain<T: Sendable>(work: @Sendable, then: @MainActor). ContentBlockerManager.loadAndCompileFromCache onMiss is @MainActor; the two files log globals nonisolated. Review hardening: encodedRuleList checks JSONSerialization.isValidJSONObject first, so a non-JSON value (which the type now admits) fails the compile instead of raising an ObjC exception on the work queue.

Warnings: 0 concurrency warnings in Browser/ContentBlocker/ (ContentBlockerManager 15 → 2, ContentRuleStore 4 → 0). The 2 left are #ImplicitStrongCapture (a [weak self] inside a closure holding self strongly), pre-existing and not concurrency; left as they are.

Tests: ContentBlockerDomainListTests, ContentBlockerExceptionTests, ContentBlockerTests, ContentBlockerWhitelistTests, ContentRuleListChunkTests, ContentRuleStoreThreadingTests: 130 tests, 0 failures, before and after the review fix; under Thread Sanitizer (before the review fix, TSan runtime in the bundle): 130 tests, 0 failures, 0 ThreadSanitizer reports.

Runtime (fresh isolated profile DetourVerify2313, unified log, category content-blocker): the four lists fetched; easylist-cookie (25,095 rules), easyprivacy (56,355) and easylist (73,772) parsed off main and "Compiled … successfully" within 8 s. Not observed: urlhaus-filter compiling (the wait stopped after three lists), the compile-from-cache path (it parses only after a rulesFormatVersion change; covered by ContentBlockerTests), and blocking of a request in a page (covered by the suites).

Follow-up noted by the review, left for TASK-231.7: the test helpers in the ContentBlocker*/ContentRule* suites still build [[String: Any]], which Swift 5 mode accepts for [ContentRule] parameters; Swift 6 mode will not.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Content-blocker parsing and compiling is now compiler-checked across the parse queue, the main thread and the rule store work queue: rules are typed `[String: any Sendable]` (ContentRule) so the parsed lists are Sendable values, the parser and encoding helpers are nonisolated, and the work-queue closures are @Sendable with main-actor continuations. No concurrency warnings remain in Browser/ContentBlocker/; JSON output, threading and ordering are unchanged (130 tests, also under TSan with no reports; a fresh profile downloaded, parsed and compiled the real lists). A non-JSON rule value now fails the compile instead of crashing.
<!-- SECTION:FINAL_SUMMARY:END -->
