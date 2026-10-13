---
id: TASK-175
title: >-
  WebKit: a GPU process WebKit failed to kill stays alive and freezes every tab
  connected to it (Google Calendar favourite frozen for 1h35m)
status: Done
assignee:
  - '@claude'
created_date: '2026-10-12 23:34'
updated_date: '2026-10-13 01:06'
labels:
  - webkit
  - bug
dependencies: []
priority: high
ordinal: 198000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen in the installed app on 2026-10-12 (pid 72620, up 1d14h, machine load average 44-66).

What happened:
- 14:38:21, 14:39:49 and 14:39:57: WebKit declared its GPU process unresponsive and replaced it, three times in 97 s (pids 46533, 25143, 26842). It did so five times that day (also 08:22, 12:25).
- The third process, 26842, took 7.6 s to launch and was declared unresponsive in the same millisecond it finished launching. AuxiliaryProcessProxy::terminate logged 'Could not signal service com.apple.WebKit.GPU: 1: Operation not permitted' (the retry 30 s later failed the same way). That message appears for every terminate, and for zoom.us too, so the hard kill never works; a GPU process normally exits because its XPC handler posts exitProcess to the main run loop (XPCServiceMain.mm). 26842's main thread was blocked (GPUProcess::createGPUConnectionToWebProcess -> VideoToolbox -> Metal -> IOSurface -> CFPreferences, waiting on cfprefsd), so it never exited. WebKit forgot it and launched 27048.
- Two web processes had been handed a connection to 26842 (73062 = the Google Calendar favourite, 15227 = another tab): 'GPUProcessConnection::create' with no didInitialize and no didClose afterwards. Because 26842 stayed alive their connections never closed.
- 73062's main thread then sat in RemoteAudioSession::ensureConnection -> sendSync(EnsureAudioSession), which has no timeout, from 14:39:55 until 16:26:00. The page showed a stale frame; the user's Reload at 16:15:21 and six Stop clicks were queued and never processed (white page, X button).
- Proof: SIGKILL of 26842 at 16:26:00 -> 73062 logged GPUProcessConnection::didClose at 16:26:01.443, a new connection initialised 12 ms later, the queued reload and stops ran, the page was live again. 15227 reconnected at 16:26:04. No reload was needed.

What to build: Detour finds GPU processes that belong to it (responsibility_get_pid_responsible_for_pid == getpid(), process name com.apple.WebKit.GPU) and that WebKit no longer reports as its GPU process (_gpuProcessIdentifier), and kills them once they have been disowned for a grace period long enough that a GPU process still launching is never hit. Detour is not sandboxed and already SIGKILLs the GPU process in GPUProcessRecycler.

Not caused by GPUProcessRecycler: it logged nothing in the window and counts surfaces with proc_pidinfo, which does not suspend the target.

Evidence (session scratch, excerpts in the notes): process samples of 73062 and 26842, the unified log 14:30-16:30 for pid 72620.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A GPU process attributed to this Detour that WebKit no longer reports as its GPU process is killed after a grace period, and the kill is logged at notice
- [x] #2 WebKit's current GPU process, a GPU process that is still launching, and GPU processes of other apps or of another Detour instance are never killed
- [x] #3 The decision is a pure function with unit tests for each of the cases above
- [x] #4 A web process reported unresponsive triggers a sweep without waiting for the next periodic check
- [x] #5 The wiki records the investigation and the rule
- [x] #6 When WebKit could not be asked at all nothing is killed; when WebKit reports that it has no GPU process, every old GPU process of this app is treated as abandoned (the one-tab case, where no replacement is ever launched)
- [x] #7 A process is killed only after it has looked abandoned on two looks five seconds apart, and never more than three in an hour
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. GPUProcessOrphanPolicy (pure): a GPU process of ours that is not the pid WebKit reports and is at least minimumAge (60 s) old is an orphan; unknown current pid means no orphans; a young disowned process sets a recheck time.
2. GPUProcessTable: enumerate com.apple.WebKit.GPU processes this app is responsible for (proc_listallpids, proc_name, responsibility_get_pid_responsible_for_pid via dlsym, start time from PROC_PIDTBSDINFO).
3. GPUProcessOrphanReaper: sweep every 120 s, at a young process's coming of age, and when a web process is reported unresponsive; re-validate pid + start time before SIGKILL; log at notice.
4. GPUProcessRecycler.gpuProcessIdentifier asks every live web view (each answers for its own process pool; 0 until that pool needed the GPU process).
5. Runtime check: SIGSTOP the GPU process of an isolated Debug instance so WebKit drops it without it exiting, and watch the reaper kill it and the page carry on.
6. Wiki: platform/abandoned-gpu-process, playbook updates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-12 investigation (installed app pid 72620). Evidence kept in docs/task-175 (process samples of web process 73062 and GPU process 26842, log timeline). WebKit source read: XPCServiceMain.mm (exit posted to the main run loop), RemoteAudioSession.cpp (sendSync, no timeout), WebProcessPool.cpp (per-pool GPU process), WebPageProxy.cpp (gpuProcessID).
Design choice: age-based grace instead of 'seen disowned on two sweeps'. The only GPU processes of ours that are legitimately not WebKit's current one are one still launching (seconds old) and one just terminated and exiting (killing it is harmless), so age alone separates them and no state is carried between sweeps.
Open: why WebKit's signal is refused (zoom.us logs the same line, so not specific to Detour); why 26842's cfprefsd read never returned; not reported to WebKit.

