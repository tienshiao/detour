---
type: Component
title: Ending native host processes
description: How Detour ends a native messaging host's process and everything it started — SIGTERM then SIGKILL after a 2 s grace, signals to the host's own process group, the spawned-host registry, and the quit and SIGTERM-to-Detour sweeps that keep hosts from outliving the app.
tags: [extensions, native-messaging, processes, signals]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:42:31Z }
sources:
  - id: host
    resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
    title: NativeMessagingHost.swift (teardownProcess, Termination, spawned registry, terminateAllSpawnedHosts, installSIGTERMHandler)
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (installSIGTERMHandler at launch, the sweep in applicationWillTerminate)
  - id: task-241
    resource: backlog:TASK-241
    title: "Native messaging: a host that ignores SIGTERM is never killed"
  - id: chromium-kill
    resource: https://github.com/chromium/chromium/blob/1a95d4d76ab47c2ff9b914eaa98d3f35b7f1fce1/base/process/kill_mac.cc
    title: Chromium base/process/kill_mac.cc (EnsureProcessTerminated, kWaitBeforeKillSeconds = 2)
  - id: task-274
    resource: backlog:TASK-274
    title: "Native messaging: a wrapper-script host that does not exec leaves its real host running after quit"
  - id: xnu-pids
    resource: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_fork.c
    title: XNU kern_fork.c (pid allocation skips live pids, process groups and sessions) and kern_sig.c (killpg1 skips zombies)
  - id: chromium-launch-posix
    resource: https://github.com/chromium/chromium/blob/2fbb17b57270034f6c85ab9819c3ec4069a54986/chrome/browser/extensions/api/messaging/launch_context_posix.cc
    title: Chromium launch_context_posix.cc (LaunchNativeProcess sets no new_process_group)
  - id: task-243
    resource: backlog:TASK-243
    title: "Native messaging: quitting Detour may leave live port hosts running"
  - id: task-277
    resource: backlog:TASK-277
    title: "Tests: cover native host quit refusal and the SIGTERM path, keep the host sweep to the test's own hosts, and route the injected clock through the permission gates"
  - id: lifecycle-tests
    resource: ../../DetourTests/NativeMessagingHostLifecycleTests.swift
    title: NativeMessagingHostLifecycleTests.swift
  - id: enforcement-tests
    resource: ../../DetourTests/NativeMessagingEnforcementTests.swift
    title: NativeMessagingEnforcementTests.swift
---

When a [native messaging](./native-messaging.md) connection ends (see
[the connection lifecycle](./native-host-lifecycle.md)), or Detour quits,
the host's process, and anything it started, has to go too. Detour sends
SIGTERM, then SIGKILL after a grace period, to the host's process group, and
keeps a registry of every host it started so that no quit path leaves one
running.

# Ending the process

