---
type: Investigation
title: Abandoned GPU process
description: A GPU process that WebKit "terminated" while its main thread was blocked stays alive, and every web process still connected to it freezes for good on its next synchronous call to it; how it was diagnosed in a running app and the reaper that kills such processes.
tags: [webkit, gpu, hang, diagnostics, performance]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-13T00:56:11Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-175
    resource: backlog:TASK-175
    title: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
  - id: evidence
    resource: ../../docs/task-175
    title: Process samples and the unified log timeline of the incident
  - id: reaper
    resource: ../../Detour/Browser/GPUProcessOrphanReaper.swift
    title: GPUProcessOrphanReaper.swift
  - id: recycler
    resource: ../../Detour/Browser/GPUProcessRecycler.swift
    title: GPUProcessRecycler.swift (gpuProcessIdentifier)
  - id: tests
    resource: ../../DetourTests/GPUProcessOrphanPolicyTests.swift
    title: GPUProcessOrphanPolicyTests.swift
  - id: runtime
    resource: ../../docs/task-175/runtime-check-orphan.log
    title: Runtime check of the reaper against a GPU process stopped with SIGSTOP
  - id: harness
    resource: ../../docs/harness/task175-176-harness.patch
    title: Verification harness for TASK-175 and TASK-176
  - id: xpc-main
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceMain.mm
    title: WebKit XPCServiceMain.mm (exit posted to the main run loop)
  - id: audio-session
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/GPU/media/RemoteAudioSession.cpp
    title: WebKit RemoteAudioSession.cpp (ensureConnection, a sendSync with no timeout)
  - id: pool
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebProcessPool.cpp
    title: WebKit WebProcessPool.cpp (ensureGPUProcess, gpuProcessExited)
---

When WebKit decides its GPU process is unresponsive it "terminates" it and
launches another. If the old process's main thread is blocked it never
exits, WebKit forgets it, and the web processes that were handed a
connection to it are left holding a connection that never closes. The first
synchronous call a page makes over that connection parks the page's main
thread for good. **A tab that is frozen with its web process at 0% CPU, and
that Reload cannot reach, is this until shown otherwise: list the
`com.apple.WebKit.GPU` processes before anything else.**

# Symptom

Seen on 2026-10-12 in the installed app, up 1 day 14 hours, on a machine at
a load average of 44 to 66.[^task-175]

- A Google Calendar favourite showed its last painted frame and did not
  react to the pointer. Nothing marked it as broken.
- Reload turned the pane white and the sidebar button into Stop. Six clicks
  on Stop changed nothing.
- The page's web process used no CPU at all: its CPU time did not advance
  by a hundredth of a second across a three-second sample.
- The page had been frozen for 1 hour 35 minutes before the user reloaded
  it, and for 1 hour 46 minutes in all.

# Root cause

Four things have to line up.[^task-175][^evidence]

1. **WebKit declares the GPU process unresponsive.** Under heavy CPU load
   this is routine: it happened five times that day (08:22, 12:25, and
   three times in 97 seconds from 14:38:21). The trigger is a web
   process's rendering backend timing out
   (`RemoteRenderingBackendProxy::didBecomeUnresponsive`), which leads to
   `GPUProcessProxy::didBecomeUnresponsive: GPUProcess with PID N became
   unresponsive, terminating it`.
2. **The termination does not kill.** Every one of those terminations
   logged `Could not signal service com.apple.WebKit.GPU: 1: Operation not
   permitted`, and so did zoom.us for its own GPU process: the signal
   WebKit sends is refused. A GPU process goes away anyway because the UI
   process drops its XPC connection and the helper's handler posts
   `exitProcess` to its **main run loop**.[^xpc-main] A helper whose main
   thread is blocked never runs that block.
3. **The process was blocked.** Pid 26842 took 7.6 s to launch and was
   declared unresponsive in the same millisecond it finished launching
   (another web process had been waiting on it all that time). Its main
   thread was inside its first `GPUProcess::createGPUConnectionToWebProcess`
   and ended up waiting on a preferences daemon reply
   (`av1HardwareDecoderAvailableInProcess` → VideoToolbox → Metal →
   IOSurface → `CFPREFERENCES_IS_WAITING_FOR_DIRECT_CFPREFSD`). It stayed
   there for 1 hour 46 minutes, using 0.11 s of CPU in its life.
4. **Web processes were already connected to it.** Two web processes had
   asked for a GPU connection while 26842 was launching. Their logs show
   `GPUProcessConnection::create` and then neither `didInitialize` nor
   `didClose`: a connection to a process that would never answer and never
   die.

One of the two pages (Google Calendar) re-created its notification sound
element when its previous GPU connection closed. That reaches
`RemoteAudioSession::ensureConnection`, which sends
`EnsureAudioSession` synchronously with no timeout.[^audio-session] The
page's main thread waited there until the abandoned process was killed by
hand. The other page never made a synchronous GPU call and kept working,
with the same trap armed.

# Evidence

All from the running app, without a debugger; the files are in
[docs/task-175](../../docs/task-175).[^evidence]

