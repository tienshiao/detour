---
id: TASK-17
title: 'Extensions: rate-limit the worker console bridge'
status: To Do
assignee: []
created_date: '2026-09-12 06:39'
labels:
  - extensions
  - logging
dependencies: []
priority: low
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The polyfill's console bridge (ExtensionAPIPolyfill.consoleJS -> ExtensionPolyfillHandler 'log' case) forwards every console.log/warn/error from extension contexts to Swift one message at a time over the native message bridge (workers) or webkit.messageHandlers (pages), and Swift logs each one. On 2026-09-11 around 20:00 the pre-TASK-15 build forwarded ~950,000 error lines from 1Password's service worker in 55 seconds (~20,000/s; a worker error loop, text was private so the cause is unknown), each a native-messaging round trip and a unified-log write. Add a per-context rate limit on the JS side (e.g. a token bucket per context, ~N messages/s with a burst, plus dedupe of identical consecutive messages with a count) and, as defence in depth, a cap in the Swift handler per extension per second that logs one summary line ('dropped N console messages') when exceeded. Keep the first occurrences so a real error is still visible, and keep ExtensionPolyfillTests' console-bridge tests passing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A context emitting console messages faster than the limit gets its excess dropped or coalesced on the JS side; the bridge sends at most the configured rate plus a summary of what was dropped
- [ ] #2 The Swift handler independently caps forwarded console messages per extension per second and logs a single 'dropped N' line instead of N lines
- [ ] #3 Identical consecutive messages are coalesced with a repeat count
- [ ] #4 ExtensionPolyfillTests cover the limiter (burst allowed, excess dropped with a summary, dedupe count) and the existing console-bridge tests still pass
<!-- AC:END -->
