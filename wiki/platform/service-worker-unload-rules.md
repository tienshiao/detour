---
type: Platform Quirk
title: Service worker unload rules
description: WebKit's rules for unloading an extension's background — the 30-second timer, the 2-minute inactive-ports rule and what counts as activity — plus the measured timings and the ways a worker dies without its page closing.
tags: [webkit, extensions, service-worker, native-messaging, platform]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:42:31Z }
stale_after: 2027-01-01T00:00:00Z
sources:
  - id: webkit-cocoa
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm
    title: WebKit WebExtensionContextCocoa.mm (unload, reload, unloadBackgroundContentIfPossible; read 2026-10-04)
  - id: webkit-context
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtensionContext.cpp
    title: WebKit WebExtensionContext.cpp (scheduleBackgroundContentToUnload; read 2026-10-04)
  - id: webkit-port
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIPortCocoa.mm
    title: WebKit WebExtensionContextAPIPortCocoa.mm (portPostMessage, addPorts, removePort; read 2026-10-04 on main and on the safari-7624 and safari-7623 branches)
  - id: task-142
    resource: backlog:TASK-142
    title: The native-port keep-alive is defeated when any other port of the background closes
  - id: task-141
    resource: backlog:TASK-141
    title: Does removePort drop a page's whole port entry when one port closes
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests.swift (TASK-141 legs d, e, f)
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan, Phase 1
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (keep-alive, supersede teardown, restart)
  - id: task-2
    resource: backlog:TASK-2
    title: Service worker restart after idle termination
  - id: task-16
    resource: backlog:TASK-16
    title: Keep the background worker alive while a native host is connected
  - id: task-21
    resource: backlog:TASK-21
    title: Signed-build verification of the keep-alive and the WebSocket relay
  - id: task-62
    resource: backlog:TASK-62
    title: Extend the keep-alive to background pages (unload measurements)
  - id: task-68
    resource: backlog:TASK-68
    title: The armed keep-alive does not stop WebKit unloading a worker
  - id: notes-webkit
    resource: "Agent session notes, 2026-09-12 to 2026-09-14 (not in the repository)"
    title: Session notes on WebKit's unload source and log locations
  - id: task-247
    resource: backlog:TASK-247
    title: "Extensions: notifications.onClicked and onClosed are never delivered to the extension"
---

# Behavior

## How a background runs

An extension's background is a **hidden web view**. For a service worker it
loads a page that registers the worker, and the worker then runs on the
*main thread* of that page's content process. For `background.scripts` or
`background.page` the web view is the background page itself. "Unloading the
background" means closing that hidden web view.

## The two timers

From WebKit's source, confirmed by measurement:

1. **30 seconds.** `scheduleBackgroundContentToUnload` arms a one-shot 30 s
   timer after every background load and every wake for an event.
2. **When it fires**, `unloadBackgroundContentIfPossible` re-arms the timer
   instead of unloading if any of these holds:
   - a permission request is pending;
   - the background page has open ports **and** less than 2 minutes have
     passed since `m_lastBackgroundPortActivityTime`;
   - the background is being inspected (Web Inspector attached), or an
     inspector extension page is open.
3. Otherwise the hidden web view is closed. The Networking process then
   clears the service-worker registration and the worker is terminated; the
   next event registers afresh and starts a new worker.

A persistent background (MV2 `persistent` not false) is never unloaded.

## What counts as activity

`m_lastBackgroundPortActivityTime` is written in exactly two places:
`portPostMessage`, when the **sender is the background page**, and
`addPorts`, when the background page opens a port.

| Does it defer the unload? | |
|---|---|
| The background posts a message on any of its ports (runtime or native) | Yes, for 2 minutes |
| The background opens a port | Yes, for 2 minutes |
| A message *arrives* on a port, from a page, a content script or the native side | **No** |
| A `runtime.sendNativeMessage` whose reply is pending (a parked polyfill request) | No |
| A port merely stays open | No, beyond moving it from rule 1 to rule 2 |
| Timers, fetches, storage writes, WebSocket frames | No |

So the app cannot keep a background alive by talking to it. It can only make
the background answer.

## Measured timings

