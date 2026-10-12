---
id: TASK-175
title: >-
  WebKit: a GPU process WebKit failed to kill stays alive and freezes every tab
  connected to it (Google Calendar favourite frozen for 1h35m)
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-12 23:34'
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
- [ ] #1 A GPU process attributed to this Detour that WebKit no longer reports as its GPU process is killed after a grace period, and the kill is logged at notice
- [ ] #2 WebKit's current GPU process, a GPU process that is still launching, and GPU processes of other apps or of another Detour instance are never killed
- [ ] #3 When no web view can report the GPU process identifier, nothing is killed
- [ ] #4 The decision is a pure function with unit tests for each of the cases above
- [ ] #5 A web process reported unresponsive triggers a sweep without waiting for the next periodic check
- [ ] #6 The wiki records the investigation and the rule
<!-- AC:END -->
