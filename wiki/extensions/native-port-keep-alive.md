---
type: Component
title: Native port keep-alive
description: How Detour keeps an extension's background alive while it holds a native messaging host or relayed WebSocket, why the native side drives it, how a dead background is detected and restarted, and the cases it does not cover.
resource: ../../Detour/Extensions/Runtime/NativeHostKeepAlive.swift
tags: [extensions, service-worker, native-messaging, webkit, 1password]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:48:49Z }
sources:
  - id: state
    resource: ../../Detour/Extensions/Runtime/NativeHostKeepAlive.swift
    title: NativeHostKeepAlive.swift
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (keep-alive ports, pinger, supersede teardown, restart)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (nativePortKeepAliveJS)
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests.swift
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan, Phase 1
  - id: task-2
    resource: backlog:TASK-2
    title: Service worker restart after idle termination (the first, JS-side keep-alive)
  - id: task-15
    resource: backlog:TASK-15
    title: The polyfill must not replace the chrome/browser globals
  - id: task-16
    resource: backlog:TASK-16
    title: Keep the background worker alive while a native host is connected (native-side)
  - id: task-21
    resource: backlog:TASK-21
    title: Signed-build verification of the keep-alive and the WebSocket relay
  - id: task-62
    resource: backlog:TASK-62
    title: Extend the keep-alive to background pages
  - id: task-67
    resource: backlog:TASK-67
    title: A replaced worker leaks its native hosts
  - id: task-68
    resource: backlog:TASK-68
    title: The armed keep-alive does not stop WebKit unloading a worker (production)
  - id: task-70
    resource: backlog:TASK-70
    title: Tracking prevention deletes an extension origin's script-written storage
  - id: task-123
    resource: backlog:TASK-123
    title: Defer an update while the extension is busy
---

# Role

Chrome keeps an extension's service worker alive for as long as it holds a
native messaging port. WebKit does not: it unloads a non-persistent
background on two timers (see
[service worker unload rules](../platform/service-worker-unload-rules.md)),
and an extension like 1Password then loses its desktop-app connection every
two minutes. This mechanism restores Chrome's behaviour, and doubles as the
only detector Detour has for a background that has died under a page WebKit
still considers loaded.

State is kept per **(controller, extension)**, so each profile's copy of an
extension is independent.

# Why the native side drives it

Three earlier designs failed, and each failure is a constraint on any future
change:

1. **The worker cannot see its own native ports.** WebKit re-materializes
   `runtime.connectNative` on every read: assignment and `defineProperty`
   complete without error and the next read is a fresh native function, so a
   wrapper never takes.[^task-16]
2. **Shadowing `chrome` / `browser` to intercept the call breaks messaging.**
   WebKit's dispatcher unwraps those globals to find the worker's `onMessage`
   listeners; a `Proxy` cannot be unwrapped, and every page-to-worker
   `runtime.sendMessage` then resolved empty.[^task-15] See
   [never replace chrome globals](../decisions/never-replace-chrome-globals.md).
3. **A timer inside the background cannot be trusted.** The worker used to
   ping on its own `setInterval` (45 s). In the first signed-build run,
   workers were unloaded about 170 s after starting with the keep-alive armed
   throughout — 120 s past the second ping — and neither side could
   tell that the pings had stopped.[^task-68]

Detour, on the other hand, knows exactly when a real host is connected
([native messaging](./native-messaging.md) spawns it), and a
`DispatchSourceTimer` in the app cannot be suspended along with the worker.

# How it works

1. **The background opens one idle port.** `nativePortKeepAliveJS` calls
   plain `chrome.runtime.connectNative('detourPolyfill')` at start-up, before
   any extension code runs. Nothing is wrapped. If the port drops it
   reconnects with a backoff (1 s, doubling, 30 s cap).
2. **`ExtensionManager` holds it.** The `.polyfillHost` branch of
   `connectUsing` stores the port in `keepAlivePorts`, one per key, without
   spawning anything.
3. **A pure state machine decides.** `NativeHostKeepAliveState` tracks
   `connectedHosts`, `portOpen` and `armed`:

   | Event | Effect |
   |---|---|
   | `hostConnected` / `hostDisconnected` | Count up / down (clamped at zero) |
   | `portOpened` / `portClosed` | A closed port clears `armed` and sends nothing |
   | `contextUnloaded` | Resets everything |
   | `controlSendFailed`, then `reconcile` 1 s later | Clears `armed` so the start/stop is re-sent if still wanted |

   It answers `.sendStart` when `connectedHosts > 0 && portOpen` becomes true
   and `.sendStop` when it becomes false. `armed` is stored, not derived,
   because it must diverge after a failed send.
4. **While armed, Detour pings.** `{type: "keepalive-ping", seq}` goes out
   immediately and then every `keepAlivePingInterval` (30 s) from a `.strict`
   dispatch timer (an ordinary one can be deferred by App Nap once every
   window is occluded). The background answers `{type: "keepalive", seq}` on
   the same port. **The reply is the point**: WebKit counts only messages the
   background itself posts.
