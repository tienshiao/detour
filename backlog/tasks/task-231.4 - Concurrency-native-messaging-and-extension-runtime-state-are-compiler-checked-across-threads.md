---
id: TASK-231.4
title: >-
  Concurrency: native messaging and extension runtime state are compiler-checked
  across threads
status: To Do
assignee: []
created_date: '2026-11-03T00:08:00Z'
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
- [ ] #1 No concurrency warnings remain in Extensions/
- [ ] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [ ] #3 Native messaging, keep-alive, updates and the polyfills behave as before: NativeMessagingEnforcementTests, NativeHostKeepAliveTests, NativeConnectLogLimiterTests, WebSocketRelaySessionTests, ExtensionPolyfillIntegrationTests, ExtensionPolyfillProfileWiringTests and the extension update suites pass
- [ ] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
- [ ] #5 The task records whether a signed-build check with 1Password was done or is still owed
<!-- AC:END -->
