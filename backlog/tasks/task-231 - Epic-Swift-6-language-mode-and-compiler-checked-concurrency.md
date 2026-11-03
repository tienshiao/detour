---
id: TASK-231
title: 'Epic: Swift 6 language mode and compiler-checked concurrency'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-03T00:07:00Z'
updated_date: '2026-11-03T00:10:00Z'
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
- [ ] #1 Both the Detour and DetourTests targets build in Swift 6 language mode with no concurrency warnings
- [ ] #2 CLAUDE.md and the wiki describe the isolation model new code follows (main actor by default, where nonisolated code lives, how shared state crossing threads is guarded)
<!-- AC:END -->
