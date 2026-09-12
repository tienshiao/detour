---
id: TASK-8
title: 'Extensions: WebSocket relay for service worker contexts'
status: To Do
assignee: []
created_date: '2026-09-12 02:09'
labels:
  - extensions
  - webkit
  - 1password
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
WebKit runs an extension's background service worker on the main thread of its content process, and WebCore's WorkerThreadableWebSocketChannel blocks the calling thread until the main thread creates the channel, so new WebSocket() in an extension worker deadlocks the whole process (root cause of TASK-2; see the plan's Phase 1). TASK-2 shipped a guard (ExtensionAPIPolyfill.webSocketGuardJS) that fails worker WebSocket connections asynchronously (error, then close 1006); the real constructor is kept as __detourNativeWebSocket. Extensions that need a socket in the worker (1Password's @1password/web-api Notifier for live vault-change push, and anything else) currently lose that feature. Build a working WebSocket for worker contexts by relaying each socket through Detour: the worker-side class implements the WebSocket interface (constructor(url, protocols), readyState, bufferedAmount, extensions, protocol, binaryType, send(string|ArrayBuffer|Blob), close(code, reason), open/message/error/close events and on* handlers) over a dedicated native messaging port to the built-in detourPolyfill host (one runtime.connectNative port per socket, or one multiplexed port with socket ids); the native side opens a URLSessionWebSocketTask per socket, forwards frames both ways (binary as base64 or a typed encoding), reports open/close codes and errors, and tears down when the worker disconnects the port or the context unloads. Keep the guard as the fallback if the relay is unavailable. The extension's host permissions and CSP connect-src should be honored the way WebKit does for page contexts; document any gap.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 In a service worker, new WebSocket('wss://...') connects, sends and receives text and binary frames, and closes with the server's code, without touching the main thread's run loop (verified with a probe extension against a public echo server and with 1Password's notifier connecting)
- [ ] #2 Sockets are torn down when the worker closes them, when the worker is unloaded, and when the extension context is unloaded; no URLSessionWebSocketTask outlives its port
- [ ] #3 Page contexts (popup, options, offscreen) keep using WebKit's native WebSocket
- [ ] #4 ExtensionPolyfillTests cover the worker-side class (state machine, event order, send/close semantics) against a fake native side, and an integration test exercises the native relay end to end
- [ ] #5 API Explorer gains a worker WebSocket probe and docs/1password-integration-plan.md records the design and remaining CSP/permission gaps
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Created 2026-09-11 after TASK-2 as the follow-up to the WebSocket guard. Depends on nothing; TASK-2 verified that the guard alone keeps 1Password alive.
<!-- SECTION:NOTES:END -->
