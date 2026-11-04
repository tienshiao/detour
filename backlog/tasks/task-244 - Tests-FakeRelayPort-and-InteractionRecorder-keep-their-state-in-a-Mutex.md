---
id: TASK-244
title: 'Tests: FakeRelayPort and InteractionRecorder keep their state in a Mutex'
status: Done
assignee: []
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T18:13:00Z'
labels:
  - tests
  - concurrency
dependencies: []
references:
  - DetourTests/WebSocketRelaySessionTests.swift
  - DetourTests/ExtensionOriginTrackingPreventionTests.swift
priority: low
type: chore
ordinal: 288000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Left after TASK-237. FakeRelayPort (DetourTests/WebSocketRelaySessionTests.swift) and InteractionRecorder (DetourTests/ExtensionOriginTrackingPreventionTests.swift) still use NSLock plus @unchecked Sendable, against the CLAUDE.md rule. FakeRelayPort holds [[String: Any]], which is not Sendable, so it needs a small redesign rather than a straight swap.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Both types keep their mutable state in Mutex values and conform to Sendable without @unchecked, or each remaining @unchecked carries a comment saying why it holds
- [x] #2 WebSocketRelaySessionTests and ExtensionOriginTrackingPreventionTests pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Both doubles are only reached from main-actor code (WebSocketRelayPort and interactionLogHookForTesting are main-actor under the default isolation), so make them @MainActor classes with no lock instead of moving [[String: Any]] / WKWebsiteDataStore into a Mutex. Grep DetourTests for other NSLock + @unchecked Sendable.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AC #1 is met through the first option (Sendable without @unchecked) by main-actor isolation, not a Mutex: WebSocketRelayPort and ExtensionOriginInteractionKeeper.interactionLogHookForTesting are main-actor (default isolation), every caller reaches both doubles on the main actor (the session hops URLSession callbacks to main via onMain before touching the port), so the classes are @MainActor with no lock. A Mutex could not hand out [[String: Any]] or WKWebsiteDataStore anyway. Other NSLock in DetourTests: TestEnvironmentSetup.changesLock guards NSObject plist values written from UserDefaults.didChangeNotification on the writing thread; left as is, already commented (Mutex cannot hand out non-Sendable NSObject). BridgeReply's @unchecked is commented. Tests: WebSocketRelaySessionTests 7/7 and ExtensionOriginTrackingPreventionTests 19/19 pass (26 total). Test build: 0 warnings mentioning Sendable/isolat/actor/concurren. /code-review: no bugs; two low notes skipped (explicit @MainActor repeats default isolation, kept as documentation; record the AC choice, done here). /verify skipped: test-only.
<!-- SECTION:NOTES:END -->
