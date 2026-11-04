---
id: TASK-232
title: >-
  Native messaging: a host that writes its reply and exits at once can have the
  exit handled before the reply
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T03:00:00Z'
updated_date: '2026-11-03T06:03:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: low
type: bug
ordinal: 276000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-231.4, not fixed there (pre-existing). NativeMessagingHost reports a host exit from Process.terminationHandler, on its own thread, with no ordering against the stdout read loop. A host that writes its response and exits with status 0 straight away (a one-shot runtime.sendNativeMessage host) can have handleDisconnect queued before the read loop has read the frame still in the pipe: onDisconnect fires first, the request settles with "Native host has exited", and the real reply is dropped or reaches onMessage after the request settled. On the port path, onMessage can call port.sendMessage after port.disconnect. Disconnects the read loop itself reports are already ordered after the messages it read (TASK-231.4). Any change here touches the 1Password host path and needs a signed-build check.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A reply the host wrote before exiting is delivered before the disconnect, for both one-shot sendNativeMessage and connectNative ports
- [x] #2 A test with the fake native host that writes one reply and exits immediately fails before the change and passes after it
- [ ] #3 The task records a signed-build check with 1Password (connect, unlock, autofill) after the change
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure join NativeHostEnding (end of stream + process exit, waits 0.5 s / 5 s, failures at once) behind a per-connect Connection object (open flag + join in Mutexes).
2. terminationHandler records the exit instead of reporting the disconnect; the read loop records end of stream / framing failures; write failures record their reason before teardown.
3. Reports and message deliveries are main-actor tasks; deliveries are dropped once the connection is closed (disconnect() or reported end).
4. Tests: NativeMessagingHostLifecycleTests (reply-then-exit x50 with a 256 KB reply, small reply, exit status joined, child holding stdout, closed stdout alive, nothing after disconnect, pure join transitions) + end-to-end sendNativeMessage x15 and connectNative x8 in NativeMessagingEnforcementTests. Show they fail before the fix.
5. Run the native messaging suites + ExtensionPolyfillProfileWiringTests + ExtensionIDDerivationTests; TSan on the new tests + framing; /code-review; /verify with a seeded extension and fake host; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Post-review rerun (2026-11-02 22:00, load ~12): ExtensionPolyfillProfileWiring, NativeHostKeepAlive, ExtensionIDDerivation, NativeConnectLogLimiter, NativeMessagingHostLifecycle, NativeMessagingEnforcement, NativeMessagingFraming: 131 tests, 13 skipped (gated), 0 failures. TSan (Lifecycle + Framing, after review): 20 pass, 0 TSan warnings. Before the fix: host level 6/25 runs failed; end to end 13/15 sendNativeMessage settled 'Native host has exited', 7/8 ports saw the disconnect first. /verify (DetourVerifyNM232, seeded MV3 SW extension + fake hosts via DETOUR_NATIVE_MESSAGING_HOSTS_DIR): 8/8 one-shot 256 KB reply-then-exit resolved with the reply, 5/5 ports message-then-disconnect, keep-alive armed (7 replies). AC #3 OPEN: signed-build 1Password check (connect, unlock, autofill) is owed by the user. Review skipped: a child holding stdout keeps the loop thread blocked until it exits (pre-existing); the 0.5 s exit-status wait can lose the status under load (diagnostic only); real-time sleeps in negative checks.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A native host's disconnect is now the join of the stdout read loop's end of stream and the process exit (NativeHostEnding, pure and unit-tested), instead of terminationHandler reporting it on its own thread. A reply the host wrote before exiting is therefore delivered before the disconnect, for one-shot sendNativeMessage and connectNative ports. EOF waits up to 0.5 s for the exit status; an exit waits up to 5 s for EOF (child holding stdout); a host that closes stdout but keeps running is reported after 0.5 s and terminated; framing errors and failed writes are handled. Each connect() gets its own Connection (Mutex state) and read queue, and nothing is delivered after disconnect. Wire bytes unchanged. Tests: NativeMessagingHostLifecycleTests (12, including reply-then-exit x50) and two end-to-end NativeMessagingEnforcement tests, failing before the fix. Owed: signed-build 1Password check (AC #3). TASK-233 (read loop holding the host strongly) follows.
<!-- SECTION:FINAL_SUMMARY:END -->
