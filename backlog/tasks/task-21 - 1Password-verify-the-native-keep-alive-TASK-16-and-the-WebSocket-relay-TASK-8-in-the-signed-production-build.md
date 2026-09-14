---
id: TASK-21
title: >-
  1Password: verify the native keep-alive (TASK-16) and the WebSocket relay
  (TASK-8) in the signed production build
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 17:29'
updated_date: '2026-09-14 02:05'
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
- [ ] #1 With 1Password unlocked and its BrowserSupport hosts connected, no 1Password worker is terminated for at least 15 minutes (log shows keep-alive armed and no re-activation cycle)
- [ ] #2 After the hosts disconnect (lock 1Password / quit it), the workers unload on WebKit's idle path and restart cleanly on the next event
- [ ] #3 The websocket-relay log shows the 1Password notifier socket being relayed and reaching open, and a vault change made elsewhere is pushed to the extension without a manual refresh
- [ ] #4 API Explorer's WebSocket (Relay) probe connects to wss://echo.websocket.org, echoes text and binary, and closes with the server's code
- [ ] #5 docs/1password-integration-plan.md records the production result for TASK-16 and TASK-8 with date and log excerpts
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
<!-- SECTION:NOTES:END -->
