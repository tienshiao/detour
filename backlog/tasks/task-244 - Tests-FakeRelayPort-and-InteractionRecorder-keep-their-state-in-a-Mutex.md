---
id: TASK-244
title: 'Tests: FakeRelayPort and InteractionRecorder keep their state in a Mutex'
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
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
- [ ] #1 Both types keep their mutable state in Mutex values and conform to Sendable without @unchecked, or each remaining @unchecked carries a comment saying why it holds
- [ ] #2 WebSocketRelaySessionTests and ExtensionOriginTrackingPreventionTests pass
<!-- AC:END -->
