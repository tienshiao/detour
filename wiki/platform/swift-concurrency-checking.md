---
type: Platform Quirk
title: Swift concurrency checking in an AppKit and WebKit app
description: What turning on complete concurrency checking, main-actor default isolation and the Swift 6 language mode does to Detour — WebKit delegate methods that silently stop being called because the SDK's closure types change, the implicit-deinit isolation error, build settings that leak into Swift packages, which settings carry runtime meaning in each language mode, how the Objective-C entry points were audited before Swift 6 could trap on them, why the test target had to follow, and the one test-class shape XCTest allows in Swift 6.
tags: [swift, concurrency, webkit, build]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-03T03:25:41Z }
sources:
  - id: task-231
    resource: backlog:TASK-231
    title: "Epic: Swift 6 language mode and compiler-checked concurrency"
  - id: task-231-1
    resource: backlog:TASK-231.1
    title: Main-actor default isolation and complete checking for the app target
  - id: task-231-6
    resource: backlog:TASK-231.6
    title: The app target builds in Swift 6 language mode
  - id: task-231-7
    resource: backlog:TASK-231.7
    title: The test target builds in Swift 6 language mode
  - id: main-actor-callbacks
    resource: ../../Detour/Browser/Shared/MainActorCallbacks.swift
    title: MainActorCallbacks.swift
  - id: reachability-tests
    resource: ../../DetourTests/WebKitDelegateReachabilityTests.swift
    title: WebKitDelegateReachabilityTests.swift
  - id: project-yml
    resource: ../../project.yml
    title: project.yml (per-target Swift settings)
  - id: se-0423
    resource: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md
    title: "SE-0423: Dynamic actor isolation enforcement from non-strict-concurrency contexts"
  - id: se-0466
    resource: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    title: "SE-0466: Control default actor isolation inference"
  - id: se-0470
    resource: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md
    title: "SE-0470: Global-actor isolated conformances"
---

# Behavior

The Detour target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`,
`SWIFT_APPROACHABLE_CONCURRENCY: YES` and `SWIFT_STRICT_CONCURRENCY: complete`
while still in the Swift 5 language mode (TASK-231). Turning that on taught
four things.[^task-231-1]

## WebKit delegate methods can stop being called, with only a warning

Under complete checking the SDK's Objective-C closure parameters are imported
with stricter types. WebKit's completion handlers become
`@escaping @MainActor @Sendable` — the JS alert, confirm and prompt panels,
`runOpenPanelWith`, `requestMediaCapturePermissionFor`, the authentication
challenge, and `WKScriptMessageHandlerWithReply`'s `replyHandler`. A Swift
method still written with the old `@escaping () -> Void` no longer matches the
protocol requirement.

- For a **required** method that is a compile error ("does not conform to
  protocol").
- For an **optional** method it is not. The method no longer witnesses the
  requirement, so it gets no Objective-C entry point (a Swift method in an
  `NSObject` subclass is only exposed to Objective-C when it witnesses an
  `@objc` requirement, overrides an Objective-C method or is marked `@objc`),
  WebKit's `respondsToSelector:` fails, and WebKit quietly falls back to its
  default: no alert sheet, no file panel, no sign-in sheet. The compiler warns
  "instance method … nearly matches optional requirement", but only when the
  method sits in the same extension as the conformance. A method declared
  elsewhere, or conforming through a refining Swift protocol (as
  `ExtensionListedWindow` refines `WKWebExtensionWindow`), gets no warning at
  all.

Twelve methods in `BrowserWindowController` and `QuickDetourWindowController`
were caught this way when the settings went on.[^task-231]

## A class's implicit deinit takes the default isolation

With main-actor default isolation, the implicit deinit of one of our own
classes is inferred main-actor isolated. A subclass's explicit `deinit` is
nonisolated, so it no longer overrides cleanly: "nonisolated deinitializer
'deinit' has different actor isolation from main actor-isolated overridden
declaration". It showed up only for subclasses of our own
`SettingsPaneViewController`; subclasses of AppKit classes are fine, since
their framework deinit is nonisolated.[^task-231-1]

## Command-line build settings reach Swift packages

`xcodebuild … SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor build` applies the
setting to every target in the build, the GRDB and Sparkle packages included,
and GRDB does not compile with main-actor default isolation (dozens of errors
in `GRDB/Core`). To measure the effect on the app alone, set the values per
target in `project.yml` (a scratch worktree plus `xcodegen generate` is
enough).[^task-231]

## What changes at runtime, and when

In the Swift 5 language mode these settings are almost all static: Swift
inserts the runtime checks that trap when main-actor code runs off the main
thread only in the Swift 6 language mode, or with the `DynamicActorIsolation`
upcoming feature (SE-0423).[^se-0423] The default-isolation change does move
`async` functions on previously nonisolated types onto the main actor
(SE-0466),[^se-0466] which in Detour affected nothing that does CPU
work.[^task-231-1] Two of the upcoming features
`SWIFT_APPROACHABLE_CONCURRENCY` turns on also carry runtime meaning:
`NonisolatedNonsendingByDefault` runs a `nonisolated` `async` function on its
caller's actor instead of the global executor, and `InferIsolatedConformances`
makes a main-actor type's conformances main-actor isolated, so a dynamic cast
through one (`as? SomeProtocol`, `String(describing:)` looking for
`CustomStringConvertible`) fails off the main thread.[^se-0470] The build
reports the static uses as `#IsolatedConformances` warnings; a dynamic cast
gets no warning. The only casts to an app protocol are
`windowController as? (any ExtensionListedWindow)`, all on the main
thread.[^task-231-1]

