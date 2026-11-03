---
id: TASK-237
title: >-
  Tests: loopback fixture servers keep their state in a Mutex instead of an
  NSLock
status: To Do
assignee: []
created_date: '2026-11-03T04:33:00Z'
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
- [ ] #1 The three loopback servers keep their mutable state in Mutex values and conform to Sendable without @unchecked (or each remaining @unchecked carries a comment saying why it holds)
- [ ] #2 The suites that use them pass: WebSocketRelaySession and the extension integration suites
<!-- AC:END -->
