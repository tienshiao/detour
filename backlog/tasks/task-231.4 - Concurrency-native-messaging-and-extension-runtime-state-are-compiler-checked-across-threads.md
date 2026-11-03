---
id: TASK-231.4
title: >-
  Concurrency: native messaging and extension runtime state are compiler-checked
  across threads
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T00:08:00Z'
updated_date: '2026-11-03T02:34:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.3
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Extensions/Runtime/ExtensionManager+Updates.swift
  - Detour/Extensions/Runtime/ExtensionOriginInteractionKeeper.swift
  - Detour/Extensions/Runtime/ExtensionTabLifecycle.swift
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 271000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
NativeMessagingHost reads the host process's output on its own queue; ExtensionPolyfillHandler hands work to a global queue; ExtensionNotificationManager, ExtensionOriginInteractionKeeper, ExtensionManager+Updates (static waiter dictionaries) and ExtensionTabLifecycle (static test seams) hold mutable statics. At the 2026-11-02 measurement: NativeMessagingHost 12 warnings, ExtensionNotificationManager 6, ExtensionPolyfillHandler 4. This is the 1Password path, so regressions are costly and partly only visible in a signed build.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No concurrency warnings remain in Extensions/
- [x] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [x] #3 Native messaging, keep-alive, updates and the polyfills behave as before: NativeMessagingEnforcementTests, NativeHostKeepAliveTests, NativeConnectLogLimiterTests, WebSocketRelaySessionTests, ExtensionPolyfillIntegrationTests, ExtensionPolyfillProfileWiringTests and the extension update suites pass
- [x] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
- [x] #5 The task records whether a signed-build check with 1Password was done or is still owed
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. NativeMessagingHost: state stays main-actor; the stdout read loop and the process termination handler only touch `isConnected` (NSLock → Mutex, nonisolated), the constant names and a nonisolated `handleDisconnect`. Messages and the disconnect both reach the main actor as `Task { @MainActor }`s (one mechanism, so a disconnect the loop reports follows the messages it read); the parsed body comes from a `sending` helper so region checking proves the hand-off. `isolated deinit` (the teardown is main-actor state).
2. WebSocketRelay: `onMain` nonisolated, taking a @MainActor @Sendable closure; the URLSession delegate @MainActor with nonisolated callbacks using MainActor.assumeIsolated (delegateQueue is .main); CookieProvider completion @MainActor @Sendable (WKHTTPCookieStore.getAllCookies type).
3. ExtensionNotificationManager.create: the maps were mutated from UNUserNotificationCenter.add completion, a background queue, while main reads them (getAll/clear/update) — a real data race. Await `add` in a main-actor Task instead; completion still after the add.
4. ExtensionPolyfillHandler chrome.history.search: read on a global queue through a continuation, build the [String: Any] reply on the main actor (as HistoryPageBridge in TASK-231.2).
5. Smaller: task-group child tasks capture only Sendable values (ExtensionManager load, ExtensionUpdater check) and are nonisolated, awaiting the main-actor calls; the keep-alive failure recovery, the interaction-keeper and idle-monitor main-run-loop timers use MainActor.assumeIsolated with a comment; OffscreenDocumentHost.evaluateJavaScript completion takes WebKit type; the popover KVO handler reads the change value instead of the web view.
6. Verify: full suite; extension and native-messaging suites under TSan; record the owed signed-build 1Password check.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done 2026-11-02.

Changes as in the plan. Real data race fixed: ExtensionNotificationManager.create mutated notificationMap/activeNotifications from UNUserNotificationCenter.add completion (a background queue) while getAll/clear/update read them on main; it now awaits add in a main-actor Task. Review cleanups: the cookie completion no longer wraps its body in onMain (the type is @MainActor now), the unused OffscreenDocumentHost.evaluateJavaScript wrapper is deleted, NativeMessagingHost comments say when the isolated deinit really runs and that termination-handler disconnects are not ordered against the read loop.

