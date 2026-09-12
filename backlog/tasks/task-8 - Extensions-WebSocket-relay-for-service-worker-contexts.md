---
id: TASK-8
title: 'Extensions: WebSocket relay for service worker contexts'
status: To Do
assignee: []
created_date: '2026-09-12 02:09'
updated_date: '2026-09-12 09:11'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design (2026-09-12, after TASK-16): 1. Native side: a second built-in host name 'detourWebSocketRelay' accepted by ExtensionManager.nativeHostAccess without the nativeMessaging manifest gate (generalise .polyfillHost to a builtInHost set); one port per socket. WebSocketRelaySession per port: first message {op:'open', url, protocols} -> URLSessionWebSocketTask (dedicated URLSession, delegate reports didOpenWithProtocol / didCloseWith code+reason); {op:'send', text} / {op:'send', binary:<base64>} forwarded; receive loop posts {op:'message', text} / {op:'message', binary:<base64>}; open -> {op:'open', protocol, extensions}; failures -> {op:'error', message} then {op:'close', code:1006}; server close -> {op:'close', code, reason, wasClean:true}; {op:'close', code, reason} from the worker cancels the task with that close code; port disconnect (worker closed the socket, worker unloaded, context unloaded via closeKeepAlivePort-style teardown) cancels the task. Registry keyed by (controller, extension, port) so nothing outlives its port. 2. Worker side (ExtensionAPIPolyfill): replace the guard's GuardedWebSocket with RelayedWebSocket implementing the WebSocket interface (constructor(url, protocols), CONNECTING/OPEN/CLOSING/CLOSED, readyState, url, protocol, extensions, bufferedAmount, binaryType 'blob'|'arraybuffer', send(string|ArrayBuffer|ArrayBufferView|Blob), close(code, reason) with code/reason validation like browsers, EventTarget + on* handlers, MessageEvent with data typed per binaryType); each instance opens its own relay port; guard behaviour kept as fallback when connectNative is unavailable. Page contexts untouched (native WebSocket). 3. Permissions/CSP: document that URLSession does not apply the extension's connect-src; enforce host_permissions match on the URL natively where the manifest declares them, else allow (Chrome allows any wss from a worker); record the gap in the plan doc. 4. Tests: ExtensionPolyfillTests drive RelayedWebSocket against a fake connectNative port (state machine, event order, send buffering before open, close codes, binary round trip); native unit test of WebSocketRelaySession against a fake port and a local loopback WebSocket server (URLSessionWebSocketTask to a Network.framework echo server, or the loopback HTTP server from the TASK-4 tests extended with an RFC6455 handshake); integration test through a real worker to a loopback echo server; API Explorer worker WebSocket probe; plan doc updated.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Created 2026-09-11 after TASK-2 as the follow-up to the WebSocket guard. Depends on nothing; TASK-2 verified that the guard alone keeps 1Password alive.
<!-- SECTION:NOTES:END -->
