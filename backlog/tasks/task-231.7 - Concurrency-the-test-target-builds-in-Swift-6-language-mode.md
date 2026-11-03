---
id: TASK-231.7
title: 'Concurrency: the test target builds in Swift 6 language mode'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:08:00Z'
updated_date: '2026-11-03T04:35:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.6
references:
  - project.yml
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 274000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
DetourTests (183 files) was not measured on 2026-11-02. It needs the same settings as the app target. With main-actor default isolation, test cases become main-actor isolated, which interacts with the tests that wait on WebKit callbacks and fixture servers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The DetourTests warning count under the app target's settings is measured and recorded before any fixes
- [x] #2 The DetourTests target has no concurrency warnings and sets `SWIFT_VERSION: "6"`
- [x] #3 The full suite passes, and a repeated run (`-test-iterations` on the WebKit-driven suites) shows no new flakiness
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure DetourTests under the app settings (main-actor default isolation, complete checking) before any fix.
2. XCTest declares XCTestCase init/setUp/tearDown nonisolated, so with default isolation every test class is an error in Swift 6 (verified with swiftc variants: plain, @MainActor class, async setUp all fail; only a nonisolated class with @MainActor members compiles). Rewrite the 197 test classes: `nonisolated` class, `@MainActor` on each member and nested type, sync setUp/tearDown overrides converted to `@MainActor override func setUp()/tearDown() async throws`, extensions of test classes @MainActor (script kept in docs/harness/task231-7-xctest-isolate.py).
3. Fix what Swift 6 reports: test seams typed with the app new closure types, captured vars mutated in @Sendable closures moved to Mutex (or a box), default values calling main-actor API made @MainActor lazy, queue-based fixture servers nonisolated, fake WebKit delegates with the SDK closure types, bridge replies handed over through a Sendable wrapper.
4. SWIFT_VERSION 6 for DetourTests; full suite; repeated runs of the WebKit-driven suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Baseline (2026-11-02, before fixes): DetourTests with SWIFT_STRICT_CONCURRENCY complete under the app default isolation: 898 unique warnings (592 inherited-initializer and 116 setUp/tearDown/class-method override isolation mismatches, 47 non-Sendable closure parameters, 29 main-actor calls from nonisolated code, 23 non-Sendable function conversions, 19 non-conformance to Sendable, 14 "consider async alternative", …), top files HistoryDatabaseTests 43, ExtensionTestSupport 24, PrivateDownloadTransferTests 16. In Swift 6 mode after the class rewrite: 186 errors, then 0.

After: DetourTests builds in Swift 6 mode; 27 warnings left, none about isolation or Sendable: 14 "consider using asynchronous alternative" for fire-and-forget loadBackgroundContent / download.cancel completions (the tests poll afterwards; awaiting would change what they test), plus unused results, unmutated weak vars and two deprecations.

Found on the way: two fake WKNavigationDelegates (ContentBlockerWhitelistTests, ContentRuleListChunkTests) declared decidePolicyFor with the old closure type, so under complete checking WebKit would not have called them; they now take the SDK type.

HANDOVER (2026-11-02 ~20:20, session ending). State: implementation done, NOT committed, NOT reviewed.

