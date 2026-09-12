---
id: TASK-21
title: >-
  1Password: verify the native keep-alive (TASK-16) and the WebSocket relay
  (TASK-8) in the signed production build
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 17:29'
labels:
  - 1password
  - extensions
  - verification
dependencies:
  - TASK-16
  - TASK-8
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
