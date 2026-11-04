---
id: TASK-256
title: >-
  Extensions: a port's onDisconnect fires in the context that called
  port.disconnect()
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T17:25:00Z'
updated_date: '2026-11-03T22:54:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: low
type: bug
ordinal: 300000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noticed during TASK-241 runtime verification: an extension page that calls port.disconnect() on its connectNative port also gets that port's onDisconnect. In Chrome onDisconnect fires only on the other end, never for the caller's own disconnect. Whether this is Detour's polyfill/native port code or WebKit's runtime.Port is unknown. Extensions that reconnect in onDisconnect (common for native hosts) can loop.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Whether the event comes from Detour's code or WebKit's is recorded
- [x] #2 If it is Detour's, a port that calls disconnect() itself no longer gets onDisconnect, for native ports and runtime.connect ports, with real-context tests; if WebKit's, the behaviour and any workaround are recorded
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure: read Detour's native port handlers (connectUsing, WebSocketRelay, anchor/keep-alive ports) and WebKit's WebExtensionAPIPortCocoa.mm at main and at its history.
2. Pin the measurement with real-context tests: a page's own disconnect() of a connectNative port and of a runtime.connect port to the worker; record whether onDisconnect runs inside the disconnect() call (web process, WebKit) or later (IPC, possibly Detour).
3. Decide on a polyfill workaround (connectNative cannot be wrapped; the keep-alive port watch relies on the self-fired event); record the finding in the wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: WebKit, not Detour. Shipped WebKit (macOS 26.7) WebExtensionAPIPort::disconnect() calls fireDisconnectEventIfNeeded(), so the caller's own onDisconnect listeners run synchronously inside disconnect(), in the web process, before anything reaches the UI process. Measured in real contexts: a page's connectNative port (fake host) and runtime.connect ports page->worker and worker->page all give during=1, after=0, no port.error. Detour's side ruled out: connectUsing's port.disconnectHandler only releases the host and calls host.disconnect() (which by design fires no onDisconnect); host.onDisconnect (process exit only) is the only path that calls port.disconnect; runtime ports never touch Detour native code. WebKit fixed it upstream 2026-10-30, c78afbcefdb9 / 325256@main (bug 329433, rdar://191316639): disconnect() now just marks, removes and notifies the other end; failed connects call fireDisconnectEventIfNeeded() so port.error still arrives. Not in a shipped build yet.

No workaround, by decision: connectNative cannot be wrapped from JS (re-materialized on every read), so the reported native case is out of the polyfill's reach; and the keep-alive's watchPort (installPortWatch) relies on the self-fired event to re-anchor when the background closes a runtime/tabs port itself. A suppression wrapper on runtime ports only would fix half the case and have to keep Detour's watch listener while dropping the extension's. Impact for extensions: one reconnect after their own deliberate disconnect (a fresh host), a loop only if the extension disconnects again on that.

Pinned with two tests that fail on a WebKit with the fix: NativeMessagingEnforcementTests.testWebKitFiresAPagesOwnOnDisconnectInsideConnectNativeDisconnect and ExtensionPolyfillProfileWiringTests.testWebKitFiresTheCallersOwnOnDisconnectInsideRuntimePortDisconnect (page and worker legs). When they fail, watchPort must wrap port.disconnect on each watched port to re-anchor.

Tests: ExtensionPolyfillProfileWiringTests 64 (13 skipped, gated legs), NativeMessagingEnforcementTests 19, NativeMessagingHostLifecycleTests 20, NativeHostKeepAliveTests 17: all pass. Test-only plus wiki: no product code changed, so /code-review and /verify were skipped (per the task brief and CLAUDE.md). Wiki: native-messaging (gotcha), native-port-keep-alive (corrected the 'shadowing port.disconnect was unnecessary' rationale), testing-extensions (trap: a connect right after the worker's first round trip can be refused with 'No runtime.onConnect listeners found' on a warm host).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The self-fired onDisconnect is WebKit's (WebExtensionAPIPort::disconnect() fires the caller's own listeners synchronously; fixed upstream in 325256@main on 2026-10-30, unshipped). Detour's native port code plays no part. No polyfill workaround: connectNative cannot be wrapped and the keep-alive port watch depends on the event. Two real-context tests pin the behaviour for native and runtime ports, page and worker, so the shipped fix is noticed; at that point the keep-alive's watchPort must wrap port.disconnect. Recorded in the wiki.
<!-- SECTION:FINAL_SUMMARY:END -->
