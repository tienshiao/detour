---
id: TASK-16
title: >-
  Extensions: keep the background worker alive while a native messaging host is
  connected (native-side, Chrome parity)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 06:39'
updated_date: '2026-09-12 10:10'
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
- [x] #1 With 1Password connected to its native host, its background worker is not terminated for at least 10 minutes of user inactivity (verified from the WebKit ServiceWorker log: no terminateWorker for the context)
- [x] #2 When the last native host for the extension exits, the worker is unloaded by WebKit's normal idle timer within a few minutes
- [x] #3 Popup, options and content-script runtime.sendMessage to the worker keep working (ExtensionPolyfillIntegrationTests.testRuntimeSendMessageReachesWorkerRunningThePolyfill stays green) and the mechanism never reassigns the chrome/browser globals
- [x] #4 Unit tests cover the native-side state machine (host connected -> keep-alive active, last host exits -> inactive, context unload -> cleaned up) and docs/1password-integration-plan.md Phase 1 is updated with the measured unload-timer behaviour
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Established (TASK-2 harness, 2026-09-11 18:14): a message the background posts on any port resets WebKit's 2-minute inactive-ports unload (WebExtensionContext::portPostMessage); with pings flowing on the detourPolyfill port a worker holding a native port survived a 3-minute hold and unloaded 30 s after release. What failed later was only the JS-side detection of real ports (connectNative unpatchable). Design: 1. Worker polyfill (service workers only): at startup open one port to detourPolyfill via a plain chrome.runtime.connectNative call (no wrapping), keep it idle, reconnect with backoff if Detour drops it; ping {type:'keepalive'} every 45 s only while a native control message {type:'keepalive-start'} has been received and until {type:'keepalive-stop'}; expose installMode/state on __detourNativePortKeepAlive for the diag; remove the dead wrap/trackRealPort machinery. 2. ExtensionManager: per (controller, extension) a NativeHostKeepAlive record {port, connectedHosts: Int}; connectUsing .allowed increments on host.connect success and decrements on host disconnect / port disconnect; 0->1 sends keepalive-start on the keep-alive port (or remembers 'pending' if the port is not open yet and sends when it opens), 1->0 sends keepalive-stop; context unload (closeKeepAlivePort) clears everything. sendNativeMessage one-shots do not count. Pure state machine extracted (struct) and unit-tested; the port plumbing tested with a fake port in ExtensionPolyfillTests / a fake NativeMessagingHost. 3. Runtime verification in the isolated harness (DETOUR_DATA_DIR, DETOUR_NATIVE_MESSAGING_HOSTS_DIR -> silent fake host script, probe extension holding a port with a 1-minute alarm): no terminateWorker for 10 min while held; unload within ~2.5 min after release; popup->worker sendMessage still works (integration test stays green). 4. docs/1password-integration-plan.md Phase 1: replace the inert-keep-alive status with the native-driven design and the measured timer behaviour.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (2026-09-12): NativeHostKeepAliveState pure state machine (connectedHosts/portOpen/armed -> sendStart/sendStop) in NativeHostKeepAlive.swift; ExtensionManager applies hostConnected after a successful NativeMessagingHost.connect() in connectUsing (.allowed), hostDisconnected exactly once from whichever of host exit / port disconnect fires first, portOpened/portClosed from the detourPolyfill port (including replacement), contextUnloaded from closeKeepAlivePort; control messages keepalive-start/stop sent on the worker's port; ping counter for tests. Worker polyfill rewritten: opens one idle detourPolyfill port at startup with a plain connectNative call (no wrapping, globals untouched), pings only between start/stop, reconnects with 1 s -> 30 s backoff, diag installMode 'port'. Tests: NativeHostKeepAliveTests (12), keep-alive JS tests rewritten (8), manager-level end-to-end test in ExtensionPolyfillProfileWiringTests (real Profile controller: worker opens the port on its own, simulated host arms it, a ping is received, disconnect disarms). 154 tests green; app builds. Plan doc Phase 1 item 1 and chrome-runtime-patching.md updated. Runtime harness verification (AC #1/#2) in progress in DETOUR_DATA_DIR=DetourKeepAlive16.

Code review (medium) decisions: keep-alive port now opened only by workers whose manifest declares nativeMessaging (otherwise every idle worker would move from the 30 s unload to the 2-minute inactive-ports path for nothing); the port is accepted (completionHandler) before keepalive-start is sent, and a failed control send clears the armed latch and reconciles after 1 s so a wanted start is retried; live NativeMessagingHosts are tracked per (controller, extension) so closeKeepAlivePort tears them down and a late release after a reload on the same key cannot send a spurious stop; wiring-test fixture and worker round-trip helpers deduplicated into ExtensionTestSupport. Declined: deriving armed from connectedHosts/portOpen, because the send-failure recovery needs armed to diverge (documented in the state machine).

Harness verification (2026-09-12 02:29-02:45, Debug build, DETOUR_DATA_DIR=DetourKeepAlive16, probe extension holding a port to a silent fake host under DETOUR_NATIVE_MESSAGING_HOSTS_DIR, 1-minute alarm): AC #1 PASS: workers created 02:29:19, keep-alive armed 4 ms after the host connected, 11 heartbeats 60 s apart all reporting armed/active, zero SWContextManager::terminateWorker / SWServerRegistration::clear / addRegistration during the 11-minute hold, no code 6, no recovery. AC #2 PASS: probe released the port at 02:40:19.948, 'Keep-alive disarmed' at .952, host torn down at .953, WebKit cleared both registrations and terminated both workers at 02:40:49.903 (30 s after the disarm); the next alarm created a fresh registration and workers (never the 'directly reusable registration' pathology); the disarmed steady state then cycles on the 2.5-minute inactive-ports path as expected. Both Default and Private profiles loaded the probe, so two independent per-(controller, extension) states armed/disarmed in lockstep. Caveat: the binary was built before the review fixes (nativeMessaging gate, completion-before-arm ordering, host registry, send-failure retry); the hold/release path is unchanged and covered by the manager-level integration test, and a re-run against the committed build follows. Predicate tip: filter by processIdentifier, the production Detour (real 1Password) pollutes process-name predicates.

Harness re-run on the committed build ee320ef (2026-09-12 02:52-03:07, DETOUR_DATA_DIR=DetourKeepAlive16b, worktree build): AC #1 PASS again: positive-probe workers lived 11 min 30 s with zero terminateWorker / registration clears; armed <=1 ms after the host connected; installMode 'port' on every heartbeat. In-run control: a second probe WITHOUT nativeMessaging logged 'none/no-nativeMessaging-permission', opened no port, and cycled on the 30 s idle unload every minute throughout. AC #2 PASS again: disarm at 03:03:54.301, registrations cleared and workers terminated at 03:04:24.30 (30.0 s later), fresh registration and workers on the next alarm, then the disarmed steady state cycles on the 30 s path. No failed control sends, no recovery. Log tip corrected: SWContextManager::terminateWorker is logged by the Detour process (WebContent tag in the body), not the Networking process; filter 'eventMessage CONTAINS "terminateWorker"' by the Detour PID and use the Networking PID only for SWServerRegistration lines. Detour info-level bridge lines age out of the in-memory log store after ~7 min; snapshot incrementally for long holds.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Chrome-parity worker lifetime, driven natively. The worker (only for extensions declaring nativeMessaging) opens one idle port to Detour's detourPolyfill host at startup with a plain connectNative call; ExtensionManager tracks live NativeMessagingHosts per (controller, extension) and a pure state machine (NativeHostKeepAliveState) sends keepalive-start when the first real host connects with the port open and keepalive-stop when the last exits; the worker pings only in between, which WebKit counts as background activity. Replaced/reconnected ports are re-armed, context unload tears down hosts and state, failed control sends clear the latch and reconcile after 1 s, one-shot sendNativeMessage hosts never count, and the chrome/browser globals are never touched. Verified: 141 tests green (NativeHostKeepAliveTests 17, keep-alive JS tests rewritten, manager-level end-to-end test on a real Profile controller, page->worker messaging integration test) and the isolated harness run above (11-minute hold with zero terminations, unload 30 s after the last host exit, fresh restart). Docs: plan Phase 1 item 1 and chrome-runtime-patching.md updated.
<!-- SECTION:FINAL_SUMMARY:END -->