Warnings (full rebuild): 252 → 204. Extensions/ has no concurrency warnings left: NativeMessagingHost 13 → 0, WebSocketRelay 17 → 0, ExtensionNotificationManager 7 → 0, ExtensionManager 3 → 0, ExtensionPolyfillHandler 4 → 1 (the one left is a non-concurrency `??` on a non-optional), 1 → 0 each for ExtensionOriginInteractionKeeper, IdleMonitor, OffscreenDocumentHost, ExtensionPopoverController, ExtensionUpdater. The two "region-based isolation checker does not understand" task-group sites were cleared by making the child tasks nonisolated and capturing only Sendable values.

Tests: full DetourTests ran while the machine was at load average ~47 (46 min instead of ~10): 3366 tests, 360 failures (105 unexpected), all in web-view suites timing out (HistoryDeletionIntegration 56, InPageLinkRouting 17, HistoryTitleUpdate 13, InternalPageIntegration 12, NativeMessagingEnforcement 10, NowPlayingTab 9, ExtensionWindowsCreatePrivate 8, NavigationFailureURL 7, FaviconLinkBridge 5, PageCaptureWebView 4, NewProfileExtensionLoad 4, LoadProgressStall 4, MediaArtworkLoader 3, PageOpenedWindow 2) plus the known SettingsPaneColumnsTests environment failure (TASK-231.1 notes). Those 14 suites rerun together at load ~25: 227 tests, 0 failures. Extension suites (ExtensionPolyfillIntegration, ExtensionPolyfillProfileWiring, ExtensionPopoverSizing, ExtensionUpdate{Deferral,Migration,Policy}, ExtensionUpdater, NativeConnectLogLimiter, NativeHostKeepAlive, NativeMessagingEnforcement, WebSocketRelaySession, WKExtensionIntegration): 213 tests, 13 skipped, 0 failures, before and after the review fixes. Under Thread Sanitizer (before the review fixes): 213 tests, 1 failure, 0 ThreadSanitizer reports. The failure, ExtensionPolyfillProfileWiringTests.testAnArmedWorkerHoldsOneAnchorAndADisarmStopsReanchoring (opened 3 > 2 anchors), is a TSan-only timing flake that predates this change: 2/5 failed with the change, 1/5 failed on 54d1f79 with the change stashed; it passes in normal runs.

Runtime (harness docs/harness/task231-4-harness.patch, profile DetourVerify2314): hello-world and api-explorer installed through ExtensionManager.install; on relaunch both "Loaded extension … enabled: true" through the changed task group. Native messaging is exercised by the integration suites with the fake host only.

Owed: a signed-build check with 1Password (native messaging, keep-alive, popup unlock) has NOT been done.

Found, not fixed (pre-existing, for the user to decide): (1) a native host that writes its reply and exits at once can have its exit (termination handler) handled before the read loop delivers that reply; (2) the read loop holds the host strongly while blocked in readData, so releasing a quiet host does not tear its process down; (3) a notifications.clear issued while create is still adding is lost; (4) UNUserNotificationCenterDelegate callbacks are main-actor isolated by default but UserNotifications gives no thread guarantee — to settle in TASK-231.6 before Swift 6 mode adds runtime checks.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Native messaging, the WebSocket relay, notifications, chrome.history and the smaller extension-runtime sites are now compiler-checked: the native host read loop and termination handler touch only a Mutex-backed isConnected and a nonisolated disconnect hop, messages and disconnects reach the main actor in order through main-actor tasks, the relay and its URLSession delegate are main-actor with documented assumeIsolated entry points, and child tasks carry only Sendable values. One real data race fixed (notification bookkeeping mutated from a UserNotifications background callback). No concurrency warnings remain in Extensions/ (target 252 → 204). 213 extension tests pass, also under TSan with no race reports (one pre-existing TSan-only timing flake recorded); installed extensions load on relaunch. A signed-build 1Password check is still owed, and four pre-existing issues found on the way are listed in the notes.
<!-- SECTION:FINAL_SUMMARY:END -->
