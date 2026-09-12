---
id: TASK-16
title: >-
  Extensions: keep the background worker alive while a native messaging host is
  connected (native-side, Chrome parity)
status: To Do
assignee: []
created_date: '2026-09-12 06:39'
updated_date: '2026-09-12 08:50'
labels:
  - extensions
  - 1password
  - webkit
dependencies: []
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Chrome keeps an extension's service worker alive while it holds a native messaging port. TASK-2 tried to reproduce this from JavaScript (ExtensionAPIPolyfill.nativePortKeepAliveJS: wrap runtime.connectNative, hold a port to Detour's own detourPolyfill host and ping it) but it cannot work in WebKit: runtime.connectNative is re-materialized on every read so the wrap never takes (installMode 'none'/'patch-rejected'), and its former fallback of swapping the chrome/browser globals broke all page->worker messaging (TASK-15). Observed 2026-09-11 22:00-22:10 even with the old wrapper in effect: all three 1Password workers were terminated and re-activated every 2 minutes (SWContextManager::terminateWorker at :06, SWServer::didFinishActivation at :36), so the JS keep-alive never prevented unload either. Detour already knows, on the native side, exactly when an extension has a live native host (NativeMessagingHost spawn/exit, ExtensionManager connectUsing delegate). Design and implement a native-side mechanism: while an extension has >=1 connected native host, keep WebKit from unloading its background content (candidates: keep an event flowing to the worker via a port Detour holds open from the native side, WebKit's activity accounting for messages received on a native port, or a supported WKWebExtensionContext API if one exists); stop when the last host exits so idle unload resumes. Measure first: confirm from the WebKit ServiceWorker log what resets the 30 s unload timer (docs/1password-integration-plan.md Phase 1). Keep the existing JS status object (installMode) so a WebKit change is noticed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With 1Password connected to its native host, its background worker is not terminated for at least 10 minutes of user inactivity (verified from the WebKit ServiceWorker log: no terminateWorker for the context)
- [ ] #2 When the last native host for the extension exits, the worker is unloaded by WebKit's normal idle timer within a few minutes
- [ ] #3 Popup, options and content-script runtime.sendMessage to the worker keep working (ExtensionPolyfillIntegrationTests.testRuntimeSendMessageReachesWorkerRunningThePolyfill stays green) and the mechanism never reassigns the chrome/browser globals
- [ ] #4 Unit tests cover the native-side state machine (host connected -> keep-alive active, last host exits -> inactive, context unload -> cleaned up) and docs/1password-integration-plan.md Phase 1 is updated with the measured unload-timer behaviour
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Established (TASK-2 harness, 2026-09-11 18:14): a message the background posts on any port resets WebKit's 2-minute inactive-ports unload (WebExtensionContext::portPostMessage); with pings flowing on the detourPolyfill port a worker holding a native port survived a 3-minute hold and unloaded 30 s after release. What failed later was only the JS-side detection of real ports (connectNative unpatchable). Design: 1. Worker polyfill (service workers only): at startup open one port to detourPolyfill via a plain chrome.runtime.connectNative call (no wrapping), keep it idle, reconnect with backoff if Detour drops it; ping {type:'keepalive'} every 45 s only while a native control message {type:'keepalive-start'} has been received and until {type:'keepalive-stop'}; expose installMode/state on __detourNativePortKeepAlive for the diag; remove the dead wrap/trackRealPort machinery. 2. ExtensionManager: per (controller, extension) a NativeHostKeepAlive record {port, connectedHosts: Int}; connectUsing .allowed increments on host.connect success and decrements on host disconnect / port disconnect; 0->1 sends keepalive-start on the keep-alive port (or remembers 'pending' if the port is not open yet and sends when it opens), 1->0 sends keepalive-stop; context unload (closeKeepAlivePort) clears everything. sendNativeMessage one-shots do not count. Pure state machine extracted (struct) and unit-tested; the port plumbing tested with a fake port in ExtensionPolyfillTests / a fake NativeMessagingHost. 3. Runtime verification in the isolated harness (DETOUR_DATA_DIR, DETOUR_NATIVE_MESSAGING_HOSTS_DIR -> silent fake host script, probe extension holding a port with a 1-minute alarm): no terminateWorker for 10 min while held; unload within ~2.5 min after release; popup->worker sendMessage still works (integration test stays green). 4. docs/1password-integration-plan.md Phase 1: replace the inert-keep-alive status with the native-driven design and the measured timer behaviour.
<!-- SECTION:PLAN:END -->
