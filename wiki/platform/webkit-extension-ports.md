---
type: Platform Quirk
title: WebKit extension ports
description: How shipped WebKit keeps the books on extension message ports — one closing port wipes a page's whole port entry, a page's own disconnect() fires its own onDisconnect, a context unload drops native ports without a callback, and an established port never receives its disconnect error.
tags: [webkit, extensions, native-messaging, service-worker, platform]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:42:31Z }
stale_after: 2027-03-01T00:00:00Z
sources:
  - id: webkit-port
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIPortCocoa.mm
    title: WebKit WebExtensionContextAPIPortCocoa.mm (portPostMessage, addPorts, removePort; read 2026-10-04 on main and on the safari-7624 and safari-7623 branches)
  - id: webkit-countedset
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/HashCountedSet.h
    title: WTF HashCountedSet.h (remove returns true when a value's count reaches zero)
  - id: webkit-cocoa
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm
    title: WebKit WebExtensionContextCocoa.mm (unload, reload; read 2026-10-04)
  - id: webkit-325256
    resource: https://github.com/WebKit/WebKit/commit/c78afbcefdb9
    title: "WebKit 325256@main: Port.disconnect() fires onDisconnect on the port that called it"
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (connectUsing, keep-alive, supersede teardown, restart)
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests.swift (TASK-141 legs d, e, f; the TASK-256 pins)
  - id: task-141
    resource: backlog:TASK-141
    title: Does removePort drop a page's whole port entry when one port closes
  - id: task-142
    resource: backlog:TASK-142
    title: The native-port keep-alive is defeated when any other port of the background closes
  - id: task-256
    resource: backlog:TASK-256
    title: "Extensions: a port's onDisconnect fires in the context that called port.disconnect() (WebKit, fixed upstream in 325256@main)"
  - id: task-263
    resource: backlog:TASK-263
    title: "Extensions: the keep-alive port watch must not depend on WebKit firing a port's own onDisconnect"
  - id: task-16
    resource: backlog:TASK-16
    title: Keep the background worker alive while a native host is connected
  - id: task-21
    resource: backlog:TASK-21
    title: Signed-build verification of the keep-alive and the WebSocket relay
  - id: task-67
    resource: backlog:TASK-67
    title: A replaced worker leaks its native hosts
  - id: notes-webkit
    resource: "Agent session notes, 2026-09-12 to 2026-09-14 (not in the repository)"
    title: Session notes on WebKit's unload source
  - id: task-68
    resource: backlog:TASK-68
    title: The armed keep-alive does not stop WebKit unloading a worker
---

WebKit keeps the books on extension message ports in two places: the UI
process's per-page record of open ports, which the unload timer's
open-ports rule reads, and each context's native port map. In shipped
WebKit (macOS 26.7) they differ from Chrome in several ways: a port closing
can wipe the per-page record, a page's own `disconnect()` fires its own
`onDisconnect`, a context unload drops native ports without telling the
embedder, and a disconnect error never reaches an established port. Detour
works around most of them; the timers are on
[service worker unload rules](./service-worker-unload-rules.md).

# Behavior

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
applies (the +29.7 s above; all of these are in the
[measured timings](./service-worker-unload-rules.md#measured-timings)).

A service worker background behaves the same (measured for TASK-142): with
the keep-alive armed but no anchor, a runtime port closed at +10 s left the
first unanswered ping to be noticed at +45 s.[^task-142] Not measured: a
signed build, and how often real extensions close a port while they are
being held. It is
a candidate explanation for the worker cycling seen after a 1Password lock
on 2026-09-13, which was attributed to the worker's own timers by
elimination and never reproduced.[^task-68]

## A page's own port.disconnect() fires its own onDisconnect

Chrome fires `onDisconnect` only at the other end. Shipped WebKit (macOS
26.7) runs the caller's listeners synchronously inside the `disconnect()`
call, for `connectNative` ports and `runtime.connect` ports alike, from a
page and from a worker, with no `port.error`. Nothing of Detour's is
involved: the call never leaves the web process before the listeners run,
and Detour's `disconnectHandler` (release the host, `host.disconnect()`)
calls nothing back on the port. The cause is
`WebExtensionAPIPort::disconnect()` calling `fireDisconnectEventIfNeeded()`;
WebKit fixed it upstream on 2026-10-30 (325256@main), not yet in a shipped
build.[^webkit-325256] An extension that reconnects in `onDisconnect`
therefore reconnects after its own deliberate disconnect too, starting a
fresh host. No workaround: `connectNative` cannot be wrapped (see
[chrome.runtime patching](../extensions/chrome-runtime-patching.md)).
`testWebKitFiresAPagesOwnOnDisconnectInsideConnectNativeDisconnect` and
`testWebKitFiresTheCallersOwnOnDisconnectInsideRuntimePortDisconnect` pin
it, so a WebKit that ships the fix fails them; flip them then.[^task-256]

## Other facts about the bookkeeping

Other facts about WebKit's port bookkeeping that matter for working around
it (WebKit main, `WebExtensionAPIPort.cpp`, `WebExtensionAPIRuntime.cpp`,
`WebExtensionContextAPIRuntimeCocoa.mm`, read 2026-10-28):[^task-142]

- **Every `onConnect` listener gets its own port.** The web process creates
  one `WebExtensionAPIPort` per listener and reports one open port per
  listener for the page. A second listener therefore adds a second port to
  the channel, which keeps it open after the first is disconnected.
- **A port's removal goes out before its `onDisconnect` listeners run**
  (`fireDisconnectEventIfNeeded` calls `remove()` first), and a page's own
  `port.disconnect()` takes the same path, so its own listeners fire too
  (Chrome does not fire them for the closing side). That last part is the
  WebKit bug [above](#a-pages-own-portdisconnect-fires-its-own-ondisconnect),
  fixed upstream on 2026-10-30 (325256@main) and still present in shipped
  WebKit (macOS 26.7).[^task-256] A port nobody holds is
  removed when it is collected, and then its listeners do **not** run
  (measured in a worker: the extension's own `onDisconnect` never fired, and
  the other side's later close found nothing).
- **`runtime.connectNative` adds the page's port before asking the
  embedder** (`addPorts` first, then `connectUsingMessagePort`), so a refused
  connect is added and then removed: a wipe like any other.
- The open-ports rule uses 2 minutes in an app and 6 s under WebKit's own
  test runner (`isNotRunningInTestRunner`); Detour's test host counts as an
  app.

## A context unload drops native ports silently

`WebExtensionContext::unload()` clears its native port map without calling
`reportDisconnection`, and `reload()` is `unload()` followed by `load()` on
the same context object. `chrome.runtime.reload()` goes through it. The
embedder therefore gets **no disconnect callback** for any native port the
old background held, and no delegate call says a reload happened.

Reproduced in a test: a worker holding two native ports called
`chrome.runtime.reload()`; no disconnect handler fired, both host processes
kept running, and the replacement worker started within about half a
second.[^task-67] Session notes from 2026-09-14 record the silent port clear
as identical in the revision closest to the then-shipped macOS
WebKit.[^notes-webkit]

Closing the background *page* is different. `disconnectPortsForPage` removes
the page's ports, and when a channel has no port left WebKit reports the
native port's disconnection. After an idle unload Detour normally sees its
ports close (the host is killed at that moment in the 120 s measurement on
[service worker unload rules](./service-worker-unload-rules.md#measured-timings)),
unless a closed port has already wiped the page's entry (above).

## A disconnect error never reaches an established port

WebKit does not deliver the error an embedder disconnects a native port
with to an *established* port. Neither `port.error` nor `runtime.lastError`
carries it (measured 2026-09-13).[^manager] The error only arrives when the
*connect* is refused.

# Why it matters here

- Detour's [keep-alive](../extensions/native-port-keep-alive.md) depends on
  `pageHasOpenPorts`: any port of the background closing used to end the
  hold at the next 30 s tick, and WebKit then reported none of the
  surviving ports closed, so Detour still held their host processes after
  the unload.
- A replaced or reloaded background leaves its native hosts running unless
  Detour notices on its own.
- An extension written for Chrome that reconnects in `onDisconnect`
  reconnects after its own disconnects too.
- Detour cannot tell an extension *why* it ended a port.

# Workaround

| Problem | What Detour does | Page |
|---|---|---|
| One port closing wipes the page's port entry | While armed, the background holds an anchor port and closes and re-opens it after any of its ports ends, which re-creates the entry (TASK-142) | [Native port keep-alive](../extensions/native-port-keep-alive.md#the-anchor-task-142) |
| A port's own `disconnect()` fires its own `onDisconnect` (and will stop doing so once the fix ships) | The keep-alive's port watch wraps `disconnect` on the ports it watches, so it sees the end either way (TASK-263);[^task-263] nothing for an extension's own reconnect | same |
| No disconnect on a context reload | Treats a second keep-alive port for the same extension as a replaced background and tears down everything held for the old one | [Native port keep-alive](../extensions/native-port-keep-alive.md#a-replaced-background-takes-its-hosts-with-it) |
| No error on an established port's disconnect | Send a message naming the reason just before disconnecting (`keepalive-superseded`) | same; [native messaging](../extensions/native-messaging.md) |

To re-check these after a WebKit update, see
[WebKit source lookup](./webkit-source-lookup.md); the TASK-256 pins and the
TASK-141 / TASK-142 measurement legs (behind
`TEST_RUNNER_DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1`, see
[testing extensions](../extensions/testing-extensions.md)) are the runtime
checks.

# Related

- [Service worker unload rules](./service-worker-unload-rules.md) — the timers that read the port record
- [Native port keep-alive](../extensions/native-port-keep-alive.md) — the anchor and port watch built on these facts
- [Native messaging](../extensions/native-messaging.md) — the `connectUsing` delegate whose ports these are
- [Writing to a native host](../extensions/native-host-writing.md) — a send failure's error text that only reaches the log
- [Chrome runtime patching](../extensions/chrome-runtime-patching.md) — why `connectNative` cannot be wrapped

[^webkit-countedset]: WTF HashCountedSet.h
[^webkit-port]: WebKit WebExtensionContextAPIPortCocoa.mm (portPostMessage, addPorts, removePort; read 2026-10-04)
[^webkit-325256]: WebKit 325256@main: Port.disconnect() fires onDisconnect on the port that called it
[^manager]: ExtensionManager.swift (connectUsing, keep-alive, supersede teardown, restart)
[^task-141]: Does removePort drop a page's whole port entry when one port closes
[^task-142]: The native-port keep-alive is defeated when any other port of the background closes
[^task-256]: Extensions: a port's onDisconnect fires in the context that called port.disconnect()
[^task-263]: Extensions: the keep-alive port watch must not depend on WebKit firing a port's own onDisconnect
[^task-16]: Keep the background worker alive while a native host is connected
[^task-21]: Signed-build verification of the keep-alive and the WebSocket relay
[^task-67]: A replaced worker leaks its native hosts
[^task-68]: The armed keep-alive does not stop WebKit unloading a worker
[^notes-webkit]: Session notes on WebKit's unload source
