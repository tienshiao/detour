---
id: TASK-231
title: 'Epic: Swift 6 language mode and compiler-checked concurrency'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:07:00Z'
updated_date: '2026-11-03T07:46:00Z'
labels:
  - concurrency
dependencies: []
references:
  - project.yml
priority: medium
type: task
ordinal: 267000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Both targets build in Swift 5.10 language mode with minimal concurrency checking (`SWIFT_VERSION: "5.10"` in project.yml) on a Swift 6.4 compiler, so the compiler checks none of the app's thread hand-offs. Most of the app runs on the main thread by necessity (AppKit, WKWebView and WKWebExtension are main-thread-only), and that stays. The races that can exist are in the code that leaves the main thread: history and session SQLite access, content-blocker compilation, native messaging, and the image, thumbnail and capture loaders. Several of those rely on comments asserting thread safety (the palette's background history pass: "It touches no shared mutable state, so it's safe to run here"), and much new code is written by agents. Swift 6 mode turns those claims into compile-time checks.

**Measured 2026-11-02** (Xcode 27.2, Swift 6.4.2, Detour app target only, in a scratch worktree; the test target was not measured):
- `SWIFT_STRICT_CONCURRENCY=complete`: 758 unique warnings in Detour/ and 2 errors. About three quarters are main-actor isolation warnings on code that already runs on the main thread.
- Adding `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY=YES` (Swift 6.2, SE-0466 and friends): about 180 warnings and 5 errors. Both builds stopped at their errors, so the counts are approximate. Largest files: HistoryDatabase 32, ContentBlockerManager 13, NativeMessagingHost 12, TabRecord+BrowserTab 11, DevToolbarInspectorGroup 9, Profile 8.
- Errors: ExtensionPolyfillHandler and InternalPageBridge no longer conform to WKScriptMessageHandlerWithReply; nonisolated `deinit` in ExtensionsSettingsViewController, LinksSettingsViewController and QuickDetourSettingsViewController.

**Migration trap:** under complete checking WebKit's completion-handler parameters gain `@MainActor`/`@Sendable`, and 12 optional WKUIDelegate/WKNavigationDelegate methods (BrowserWindowController+WKUIDelegate, BrowserWindowController+Navigation, QuickDetourWindowController+WebKit) only "nearly match" their requirements. A method that does not witness a requirement is not exposed to Objective-C, so WebKit would stop calling it with nothing but a warning: JS alert/confirm/prompt, the file upload panel, camera/mic permission, auth challenges.

**Measuring:** passing these settings on the xcodebuild command line also applies them to the GRDB and Sparkle packages, and GRDB does not compile with default MainActor isolation. Set them per target in project.yml (a scratch worktree plus `xcodegen generate` works).

**Order:** the subtasks run in sequence on main, one subsystem per commit. Out of scope: moving main-thread logic off the main thread. The measured main-thread history costs are TASK-97 and TASK-163, which are safer to do once this epic is done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Both the Detour and DetourTests targets build in Swift 6 language mode with no concurrency warnings
- [x] #2 CLAUDE.md and the wiki describe the isolation model new code follows (main actor by default, where nonisolated code lives, how shared state crossing threads is guarded)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
HANDOVER (2026-11-02 ~20:20). Done and committed on main (not pushed): .1 b79b6c6, .2 b70cf8a, .3 54d1f79, .4 8514f54, .5 1657228, .6 1ba9021 (app target in Swift 6 mode, 0 concurrency warnings, full suite 3371/0). Follow-ups filed and committed as TASK-232..236 (53bbd2c). .7 implemented but uncommitted and unreviewed: see its handover note. .8 not started. Owed by the user: a signed-build check with 1Password (native messaging changed in .4). Epic AC #2 (CLAUDE.md + wiki describe the isolation model) is done for the app; the test-target part is in .7 step 4.

Post-epic check (2026-11-02 23:59): after 231.8 and follow-ups TASK-232..237 (72be76a..1a3268d), two full DetourTests runs failed ~175 tests in ExtensionWindowsCreatePrivate/FaviconLinkBridge/HistoryDeletionIntegration. Cause: the screen was locked during both runs (pmset/loginwindow logs); the test host's GPU process stops accepting new web processes a few minutes into a lock, so new web views never load. Not a code regression: prefix bisection runs passed, and a full run under caffeinate -d -i on 1a3268d passed 3420 tests, 17 skipped, 0 failures (load 13-40). Trap recorded in wiki/playbooks/build-and-test.md (4567fc8).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
All eight subtasks are Done on main: the app target (231.1–231.6, 1ba9021) and the test target (231.7, deb41aa) build in Swift 6 language mode with main-actor default isolation and complete checking, with no concurrency warnings left (the test target has 27 others: async-alternative hints, unused results, deprecations). The full suite passed (3371 tests, 0 failures), and the WebKit-driven suites passed 3 iterations. CLAUDE.md's Concurrency paragraph states the model: main actor by default, nonisolated off-main code with Sendable data, Mutex for shared state, MainActorCallbacks helpers, comments on every unchecked escape, the XCTest class shape, and WebKitDelegateReachabilityTests rows. wiki/platform/swift-concurrency-checking.md holds the background. 231.8 (72be76a) was a one-time strict-memory-safety audit: CRX and native-messaging parsing are bounds-checked, and the setting is not left on (wiki/platform/strict-memory-safety.md). Owed by the user: a signed-build 1Password check (native messaging changed in 231.4 and 231.8). Follow-ups: TASK-232..237.
<!-- SECTION:FINAL_SUMMARY:END -->
