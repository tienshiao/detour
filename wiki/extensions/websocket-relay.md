---
type: Component
title: WebSocket relay
description: Why a WebSocket opened in an extension service worker deadlocks WebKit, and how Detour replaces it with a socket relayed through a native port to URLSessionWebSocketTask — protocol, lifetime, cookies and deliberate gaps.
resource: ../../Detour/Extensions/Runtime/WebSocketRelay.swift
tags: [extensions, service-worker, websocket, webkit, 1password]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:48:49Z }
sources:
  - id: relay
    resource: ../../Detour/Extensions/Runtime/WebSocketRelay.swift
    title: WebSocketRelay.swift
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (webSocketRelayJS)
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (openWebSocketRelay, connectUsing)
  - id: session-tests
    resource: ../../DetourTests/WebSocketRelaySessionTests.swift
    title: WebSocketRelaySessionTests.swift
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan (Phase 1 root cause, WebSocket relay section)
  - id: task-2
    resource: backlog:TASK-2
    title: Service worker restart after idle termination (root cause and the guard)
  - id: task-8
    resource: backlog:TASK-8
    title: WebSocket relay for service worker contexts
  - id: task-21
    resource: backlog:TASK-21
    title: Signed-build verification of the keep-alive and the WebSocket relay
---

# Role

In an extension service worker, `WebSocket` is not WebKit's. Detour replaces
it with `RelayedWebSocket`, a full implementation of the interface that owns
no socket: it opens a native messaging port to Detour's built-in
`detourWebSocketRelay` host, and `WebSocketRelaySession` drives a real
`URLSessionWebSocketTask` in the app process. Page contexts (popup, options,
offscreen, tabs) keep WebKit's native `WebSocket`.

# Why a worker cannot use WebKit's WebSocket

WebKit runs an extension's background service worker **on the main thread of
its content process**. A worker's `new WebSocket()` goes through
`WorkerThreadableWebSocketChannel`, whose constructor blocks the calling
thread on a semaphore until the *main thread* creates the channel. On a
main-thread worker that wait never ends.[^task-2]

This was the root cause of 1Password dying about two minutes after launch,
and everything observed followed from the frozen process:

1. The worker's event loop stops. No more port traffic, no timers.
2. WebKit's idle unload closes the hidden background page, but the frozen
   process never handles the close, so the service-worker client is never
   unregistered and the registration is never cleared.
3. Every later wake finds a "directly reusable registration" for a worker
   that cannot run, creates no worker, and fails 30 s later with
   `backgroundContentFailedToLoad` (code 6) — once a minute, for hours.

It was found by running `sample` on the hidden page's content process in the
signed build: the main thread was parked in the channel constructor under
1Password's notifier code. Five harness experiments had failed to reproduce
it, because without a trusted desktop-app session 1Password never reaches
that code.[^task-2] The synchronous wait was still in WebKit `main` on
2026-09-11; not re-checked since.

The first fix (TASK-2) was a **guard**: fail the connection asynchronously
with `error` then `close` 1006, the path an extension already handles for an
unreachable server. The relay (TASK-8) replaced it and keeps it as a
fallback.

# How it works

One socket is one port is one session.

- **JS side**: `webSocketRelayJS` installs only where
  `ServiceWorkerGlobalScope` exists. The real constructor stays reachable as
  `__detourNativeWebSocket`. `__detourWebSocketRelay.mode` is `relay` or
  `guard`, decided once per context from whether `runtime.connectNative` is
  reachable; the polyfill diagnostics report it as `apis.webSocket` (`native`
  in page contexts).
- **Gate**: `ExtensionManager.nativeHostAccess` accepts the host name without
  the `nativeMessaging` manifest permission — a worker may open a socket
  whether or not it declares native messaging. A one-shot `sendNativeMessage`
  to it is refused ("port-only host"). The context must still be one its
  profile lists.
- **Native side**: `openWebSocketRelay` wraps the port in
  `MessagePortRelayPort` (one `onDisconnect` signal whichever side ends it),
  creates the session, and registers it in `webSocketRelays` under
  (controller, extension).

| Worker to native | Native to worker |
|---|---|
| `{op:"open", url, protocols}` (exactly once) | `{op:"open", protocol, extensions}` |
| `{op:"send", text}` or `{op:"send", binary}` (base64) | `{op:"message", text}` or `{op:"message", binary}` |
| `{op:"close", code, reason}` | `{op:"close", code, reason, wasClean}`, then the port is dropped |
| | `{op:"error", message}`, always followed by a close |

An op before `open`, a second `open` or an unknown op is a protocol error:
`error` plus `close` 1006 with reason "protocol error".

## Details that are easy to get wrong

