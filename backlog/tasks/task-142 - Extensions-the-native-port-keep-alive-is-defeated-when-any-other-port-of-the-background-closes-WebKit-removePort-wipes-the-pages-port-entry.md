---
id: TASK-142
title: >-
  Extensions: the native-port keep-alive is defeated when any other port of the
  background closes (WebKit removePort wipes the page's port entry)
status: Done
assignee:
  - '@claude'
created_date: 2026-10-04 02:09
updated_date: '2026-10-29T02:27:00Z'
labels: []
dependencies:
  - TASK-141
references:
  - wiki/platform/service-worker-unload-rules.md
  - wiki/extensions/native-port-keep-alive.md
priority: high
ordinal: 165000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-141 confirmed, in WebKit's source and at runtime, that WebExtensionContext::removePort removes a page's whole entry from m_pagePortMap when any one port's count reaches zero. From then on pageHasOpenPorts is false for the background, the 2-minute open-active-ports rule no longer applies, and the next 30 s unload tick closes the background — while Detour's keep-alive port is open, armed and being answered.

Measured 2026-10-03 on a background page in the test host (ExtensionPolyfillProfileWiringTests, DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1): two native ports, one disconnected at +10 s, keep-alive armed with a host still connected: unloaded at +29.7 s (control without the close: still running at +300 s). The same with an ordinary runtime.connect port that an extension page opened and closed: unloaded at +30.2 s. After the unload WebKit reports no disconnect for the surviving ports, so Detour keeps the host process and an armed keep-alive until the missed-reply recovery drops them 15–30 s later and reloads the background about 60 s after the unload; if the extension repeats the pattern, it cycles.

So the keep-alive (TASK-16/62/68) only holds for a background whose ports never close while it is being held. Any content-script port ending (a tab closing or navigating), a second native port closing, or a relayed socket closing breaks it. Not yet measured: a service worker background (same WebKit code path), a signed build, and how often real extensions (1Password) hit it.

Directions to evaluate, not decided: (a) re-create the page's entry after a loss — WebKit's addPorts re-creates it whenever the background opens a port, so the polyfill could open a fresh keep-alive port after any of the background's ports disconnects, and/or on every ping; (b) have the native side detect the unload sooner than two missed pings; (c) report the bug to WebKit (the fix there is to remove the page entry only when its counted set is empty).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A background that is being kept alive stays loaded after another of its ports closes: a second native port, a runtime.connect port closed by the other end, and a port the background closes itself
- [x] #2 The TASK-141 legs (d)–(f) are joined by legs showing the page still running well past the 30 s tick with the fix, and the existing keep-alive tests still pass
- [x] #3 The same is shown for a service worker background, not only a background page
- [x] #4 No port or host is leaked by the fix, and a background that should unload (no host, no relayed socket) still does
- [x] #5 A WebKit bug is filed or the task records why not; the wiki pages platform/service-worker-unload-rules.md and extensions/native-port-keep-alive.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Confirm from WebKit source what re-creates a page's port entry (addPorts: a port the page opens or receives) and when the unload tick runs.
2. Proof of concept in a measurement leg: close-then-reopen a native port after the runtime port ends.
3. Anchor port (detourKeepAliveAnchor) held natively; polyfill re-anchors on: watched port ends (wrapped runtime.connect / tabs.connect / onConnect listeners), Detour's keepalive-reanchor after a host/relay close or refused connect, every ping.
4. Tests (JS, wiring, permission), legs with and without the anchor for page and worker; /code-review --fix, /verify; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-28 implementation:
- WebKit facts (main): removePort wipes on the first tuple to reach zero; addPorts re-creates; runtimeConnectNative calls addPorts before asking the delegate; fireDisconnectEventIfNeeded sends PortRemoved before running onDisconnect listeners, and a local disconnect() fires the page's own listeners; every onConnect listener gets its own WebExtensionAPIPort (one counted per listener); a collected port is removed without its listeners running (measured in a worker).
- POC (leg f + close/reopen of a fake-host port): unloaded at +30.2 s before, still running at +211 s.
- Design: anchor port detourKeepAliveAnchor (.keepAliveAnchorHost, keepAliveAnchorPorts); polyfill closes then re-opens it on a task of its own (coalesced). Triggers: wrapped runtime.connect/tabs.connect, wrapped extension onConnect/onConnectExternal listeners (a listener of Detour's own was tried first and rejected: it got a port of its own, nobody held it, and it kept the channel open), keepalive-reanchor from Detour (applyKeepAlive on hostDisconnected while armed, refused connectNative), keepalive-start, every ping. Disarm leaves the anchor open (closing it wiped the entry and the unload then reported no port). The last anchor closing while disarmed with none a second later = the unload (WebKit then reports only the anchor): Detour drops/disconnects the keep-alive port and applies portClosed. Anchors dropped on keep-alive port arrival, context unload, restart.
- Review (/code-review --fix): added re-anchor on a refused connectNative, browser.* namespaces watched too, helper error, dead check removed; skipped re-anchoring after a Detour-side anchor drop (loop risk) and an anchor cap (closing one would wipe).
Measured (test host, macOS 26.7, pings every 15 s): page legs without -> with anchor: one of two native ports closed at +10 s: unloaded +29.7 s -> alive at +150 s (1 re-anchor request); runtime port closed by the page at +10.5 s: +30.2 s -> alive at +150 s; background closes its own port at +10.2 s: +29.7 s -> alive at +150 s; each with 1 anchor held, 1 host + 1 host process, 1 background start. Worker, runtime port closed at +10 s: first unanswered ping at +45 s -> all 11 pings answered over 150 s, 1 anchor. TASK-68 worker leg (60 s): replies 3/3, released -> keep-alive port closed 151.3 s later (149.4 s before TASK-142). Leg d (WebKit pin) unchanged: +29.7 s.
Tests: ExtensionPolyfillTests + ExtensionPermissionTests + ExtensionPolyfillProfileWiringTests + NativeHostKeepAliveTests: 289 passed, 13 skipped (long legs), 0 failed; long legs run separately as above, all pass.
/verify: Debug build, isolated DETOUR_DATA_DIR, seeded MV3 worker with nativeMessaging + fake host holding two ports, second closed at +10 s: 'Keep-alive re-anchor requested' at the close, pings #2-#4 answered through +90 s, anchor open (opened 5), no polyfill errors; cleaned up (orphaned fake host, defaults keys, data dir).
Not verified: signed build with 1Password.
WebKit bug: not filed by the agent (it goes out under the user's account); draft with the fix (remove the page entry only when its counted set is empty) and repro is in the final summary's pointer: scratchpad webkit-bug-removePort.md, text also below.
Bug text: WebExtensionContext::removePort (WebExtensionContextAPIPortCocoa.mm) removes m_pagePortMap[page] when pagePorts.remove(tuple) returns true, i.e. when that tuple's count reaches zero, not when the page has no ports; expected 'if (pagePorts.remove(...) && pagePorts.isEmpty())'. Repro: non-persistent background with two ports, keep posting, close one at +10 s -> unloaded at the next 30 s tick; and disconnectPortsForPage then reports none of the surviving ports.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An armed background now survives any of its other ports closing. It holds an extra 'anchor' native port and, after any of its ports ends (watched in the polyfill, or reported by Detour for native hosts, relays and refused connects, plus every ping), closes and re-opens it, which re-creates the port record WebKit's removePort wipes. Measured: background pages that unloaded at about +30 s after a native port, a runtime port or their own port closed now run past +150 s; a service worker likewise; nothing leaks (one anchor, the right hosts, one start); a released worker still unloads after about 150 s and is now reported. Verified in the running app with a seeded extension and fake host. Not checked in a signed build with 1Password. WebKit bug drafted for the user to file.
<!-- SECTION:FINAL_SUMMARY:END -->