The teardown closes the host's stdin and sends SIGTERM. A host still
running `Termination.grace` (2 s) later is sent SIGKILL; before TASK-241 a
host that ignored or blocked SIGTERM stayed running as a child of Detour
after its port or request was gone.[^task-241] The wait runs on a global
queue and holds the `Process`, never the host, so a teardown from `deinit`
still escalates and the host is not kept alive. It checks that the host, or
anything left in its process group, is still alive first (`isAlive`, see
[the host's process tree](#the-hosts-process-tree)). `Process.isRunning`
goes false when Foundation reaps the child,
and until the reap the pid is a zombie's and cannot be reused, so a host
that exited on SIGTERM (1Password's does) is sent nothing more. A host that
had already exited when the teardown ran gets no signal at all.

Chrome does it differently on macOS: `~NativeMessageProcessHost` closes the
pipes and posts `base::EnsureProcessTerminated`, which waits up to
`kWaitBeforeKillSeconds = 2` for the exit (kqueue `NOTE_EXIT`) and then
sends SIGKILL; it sends no SIGTERM. The Linux path (`kill_posix.cc`,
`BackgroundReaper`) also waits 2 s and then kills.[^chromium-kill] Detour
keeps its SIGTERM first, so a host that exits on it is unaffected.

What a teardown does to writes still queued for the host is on
[writing to a native host](./native-host-writing.md): they are abandoned,
never waited on.

# The host's process tree

Every signal goes to the host's process group, so a host's descendants end
with it (TASK-274).[^task-274] Foundation's `Process` starts the host as the
leader of a process group of its own: its pgid is its pid, a child it starts
without `exec` shares it, and Detour's own group is a different one
(measured with a standalone probe; `testAHostLeadsAProcessGroupOfItsOwn`
fails if Foundation stops doing it). `Process.terminate()` signals that
group too (Apple: "the receiver and all of its subtasks"), so the
teardown's SIGTERM already reached a wrapper's child. What went to the pid
alone was the TASK-241 SIGKILL, which also fired only while the host itself
was running, and the quit sweep's SIGTERM and SIGKILL, and so the SIGTERM
handler's. A host installed as a `#!/bin/sh` wrapper that runs `python3
host.py` without `exec` dies on SIGTERM; its real host, reparented to
launchd, stayed running if it ignored SIGTERM, and at quit whenever it did
not watch its stdin.

- **The group is recorded at spawn**, in the registry entry, only when
  `getpgid(pid) == pid` and it is not Detour's group (a `killpg` of that
  would end Detour). Otherwise only the pid is signalled, logged as
  `NM GROUP`.
- **`send`** `killpg`s the group, and `kill`s the host's pid as well when
  the host is running but has moved out of the group. **`isAlive`** is the
  host running, or `killpg(group, 0) == 0`: XNU's `killpg` skips zombies and
  fails when only zombies are left.[^xnu-pids]
- **A torn-down host that exits while its group still has a live member**
  keeps its registry entry (`hostExited`) until its SIGKILL timer fires, so
  the timer, and a quit before then, still kill a wrapper's
  SIGTERM-ignoring child once the wrapper has died of the SIGTERM. The timer
  goes into the entry before the SIGTERM is sent, so an exit caused by the
  SIGTERM cannot get there first and cancel it. An entry with nothing left
  in its group goes at the exit as before.
- **The quit sweep** waits while a host or anything in its group is alive,
  and SIGKILLs the groups still alive at the deadline.

Why the group's id names nobody else: it is the host's pid, and XNU
allocates pids one after the other, wrapping at `PID_MAX` (99,999) to 100,
and skips any id that is in use as a pid, a process-group id or a session
id (`kern_fork.c`). So the id cannot be handed to another process while the
host is unreaped or any process in its group is alive. Once they have all
gone, it comes back only after the counter has gone all the way round.
Detour signals a group only while the host is unreaped, or within a
teardown's grace (2 s) or the quit's wait (1 s) after the host's exit,
never later. A process joining the group from outside would have to be in
Detour's session and call `setpgid` with it, which nothing does.

Limits, decided and not chased:

- A descendant that leaves the group (`setsid`, `setpgid`, a host that
  daemonises) is not reached.
- Processes left behind by a host that exits on its own, such as a wrapper
  that starts its real host in the background and exits, are not signalled:
  nothing bounds how long ago the host went, so the group's id is no longer
  safe to use.

Chrome does none of this on macOS. `LaunchNativeProcess` sets no
`new_process_group` (the host stays in Chrome's group), and
`EnsureProcessTerminated` SIGKILLs the pid alone, so a wrapper's child
outlives Chrome's teardown too.[^chromium-launch-posix]

# Quitting

Exiting ends no host by itself. A host is a child of Detour, in a process
group of its own that nothing signals when Detour dies; the exit closes the
host's stdin, which ends a host that reads it, and one that does not read it (a silent host
holding the keep-alive) carries on, reparented to launchd. The exit also
takes every pending SIGKILL timer with it. Measured before TASK-243 with two
fake port hosts (`exec sleep`, one with `trap '' TERM`): after a normal quit
and after a SIGTERM to the app, both were still running with ppid 1. No
teardown ran at quit at all.[^task-243]

So `NativeMessagingHost` keeps a registry of every host process it started
and has not seen exit (`spawned`, a `Mutex` keyed by the `Process`). It
covers hosts an owner still holds as well as torn-down ones still inside
their grace period. `connect()` calls `run()` and adds the entry under the
same lock, so a sweep sees a host either running or not at all. The
termination handler removes the entry, waiting on the lock if the exit
comes straight after `run()`. A sweep from a quit path sets `isQuitting`,
after which `connect()` throws (`NativeMessagingError.quitting`). Without
that, on the SIGTERM path, where the main thread keeps running, an extension
reconnecting when its host exits on the sweep's SIGTERM would start a host
that outlives Detour. The flag is never cleared in the app; tests lift it
with the Debug-only `setRefusingNewHostsForTesting`. Tests sweep through the
Debug-only `terminateSpawnedHostsForTesting(running:within:refusingNewHosts:)`,
the same sweep limited to the hosts started from the executables it names
(each registry entry keeps its manifest `path`), so a test ends only its own
fixtures' hosts and never one another suite left in the test
host.[^task-277]
`terminateAllSpawnedHosts(within:refusingNewHosts:)` sends SIGTERM to each running one's
process group, waits for them all together, polling `isAlive` (the host or
anything left in its group), then sends SIGKILL to the groups still
alive ([the host's process tree](#the-hosts-process-tree)). It logs `NM QUIT: N host(s) sent SIGTERM, M … sent SIGKILL`. It blocks
the calling thread, which may be the main thread: Foundation reaps the child
on a queue of its own, so `isRunning` changes while the main thread waits
(checked with a standalone probe). The owners hear nothing, since their
reports are main-actor tasks and the app exits first.

- **Normal quit**: called last in `applicationWillTerminate`, after the
  session and download saves. It goes there and not in
  `applicationShouldTerminate`, whose quit alert can still cancel. Every
  `terminate` that goes ahead (the alert, no windows, a Sparkle relaunch)
  ends there.
- **The wait** is `quitGrace` = 1 s for all hosts together, against 2 s per
  host for a teardown, because it delays the quit. A host that exits on
  SIGTERM takes milliseconds (measured: 2 ms), so the second is only spent
  on a host that ignores SIGTERM.
- **SIGTERM to Detour**: `installSIGTERMHandler()` (at the start of
  `applicationDidFinishLaunching`, after only a test-run setting) sets SIGTERM to `SIG_IGN` and handles it
  with a `DispatchSource` on a global queue (made by
  `makeHostEndingSignalSource(_:endHosts:)`). That works even when the main
  thread is busy or hung. The handler ends the hosts in the same way (and
  removes the [automation endpoint](../features/automation-endpoint.md)'s
  file, which no quit path would), then cancels the source (it sees the re-sent signal too, whatever the
  disposition), restores `SIG_DFL` and sends SIGTERM to itself again. The app
  still dies of the signal, with exit status 143, and runs no quit path: no
  quit alert, no save. Worth doing because SIGTERM is what a `kill`, a
  launchd job or a test runner sends. Logout and Activity Monitor's Quit send
  a quit Apple Event, which goes through `terminate`. A child does not
  inherit the ignored SIGTERM: Foundation's `Process` resets signal
  dispositions when it spawns (a `sleep` started with SIGTERM ignored in the
  parent died on SIGTERM), so hosts still exit on the teardown's SIGTERM.
- **SIGKILL** leaves nothing to do. A host killed while in uninterruptible
  sleep would linger until it wakes; nothing has done that.

The TASK-241 timer is now a `DispatchSourceTimer` kept in the host's
registry entry, so the termination handler cancels it and the `Process` and
its pipes go as soon as the host exits, rather than once the grace period is
over. Removing the entry alone releases the handler: a resumed timer source
with no references left is freed. The cancel makes that explicit. A timer
made for a host whose entry is already gone (it exited between the
teardown's `isRunning` and the registry lock) is cancelled and still
resumed: libdispatch crashes when a source that was never activated is
released ("Release of an inactive object").

Measured after the change, Debug build, isolated profile, a keep-alive port
on a silent host and a port on a SIGTERM-ignoring one: a normal quit
(`NSApp.terminate`, the quit alert answered) logged the silent host's exit
(status 15) 2 ms into `applicationWillTerminate`, and killed the other (status
9) at the 1 s deadline; both were gone after the quit. A SIGTERM to the app
did the same and exited with status 143.

# Tests

- SIGTERM and the grace period (TASK-241), in
  `NativeMessagingHostLifecycleTests`: a host
  that ignores SIGTERM (`silentIgnoringSIGTERM`, `trap '' TERM` before
  `exec sleep`) is still running partway through a shortened
  `Termination.grace` and killed after it, by `disconnect()` and by release;
  `Termination.onKill` shows a `.silent` host (which exits on SIGTERM) and a
  host that already exited are never sent SIGKILL.
- Process trees (TASK-274), in `NativeMessagingHostLifecycleTests`, with
  wrapper hosts (`wrapsSilentChild`: the script runs `/bin/sleep <token>`
  and then `exit $?`, so the shell cannot run it in place;
  `wrapsChildIgnoringSIGTERM`: the child is a shell that sets `trap ''
  TERM` and `exec`s the sleep). Each test first checks the shape: the
  child's ppid is the wrapper and its pgid the wrapper's pid. The host leads
  its own group; `signallableGroup(host:hostGroup:detourGroup:)`, the pure
  check behind the recorded group, refuses Detour's group, a group the host
  does not lead, a failed `getpgid` and the ids 0 and 1; `disconnect()` ends a wrapper and its child with no SIGKILL
  (this passed before the fix, through `Process.terminate()`); a
  SIGTERM-ignoring child outlives its wrapper until the grace period is over
  and is then killed through the group; the quit sweep ends a wrapper's
  child, waits for and kills a SIGTERM-ignoring one, and kills one left
  from a teardown inside the grace period; a `Process` of the test's own
  (also a group leader) survives a wrapper host's teardown, SIGKILL
  included, and then the quit sweep, and another host survives the
  teardown. Before
  the fix, all of these failed except the `disconnect()` one and the group
  check. `wrapperIDs()` finds the wrapper shell by the script's path, which
  is in the fixture's own directory, and the fixture's `tearDown()` kills by
  that path as well as by the token, so a child left by a failed run is
  killed too.
- Quitting (TASK-277): `NativeMessagingEnforcementTests` sets the quit
  refusal and shows an extension page's `sendNativeMessage` (promise and
  callback) and `connectNative` all get "Detour is quitting", with no
  process started and no live or pending host. The SIGTERM handler's
  sequence runs in the test host through `makeHostEndingSignalSource` with
  SIGURG (default action: discard) and a sweep limited to the test's host:
  the handler runs once, the host is ended and new connects refused before
  the signal is sent again, a second signal source sees both deliveries (a
  signal source sees every delivery, even of a signal whose disposition
  discards it), and the disposition is `SIG_DFL` again. SIGTERM itself
  cannot be sent there (it would end the test host), and spawning Detour
  from a test is ruled out (an app launch must have an isolated data
  directory), so that SIGTERM's default action then ends Detour with status
  143 rests on the kernel and the runtime check with
  `docs/harness/task274-harness.patch`. A test's sweep leaves a host it does
  not name running.
- The quit sweep with megabytes queued for a host that ignores SIGTERM is a
  [writing](./native-host-writing.md#tests) leg.

# Related

- [Native messaging](./native-messaging.md) — spawn, where a refused connect after quitting is reported
- [Native host connection lifecycle](./native-host-lifecycle.md) — the teardown that calls into this, and when
- [Writing to a native host](./native-host-writing.md) — why no teardown or quit waits on a write
- [App shell](../architecture/app-shell.md) — launch and termination order around the sweep
- [Automation endpoint](../features/automation-endpoint.md) — the other thing the SIGTERM handler cleans up

[^task-241]: Native messaging: a host that ignores SIGTERM is never killed
[^chromium-kill]: Chromium base/process/kill_mac.cc (EnsureProcessTerminated, kWaitBeforeKillSeconds = 2)
[^task-274]: Native messaging: a wrapper-script host that does not exec leaves its real host running after quit
[^xnu-pids]: XNU kern_fork.c (pid allocation skips live pids, process groups and sessions) and kern_sig.c (killpg1 skips zombies)
[^chromium-launch-posix]: Chromium launch_context_posix.cc (LaunchNativeProcess sets no new_process_group)
[^task-243]: Native messaging: quitting Detour may leave live port hosts running
[^task-277]: Tests: cover native host quit refusal and the SIGTERM path, keep the host sweep to the test's own hosts, and route the injected clock through the permission gates