- **Cookies.** The handshake carries the owning profile's cookies for the
  origin, as Chrome's does. `WKHTTPCookieStore.getAllCookies` returns the
  whole jar, so `applicableCookies` filters by domain, path, `Secure` and
  expiry. `httpShouldHandleCookies` is set to false on the request, because
  the session's own (empty, ephemeral) store would otherwise replace a
  hand-set `Cookie` header.
- **Subprotocols** travel in `Sec-WebSocket-Protocol`: the `URLRequest` form
  of `webSocketTask` has no protocols parameter.
- **Close is answered at once**, not from the delegate. `cancel(with:)` did
  deliver `didCloseWith` when measured against the loopback server, but
  nothing documents that it must, and an unanswered close leaves the worker's
  socket stuck in `CLOSING`.[^task-8]
- **`close()` with no code reports 1005** with an empty reason, not the 1000
  the task is cancelled with.
- **Application close codes (3000–4999)** have no `CloseCode` case. The frame
  goes out as a normal closure; the worker is told the code it asked for.
- **A clean server close also surfaces as a receive failure.** The receive
  loop checks `task.closeCode` before reporting a 1006.
- **The close message is sent before the port is dropped.** A port dropped
  first would surface in the worker as a 1006.
- **Blob frames keep order**: each socket has a FIFO that also flushes during
  `CLOSING`.

## Lifetime

A session ends when the worker closes the socket, when the port disconnects
(worker gone), or from Detour's side through `tearDownNativeConnections` on
context unload, on a replaced background, or on a restart of an unresponsive
one. No task outlives its port.

An open relayed socket is counted as a connected host by the
[keep-alive](./native-port-keep-alive.md), so that a quiet long-lived socket
is not killed with an idle worker. That only has an effect in an extension
that also declares `nativeMessaging`, because only those open a keep-alive
port.

# Deliberate gaps

- **The extension's CSP `connect-src` is not applied.** WebKit enforces it on
  its own channel, which the relay bypasses.
- **No host-permission check**, matching Chrome, which does not restrict
  WebSockets from an extension worker.
- **Cookies are read at handshake time only.** Nothing is written back and a
  `Set-Cookie` on the 101 response is not stored.
- **Frames are base64 over the port and cross the main thread**, about a
  third more bytes plus a hop each way. Fine for a notifier; not a bulk
  transport.
- **Guard fallback paces reconnects.** The first failed socket fails at once;
  each further one in the context is delayed by 250 ms more, capped at 2 s,
  so a client reconnecting from `onclose` cannot spin the worker.

# Evidence

- Tests run a real worker against a loopback WebSocket echo server: text and
  binary round trip, server close code, registry back to zero.
- Signed build, 2026-09-13: 1Password's notifier sockets were relayed and
  opened in every profile and stayed open until the user locked 1Password
  (`code 1005, clean true`).[^task-21]
- Signed build, 2026-09-21: a vault change made on another device reached all
  three workers within 160 ms of each other with no local trigger, and the
  item appeared without a refresh. API Explorer's relay probe against a
  public echo server echoed text and binary and closed 1000.[^task-21]

# Gotchas

- API Explorer's worker opens `wss://example.invalid` at every start on
  purpose. The resulting `hostname could not be found` and `code 1006` lines
  in category `websocket-relay` are not a relay fault.
- The socket URL is logged `.private`; the extension id is public.
- The relaying, open and closed lines are info level; failures are error.

# Tests

- `WebSocketRelaySessionTests` — the session with a fake port against a real
  loopback server: protocol errors, close codes, cookies on the wire.
- `ExtensionPolyfillTests` — the JS state machine against a fake
  `connectNative`.
- `ExtensionPolyfillIntegrationTests.testWorkerWebSocketIsRelayedToARealServer`
  and `testOneShotMessageToTheRelayHostIsRejected`.
- `ExtensionPolyfillProfileWiringTests.testWorkerWebSocketIsRelayedAndReleasedThroughTheProductionWiring`
  (an extension declaring no permissions) and
  `testARelayedSocketKeepsTheWorkerAlive`.

# Related

- [Native messaging](./native-messaging.md) — the port mechanism and the access gate
- [Native port keep-alive](./native-port-keep-alive.md) — sockets count as hosts
- [Polyfill layer](./polyfill-layer.md) — how the module reaches a worker
- [Service worker unload rules](../platform/service-worker-unload-rules.md) — the worker runs on the main thread of a hidden page
- [1Password integration](./1password-integration.md) — the notifier socket this exists for
- [Diagnosing extension problems](../playbooks/diagnosing-extension-problems.md) — sampling a helper process

[^task-2]: Service worker restart after idle termination (root cause and the guard)
[^task-8]: WebSocket relay for service worker contexts
[^task-21]: Signed-build verification of the keep-alive and the WebSocket relay
