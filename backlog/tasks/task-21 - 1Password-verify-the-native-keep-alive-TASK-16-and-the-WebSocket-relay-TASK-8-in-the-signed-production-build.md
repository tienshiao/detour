---
id: TASK-21
title: >-
  1Password: verify the native keep-alive (TASK-16) and the WebSocket relay
  (TASK-8) in the signed production build
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 17:29'
updated_date: '2026-09-21 08:31'
labels:
  - 1password
  - extensions
  - verification
dependencies:
  - TASK-16
  - TASK-8
  - TASK-67
  - TASK-68
documentation:
  - docs/1password-integration-plan.md
priority: medium
ordinal: 21000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Both TASK-16 and TASK-8 were verified only in the isolated debug harness / loopback tests; neither has run against real 1Password, which only trusts the signed Developer ID build in /Applications. Before TASK-16 the symptom was all three 1Password service workers being terminated and re-activated every two minutes (each cycle SIGTERMs three BrowserSupport processes; plan doc timeline at 15:01:14). In the harness the fix held a worker for 11.5 min with zero terminations while a host was connected and unloaded 30 s after the last host exited. This task is the production check for both changes in one deploy session. Deploy with scripts/deploy-1password-test.sh (--log streams 1PW-DEBUG), unlock 1Password so BrowserSupport hosts connect, and watch the unified log for process Detour: category extension-manager for 'Keep-alive port opened', 'Keep-alive armed for ... native host(s) connected' and the absence of 'Keep-alive disarmed' / worker re-activation while the hosts stay connected; category websocket-relay for 'Relaying a WebSocket for aeblfdkhhhdcdjpifhhbdiojplfjncoa' and 'Relayed WebSocket open' (the notifier's wss socket). Also run the API Explorer's WebSocket (Relay) panel against wss://echo.websocket.org, the public echo server TASK-8 AC #1 named. Record timings and the exact log lines in the notes and update the plan doc's status lines for TASK-16 and TASK-8. If either fails, file the fix as its own task rather than widening this one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With 1Password unlocked and its BrowserSupport hosts connected, no 1Password worker is terminated for at least 15 minutes (log shows keep-alive armed and no re-activation cycle)
- [x] #2 After the hosts disconnect (lock 1Password / quit it), the workers unload on WebKit's idle path and restart cleanly on the next event
- [x] #3 The websocket-relay log shows the 1Password notifier socket being relayed and reaching open, and a vault change made elsewhere is pushed to the extension without a manual refresh
- [x] #4 API Explorer's WebSocket (Relay) probe connects to wss://echo.websocket.org, echoes text and binary, and closes with the server's code
- [x] #5 docs/1password-integration-plan.md records the production result for TASK-16 and TASK-8 with date and log excerpts
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Production run 2026-09-13 (signed build from scripts/deploy-1password-test.sh, Detour pid 46243 launched 18:15:47, 1Password 8.12.26.40, macOS 26.6.2, three profiles Personal/Private/Work). Logs recorded with `/usr/bin/log stream --level info --process Detour` on categories extension-manager, native-messaging, websocket-relay, extension-idle, EXT-LOAD, extension-polyfill. Note: `--log` in the deploy script filters out extension-manager and websocket-relay, and these lines are info level, so `log show` needs `--info`.

First attempt (pid 44016) was invalid: the 1Password desktop app was not running, so each worker connected to BrowserSupport, got no app, disconnected after 10 s and tried the absent 1Password 7 host; the keep-alive correctly disarmed and workers idle-unloaded and restarted on events.

AC #1 (15 min, no termination): partial. 18:15:49 all three workers `Keep-alive armed ... 1 native host(s) connected`. Personal and Work held with no restart until the lock at 18:37:28 (21+ min). Private's worker was unloaded by WebKit at 18:18:42 while armed (`WebPageProxy::close`, then `Keep-alive port closed`, host SIGTERM), its next background load failed at 18:18:49 (WKWebExtensionContextErrorDomain code 6) and Detour's recovery reloaded it (attempt 1 of 3); it held from then on while 1Password was unlocked. User did nothing in Private. Filed as TASK-68 (hypothesis: pings not counted; the two workers that held had a relayed socket).

AC #2 (unload after hosts disconnect): not testable by lock or quit. Lock (18:37:28) keeps BrowserSupport connected. Quit (18:38:41): 1Password restarted all three workers at 18:38:49 and the extension relaunched the desktop app at 18:38:50 (1Password pid 49809), so hosts never went to zero. That restart exposed TASK-67: old hosts were not disconnected (no EOF/EXIT), keep-alive ports logged `superseded`, and the armed count later read 2 and 3 for one profile; 10 BrowserSupport children of Detour at 18:44. With 1Password locked, workers then cycled: unloaded ~170 s after start and woken about once a minute (TASK-68). The idle-unload path itself remains covered only by the TASK-16 harness.

AC #3 (relay): partial. 18:15:50 two `Relaying a WebSocket for aeblfdkhhhdcdjpifhhbdiojplfjncoa` + `Relayed WebSocket open`; Private's reloaded worker opened a third at 18:18:50 (open 18:18:50.991). On lock, 18:37:28 all three `Relayed WebSocket closed ... code 1005, clean true`. Vault change pushed live: not tried.

AC #4 (API Explorer echo probe): not run.

Side observations: after the Private reload WebKit logged `Unable to find "background/offscreen/vendor/semver.js"` and `just-pick.js` (1Password offscreen page; check whether this appears on a normal launch). The 1Password worker logs `Unchecked runtime.lastError: Invalid call to windows.get(). Window not found.` at startup.

Remaining for this task: AC #1 re-run and AC #2 after TASK-67/TASK-68 land; AC #3 vault push; AC #4; AC #5 plan doc update.

2026-09-14: docs/1password-integration-plan.md now carries interim production sections for TASK-16 (Phase 1 item 1, 'Production, 2026-09-13') and TASK-8 (end of the relay section) with the timings and outcomes above; AC #5 stays open until the re-run after TASK-67/TASK-68 land adds the final result.

Re-run 2026-09-21 (signed build from 761c4b6 = TASK-67/68/73 landed, Detour pid 68860 launched 00:56:39, 1Password 8.12.26.40 unlocked, profiles Personal/Work/Private with 1Password allowed in Private, capture: /usr/bin/log stream --level info --process Detour on extension-manager, native-messaging, websocket-relay, extension-idle, EXT-LOAD, extension-polyfill, ExtensionConsoleLogPublic set).
AC #1 MET: Personal + Work 'Keep-alive port opened' 00:56:40.578 / 00:56:41.099, 'Keep-alive armed ... 1 native host(s) connected' 00:56:40.829 / 00:56:41.285; Private (opened by the user later) loaded 01:00:34.294, armed 01:00:35.255. Through 01:19:35 (23 min / 19 min for Private): every 30 s ping answered (6 replies/min steady, max 74 ms), exactly one 'Keep-alive port opened' per profile, 0 disarmed / port closed / superseded / recovery / SWServerRegistration::clear / runRegisterJob / terminateWorker lines. Private is the worker WebKit unloaded while armed on 2026-09-13 (TASK-68) — it held.
AC #3 MET: 'Relaying a WebSocket for aeblfdkhhhdcdjpifhhbdiojplfjncoa' + 'Relayed WebSocket open' x2 at 00:57:18.19-.50 and for Private at 01:00:36.43/.66, none closed. Vault push: user changed an item elsewhere at ~01:19; at 01:18:47.646/.794/.804 all three workers logged '[Syncer] Sync started ... reason code: 7 - syncing all' within 160 ms with no local trigger before it (startup syncs were codes 17/18/20), each completed in ~0.5 s and reloaded the item cache; user confirms the item appeared in Detour's 1Password without a refresh.

AC #4 MET 2026-09-21 01:21:43: API Explorer WebSocket (Relay) panel against wss://echo.websocket.org — result {mode: relay, relayed: true, opened: true, messages: [server banner 'Request served by …', text 'detour-relay-hello' echoed, binary [1,2,3,4] echoed], closeCode 1000, closeReason 'done', wasClean true, error null, timedOut false}. Log: 'Relaying a WebSocket for F957EE44-…' 01:21:43.478, 'Relayed WebSocket open' .673, 'Relayed WebSocket closed … code 1000, clean true' .815. The 'Relayed WebSocket failed … hostname could not be found' / 'code 1006, clean false' lines for the same extension at 01:20:41, 01:21:27 and 01:21:41 are API Explorer's deliberate wss://example.invalid probe that runs at every worker start (background.js), not a relay fault.

AC #2 MET 2026-09-21 (Personal; hosts brought to zero by turning off 'Integrate with 1Password app' in the extension's own settings, since lock/quit never does): 01:26:08.965 '[AppIntegration] Disconnected from Desktop app due to ExtensionSupportDisabled', 'Disconnecting native host', 'NM EOF' .969; 01:26:09.222 'Relayed WebSocket closed … code 1005, clean true' + 'Keep-alive disarmed … no native host connected' + 'keepalive-stop delivered'. WebKit: 01:26:39.228 WebPageProxy::close (30.0 s after disarm), .232 SWServerRegistration::clear 76 / terminateWorker 77 / workerTerminated. Next event: 01:26:41.302 loadServiceWorker, runRegisterJob 'No existing registration', 'Keep-alive port … superseded by a newer one' + 'opened' .380 (expected: WebKit's unload reports no port disconnect), '[Background] Finished initializing 1Password' .601 (148 ms); no code-6 load failure, no recovery. Work + Private answered pings throughout. Integration back on: host connected 01:29:16.385 (profile Personal); ps shows exactly 3 BrowserSupport children of Detour (00:56:40, 01:00:35, 01:29:16) — no leak. Note for log readers: 'Keep-alive armed … 1 native host(s) connected' at 01:28:46.870 came from the relayed notifier socket reopening after an unlock while the integration was still off — relayed sockets count as hosts by design (ExtensionManager relay port → applyKeepAlive(.hostConnected)); only the log wording says 'native'.
AC #5: docs/1password-integration-plan.md gained 'Production, 2026-09-21' paragraphs under Phase 1 item 1 (TASK-16) and at the end of the relay section (TASK-8).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Production verification of TASK-16 (native keep-alive) and TASK-8 (WebSocket relay) with real 1Password in the signed build. The 2026-09-13 run was partial and produced TASK-67 and TASK-68; the 2026-09-21 re-run after those fixes passed everything: three workers held 19–23 min with every ping answered and no termination; with hosts at zero WebKit idle-unloaded the worker 30.0 s after the disarm and it restarted cleanly on the next event with no host leak; notifier sockets relayed and a remote vault change was pushed live; API Explorer's relay probe echoed text and binary against wss://echo.websocket.org and closed 1000. No code change. Results in docs/1password-integration-plan.md.
<!-- SECTION:FINAL_SUMMARY:END -->