| Observation | How it was seen |
|---|---|
| The page's main thread is parked in a sync IPC, not busy | `sample <web pid> 3`: every sample of the main thread in `MediaSessionManagerCocoa::updateSessionState` → `RemoteAudioSession::ensureConnection` → `IPC::Connection::sendSyncMessage` → `waitForSyncReply`; `ps` shows CPU time unchanged |
| The reload never started | The log has `WebPageProxy::reload:` and no `didStartProvisionalLoadForFrame` after it; `WebPageProxy::stopLoading:` six times |
| Which GPU process the page was waiting on | Its last `GPUProcessConnection::create` (14:39:55) falls in the window where the GPU process being launched was 26842, and there is no `didInitialize` for that connection |
| The GPU process WebKit "terminated" is alive | `ps` lists a `com.apple.WebKit.GPU` started at 14:39:50 that is not the pid of the newest `GPUProcessProxy::didFinishLaunching`; `sample` shows where its main thread is stuck |
| It belongs to this app | `responsibility_get_pid_responsible_for_pid(pid)` is Detour's pid. The helpers' parent is launchd, and other apps (Mimestream, zoom.us) had GPU processes of the same name |
| Killing it is the cure | `kill -9 26842` at 16:26:00. At 16:26:01.443 the page's process logged `GPUProcessConnection::didClose` for the stale connection, a new one initialised 12 ms later, and the queued reload and stops ran. The other page reconnected at 16:26:04. No reload was needed |

## Ruled out

- **[Hidden web view load stalls](./hidden-webview-load-stalls.md).** That
  is a process at background priority that is slow; this one was visible,
  at foreground priority, and not runnable at all.
- **The network.** Nothing was requested: the reload was never read.
- **The [GPU process recycler](./gpu-iosurface-limit.md).** It logged
  nothing in the window, and it counts surfaces with `proc_pidinfo`, which
  does not suspend the process it inspects.
- **Something specific to Detour's signing or entitlements.** zoom.us logs
  the same refused signal for its WebKit GPU process.

# Fix

[GPUProcessOrphanReaper.swift](../../Detour/Browser/GPUProcessOrphanReaper.swift)
kills GPU processes that WebKit has abandoned. Their web processes then
reconnect to a live GPU process and carry on where they were; no page is
reloaded.[^task-175]

A process is an orphan (`GPUProcessOrphanPolicy.verdict`) when all of these
hold:

| Condition | Why |
|---|---|
| It is named `com.apple.WebKit.GPU` and this process is responsible for it (`GPUProcessTable.ownGPUProcesses`) | Every WebKit app has a GPU process of that name, and none of them is a child of its app |
| It is not the process WebKit names as its GPU process (`GPUProcessRecycler.webKitGPUProcess`): WebKit names another, **or none** | See below. When nothing could be asked (`.unknown`), nothing is killed |
| It is at least `minimumAge` old (60 s, `DETOUR_GPU_ORPHAN_MIN_AGE_SECONDS`) | A GPU process that is still launching is not yet the one WebKit names; the slow launch here took 7.6 s |
| It has looked that way on two looks at least `confirmationDelay` (5 s) apart | Age is wall-clock time. A process spawned just before the Mac slept, or before the main thread stalled, is "old" on wake and not named yet. The first look only records a suspect (`Verdict.suspects`, kept per process, not per pid); a process WebKit adopts in the meantime is cleared |

The reaper looks every 30 s (`DETOUR_GPU_ORPHAN_CHECK_SECONDS`), again when
a suspect is due for its second look or a disowned process that was too
young comes of age, and at once when WebKit
reports any web process unresponsive
(`BrowserTab.webProcessDidBecomeUnresponsive`), since that is the symptom.
Before the `SIGKILL` it checks that the pid still names the same process,
by start time. Each kill is logged at notice in the category `gpu-orphan`,
and a kill that fails is logged with its errno. It stops after three kills
in an hour (`maximumKillsPerHour`): one abandonment leaves one process
behind, and WebKit answers a GPU process that dies repeatedly by
terminating every web process.[^pool]

## Asking WebKit which process is its own

`webKitGPUProcess` has three answers, and the difference between two of
them was found by the runtime check, not by reading.[^runtime]

| Answer | Meaning | How it is known |
|---|---|---|
| `.running(pid)` | WebKit's live GPU process | Some live web view names it (`-[WKWebView _gpuProcessIdentifier]`), or the app-wide `+[WKProcessPool _gpuProcessInfo]` does |
| `.notRunning` | WebKit tracks no launched GPU process | No web view names one **and** `_gpuProcessInfo` returns nil |
| `.unknown` | Nothing could be asked | No web view names one and `_gpuProcessInfo` does not exist |

- **Each web view answers for its own process pool.** A pool whose pages
  have not needed the GPU process since its last relaunch answers 0, so
  "every tab answers 0" does not mean there is none.[^pool] The recycler
  used to ask only the first web view.
