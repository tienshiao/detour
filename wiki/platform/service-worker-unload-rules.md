---
type: Platform Quirk
title: Service worker unload rules
description: WebKit's rules for unloading an extension's background — the 30-second timer, the 2-minute inactive-ports rule and what counts as activity — plus the ways a worker dies without its page closing and the native ports WebKit drops without telling anyone.
tags: [webkit, extensions, service-worker, native-messaging, platform]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:15:18Z }
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
  - id: webkit-countedset
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/HashCountedSet.h
    title: WTF HashCountedSet.h (remove returns true when a value's count reaches zero)
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
  - id: task-67
    resource: backlog:TASK-67
    title: A replaced worker leaks its native hosts
  - id: task-68
    resource: backlog:TASK-68
    title: The armed keep-alive does not stop WebKit unloading a worker
  - id: notes-webkit
    resource: "Agent session notes, 2026-09-12 to 2026-09-14 (not in the repository)"
    title: Session notes on WebKit's unload source and log locations
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
| A port merely stays open | No, beyond moving it from rule 1 to rule 2 |
| Timers, fetches, storage writes, WebSocket frames | No |

So the app cannot keep a background alive by talking to it. It can only make
the background answer.

## Measured timings

| Situation | Unloaded after |
|---|---|
| Idle, no open port | 29.7 s[^task-62] |
| One open, silent native port | 120.0 s after load (120.1 s on a re-run)[^task-62] |
| Ports open, background's last post at T | T + 2 min, rounded up to the next 30 s tick: 149.4 s after the last post in a test; 151 s after load in production, where the last post was about a second after load[^task-68] |
| Background posts at least every 30 s | Not unloaded: 300 s in tests, 23 min in the signed build[^task-21] |
| A native port closes at T while another port stays open | 30.0 s after T in all three recorded cases (see below)[^task-16] |
| Two silent native ports, the background disconnects one at +10 s | +29.7 s, the first tick after load, instead of +120 s[^task-141] |
| Keep-alive armed and answered every 15 s, one of two native ports disconnected at +10 s | +29.7 s[^task-141] |
| Keep-alive armed and answered, a `runtime.connect` port closed by the other end at +10.6 s | +30.2 s[^task-141] |

The shorter delays in WebKit's source (3 s and 6 s) apply only inside
WebKit's own test runner, chosen by bundle id. Detour's tests get the
production timers, which is why the measurement legs take minutes.

## A context unload drops native ports silently

`WebExtensionContext::unload()` clears its native port map without calling
`reportDisconnection`, and `reload()` is `unload()` followed by `load()` on
the same context object. `chrome.runtime.reload()` goes through it. The
embedder therefore gets **no disconnect callback** for any native port the
old background held, and no delegate call says a reload happened.

Reproduced in a test: a worker holding two native ports called
`chrome.runtime.reload()`; no disconnect handler fired, both host processes
kept running, and the replacement worker started within about half a
second.[^task-67]

Closing the background *page* is different. `disconnectPortsForPage` removes
the page's ports, and when a channel has no port left WebKit reports the
native port's disconnection. After an idle unload Detour normally sees its
ports close (the host is killed at that moment in the 120 s measurement
above).

## Closing one port makes WebKit forget the others

Confirmed in WebKit's source and at runtime on 2026-10-03 (local date), on
macOS 26.7 with WebKit framework 21624.5.1.11.3, in the Debug test host
(legs d, e and f of `ExtensionPolyfillProfileWiringTests`, run twice with the
same timings).

`m_pagePortMap` holds, per page, a counted set of that page's ports.
`removePort` ends with:

```cpp
auto& pagePorts = entry->value;
if (pagePorts.remove({ sourceContentWorldType, targetContentWorldType, channelIdentifier }))
    m_pagePortMap.remove(webPageProxyIdentifier);
```

`HashCountedSet::remove` returns true when *that value's* count reaches
zero, not when the set becomes empty.[^webkit-countedset] So the first port
of a page to go takes the page's whole entry with it. The code is identical
on `main` and on the `safari-7624` and `safari-7623` branches.[^webkit-port]
Three things follow, each measured:[^task-141]

- **The open-ports rule stops applying.** `pageHasOpenPorts` is false from
  then on, whatever the background still holds, so the next 30 s tick
  unloads it. A background page with two silent native ports that
  disconnected one at +10 s was closed at +29.7 s; with one port it lives
  120 s.
- **Posting does not help.** The same page with Detour's keep-alive armed,
  a host still connected and every ping answered was closed at +29.7 s. The
  control without the port close was still running at +300 s.
- **Any port counts, whoever closes it.** A `runtime.connect` port opened by
  an extension page and disconnected by that page 10 s later (the shape of a
  content script's port ending when its tab closes) had the armed,
  answering background closed at +30.2 s.

The entry is re-created only by `addPorts`, that is, when the page opens or
receives a new port. Ports that were open before the loss are not put back.

When the page then closes, `disconnectPortsForPage` finds no entry and
reports nothing, so the embedder is **not** told the surviving ports ended:
in the two-port legs Detour still held the surviving port's host process
after the unload, and the port's `onDisconnect` never ran in the page (its
last heartbeat still read "open"). Seen once before in the signed build: the
next worker's keep-alive port arrived while the old one was still
registered, two seconds after the page closed.[^task-21]

Which tick it is depends on what re-arms the timer. A disconnect that is
delivered *to* the background as an event wakes it, and a wake re-arms the
30 s timer: that is the "30.0 s after the last real native port closed" seen
three times when the host side ended the port.[^task-16][^task-21] A port
the background closes itself re-arms nothing, so the tick already scheduled
applies (the +29.7 s above).

Not measured: a service worker background (the bookkeeping is per hidden
page and shared, and the earlier worker observations fit), a signed build,
and how often real extensions close a port while they are being held. It is
a candidate explanation for the worker cycling seen after a 1Password lock
on 2026-09-13, which was attributed to the worker's own timers by
elimination and never reproduced.[^task-68]

A related gap: WebKit does not deliver the error an embedder disconnects a
native port with to an *established* port. Neither `port.error` nor
`runtime.lastError` carries it.[^manager]

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
| One port closing wipes the page's port entry | Nothing yet. The missed-reply recovery below notices 15 to 30 s after the unload and reloads the background about 60 s after it; a fix is tracked as TASK-142 | same |
| No disconnect on a context reload | Treats a second keep-alive port for the same extension as a replaced background and tears down everything held for the old one | same |
| Worker dead under a live page | Two unanswered pings: drop all ports so WebKit's next 30 s tick closes the page, then `loadBackgroundContent` 35 s later | same |
| Stuck registration, code 6 | Unload and reload the context, which gets a fresh origin; at most 3 times per 10 minutes per extension | same |
| No error on an established port's disconnect | Send a message naming the reason just before disconnecting | [Native messaging](../extensions/native-messaging.md) |
| WebSocket deadlock in a worker | Never construct WebKit's worker WebSocket | [WebSocket relay](../extensions/websocket-relay.md) |

To observe the rules, use a one-minute alarm as the wake source and filter
the log by the process id of the instance under test; see
[reading runtime logs](../playbooks/reading-runtime-logs.md). To re-check the
rules after a WebKit update, see
[WebKit source lookup](./webkit-source-lookup.md). The source links on this
page are to WebKit `main` as read on 2026-10-04; session notes from
2026-09-14 record the unload rule and the silent port clear as identical in
the revision closest to the then-shipped macOS WebKit.[^notes-webkit]

# Related

- [Native port keep-alive](../extensions/native-port-keep-alive.md) — the mechanism built on these rules
- [Data store and ITP](../extensions/data-store-and-itp.md) — what cleared the registration under a live page in production
- [Private profile extensions](../extensions/private-profile-extensions.md) — a different reason a worker never answers
- [Testing extensions](../extensions/testing-extensions.md) — the env-gated legs that measure these timers
- [Hidden web view load stalls](./hidden-webview-load-stalls.md) — WebKit's treatment of hidden web views in general
- [WebKit test host traps](./webkit-test-host-traps.md) — other WebKit behaviour that bites in tests

[^manager]: ExtensionManager.swift (keep-alive, supersede teardown, restart)
[^task-2]: Service worker restart after idle termination
[^task-16]: Keep the background worker alive while a native host is connected
[^task-141]: Does removePort drop a page's whole port entry when one port closes
[^webkit-countedset]: WTF HashCountedSet.h
[^task-21]: Signed-build verification of the keep-alive and the WebSocket relay
[^task-62]: Extend the keep-alive to background pages (unload measurements)
[^task-67]: A replaced worker leaks its native hosts
[^webkit-port]: WebKit WebExtensionContextAPIPortCocoa.mm (portPostMessage, addPorts, removePort; read 2026-10-04)
[^task-68]: The armed keep-alive does not stop WebKit unloading a worker
[^notes-webkit]: Session notes on WebKit's unload source and log locations
