---
id: TASK-237
title: >-
  Tests: loopback fixture servers keep their state in a Mutex instead of an
  NSLock
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T04:33:00Z'
updated_date: '2026-11-03T05:07:00Z'
labels:
  - concurrency
  - tests
dependencies: []
priority: low
type: chore
ordinal: 281000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
LoopbackWebSocketServer, LoopbackHandshakeCaptureServer and LoopbackHTTPServer (DetourTests/ExtensionTestSupport.swift) are nonisolated `@unchecked Sendable` classes that guard their state with an NSLock. CLAUDE.md says shared mutable state goes behind a Synchronization.Mutex, never an NSLock plus @unchecked Sendable. Found by the TASK-231.7 review and left out of it: the locks predate that task and have many lock sites, and the servers are shared by many suites (WebSocket relay, native messaging, extension integration).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The three loopback servers keep their mutable state in Mutex values and conform to Sendable without @unchecked (or each remaining @unchecked carries a comment saying why it holds)
- [x] #2 The suites that use them pass: WebSocketRelaySession and the extension integration suites
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Move each server's mutable state (connections, counters, recorded requests, held connections, port) into a private State struct behind one Mutex; drop NSLock and @unchecked.
2. Build the test target, confirm no new or concurrency warnings.
3. /code-review --fix on the diff.
4. Run every suite that uses the three servers (22 classes).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Each server's mutable state is in a private State struct behind one Mutex; NSLock and @unchecked Sendable are gone and all three classes are plain Sendable (NWListener, NWConnection and DispatchQueue are Sendable in the SDK, so nothing stays unchecked). LoopbackHTTPServer.Request is Sendable now.
/code-review --fix: fixed an existing race in LoopbackHTTPServer.respond, which recorded the path and held the connection in two separate critical sections. A release(_:) that ran between them, after the test had seen the path in requestedPaths, found no connection, and the load hung (a possible flake in QuickDetourProfileSwitchWindowTests). Both now happen in one withLock. Also moved State first. Skipped: FakeRelayPort (WebSocketRelaySessionTests) and InteractionRecorder (ExtensionOriginTrackingPreventionTests), which are still NSLock + @unchecked Sendable but outside this task; the defer-in-stop readability nit; the handshake server keeping cancelled connections until stop() (predates this, changing it would change behaviour).
Tests (sandbox off, load ~10): all 22 suites that use the servers, i.e. WebSocketRelaySession, ExtensionPolyfillIntegration, ExtensionPolyfillProfileWiring, CommittedLoadFailure, ExtensionMenuPopupDecision, ExtensionWindowsCreatePrivate, InPageLinkRouting, NavigationFailureURL, PageOpenedWindow, ExtensionPageOpenedWindow, Quarantine, QuarantineWindow, QuickDetour{,Extension,OpenIn,OpenInWindow,ProfileSwitch,ProfileSwitchWindow,TitleBar,Window}, SameDocumentVisit, TabTitleRetention: 410 tests, 13 skipped, 0 failures. Test-target build: 26 located warnings + the AppIntents note (= 27 baseline), none about concurrency; recompiling ExtensionTestSupport.swift gives 0 warnings. /verify skipped (test-only change).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The loopback fixture servers (LoopbackWebSocketServer, LoopbackHandshakeCaptureServer, LoopbackHTTPServer) keep their state in a Mutex and conform to plain Sendable, so there is no NSLock and no @unchecked left. The review also found an existing race in LoopbackHTTPServer, where release(_:) could miss a held connection, and fixed it by recording the path and the connection in one critical section. All 22 suites that use the servers pass (410 tests, 0 failures). The test build adds no warnings. Follow-up: FakeRelayPort and InteractionRecorder in two other test files still use NSLock + @unchecked Sendable.
<!-- SECTION:FINAL_SUMMARY:END -->