| Situation | Unloaded after |
|---|---|
| Idle, no open port | 29.7 s[^task-62] |
| Idle, a `runtime.sendNativeMessage` reply pending (the polyfill's parked `notifications.awaitEvent`) | Unloaded within 45 s: a pending native-message reply is not activity[^task-247] |
| One open, silent native port | 120.0 s after load (120.1 s on a re-run)[^task-62] |
| Ports open, background's last post at T | T + 2 min, rounded up to the next 30 s tick: 149.4 s after the last post in a test; 151 s after load in production, where the last post was about a second after load[^task-68] |
| Background posts at least every 30 s | Not unloaded: 300 s in tests, 23 min in the signed build[^task-21] |
| A native port closes at T while another port stays open | 30.0 s after T in all three recorded cases (see [WebKit extension ports](./webkit-extension-ports.md#closing-one-port-makes-webkit-forget-the-others))[^task-16] |
| Two silent native ports, the background disconnects one at +10 s | +29.7 s, the first tick after load, instead of +120 s[^task-141] |
| Keep-alive armed and answered every 15 s, one of two native ports disconnected at +10 s | +29.7 s[^task-141] |
| Keep-alive armed and answered, a `runtime.connect` port closed by the other end at +10.6 s | +30.2 s[^task-141] |

The shorter delays in WebKit's source (3 s and 6 s) apply only inside
WebKit's own test runner, chosen by bundle id. Detour's tests get the
production timers, which is why the measurement legs take minutes.

## Port bookkeeping

How WebKit records a background's open ports, which the open-ports rule
reads, is on [WebKit extension ports](./webkit-extension-ports.md): one port
closing wipes the page's whole port entry, so the next 30 s tick unloads it
(TASK-141, TASK-142); a context unload or reload drops native ports without
a disconnect callback (TASK-67); an established port never receives its
disconnect error.

## A worker can die while its page stays loaded

The registration can be cleared from outside the unload path: by a
website-data deletion, by tracking prevention purging the extension origin,
or by the worker calling `registration.unregister()` on itself. The worker is
terminated but the hidden page is **not** closed. From outside:

- every port stays open;
- nothing answers; alarms and messages for the background are lost;
- no error is recorded on the context;
- WebKit closes the page only when the inactive-ports rule finally lets it,
  two minutes after the worker's last post (151 s and 174 s after start in
  the two production cases).[^task-68]

## A page can close without the registration clearing

If the worker's process is frozen (the case seen was a main-thread deadlock
in `new WebSocket()`), the page close is never handled, the registration
stays, and every later wake finds a "directly reusable registration" with no
worker behind it. The pending load then fails when the next unload closes
the page, as `WKWebExtensionContext.Error.backgroundContentFailedToLoad`
(code 6), once per wake.[^task-2]

## Where the log lines are

| Line | Process |
|---|---|
| `WebPageProxy::close`, `WebPageProxy::loadServiceWorker` | The app |
| `SWContextManager::terminateWorker` | The app (the message names the content process)[^notes-webkit] |
| `SWServerRegistration::clear`, `SWServerJobQueue::runRegisterJob` | `com.apple.WebKit.Networking` |
| "Not unloading background content because …" | The app, category `Extensions`, debug level |

`runRegisterJob: No existing registration` after an unload is the healthy
restart. `Found directly reusable registration` on every wake is the stuck
state above.

# Why it matters here

- Chrome keeps a worker alive while it holds a native messaging port;
  WebKit unloads it two minutes after its last post. An extension built for
  Chrome (1Password) loses its desktop-app connection on that schedule.
- Detour holds native resources per background: host processes, relayed
  sockets, a keep-alive port. If WebKit does not report that a background
  went away, those leak and keep counting.
- A dead worker under a live page looks healthy to every API Detour has.

# Workaround

| Problem | What Detour does | Page |
|---|---|---|
| Unload while a native host or relayed socket is live | Pings the background on a built-in port every 30 s; the *reply* is the background post WebKit counts | [Native port keep-alive](../extensions/native-port-keep-alive.md) |
| WebKit's port bookkeeping (a wiped port entry, no disconnect on a context reload) | See the workarounds on [WebKit extension ports](./webkit-extension-ports.md#workaround) | [WebKit extension ports](./webkit-extension-ports.md) |
| Worker dead under a live page | Two unanswered pings: drop all ports so WebKit's next 30 s tick closes the page, then `loadBackgroundContent` 35 s later | same |
| Stuck registration, code 6 | Unload and reload the context, which gets a fresh origin; at most 3 times per 10 minutes per extension | same |
| WebSocket deadlock in a worker | Never construct WebKit's worker WebSocket | [WebSocket relay](../extensions/websocket-relay.md) |

To observe the rules, use a one-minute alarm as the wake source and filter
the log by the process id of the instance under test; see
[reading runtime logs](../playbooks/reading-runtime-logs.md). To re-check the
rules after a WebKit update, see
[WebKit source lookup](./webkit-source-lookup.md). The source links on this
page are to WebKit `main` as read on 2026-10-04; session notes from
2026-09-14 record the unload rule (and the silent port clear, now on
[WebKit extension ports](./webkit-extension-ports.md)) as identical in
the revision closest to the then-shipped macOS WebKit.[^notes-webkit]

# Related

- [Native port keep-alive](../extensions/native-port-keep-alive.md) — the mechanism built on these rules
- [WebKit extension ports](./webkit-extension-ports.md) — the port record the open-ports rule reads, and where it goes wrong
- [Data store and ITP](../extensions/data-store-and-itp.md) — what cleared the registration under a live page in production
- [Private profile extensions](../extensions/private-profile-extensions.md) — a different reason a worker never answers
- [Testing extensions](../extensions/testing-extensions.md) — the env-gated legs that measure these timers
- [Hidden web view load stalls](./hidden-webview-load-stalls.md) — WebKit's treatment of hidden web views in general
- [WebKit test host traps](./webkit-test-host-traps.md) — other WebKit behaviour that bites in tests

[^task-2]: Service worker restart after idle termination
[^task-16]: Keep the background worker alive while a native host is connected
[^task-141]: Does removePort drop a page's whole port entry when one port closes
[^task-21]: Signed-build verification of the keep-alive and the WebSocket relay
[^task-62]: Extend the keep-alive to background pages (unload measurements)
[^task-68]: The armed keep-alive does not stop WebKit unloading a worker
[^notes-webkit]: Session notes on WebKit's unload source and log locations
[^task-247]: Extensions: notifications.onClicked and onClosed are never delivered to the extension
