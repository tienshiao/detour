---
id: TASK-62
title: >-
  Extensions: extend the native-port keep-alive (TASK-16) to MV2/MV3 background
  pages
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 19:25'
updated_date: '2026-09-13 23:23'
labels: []
dependencies: []
ordinal: 62000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-43 made the polyfill recognise a background page (MV2, or MV3 background.scripts/page) as the extension's background context (g.__detourContextKind === 'background-page'), and the content-script bridge now installs there. nativePortKeepAliveJS still gates on ServiceWorkerGlobalScope, so a background-page extension with nativeMessaging gets no keep-alive and WebKit unloads its non-persistent page like the bug TASK-16 fixed for workers. The keep-alive premise (WebKit counts the worker's pings as background activity that defers the unload) was measured for workers only, and a persistent MV2 page needs no keep-alive at all — so this needs measurement before the gate is relaxed. Found in the review of e912d33..1e26a52.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Measured: whether WebKit unloads a non-persistent background page with an open native port, and whether the keep-alive pings defer it
- [x] #2 nativePortKeepAliveJS installs in a non-persistent background page with nativeMessaging permission (and records why not otherwise) based on the measurement; a persistent MV2 page is skipped
- [x] #3 ExtensionPolyfillProfileWiringTests cover the background-page install decision; the API Explorer shows the keep-alive status for its context kind
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure in ExtensionPolyfillProfileWiringTests with a background.scripts extension declaring nativeMessaging, a fake native host (the NativeMessagingEnforcementTests fixture: DETOUR_NATIVE_MESSAGING_HOSTS_DIR + a script that execs sleep), and the TASK-43 localStorage loads counter: (a) idle non-persistent background page with no port: is it unloaded after WebKit's 30 s idle rule; (b) with an open native port and no traffic: unloaded on the 2-minute inactive-ports rule; (c) with the keep-alive pings on the detourPolyfill port (shortened interval via __detourKeepAlivePingIntervalMs): does the page stay loaded past the point (b) unloaded. Record the numbers.
2. Based on the measurement, relax the nativePortKeepAliveJS gate from ServiceWorkerGlobalScope to 'worker or non-persistent background page' using g.__detourContextKind === 'background-page' and the manifest (an MV2 page with persistent !== false is skipped, installDetail 'persistent-background-page'; a non-background page stays 'not-a-worker' → rename the detail to 'not-a-background-context'). If the pings do not defer a page unload, keep the gate and record why in installDetail and the task.
3. Tests: wiring tests for the install decision per context kind (worker, non-persistent scripts page, persistent MV2 page, ordinary page); API Explorer's keep-alive probe reports contextKind alongside installMode/installDetail.
4. Update the doc comment above nativePortKeepAliveJS and docs/1password-integration-plan.md's TASK-16 notes with the page measurement.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured 2026-09-13 on a non-persistent MV3 background.scripts page (heartbeat to localStorage every 0.5 s, read from a same-origin extension page so nothing wakes the background): (a) idle, no port: last heartbeat +29.7 s, next message started a new page (loads 1 -> 2); (b) one real connectNative port to a silent fake host, polyfill port suppressed: survived the 30 s idle unload, unloaded at +120.0 s (re-run +120.1 s), port closed and Detour killed the host; (c) as (b) with the real keep-alive armed, pings every 15 s: still running at +300.9 s, host connected, 21 pings. Gate relaxed: installs in a worker or non-persistent background page declaring nativeMessaging. installDetail: 'not-a-background-context' (was 'not-a-worker'), 'no-nativeMessaging-permission', new 'persistent-background-page' (manifest_version < 3 and persistent !== false). Tests: four install-decision wiring tests plus the three env-gated legs (set TEST_RUNNER_DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1; xcodebuild only forwards TEST_RUNNER_-prefixed vars). FakeNativeMessagingHost fixture shared with NativeMessagingEnforcementTests. API Explorer probe reports contextKind. Docs: plan doc TASK-62 table, chrome-runtime-patching gate paragraph.
Incident during the work: an early version of the test helper prependUserScript iterated WKUserContentController.userScripts while re-adding to it; the bridged array tracks the controller, so the loop never ended and a test host reached 36.66 GB in 90 s, putting the Mac under memory pressure. Fixed by snapshotting plain values first, with a 64-script guard and a count assertion. Rerun with a session watchdog (kill test host > 4 GB, all hosts if system free < 35%): peak RSS 127-161 MB per run.
Residual limit recorded in ExtensionManager: a top-level extension page navigated to the background path can open the keep-alive port and evict the real background's; the TASK-66 registry cannot help because a native-message port carries no web view.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Measured that a non-persistent background page is unloaded on the same two WebKit timers as a worker (30 s idle; 120 s with a silent native port, which kills the host) and that the keep-alive pings keep it loaded (still running at 300 s with 21 pings). The nativePortKeepAliveJS gate now installs in workers and non-persistent background pages declaring nativeMessaging; persistent MV2 pages and ordinary pages are skipped with distinct installDetail values. Verified with four install-decision wiring tests, three env-gated measurement legs, and the merged affected suites (340 tests, 0 failures).
<!-- SECTION:FINAL_SUMMARY:END -->