Uncommitted in the working tree (main, HEAD 1ba9021): project.yml (DetourTests SWIFT_VERSION "6" + SWIFT_STRICT_CONCURRENCY complete), 184 DetourTests/*.swift files (the class rewrite + fixes), docs/harness/task231-7-xctest-isolate.py (the rewrite script, for the record), and five small app-side changes made so test code can call pure constants off the main actor: SiteSettingsStore.settingKey/profileIDKey, TabStore.spaceDeletionBlock(from:) + spaceDeletionBlockKey, UserDefaultsScope (nonisolated enum; `defaults` nonisolated(unsafe) with a comment: UserDefaults is thread-safe but not Sendable), WebKitStorageScope.currentDataDirectoryName/currentIsDefaultDataDirectory, BrowserWindowController.frameAutosaveName/splitViewAutosaveName — all now nonisolated.

The test target BUILDS in Swift 6 mode (TEST BUILD SUCCEEDED, 27 non-concurrency warnings). A full DetourTests run was started at ~20:12 (log: the previous session scratchpad t19.log; it is not reachable from a new session, so just rerun). Its result is not known at handover.

Next steps for the next session:
1. Run the full suite (`xcodebuild -scheme DetourTests -configuration Debug -derivedDataPath .derived test`, sandbox off; check `uptime` first — at load 40+ web-view suites time out, rerun failing suites alone before trusting a failure). Things to watch: the 99 setUp/tearDown overrides were converted from sync to `@MainActor override func setUp()/tearDown() async throws` (XCTest calls the async form before the sync one; `super` calls now `try await super.setUp()`), so ordering-sensitive fixtures could behave differently; `MainActor.assumeIsolated` added in test notification/KVO/NWConnection handlers traps if a callback is ever off main.
2. Repeated runs for AC #3: e.g. `-test-iterations 3` on WebKit-driven suites (ExtensionPolyfillIntegrationTests, InternalPageIntegrationTests, HistoryDeletionIntegrationTests, PageOpenedWindowTests, QuarantineWindowTests).
3. /code-review --fix with an explicit target (git diff HEAD; ignore backlog/ and docs/harness/).
4. Update CLAUDE.md (its Concurrency paragraph still says the test target is in Swift 5.10 mode) and wiki/platform/swift-concurrency-checking.md (new section: XCTest declares init/setUp/tearDown nonisolated, so a test class must be `nonisolated` with `@MainActor` members and async main-actor setUp/tearDown; the swiftc variant experiment; BridgeReply; fake delegates found broken), wiki/log.md line, `python3 scripts/wiki-lint.py --fix`.
5. Check ACs, final summary, Done, commit as "Concurrency: the test target builds in Swift 6 language mode (TASK-231.7)". Then TASK-231.8 (memory safety audit, independent) and finally the epic TASK-231 itself (its two ACs).

Handover addendum (20:21): the full DetourTests run with the Swift 6 test target finished: 3371 tests, 17 skipped, 0 failures, no test-host restart (load average ~20). Next-step 1 is therefore done; continue at step 2 (repeated runs of the WebKit-driven suites).

Session 2 (2026-11-02 20:22, load ~10-19): repeated run for AC #3 — `-test-iterations 3` on ExtensionPolyfillIntegrationTests, ExtensionPolyfillProfileWiringTests, InternalPageIntegrationTests, HistoryDeletionIntegrationTests, PageOpenedWindowTests, QuarantineWindowTests: 565 executions, 13 skipped (TEST_RUNNER-gated legs), 0 failures, no test-host restart. CLAUDE.md Concurrency paragraph and wiki/platform/swift-concurrency-checking.md (new section: the one XCTest class shape in Swift 6) updated; wiki-lint 0 errors. /code-review --fix running.

Review (/code-review --fix, 10 findings): fixed 8 — BridgeReply/LockedFlag doc comment split repaired and LockedFlag, FetchLog (ExtensionFaviconScopeTests), EncoderSpy (ContentRuleStoreThreadingTests) moved from NSLock to Mutex; duplicate doc paragraph in TestEnvironmentSetup merged; `nonisolated(unsafe) static var shared` in ExtensionPolyfillIntegrationTests/WKExtensionIntegrationTests → @MainActor; redundant @unchecked Sendable dropped from SlowDownloadServer and FakeFetcher; constant `@MainActor lazy var`s → computed properties. Skipped 2: the three loopback fixture servers' NSLock (predates this task, many lock sites → TASK-237) and `await dbQueue.write` in five async tearDowns (no concrete failure; tests have finished by then). After the fixes: the reviewer ran 11 touched suites (179 tests, 0 failures); ExtensionPolyfillIntegrationTests + WKExtensionIntegrationTests 46 tests, 0 failures; clean test build 27 warnings, 0 about concurrency. /verify: Debug build, isolated DETOUR_DATA_DIR launch, window autosave + split-view autosave keys scoped to the data dir (frameAutosaveName/splitViewAutosaveName → WebKitStorageScope), seeded tab loaded a local page and saved its title, clean quit, no crash report; defaults keys and data dir removed. Not verified: signed build (no app behaviour changed here).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
DetourTests is in Swift 6 language mode with complete checking (project.yml). XCTest declares XCTestCase init/setUp/tearDown nonisolated, so every test class became `nonisolated` with @MainActor members and async main-actor setUp/tearDown (scripted rewrite, docs/harness/task231-7-xctest-isolate.py), then the remaining errors were fixed (Mutex for captured state, @MainActor lazy/computed defaults, nonisolated fixture servers, SDK closure types on fake WebKit delegates — two of which WebKit had stopped calling, BridgeReply). Five pure app constants became nonisolated so tests can read them off main. Baseline 898 warnings → 27, none about concurrency. Full suite 3371 tests / 0 failures; the six WebKit-driven suites ×3 iterations 565 executions / 0 failures; /code-review --fix (8 of 10 fixed); /verify clean. CLAUDE.md and wiki/platform/swift-concurrency-checking.md describe the test-class shape. Follow-up: TASK-237 (loopback fixture servers to Mutex).
<!-- SECTION:FINAL_SUMMARY:END -->