5. **What counts as a host**: live `connectNative` hosts and open
   [relayed WebSockets](./websocket-relay.md). One-shot `sendNativeMessage`
   hosts never do.

`keepalive-start` / `keepalive-stop` still travel on the port but only flip a
diagnostic flag in the background; it answers every ping regardless.

## A replaced background takes its hosts with it

`chrome.runtime.reload()`, and a WebKit-internal restart of the background,
run WebKit's context unload, which drops native ports **without any
disconnect callback**. The old host processes stayed alive as Detour's
children and kept counting: in the first signed-build run the armed count
read 2 and then 3 for one profile, and ten host processes existed for three
workers.[^task-67]

The one signal Detour gets is the replacement's keep-alive port arriving
while the old one is still registered. Because the polyfill opens that port
before extension code runs, everything registered under the key at that
moment belongs to the context that went away. The supersede path therefore
calls `tearDownNativeConnections` (hosts killed, their ports disconnected,
relay sessions ended, state reset), then accepts the new port. The evicted
port is first sent `{type: "keepalive-superseded"}` so its context stops
instead of reconnecting — otherwise two contexts evict each other about once
a second forever. The reason has to be a message because WebKit does not
deliver a disconnect error to an established port.

## A background that stops answering is restarted

WebKit can terminate a worker while its hidden background page stays loaded
(the confirmed cause was tracking prevention clearing the registration, see
[data store and ITP](./data-store-and-itp.md)). Every port stays open, alarms
are lost, and nothing reports it. The pings are the detector:

1. A ping still unanswered at the next tick logs
   `ping #n sent N s ago has no reply …; sending #n+1`.
2. `keepAliveMissedReplyLimit` (2) such ticks in a row — 60 s of silence,
   still inside WebKit's 2-minute window — logs
   `no reply to pings #n–#m for N s; treating the background as dead and restarting it`.
   A late reply to an older ping counts as proof of life and restarts the
   count.
3. `restartUnresponsiveBackground` runs the same teardown as a supersede and
   also drops the keep-alive port. With no open ports left, WebKit's next
   30 s tick closes the zombie page instead of waiting two minutes.
4. `keepAliveRestartDelay` (35 s, longer than that tick) later it calls
   `loadBackgroundContent` on the context. It is *not* a context
   unload/reload: that would close the extension's popup and other pages.
   The pending load is cancelled if a keep-alive port arrives first or the
   context unloads.

If the load fails, WebKit records `backgroundContentFailedToLoad` and
`Profile.recoverFromBackgroundLoadFailure` takes over: a full unload and
reload of the context onto a fresh origin, limited to 3 per 10 minutes per
extension.

# Where it installs

| Context | `installDetail` |
|---|---|
| Service worker, or non-persistent background page, declaring `nativeMessaging` | *(installs; `installMode: 'port'`)* |
| Popup, options page, tab, offscreen document | `not-a-background-context` |
| Background without `nativeMessaging` | `no-nativeMessaging-permission` |
| MV2 background page with `persistent` not `false` | `persistent-background-page` |
| A newer port took over | `superseded` |

The permission gate is not cosmetic: an idle open port alone moves a
background off WebKit's 30 s unload onto the 2-minute path.[^task-62] The
status is readable as `globalThis.__detourNativePortKeepAlive` and logged
once per background start through the [console bridge](./console-bridge.md).

# Where it does not hold

- **It does not prevent termination, it recovers from it.** Death is declared
  when the first unanswered ping is 60 s old, which is up to 90 s after the
  worker actually died, and the reload follows 35 s later. Alarms and
  messages in that window are lost. Observed in the signed build: registration
  cleared 23:19:23, background reloaded 23:21:31.[^task-70]
- **A relayed socket alone does not arm it.** Without `nativeMessaging` the
  background has no keep-alive port, so the state reads `connectedHosts: 1,
  portOpen: false, armed: false` and no ping is sent. Pinned by
  `testWorkerWebSocketIsRelayedAndReleasedThroughTheProductionWiring`.
- **Suspected, untested: closing one of several ports ends the hold.** By
  WebKit's source, removing any one of a background's ports makes it forget
  the rest for its open-ports check, and the next 30 s tick unloads whatever
  the pings do. See
  [service worker unload rules](../platform/service-worker-unload-rules.md).
  It would matter for an extension that closes a relayed socket or a second
  native port while its host stays connected.
- **Registries are per extension, not per context.** A `connectNative` port
  held by a still-open popup or options page is torn down with the
  background's on a supersede or a restart; the page sees an ordinary
  `onDisconnect`. A native port carries nothing that says which context
  opened it.
- **A tab navigated to the background document's path** passes the polyfill's
  gate and can take the keep-alive port from the real background, which then
  stays stopped until its next start. Same root cause as the previous point.
- **An extension held alive is never idle for updates.** A live native host
  counts as busy for update deferral, so such an extension updates only at
  launch or through Install Now.[^task-123] See [updates](./updates.md).

