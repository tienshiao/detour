---
id: TASK-68
title: >-
  Extensions: the armed keep-alive does not stop WebKit unloading a 1Password
  worker that has no relayed WebSocket (production)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-14 01:45'
updated_date: '2026-09-14 04:13'
labels:
  - extensions
  - 1password
  - bug
dependencies:
  - TASK-16
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
documentation:
  - docs/1password-integration-plan.md
priority: high
ordinal: 68000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during the TASK-21 production run (2026-09-13, signed build, pid 46243, 1Password 8.12.26.40, macOS 26.6.2). In the debug harness (TASK-16) the armed keep-alive held a worker for 11.5 min. In production it held the Personal and Work workers for 18+ min, but those two also had a relayed WebSocket open (1Password's notifier socket, TASK-8). Workers without a relayed socket were unloaded by WebKit about 170 s after they started, with the keep-alive armed the whole time:

- Private profile (only two relayed sockets opened at launch for three profiles; Private is presumed to be the one without, probably no signed-in account — confirm): background page created 18:15:48, `Keep-alive armed` 18:15:49, `WebPageProxy::close` of that page 18:18:42 (174 s). Nothing in Detour's or WebKit's log in the preceding 3 s; the user did nothing in that profile. The keep-alive port then closed, Detour killed the host, WebKit's next background load failed at 18:18:49 (WKWebExtensionContextErrorDomain code 6) and Detour's recovery reloaded the context (attempt 1 of 3).
- After the user locked 1Password (18:37:28) all relayed sockets closed. A worker started at 18:38:49 was closed at 18:41:37 (168 s) and restarted 12 s later at 18:41:49. After that restarts came about once a minute at hh:mm:49, which looks like 1Password's alarm waking a worker WebKit had unloaded.

Hypothesis: the polyfill's `{type:'keepalive'}` posts (every 45 s, `nativePortKeepAliveJS`) are not counted as activity by WebKit's inactive-ports timer in this build, or never start in production, and the relay socket's traffic is what actually held Personal and Work. About 170 s matches the 2-minute inactive-ports rule measured from the worker's last real native traffic (startup handshake) rather than from the last ping. `keepAlivePingCounts` is not logged, so production cannot tell yet whether pings arrived. Related: TASK-67 (hosts leaked when a worker is replaced) keeps the armed count wrong but does not explain these unloads, which happened with a correct count of 1.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Detour logs, per keep-alive key, when keepalive-start is sent and each ping it receives (or a periodic count), so a production log shows whether pings flow while armed
- [x] #2 The cause of the ~170 s unload of an armed worker with no relayed socket is identified and reproduced in the debug harness (for example a worker whose only port traffic is the keep-alive pings)
- [x] #3 With the fix, a worker whose native host stays connected and idle (1Password locked, or a profile with no account) is not unloaded for at least 15 minutes, in a test and in the signed build
- [x] #4 The disarmed path is unchanged: with no host connected the worker still unloads on WebKit's idle timers
- [x] #5 docs/1password-integration-plan.md records the cause and the production result
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Diagnosis from WebKit source: unloadBackgroundContentIfPossible runs every 30 s and keeps the page only while pageHasOpenPorts(background) and now - m_lastBackgroundPortActivityTime < 2 min; the activity time is set only by portPostMessage/addPorts from the background page itself. The production 170 s lifetime is 120 s past the second 45-second ping, which fits 'the first two pings counted, later ones never arrived'; the harness (Debug) held workers and pages with pings flowing, so the difference is in the worker's posting, not WebKit's counting. 2. Design change: Detour drives the pings instead of a worker-side setInterval. While armed ExtensionManager sends {type:'keepalive-ping', seq} on the keep-alive port every 30 s (DispatchSourceTimer on main, first ping immediately on arm); the polyfill replies {type:'keepalive', seq} at once (the reply is the background post WebKit counts). keepalive-start/stop stay only to flip the worker's diagnostic armed flag. This removes the dependency on worker timers and lets Detour observe every round trip. 3. Logging (AC #1): info line per ping sent and per reply received (seq, round trip), keepalive-start/stop delivery, and an error line when a ping's reply is still missing at the next tick (worker stalled, timers suspended, or dead port). 4. Harness (AC #2/#3/#4): a DETOUR_MEASURE_WORKER_UNLOAD=1 leg (duration from DETOUR_MEASURE_WORKER_UNLOAD_SECONDS, default 300) with a worker whose only port traffic is the keep-alive: armed via simulateNativeHostForTesting, expect the port to stay open and replies to flow for the whole leg and a single worker start; then release and expect the idle unload within ~2.5 min. Run it once for 5 minutes and record the numbers. 5. Update ExtensionPolyfillTests keep-alive JS tests (echo instead of interval), the wiring test, and docs/1password-integration-plan.md (AC #5 gets the production result after the user's next run).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design changed as planned: Detour drives the pings. ExtensionManager keeps a KeepAlivePinger per armed key (DispatchSourceTimer on the main queue, keepAlivePingInterval = 30 s, leeway 1 s), sends {type:'keepalive-ping', seq} immediately on arm and every interval after, and stops on .sendStop, port close/replacement, context unload and a failed send (routed through handleKeepAliveControlFailure, so reconcile restarts it). The polyfill's setInterval and __detourKeepAlivePingIntervalMs are gone; nativePortKeepAliveJS now just answers each ping with {type:'keepalive', seq} on the same port, whether or not armed, and keepalive-start/stop only flip the diagnostic armed flag. Status object swapped pingIntervalMs for repliesSent.

AC #1 (done): category extension-manager, info — "Keep-alive 'keepalive-start' delivered to <ext>", 'Keep-alive ping #n sent to <ext>', 'Keep-alive reply #n from <ext> (N ms)'; error — 'Keep-alive for <ext>: ping #n sent N s ago has no reply (worker stalled, its timers suspended, or the port is dead); sending #n+1'.

Measurement leg (new, DETOUR_MEASURE_WORKER_UNLOAD=1, DETOUR_MEASURE_WORKER_UNLOAD_SECONDS default 300), run once for 300 s on 2026-09-13 at the production 30 s interval with a worker whose only port is the keep-alive, armed via simulateNativeHostForTesting:
- armed phase: port open for the whole 300.9 s; 11 pings sent, 11 replies received, round trips 0-3 ms; never a ping awaiting a reply at the next tick; keepAlivePortOpenCount stayed 1, i.e. exactly one worker start. That is well past the ~170 s at which production's worker-driven pings stopped counting.
- released (connected: false): 'keepalive-stop' delivered, WebKit closed the port 149.4 s later — the inactive-ports path (2 min after the last reply, evaluated on WebKit's 30 s timer). AC #4 met; the test asserts < 180 s to leave room for that 30 s tick.
- The chrome.storage.local start counter read back -1 from the extension page in this run (the page's read returned nothing), so the 'started exactly once' check rests on keepAlivePortOpenCountForTesting == 1, which is native-side and equally conclusive (every worker start opens a keep-alive port). Worth a look if the counter is wanted later.

AC #2 left open: the ~170 s production unload was NOT reproduced. The harness has always held workers with pings flowing (TASK-16, TASK-62 leg c), and it still does; the cause is identified by elimination and by WebKit's rule (only the background's own posts count, so a background whose timers stop firing is unloaded on schedule while everything else looks healthy) rather than by a reproduction. The new design removes the dependency on the background's timers and, with the per-round-trip logging, the next production run can say directly whether replies flow.
AC #3 left open: the test leg covers 300 s, not 15 minutes, and the signed-build half is the user's next run.
AC #5 left open until that production result lands; docs/1password-integration-plan.md Phase 1 item 1 already carries the design change, the log lines and the harness table, and docs/chrome-runtime-patching.md was updated.

Test classes run green after the change: NativeHostKeepAliveTests, ExtensionPolyfillProfileWiringTests, ExtensionPolyfillTests, ExtensionPolyfillIntegrationTests, NativeMessagingEnforcementTests, ExtensionPermissionTests — 285 tests, 0 failures, 4 skipped (the measurement legs). Committed as 73dd343.

Code review (medium, --fix) on 73dd343: applied — a ping that fails to send is now only logged and retried by the next tick (routing it through handleKeepAliveControlFailure discarded the pinger ledger and doubled the 1 Hz retry loop on an orphaned port); the ping timer is a strict DispatchSourceTimer so App Nap / coalescing cannot defer a tick past WebKit's 2-minute window; redundant pingsSent/lastReplyAt dropped (seq is the count; keepAlivePingsSentForTesting returns seq); the API Explorer keep-alive probe now logs repliesSent and describes the Detour-driven protocol. Reported, not changed: keepalive-start/stop and the controlSendFailed/reconcile retry are now diagnostic only (the worker answers pings regardless) and could be removed in a follow-up.

Production run 2 (2026-09-13 20:04, commit 3b8d8f4 signed build, Detour pid 69925, 1Password app pid 49809): AC #1 logging works and AC #2's cause is now reproduced in production, and it is not the pings. All three workers armed at 20:04:22 with 1 host each; Detour's pings got replies in 0-20 ms. The first worker (page 476/477, WebContent 69962, worker 36) answered ping #1 only. WebKit's own log shows why: 1Password opened its offscreen document (page 577, created by WebKit's native chrome.offscreen in the same process with loadRequest; Detour's OffscreenDocumentHost was not involved), two of its vendor scripts were missing from the bundle (EXT-LOAD code 2 for background/offscreen/vendor/semver.js and just-pick.js at 20:04:22.556), the page closed at 20:04:22.565 (offscreen.closeDocument or WebKit unloading it), and 14 ms later the Networking process logged 'SWServerRegistration::clear 31' and the content process 'SWContextManager::terminateWorker 36'. The hidden background page 476 was NOT closed or re-navigated; it lived on with a dead worker (Detour logged 'ping #2 sent 30 s ago has no reply' every 30 s, the alarm events at 20:05:22 and 20:06:22 were lost) until WebKit unloaded it at 20:06:52.521 (151 s after load = 120 s after its last counted post plus the 30 s tick); the keep-alive port closed, Detour killed the host, and the 20:07:22 alarm loaded a fresh worker that reconnected and answers every ping. Yesterday's log (18:15:49.335 page 165 close -> 18:15:49.346 clear 33 + terminateWorker 40, hidden page 56 closed 18:18:42.913 = 174 s) is the same signature for the Private worker. Yesterday's post-lock cycling was different: the hidden pages were closed at 90-150 s with the worker terminated AFTER the close (normal idle unload), i.e. the old worker-side setInterval pings stopped flowing while the worker was alive; with Detour-driven pings today the two untouched workers and the restarted one are holding (checked at 20:11, 15-minute check pending). Only the profile whose 1Password opened an offscreen document at start was hit; the other two never created one. In WebKit's source the clear on a client unregister runs only for the client whose identifier is the registration's serviceWorkerPageIdentifier (SWServer::unregisterServiceWorkerClientInternal), so the offscreen page's close is being treated as the service-worker page's close; exact internal reason not traced.

15-minute hold in the signed build (AC #3, 2026-09-13 20:04-20:20, commit 3b8d8f4): the two workers not hit by the offscreen kill answered every Detour ping from 20:04:22 to 20:20:23 (replies #1-#33, 0-20 ms, no error line, no WebPageProxy::close, no loadServiceWorker) = 16 min; the restarted third worker answered #1-#27 from 20:07:22 (13 min). No relayed WebSocket opened in this run (1Password apparently locked / no notifier socket), so this is exactly the idle-host case that died at ~170 s yesterday. Exactly three BrowserSupport hosts for three workers; the killed worker's host was replaced, not leaked. Caveat: the harness leg covers 300 s, not 15 min.

Recovery landed (commit 03fe845).

Part 1, harness (AC #2): the production trigger is NOT reachable in the harness. The probe worker captures chrome.offscreen before the polyfill runs and finds nothing (capturedNative false), so in this build chrome.offscreen in a worker is Detour's polyfill and createDocument goes to OffscreenDocumentHost (a WKWebView of Detour's own), not a page in the worker's WebContent process. Results per variant, ExtensionPolyfillProfileWiringTests:
- (a) WebKit-native offscreen: cannot be exercised — no native namespace exists to call (createDocument reported 'no offscreen namespace').
- (c) Detour-hosted offscreen document created and closed (testADetourHostedOffscreenDocumentDoesNotKillTheWorker, 4.6 s): the worker never notices; pings keep round-tripping, one keep-alive port, no restart.
- (b) an extension page opened and released while another page stays open (testAnOrdinaryExtensionPageClosingDoesNotKillTheWorker, 6.4 s): the worker survives; a page teardown may cost one missed ping.
- The symptom itself IS reproduced (testAWorkerTerminatedUnderItsLiveBackgroundPageIsRestarted, 46 s): the probe worker clears its own registration (registration.unregister()), which reaches WebKit's teardown from the other end. Unified log, test host 77844: 20:42:20.614 Networking 'SWServerRegistration::clear 6', 20:42:20.615 WebContent 'SWContextManager::terminateWorker 7' — with the hidden background page (pageProxyID=13/webPageID=14) NOT closed, the keep-alive port still open, portOpen/armed still true and the pings simply not coming back. Exactly the production state.
- It first appeared by accident on 2026-09-13 20:27:54: a website-data deletion for session 1 (NetworkProcess::deleteWebsiteDataForOrigins) cleared another leg's registration 6 and terminated worker 7 while its page stayed loaded, and Detour pinged the corpse until the test ended.

Part 2, recovery (ExtensionManager.restartUnresponsiveBackground): keepAliveMissedReplyLimit (2) unanswered pings in a row => one error line 'Keep-alive for <ext>: no reply to pings #n–#m for N s; treating the background as dead and restarting it'; then tearDownNativeConnections with a new 'Detour restarted an unresponsive background context.' error, the pinger stopped, and the keep-alive port removed from keepAlivePorts before being disconnected (so its own handler is a no-op and no portClosed lands on top of contextUnloaded); then, after keepAliveRestartDelay (35 s, longer than WebKit's 30 s unload tick), loadBackgroundContent on the context, found via a new weak per-key controller registry (profile(for:) -> profile.extensionContext(for:)). No context unload/reload, so the extension's other pages survive. Guards: keepAliveRestartsInFlight per key, and the delayed load re-checks the port (a background that came back on its own wins), the controller, the profile and the context. Both knobs are instance properties for tests. NativeHostKeepAliveState is untouched — the teardown reuses .contextUnloaded — so no new state event was needed.

Timings measured on the repro leg (ping interval 2 s in the test, production knobs otherwise): worker terminated 20:42:20.6; ping #3 unanswered logged 20:42:24.4; recovery at 20:42:26.5 (4 s of silence); WebKit closed the now-portless zombie page 20:42:50.6 (its own 30 s tick); loadBackgroundContent 20:43:01.5 -> 'background content loaded' + WebPageProxy::loadServiceWorker; second keep-alive port, armed, answering every ping.

Test-only hook added to nativePortKeepAliveJS: __detourKeepAliveIgnorePings (a count, or true) drops pings so a test can play a silent background — used by testASilentBackgroundIsTornDownAndRestarted (6.5 s) and the negative testASingleMissedKeepAliveReplyDoesNotRestartTheBackground (5.4 s).

Test runs, all green: ExtensionPolyfillProfileWiringTests 46 tests, 4 skipped (the env-gated measurement legs), 0 failures; ExtensionPolyfillTests 155; ExtensionPolyfillIntegrationTests 23; NativeHostKeepAliveTests 17; NativeMessagingEnforcementTests 9. AC #5: docs/1password-integration-plan.md Phase 1 item 1 now carries the cause, the harness table and the recovery. AC #3 still needs the signed-build 15-minute confirmation.

CORRECTION (2026-09-13 20:55): the offscreen page's close was a coincidence. The Networking log shows the actual trigger in both runs: 'NetworkProcess::deleteAndRestrictWebsiteDataForRegistrableDomains started to delete and restrict data for session 1 with candidate domains - 9 ... 706 domainsToDeleteAllScriptWrittenStorageFor' immediately before 'SWServerRegistration::clear' (31 today, 33 yesterday) — WebKit's tracking prevention purging script-written storage for the extension origin, which never earns first-party user interaction. Filed as TASK-70. The harness result stands: neither a Detour-hosted offscreen close nor an ordinary page close kills the worker, and the recovery (03fe845) handles the state whatever clears the registration.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Two faults hid behind the ~170 s unload. (1) The worker-side setInterval pings stopped flowing after a 1Password lock while the worker lived; Detour now drives the pings (30 s strict timer, numbered keepalive-ping / keepalive echo) and logs every round trip, and in the signed build all workers answered every ping for 16 minutes with no relayed socket open. (2) The worker was being terminated one second after launch, under its still-loaded hidden page, by WebKit's tracking-prevention purge of script-written storage for the extension origin (SWServerRegistration::clear right after deleteAndRestrictWebsiteDataForRegistrableDomains in both production runs) — prevention filed as TASK-70. Detour now detects a background that stops answering (two ticks with no reply of any kind), tears down its ports so WebKit closes the zombie page at its next tick, and reloads the background 35 s later (cancellable on unload/reload/replacement); harness reproduction via registration.unregister() restarts in ~40 s. Also: a replaced context's stale hosts are torn down on supersede (TASK-67). Commits 73dd343, 3b8d8f4, 03fe845, 7c6e4d3; docs/1password-integration-plan.md Phase 1 item 1 carries the mechanism, log lines, harness table and production numbers.
<!-- SECTION:FINAL_SUMMARY:END -->
