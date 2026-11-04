---
id: TASK-233
title: 'Native messaging: a quiet host process outlives the owner that released it'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T03:00:00Z'
updated_date: '2026-11-03T06:16:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 277000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-231.4 (pre-existing). NativeMessagingHost's stdout read loop runs `while let self, self.isConnected`, so it holds the host strongly for the whole iteration, including the blocking readData(ofLength:). When the owner drops the host (a one-shot request settling and removing its activeMessagingHosts entry) while the host process is alive and silent, deinit does not run, disconnect() is never called, and the host keeps running as a child of Detour until it exits on its own. Owners must call disconnect() explicitly today; the isolated deinit only covers the case where the read loop is not blocked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Releasing a host whose process is alive and silent terminates the process (or every owner provably calls disconnect first, with the deinit no longer relied on)
- [x] #2 A test with a fake host that stays alive after answering shows the process gone after the owner releases it
- [ ] #3 The task records a signed-build check with 1Password after the change
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Read loop captures only stdout, the Connection and the host name; loops while connection.isOpen; delivers through a weak-self main-actor task; reports through record(reportingTo:) with the weak reference.
2. Update the isolated deinit comment: releasing the last owner runs disconnect() -> terminate; the loop then reads EOF and exits.
3. Tests: host-level release test (Lifecycle) and end-to-end one-shot answers-then-stays-alive (Enforcement), both failing before the fix; plus an end-to-end leg that a connectNative port keeps its quiet host until the page disconnects (keep-alive owner).
4. Suites (Lifecycle + Framing under TSan), /verify with fake hosts, /code-review --fix, wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: startReadLoop ran `while let self, connection.isOpen`, holding the host strongly across the blocking readData, so a live, silent host's isolated deinit never ran when its owner let go.
Fix: the loop holds the host weakly (captures stdout, connection, hostName), delivers via Task { @MainActor [weak self] }. The termination handler and the end-of-stream waits were already weak.
Before the fix: testReleasingALiveSilentHostTerminatesItsProcess failed (host not released; process alive after 5 s) and testAOneShotHostThatStaysAliveIsTerminatedOnceItHasAnswered failed (process alive after 5 s). After: both pass.
Keep-alive: the port path keeps its host in liveNativeHosts and in port.messageHandler/disconnectHandler while the port is open; new testAConnectNativePortKeepsAHostThatStaysAliveUntilThePageDisconnects shows the host still running 1 s after its reply with the port open, and gone after the page disconnects.
Tests: ExtensionPolyfillProfileWiringTests 62 (13 skipped), NativeHostKeepAliveTests 17, ExtensionIDDerivationTests 11, NativeConnectLogLimiterTests 8, NativeMessagingHostLifecycleTests 13, NativeMessagingEnforcementTests 15, NativeMessagingFramingTests 8: 134 run, 0 failures. Lifecycle + Framing under -enableThreadSanitizer YES: 21 run, 0 failures, no TSan reports.
/verify (Debug build, DETOUR_DATA_DIR isolated profile, seeded MV3 SW extension, DETOUR_NATIVE_MESSAGING_HOSTS_DIR fake hosts): 8 one-shots + 5 ports to an answer-then-exit host all got the reply first; both one-shots to the 'stays alive' host (exec sleep 742233) got pong=1 and the process was SIGTERMed (status 15) about 1 ms after the reply, no sleep 742233 left; the silent connectNative host (sleep 742234, keep-alive) stayed running until the app was quit. Profile dir and the two defaults keys removed; own PIDs killed only.
/code-review --fix: fixed the deinit comment (owners can include the port's handlers; a child holding stdout keeps the loop blocked). Skipped as out of scope: no SIGKILL after SIGTERM for a host that ignores SIGTERM; a non-dictionary one-shot message spawns a host that is never sent anything and never released (ExtensionManager); the port leg's 1 s negative-assertion sleep.
Not verified: AC #3, the signed-build 1Password check, is owed by the user.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Releasing a NativeMessagingHost now ends its process: the stdout read loop holds the host weakly instead of `while let self`, so the isolated deinit runs disconnect() -> terminate when the owner lets go, even while the host is alive and silent; the blocked read then returns EOF and the loop exits. A one-shot host that answers and stays alive is gone ~1 ms after its reply (tests and /verify). The port path's keep-alive host is held by liveNativeHosts and the port handlers, unaffected (new end-to-end test). 134 tests in 7 suites pass, Lifecycle + Framing clean under TSan. AC #3 (signed-build 1Password check) is owed by the user; everything else is complete. Follow-ups: SIGKILL escalation for a host ignoring SIGTERM; non-dictionary one-shot messages spawn a host that is never released.
<!-- SECTION:FINAL_SUMMARY:END -->