# Evidence

| Date | Build | Result |
|---|---|---|
| 2026-09-12 | Debug harness, fake host | Worker held 11 min 30 s with zero `terminateWorker`; unloaded 30.0 s after the last host exit; a control probe without `nativeMessaging` cycled on the 30 s unload throughout[^task-16] |
| 2026-09-13 | Tests, background page | No port: gone at +29.7 s. Silent native port: gone at +120.0 s. Keep-alive armed: still running at +300.9 s[^task-62] |
| 2026-09-13 | Signed build, real 1Password, run 1 | Partial. Workers with a relayed socket held 21 min; one without was unloaded at 174 s while armed. Exposed the leak and the dead timer[^task-21] |
| 2026-09-13 | Tests, 300 s leg, Detour-driven pings | 11 pings, 11 replies in 0–3 ms; after release WebKit closed the port 149.4 s later[^task-68] |
| 2026-09-13 | Signed build, run 2 | Two workers answered replies #1–#33 over 16 min with no relayed socket open; the third was killed by the ITP purge 1 s after launch and recovered[^task-68] |
| 2026-09-21 | Signed build, after TASK-67/68/73 | Three workers (one in Private) held 19–23 min, every ping answered (max 74 ms). With hosts at zero: unload 30.0 s after the disarm, clean restart on the next event, exactly three host processes[^task-21] |

The restart path is reproduced in tests with a worker that calls
`registration.unregister()` on itself, which reaches WebKit's teardown from
the other end and leaves the same state: page loaded, port open, no replies.

# Reading the log

Category `extension-manager`. Everything except the two watchdog lines is
**info** level: use `log stream --level info` or `log show --info`, and
remember info lines age out of the store within minutes.

- `Keep-alive port opened for <ext>` / `closed` / `superseded by a newer one`
- `Keep-alive armed for <ext>: N native host(s) connected` / `disarmed`
- `Keep-alive ping #n sent to <ext>` / `Keep-alive reply #n from <ext> (N ms)`
- `Replaced background context of <ext>: tore down N stale native host(s) and M relayed WebSocket(s)`

Traps: these lines carry **no profile name** (tell workers apart by the
`connectNative … in profile X` lines); "native host(s)" counts relayed
sockets too; `superseded` right after an idle unload is expected and was seen
in the 2026-09-21 run.[^task-21]

# Gotchas

- **Stale comments.** The doc comment on `restartUnresponsiveBackground`, a
  paragraph in `nativePortKeepAliveJS`, and the relay section of the plan
  document still say a `chrome.offscreen` document's close terminates the
  worker. TASK-68's own correction found that a coincidence; the trigger was
  the ITP pass that ran in the same millisecond.[^task-68]
- **Take the registry entry before disconnecting.** Every teardown removes
  the whole entry first, so the callbacks it sets off find nothing to
  release. Reordering this double-releases a host.
- **Accept the port before arming it.** `completionHandler(nil)` is called
  before `portOpened` is applied, because arming may send on the port at
  once.
- **Each background start opens one port.** `keepAlivePortOpenCountForTesting`
  is therefore a native-side count of background starts (a reconnect after a
  dropped port counts too).

# Tests

- `NativeHostKeepAliveTests` — the state machine, every ordering.
- `ExtensionPolyfillTests` — the JS side against a fake `connectNative`.
- `ExtensionPolyfillProfileWiringTests` — real `Profile` and worker:
  arm/disarm, `runtime.reload()` with one and two hosts, a superseded relay,
  a silent background restarted, one missed reply not restarting, and the
  four install decisions. `__detourKeepAliveIgnorePings` lets a test play a
  dead background.
- Long measurement legs are skipped unless
  `TEST_RUNNER_DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1` or
  `TEST_RUNNER_DETOUR_MEASURE_WORKER_UNLOAD=1` is set; see
  [testing extensions](./testing-extensions.md).

# Related

- [Service worker unload rules](../platform/service-worker-unload-rules.md) — the WebKit timers this works against
- [Native messaging](./native-messaging.md) — where hosts connect and disconnect
- [WebSocket relay](./websocket-relay.md) — sockets count as hosts
- [Data store and ITP](./data-store-and-itp.md) — what actually killed the worker in production
- [Chrome runtime patching](./chrome-runtime-patching.md) — why `connectNative` cannot be wrapped
- [1Password integration](./1password-integration.md) — the extension this was built for
- [Signed-build verification](../playbooks/signed-build-verification.md) — how the production rows were obtained

[^task-15]: The polyfill must not replace the chrome/browser globals
[^task-16]: Keep the background worker alive while a native host is connected (native-side)
[^task-21]: Signed-build verification of the keep-alive and the WebSocket relay
[^task-62]: Extend the keep-alive to background pages
[^task-67]: A replaced worker leaks its native hosts
[^task-68]: The armed keep-alive does not stop WebKit unloading a worker (production)
[^task-70]: Tracking prevention deletes an extension origin's script-written storage
[^task-123]: Defer an update while the extension is busy