Runtime check (2026-10-12, Debug build, isolated data directory, docs/harness/task175-176-harness.patch, logs in docs/task-175/runtime-check-orphan.log): SIGSTOP on the GPU process of a one-tab instance. WebKit dropped it 16 s later and it stayed alive; the page froze. The first version of the rule then did nothing: with the only web process frozen, WebKit never launches a replacement, every web view answers 0, and 'not the process WebKit names' had no process to compare with. Added the three-way answer (unknown / notRunning / running) using +[WKProcessPool _gpuProcessInfo], which reads WebKit's single GPUProcessProxy. Re-run: the reaper killed the stopped process 9 s after WebKit dropped it (minimum age 20 s and check interval 10 s for the run), the web process logged GPUProcessConnection::didClose 34 ms later, WebKit launched a new GPU process, and the page's frame counter continued in the same web process.
Added after the second review: a second look five seconds later before killing (a process spawned just before the Mac slept is 'old' on wake and not named yet), a limit of three kills an hour (WebKit terminates every web process when its GPU process dies repeatedly), default check interval 30 s instead of 120 s.
Tests: GPUProcessOrphanPolicyTests 20, GPUProcessRecyclePolicyTests 14; full DetourTests run 2,180 tests, 11 skipped, 0 failures. Earlier full runs on this branch each had one failure in a timing-sensitive test outside the change (tracking prevention pass, then a garbage-collection probe), each passing alone and in the other runs; one run hung in WKExtensionIntegrationTests after my real-web-view tests timed out waiting for their first page while about fifty web processes from earlier suites were still launching (machine at load average 50-65); their launch waits are now 60 s.
Not verified: criterion 5 (an unresponsive report triggers a sweep) is one call in BrowserTab.webProcessDidBecomeUnresponsive and has no test of its own; in the runtime check the kill came from the periodic sweep. The production timing (60 s minimum age, 30 s interval) was not run. Whether a system service ever runs a WebKit GPU process of its own under Detour's responsibility was not found and not ruled out (QLPreviewView does not).

Correction to the note above: GPUProcessOrphanPolicyTests has 21 tests, and the criterion without a test of its own is #4 (an unresponsive report triggers a sweep) since the criteria were renumbered.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Detour now kills GPU processes that WebKit dropped without them exiting (GPUProcessOrphanReaper). A page frozen on such a process reconnects to a live GPU process and carries on where it was, with no reload. The rule is a pure function: a com.apple.WebKit.GPU process this app is responsible for, that is not the process WebKit names (or WebKit has none), at least 60 s old, on two looks 5 s apart; at most three kills an hour. Sweeps run every 30 s and whenever a web process is reported unresponsive. Found by diagnosing a Google Calendar favourite frozen for 1 h 46 min in the installed app; verified in a running Debug build by stopping its GPU process with SIGSTOP. Wiki: platform/abandoned-gpu-process.
<!-- SECTION:FINAL_SUMMARY:END -->
