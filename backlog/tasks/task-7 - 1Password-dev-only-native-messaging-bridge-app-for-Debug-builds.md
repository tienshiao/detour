---
id: TASK-7
title: '1Password: dev-only native messaging bridge app for Debug builds'
status: To Do
assignee: []
created_date: '2026-09-12 00:04'
labels:
  - 1password
  - extensions
  - dev-tooling
dependencies:
  - TASK-6
documentation:
  - docs/1password-integration-plan.md
priority: low
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
1Password's BrowserSupport helper verifies the process that spawns it and, as far as we recall, only accepts a Release build signed with Developer ID and installed at /Applications/Detour.app (TASK-6 double-checks this). That forces the scripts/deploy-1password-test.sh loop (Release build, sign, copy, relaunch) for every 1Password test and rules out running under the Xcode debugger. Build a small, separately signed macOS app, installed at /Applications, that a Debug build of Detour can talk to instead of spawning native messaging hosts itself. The bridge is the process that spawns BrowserSupport, so 1Password trusts it; the Debug build relays frames through it. Design decisions from the 2026-09-11 discussion: (1) the bridge is launched MANUALLY by the developer (Finder or open -a) before a session and stays up across Debug rebuilds; Detour never launches it, so its responsible process is itself and there is nothing for the verifier to trace back to the Debug build. (2) It is dev-only: real builds never contain the client path (compile it out of Release or gate on a DETOUR_NATIVE_MESSAGING_BRIDGE env var / Debug configuration). Client verification is intentionally skipped; the accepted residual risk is any process running as the developer's user on the dev machine while the bridge is up. Cheap mitigation: listen on a Unix socket in a user-only directory, exit when the Debug client disconnects. (3) Keep the bridge dumb: one host process per bridged connection, relay length-prefixed native messaging frames both ways, forward host stderr and exit status. Origin validation (allowed_origins), the 1 MB message limit, host lookup and lifecycle stay in Detour's NativeMessagingHost so the code under test is the code that ships. Open question to confirm from BrowserSupport logs on the first run: whether 1Password requires the frames to originate from the parent process itself or only that the parent be trusted. Skip this task entirely if TASK-6 shows a Debug build is trusted.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A Debug build of Detour running from DerivedData, with the bridge running, completes 1Password unlock and autofill end to end
- [ ] #2 With the bridge not running, a Debug build falls back to spawning native messaging hosts directly and behaves exactly as today
- [ ] #3 Release builds contain no bridge client code path (verified by inspection or a build-config test) and ignore the bridge environment variable
- [ ] #4 The bridge accepts connections only on a Unix socket in a user-only directory and exits when its last client disconnects
- [ ] #5 The bridge relays host stderr and exit status so NativeMessagingHost's existing logging and disconnect handling work unchanged
- [ ] #6 docs/1password-integration-plan.md documents how to install, launch and use the bridge, and the result of the parent-process question from the BrowserSupport logs
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Created from the 2026-09-11 discussion after TASK-1. Depends on the outcome of TASK-6: only worth building if a Developer ID-signed Debug build is NOT trusted by BrowserSupport.
<!-- SECTION:NOTES:END -->
