---
id: TASK-274
title: >-
  Native messaging: a wrapper-script host that does not exec leaves its real
  host running after quit
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T03:15:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - wiki/extensions/native-messaging.md
priority: low
type: bug
ordinal: 321000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

Termination signals only the direct child (`NativeMessagingHost.swift` ~344-347, ~430-441); there is no process group or descendant handling. A host installed as a `#!/bin/sh` wrapper that starts python or node without `exec` dies on SIGTERM/SIGKILL, and the real host is reparented to launchd and keeps running if it does not watch stdin. TASK-243 and wiki/extensions/native-messaging.md say no host outlives quit; that holds only for hosts that exec.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Quitting Detour, and SIGTERM to Detour, end a wrapper host's descendants as well as the wrapper (or the limit is decided and recorded in the wiki with the reason)
- [x] #2 Signalling never reaches a process outside the host's own tree
- [x] #3 A test uses a fake wrapper host that spawns a non-exec child
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Research (done): Foundation's Process on Darwin already spawns the host as the leader of its own process group (probe: host pgid == host pid, a non-exec child shares it, Detour's own group differs), so a wrapper's foreground children are in the host's group. Chromium (launch_context_posix.cc) sets no new_process_group on macOS and EnsureProcessTerminated SIGKILLs only the pid after 2 s, so Chrome has this same leak. XNU allocates pids sequentially and never hands out an id that is a live pid, process group or session (kern_fork.c), and killpg skips zombies (kern_sig.c).
2. Keep Process. Record the host's group at spawn (only when getpgid(pid) == pid and != Detour's own group, else fall back to the pid alone). Every SIGTERM/SIGKILL (teardown, the TASK-241 timer, the quit sweep, so the SIGTERM handler too) goes to the group with killpg, plus the pid itself if the leader has left the group.
3. A torn-down host whose leader exits while its group still has live members keeps its registry entry and SIGKILL timer until the timer fires (bounded by the grace), so the timer and a quit inside the grace still reach a child that ignores SIGTERM. Arm the timer before the SIGTERM so the leader's exit cannot beat it. The quit sweep waits for, and SIGKILLs, groups as well as leaders. Groups are only ever signalled while the leader is unreaped or within the grace/quit window after it, so the id cannot have been reused.
4. Limits recorded in the wiki: a descendant that leaves the group (setsid/setpgid, a daemon) and a host that exits on its own leaving children behind are not chased.
5. Tests (fake wrapper hosts in FakeNativeMessagingHost: a sh wrapper running a sleep child without exec, and one whose child ignores SIGTERM): the host leads its own group; disconnect and the quit sweep end the child; SIGKILL reaches a SIGTERM-ignoring child after the wrapper is gone, from the timer and from a quit inside the grace; a canary process outside the host's tree survives. Fixture tearDown kills strays by token and by fixture dir. Run them first against the old code to see them fail.
6. Runtime: temporary env-gated DEBUG harness connecting a wrapper host at launch; check the child is gone after SIGTERM to the app and after a normal quit. Harness patch saved under docs/harness.
7. Wiki native-messaging.md (Quitting, Ending the process), log, lint; review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Findings: Foundation's Process on Darwin already spawns each host as the leader of a process group of its own (pgid == pid; a non-exec child shares it; Detour's group differs), and Process.terminate() signals that group (Apple: 'the receiver and all of its subtasks'), so the teardown's SIGTERM already reached a wrapper's child. The leak was the TASK-241 SIGKILL timer (kill(pid), and only while the host itself ran) and the quit sweep's kill(pid) SIGTERM/SIGKILL, so also the SIGTERM handler's. Chromium on macOS (launch_context_posix.cc) sets no new_process_group and EnsureProcessTerminated SIGKILLs the pid alone: Chrome has this leak.
Change (kept Process, no posix_spawn): SpawnedProcess records the group at spawn via the pure signallableGroup(host:hostGroup:detourGroup:) (only a group the host leads, > 1, not Detour's; else pid-only, logged NM GROUP). send() killpg's the group, plus kill(pid) if the host has left it; isAlive = host running or killpg(group, 0) == 0 (XNU killpg skips zombies). The SIGKILL timer is stored in the entry before the SIGTERM; a torn-down host that exits while its group has a live member keeps its entry (hostExited) until its timer fires, so the timer and a quit in the grace still reach the child. The quit sweep waits for and SIGKILLs groups. Safety: XNU allocates pids sequentially and skips ids live as pid, pgid or session (kern_fork.c), so the group id is reserved while the host is unreaped or any member lives; groups are signalled only then or within the grace (2 s) / quit wait (1 s) after the host's exit. Limits, decided and recorded in the wiki: a descendant that leaves the group (setsid/setpgid/daemon), and children of a host that exits on its own, are not chased.
Tests: 7 new (+1 from review) in NativeMessagingHostLifecycleTests with fake wrapper hosts (wrapsSilentChild, wrapsChildIgnoringSIGTERM); fixture tearDown kills by token and by script path. Against the old code 5 failed as expected (SIGKILL timer, quit sweep x3, canary test); the disconnect test and the group check passed (Process.terminate already signals the group). After: Lifecycle, Framing, ManifestValidation, Enforcement, NativeHostKeepAlive, ExtensionPolyfillProfileWiring: 177 tests, 13 env-gated skips, 0 failures; after the review fixes Lifecycle/Framing/ManifestValidation/Enforcement/KeepAlive: 111 tests, 0 failures.
/code-review --fix: no safety bug found; fixed a flaky grace in one test (2 s -> 4 s), extracted signallableGroup with a unit test for the never-Detour's-group guard, stopped logging ESRCH races as errors, deduplicated the fixture's pgrep. Skipped: EPERM counted as dead (cannot signal those anyway), a wrapper exiting on its own (recorded limit).
Runtime (Debug build in .derived, isolated DETOUR_DATA_DIR, temporary env-gated harness saved as docs/harness/task274-harness.patch, removed before commit): two wrapper hosts connected at launch, one whose child ignores SIGTERM. SIGTERM to the launched Detour pid: both wrappers exited on SIGTERM at once, NM QUIT '2 host(s) sent SIGTERM, 1 ... sent SIGKILL' at the 1 s deadline, exit status 143, no sleep child or wrapper left. Normal quit (NSApp.terminate after closing windows): same log, exit 0, nothing left. Defaults keys and data dirs removed.
Not verified: a signed build with 1Password (its host execs a binary, so this changes nothing for it but the group signal).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A wrapper-script native host that runs its real host without exec no longer leaves that host running after a quit, a SIGTERM to Detour, or a teardown whose child ignores SIGTERM. Foundation's Process already starts every host as the leader of its own process group, and Process.terminate() already signalled it; what reached only the pid was the TASK-241 SIGKILL and the quit sweep. Every signal now goes to the host's group via killpg (pid too if the host left the group), the SIGKILL timer outlives the host's exit while its group has live members, and the quit sweep waits for and kills groups. Signals stay in the host's tree: the group is used only if the host leads it and it is not Detour's, and only while the host is unreaped or within the 2 s grace / 1 s quit wait after it (XNU never reuses a live pgid as a pid). Recorded limits: descendants that leave the group, and children of a host that exits on its own. Chrome on macOS signals the pid alone. Tests: 8 new lifecycle tests with fake wrapper hosts (5 failed before the fix); 177 + 111 native-messaging tests pass. Runtime: SIGTERM and normal quit of an isolated Debug build each ended both wrapper trees, SIGKILLing the SIGTERM-ignoring child at the 1 s deadline. Not checked: signed build with 1Password (its host is a Mach-O binary, so only the target of the signal changes).
<!-- SECTION:FINAL_SUMMARY:END -->