The Swift 6 language mode (the Detour target since TASK-231.6) adds the
checks: an Objective-C entry point of a main-actor method (a delegate method,
a selector-based notification observer, a target/action) traps if it is
called off the main thread. Before the switch every such entry point was
audited:[^task-231-6]

- Selector-based notification observers are only safe when every post is on
  the main thread. Every post in the app comes from main-actor code, which
  Swift 6 itself guarantees runs on main; system notifications observed this
  way (frame, scroll, screen, popover, workspace) are main-thread ones.
- Framework delegates that do not promise a thread are `nonisolated` and hop
  to main: `UNUserNotificationCenterDelegate`, the URLSession delegates
  (`WebSocketRelaySession.Delegate`, the artwork fetcher). A protocol the SDK
  marks `NS_SWIFT_UI_ACTOR` (`AVAudioPlayerDelegate`) is already main-actor
  and stays so: hopping would let a player started in between be torn down by
  the old one's completion.
- Callbacks AppKit runs on main but types as nonisolated `@Sendable` closures
  go through `MainActorCallbacks.swift` (`NSAnimationContext.runAnimationGroup(_:onMain:)`,
  `Timer.scheduledMainTimer`, `NotificationCenter.addMainObserver`) or an
  inline, commented `MainActor.assumeIsolated` (KVO change handlers, a
  `Timer` added to the main run loop, `RunLoop.main.perform`, the Carbon
  hot-key handler on the application event target). `assumeIsolated` traps if
  the assumption is ever wrong, in either language mode.
- `observeValue(forKeyPath:…)` overrides are `nonisolated` (NSObject's is),
  read the change there and apply it on main.

The full suite (3371 tests) and a runtime pass (split, web-view hand-off
between two windows, palette, extension popup, History page) ran on the
Swift 6 build with no trap.[^task-231-6]

## A Swift 6 app module makes its test target strict too

While the app was in the Swift 5 mode, a test target in the Swift 5 mode could
call its main-actor API from nonisolated `XCTestCase` methods without a
diagnostic. Once the app module is in the Swift 6 mode its declarations are no
longer treated leniently, and the same calls are errors: 4,439 of them in
DetourTests. Giving the test target the app's default isolation
(`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, approachable concurrency), still
in the Swift 5 mode, made the test methods main-actor isolated and left 5
errors, all closures and default arguments; XCTest runs synchronous tests on
the main thread anyway.[^task-231-6]

## XCTest allows only one test-class shape in Swift 6

XCTest declares `XCTestCase`'s `init`, `setUp()` and `tearDown()`
nonisolated. Under main-actor default isolation every test class therefore
fails in the Swift 6 mode: its inherited initializers and its `setUp` /
`tearDown` overrides are main-actor isolated against a nonisolated base.
Compiling small variants with `swiftc` showed that a plain class, an explicit
`@MainActor` class and an async `setUp` on a main-actor class all fail; the
only shape that compiles is a `nonisolated` class with `@MainActor` on each
member and nested type, and setUp/tearDown written as
`@MainActor override func setUp() async throws` with
`try await super.setUp()`. XCTest calls the async form before the sync one,
so fixtures keep their order. Extensions of test classes are `@MainActor`.
The 197 classes in DetourTests were rewritten by a script
(`docs/harness/task231-7-xctest-isolate.py`); before that, the target had 898
warnings under complete checking, 708 of them these override and
inherited-initializer mismatches.[^task-231-7]

What the compiler reported after the rewrite was mostly test plumbing:
captured variables mutated from `@Sendable` closures (moved behind a `Mutex`),
default property values that call main-actor API (made `@MainActor lazy`),
queue-based fixture servers (made `nonisolated`), and bridge replies holding
`Any?` handed from a reply handler to an awaiting test (wrapped in
`BridgeReply`, `@unchecked Sendable` because the value is handed over once).
Two fake `WKNavigationDelegate`s (in `ContentBlockerWhitelistTests` and
`ContentRuleListChunkTests`) still declared `decidePolicyFor` with the old
closure type, so under complete checking WebKit had stopped calling them —
the same silent loss as in the app, found in test code.[^task-231-7]

# Why it matters here

Most of Detour runs on the main thread because AppKit, `WKWebView` and
`WKWebExtension` require it, so main-actor default isolation matches what is
already true and leaves the warnings that point at real thread crossings.
The silent delegate loss is the one way the migration can break features
without a failing build.

# Workaround

- Write WebKit delegate methods with the SDK's closure types
  (`@escaping @MainActor @Sendable (…) -> Void`).
- `WebKitDelegateReachabilityTests` lists, for each class, the optional
  WebKit (and UserNotifications) selectors it implements, checks each is
  declared by the protocol, and asserts the class responds to it. Add a row
  when you implement a new optional delegate method.[^reachability-tests]
- Give a base class an explicit `nonisolated deinit {}` when its subclasses
  declare their own deinit (as `SettingsPaneViewController` does).
- Put concurrency settings in `project.yml` per target, never on the
  xcodebuild command line.

# Related

- [WKWebView delegate call order](./wkwebview-delegate-order.md) — which of these delegate methods WebKit calls, and when.
- [Build and test](../playbooks/build-and-test.md) — the build commands these settings apply to.
- [AppKit gotchas](./appkit-gotchas.md) — other AppKit behaviour found the hard way.
- [Strict memory safety](./strict-memory-safety.md) — the memory safety checking audited in the same epic, and why it is not left on.

[^task-231]: TASK-231
[^task-231-1]: TASK-231.1
[^reachability-tests]: WebKitDelegateReachabilityTests.swift
[^se-0423]: SE-0423
[^se-0466]: SE-0466
[^se-0470]: SE-0470
[^task-231-6]: TASK-231.6
[^task-231-7]: TASK-231.7