- **WebKit can have no GPU process while an abandoned one is alive.** The
  next GPU process is launched only when a web process asks for a
  connection, and a web process frozen on the abandoned one never asks.
  With one tab open, the first version of the rule ("some web view names
  a *different* process") did nothing at all: after WebKit dropped the
  process, every answer was 0 and the page stayed frozen. Hence `.notRunning`,
  which needs the app-wide SPI: it reads WebKit's single
  `GPUProcessProxy`, not a pool.
- **The responsibility lookup is not public API.**
  `responsibility_get_pid_responsible_for_pid` is exported by libSystem
  and declared in no header. It is resolved with `dlsym`; without it the
  reaper finds no processes and does nothing. A test fails if it stops
  resolving.[^tests]

## Checked in the running app

A Debug build in an isolated data directory, one tab whose page draws to a
canvas and reads a pixel back once a second, and `kill -STOP` on its GPU
process, which makes WebKit drop a process that cannot
exit.[^runtime]

| Time | Event |
|---|---|
| 17:30:45 | `SIGSTOP`; the page's frame counter stops |
| 17:31:01 | `GPUProcess with PID 20616 became unresponsive, terminating it`, then the refused signal. The process stays; WebKit reports no GPU process; the page is frozen |
| 17:31:10.078 | `Killing abandoned GPU process 20616, launched 40 s ago` (minimum age set to 20 s for the run; the run predates the second look, which adds five seconds) |
| 17:31:10.112 | the page's web process: `GPUProcessConnection::didClose`, then `create`; WebKit launches a new GPU process |
| 17:31:11 | the counter continues from where it stopped, in the same web process |

The backstop for a web process that hangs for any other reason is on
[unresponsive web process](./unresponsive-web-process.md).

## Reproducing it

`SIGSTOP` is the way to make an abandoned GPU process on demand: WebKit's
terminate cannot kill it and it cannot run its own exit. Three things the
check needed, all in
[the harness](../../docs/harness/task175-176-harness.patch):

- The page must be using the GPU process when it stops, or WebKit never
  notices. A 2D canvas `fillRect` plus `getImageData` does it.
- A window launched behind others is hidden to WebKit, and on a busy
  machine a hidden page's own timers barely run
  ([hidden web view load stalls](./hidden-webview-load-stalls.md)). The
  harness drives the drawing with `evaluateJavaScript` once a second
  instead.
- The fixture is served over HTTP. A `file:` or `data:` URL does not load
  in a web view the window has claimed.

# Recognising it again

```bash
ps -axo pid,lstart,time,command | grep 'com.apple.WebKit.GPU' | grep -v grep
/usr/bin/log show --last 6h --predicate \
  'processIdentifier == <detour pid> AND eventMessage CONTAINS "GPUProcessProxy::"' | grep -E 'terminating it|didFinishLaunching'
```

A GPU process that is older than the newest `didFinishLaunching` of the
app, uses no CPU, and whose pid appears in a `terminating it` line is
abandoned. Which of several GPU processes belong to the app:
[WebKit helper diagnostics](../playbooks/webkit-helper-diagnostics.md).

# Open questions

- Why the abandoned process's preferences read never returned. Its last
  log line is `Loading Preferences From Direct CFPrefsD`, 31 s after
  WebKit dropped it; whether losing its XPC connection caused that was not
  established.
- Why WebKit's signal is refused. It was not checked whether Safari sees
  the same message.
- Whether a system service ever runs a WebKit GPU process of its own on
  Detour's behalf, which the reaper would take for an orphan. A Quick Look
  preview of an HTML file inside the app does not: it is an in-process web
  view on the app's own GPU process, and a non-sandboxed app's open panel
  is in-process too.[^task-175] None was found; the kill limit bounds the
  damage if one exists.
- `+[WKProcessPool _gpuProcessInfo]` returns nil when WebKit cannot read
  the process's task info as well as when there is no process. It was not
  established when, if ever, that fails for a live process; the web views'
  answers are consulted first for that reason.
- Not reported to WebKit. Two defects are involved: a termination that
  depends on the main thread of the process being terminated, and a
  synchronous message with no timeout.

# Related

- [Unresponsive web process](./unresponsive-web-process.md) — what WebKit reports about a blocked web process, and the Reload that replaces it.
- [GPU IOSurface limit](./gpu-iosurface-limit.md) — the other GPU process failure, and the recycler that shares the pid lookup.
- [Hidden web view load stalls](./hidden-webview-load-stalls.md) — the slow-but-alive case this must not be confused with.
- [WebKit helper diagnostics](../playbooks/webkit-helper-diagnostics.md) — sampling a helper and attributing it to an app.
- [Reading runtime logs](../playbooks/reading-runtime-logs.md) — the log lines used above.
- [WebKit source lookup](./webkit-source-lookup.md) — fetching the files cited here.

[^task-175]: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
[^evidence]: Process samples and the unified log timeline of the incident
[^xpc-main]: WebKit XPCServiceMain.mm (exit posted to the main run loop)
[^audio-session]: WebKit RemoteAudioSession.cpp (ensureConnection, a sendSync with no timeout)
[^pool]: WebKit WebProcessPool.cpp (ensureGPUProcess, gpuProcessExited)
[^tests]: GPUProcessOrphanPolicyTests.swift
[^runtime]: Runtime check of the reaper against a GPU process stopped with SIGSTOP
