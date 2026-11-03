---
type: Platform Quirk
title: Swift concurrency checking in an AppKit and WebKit app
description: What turning on complete concurrency checking and main-actor default isolation does to Detour — WebKit delegate methods that silently stop being called because the SDK's closure types change, the implicit-deinit isolation error, build settings that leak into Swift packages from the xcodebuild command line, and why the settings change almost nothing at runtime until the Swift 6 language mode.
tags: [swift, concurrency, webkit, build]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-03T01:00:00Z }
sources:
  - id: task-231
    resource: backlog:TASK-231
    title: "Epic: Swift 6 language mode and compiler-checked concurrency"
  - id: task-231-1
    resource: backlog:TASK-231.1
    title: Main-actor default isolation and complete checking for the app target
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

## In the Swift 5 mode these settings are almost all static

Swift inserts the runtime checks that trap when main-actor code runs off the
main thread only in the Swift 6 language mode, or with the
`DynamicActorIsolation` upcoming feature (SE-0423).[^se-0423] Until
`SWIFT_VERSION` becomes 6, code the compiler warns about keeps running as it
did before; the default-isolation change does move `async` functions on
previously nonisolated types onto the main actor (SE-0466),[^se-0466] which
in Detour affected nothing that does CPU work.[^task-231-1] Two of the
upcoming features `SWIFT_APPROACHABLE_CONCURRENCY` turns on also carry
runtime meaning: `NonisolatedNonsendingByDefault` runs a `nonisolated`
`async` function on its caller's actor instead of the global executor (Detour
has no such function today), and `InferIsolatedConformances` makes a
main-actor type's conformances main-actor isolated, so a dynamic cast through
one (`as? SomeProtocol`, `String(describing:)` looking for
`CustomStringConvertible`) fails when it runs off the main thread.[^se-0470]
The build reports the static uses as `#IsolatedConformances` warnings; a
dynamic cast gets no warning. When the settings went on, the only casts to
an app protocol were `windowController as? (any ExtensionListedWindow)`, all
in AppKit code on the main thread; string interpolation of app types inside
background closures can still lose a custom description (log text only).[^task-231-1] The switch to
Swift 6 mode is the step that can start trapping at runtime, so it needs its
own runtime pass.

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

[^task-231]: TASK-231
[^task-231-1]: TASK-231.1
[^reachability-tests]: WebKitDelegateReachabilityTests.swift
[^se-0423]: SE-0423
[^se-0466]: SE-0466
[^se-0470]: SE-0470
