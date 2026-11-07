---
type: Component
title: Native messaging
description: How Detour runs Chrome native messaging hosts for extensions — host discovery, the access gate at dispatch, the one-shot and port paths, exactly-once teardown, and what may and may not be logged.
resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
tags: [extensions, native-messaging, security, logging]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-03T06:20:00Z }
sources:
  - id: task-232
    resource: backlog:TASK-232
    title: A host that writes its reply and exits at once can have the exit handled before the reply
  - id: ending
    resource: ../../Detour/Extensions/Runtime/NativeHostEnding.swift
    title: NativeHostEnding.swift (the join of end of stream and process exit)
  - id: lifecycle-tests
    resource: ../../DetourTests/NativeMessagingHostLifecycleTests.swift
    title: NativeMessagingHostLifecycleTests.swift
  - id: task-233
    resource: backlog:TASK-233
    title: A quiet host process outlives the owner that released it
  - id: task-241
    resource: backlog:TASK-241
    title: "Native messaging: a host that ignores SIGTERM is never killed"
  - id: chromium-runtime
    resource: https://github.com/chromium/chromium/blob/f0ba36023a040e2260f145ac7fa33a9f3e8e1db7/extensions/common/api/runtime.json
    title: Chromium extensions/common/api/runtime.json and extensions/renderer/bindings/argument_spec.cc
  - id: task-242
    resource: backlog:TASK-242
    title: A one-shot sendNativeMessage with a non-object message leaks the host and never settles
  - id: task-266
    resource: backlog:TASK-266
    title: "Native messaging: a host manifest without allowed_origins admits every extension"
  - id: task-265
    resource: backlog:TASK-265
    title: "Native messaging: writing to a host that stops reading stdin blocks the main thread and freezes the app"
  - id: chromium-limits
    resource: https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/native_message_process_host.cc
    title: Chromium native_message_process_host.cc (kMaximumNativeMessageSize, the unbounded write queue, kHostInputOutputError) and extensions/renderer/api/messaging/messaging_util.cc (the 64 MiB kMaxMessageBytes)
  - id: chromium-launcher
    resource: https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/native_process_launcher.cc
    title: Chromium native_process_launcher.cc and native_messaging_host_manifest.cc (manifest checks, their order and result codes)
  - id: manifest-tests
    resource: ../../DetourTests/NativeHostManifestValidationTests.swift
    title: NativeHostManifestValidationTests.swift
  - id: task-275
    resource: backlog:TASK-275
    title: "Native messaging: a failed connect leaves the host's pipes and stderr handler behind"
  - id: task-243
    resource: backlog:TASK-243
    title: "Native messaging: quitting Detour may leave live port hosts running"
  - id: task-256
    resource: backlog:TASK-256
    title: "Extensions: a port's onDisconnect fires in the context that called port.disconnect()"
  - id: webkit-325256
    resource: https://github.com/WebKit/WebKit/commit/c78afbcefdb9
    title: "WebKit 325256@main: Port.disconnect() fires onDisconnect on the port that called it"
  - id: task-274
    resource: backlog:TASK-274
    title: "Native messaging: a wrapper-script host that does not exec leaves its real host running after quit"
  - id: chromium-launch-posix
    resource: https://github.com/chromium/chromium/blob/2fbb17b57270034f6c85ab9819c3ec4069a54986/chrome/browser/extensions/api/messaging/launch_context_posix.cc
    title: Chromium launch_context_posix.cc (LaunchNativeProcess sets no new_process_group)
  - id: xnu-pids
    resource: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_fork.c
    title: XNU kern_fork.c (pid allocation skips live pids, process groups and sessions) and kern_sig.c (killpg1 skips zombies)
  - id: chromium-kill
    resource: https://github.com/chromium/chromium/blob/1a95d4d76ab47c2ff9b914eaa98d3f35b7f1fce1/base/process/kill_mac.cc
    title: Chromium base/process/kill_mac.cc (EnsureProcessTerminated, kWaitBeforeKillSeconds = 2)
  - id: task-231-8
    resource: backlog:TASK-231.8
    title: Memory safety audit of raw-pointer code and untrusted-byte parsing
  - id: framing-tests
    resource: ../../DetourTests/NativeMessagingFramingTests.swift
    title: NativeMessagingFramingTests.swift
  - id: host
    resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
    title: NativeMessagingHost.swift
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (nativeHostAccess, sendMessage and connectUsing delegate methods)
  - id: connect-log
    resource: ../../Detour/Extensions/Runtime/NativeConnectLogLimiter.swift
    title: NativeConnectLogLimiter.swift
  - id: enforcement-tests
    resource: ../../DetourTests/NativeMessagingEnforcementTests.swift
    title: NativeMessagingEnforcementTests.swift
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan (reference data, security note, TASK-25 and TASK-44 decisions)
  - id: task-1
    resource: backlog:TASK-1
    title: 1Password extension log hygiene
  - id: task-25
    resource: backlog:TASK-25
    title: Enforce the saved nativeMessaging decision
  - id: task-62
    resource: backlog:TASK-62
    title: Keep-alive in background pages (the review that found two contexts evicting each other's port)
  - id: task-90
    resource: backlog:TASK-90
    title: 1Password reconnect loop investigation (connect logging, unlisted-context refusal)
---

# Role

`NativeMessagingHost` runs **one** native messaging host process and speaks
Chrome's stdio protocol to it. `ExtensionManager`, as the
`WKWebExtensionControllerDelegate` of every profile's controller, decides
whether a host may be started, owns the running hosts, and reports their
coming and going to the [keep-alive](./native-port-keep-alive.md). 1Password's
desktop-app channel is the main user (see
[1Password integration](./1password-integration.md)).

# How it works

## Discovery and spawn

`NativeMessagingHost.connect()`:

1. Rejects a host name that is not lowercase alphanumerics, dots and
   underscores (`isValidHostName`). The name is joined onto a directory path,
   so this is what stops `../../evil`.
2. Looks for `<name>.json` in `searchDirectories`, in order, and takes the
   first file it finds:

   | Order | Directory |
   |---|---|
   | 0 (Debug builds only) | `$DETOUR_NATIVE_MESSAGING_HOSTS_DIR` |
   | 1 | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts` |
   | 2 | `~/Library/Application Support/Chromium/NativeMessagingHosts` |
   | 3 | `~/Library/Application Support/Detour/NativeMessagingHosts` |
   | 4 | `/Library/Google/Chrome/NativeMessagingHosts` |

   A file that is there but refused (step 3, or a `name` field that is not
   the requested name) ends the search, as in Chrome, which loads the first
   manifest it finds: a later directory does not stand in for it.
3. `NativeHostManifest.parse` refuses what Chrome's manifest parser
   refuses: a file that is not a JSON object, a missing `name` or `path`,
   a `type` other than `"stdio"`, and an `allowed_origins` that is missing,
   null, not a list, or holds a non-string. `description`, required by
   Chrome, is not checked: it plays no part in who may start the
   host.[^task-266]
4. `allowed_origins` must contain `chrome-extension://<extension id>/`.
   This works with manifests written for Chrome because Detour derives the
   same ids Chrome does (see [installer and CRX](./installer-and-crx.md)).
   The manifests sit in user-writable directories, so this check is the only
   thing tying a host to the extensions it was installed for; until TASK-266
   it only ran when the key was present, so a manifest without it admitted
   every extension with `nativeMessaging`.
5. `path` must be absolute (macOS has no relative form; Chrome resolves one
   against the manifest's directory only on Windows), checked after the
   origin, where Chrome checks it. A relative path used to resolve against
   Detour's working directory.
6. `path` must be an executable file. It is spawned with the origin as its
   one argument, as Chrome does, with pipes for stdin, stdout and stderr.
   The process and pipes stay local to `connect()` until `run()` has
   succeeded under the registry lock; when the spawn throws there (Detour
   is [quitting](#quitting), or `run()` fails, e.g. on a `path` that is a
   directory, which passes the executable check) every pipe end is closed
   before the error goes out, and the stderr reader is only installed once
   the host runs. Each failed connect used to keep 3 (failed `run()`) to 7
   (quit refusal) descriptors open for as long as its host object
   lived.[^task-275]

What the extension sees for each refusal is Chrome's text for the
launcher's result, as a rejected `sendNativeMessage` (promise and
`runtime.lastError`) or on the refused port's `port.error`; the specifics
(host name, the manifest's fault, the directory) go to the
`native-messaging` log category only, and `NativeMessagingError.logDetail`
carries them into the rate-limited `connectNative` attempt line:[^chromium-launcher]

| Refusal | `NativeMessagingError` | Text |
|---|---|---|
| Host name refused (step 1) | `.invalidName` | "Invalid native messaging host name specified." |
| No manifest, invalid manifest (step 3) or one naming another host, relative path | `.manifestNotFound`, `.invalidManifest`, `.pathNotAbsolute` | "Specified native messaging host not found." |
| Origin not listed (an empty list included) | `.originNotAllowed` | "Access to the specified native messaging host is forbidden." |
| `path` not an executable | `.hostNotFound` | "Failed to start native messaging host." |

The legs are tested in `NativeHostManifestValidationTests` (parse and
`connect()` against a fake host whose manifest each test edits; the
relative path resolves to the fake host's script, so only the refusal keeps
it from running), `NativeMessagingEnforcementTests` (an extension page,
all three delivery forms) and `ExtensionPolyfillProfileWiringTests` (a
service worker).[^manifest-tests] Detour's own hosts never reach any of
this (see below).

Framing is a 4-byte little-endian length followed by UTF-8 JSON. A host
may send at most `maxIncomingMessageSize` (1 MB); Detour sends a host at
most 64 MiB (see [writing to the host](#writing-to-the-host)). The read loop runs on a
private serial queue and delivers to the main queue. It reads the prefix
(`Data.littleEndianUInt32()`, byte by byte, no raw-pointer load), refuses 0
or anything above the cap ("Invalid message length: N"), then reads that
many bytes; a short read (the host closed stdout early) disconnects with
"Incomplete message read", and fewer than four prefix bytes is the end of
stream (see [the host going away](#the-host-going-away)). Frames read before
a bad one are delivered first.
See [Strict memory safety](../platform/strict-memory-safety.md).[^task-231-8]

## Writing to the host

`sendMessage` encodes the message and queues the frame; it never writes in
place. Until TASK-265 it wrote with a blocking `FileHandle.write` on the
main actor, so a host that stopped reading its stdin froze the app once the
pipe's 64 KB buffer was full, and a normal quit hung with it
(`applicationWillTerminate` could not run; only the SIGTERM path still ended
hosts).[^task-265]

- **The writer.** Each connection has a `StdinWriter` (nonisolated,
  `Sendable`, its counters behind a `Mutex`) owning a `DispatchIO` stream
  channel on the stdin descriptor. libdispatch writes as the pipe drains,
  without holding a thread, and a stream channel performs its writes in the
  order they were submitted, so the host gets messages in `sendMessage`
  order (tested with forty echoed messages, every other one 200 KB). The
  descriptor is closed in the channel's cleanup handler, which also holds
  the `FileHandle` until then: closing it under the channel could hand its
  number to another file mid-write.
- **Teardown abandons what is queued.** `teardownProcess` closes the
  channel with `.stop`: a write still waiting on a host that never reads is
  cancelled, then the descriptor closes and the process gets SIGTERM as
  before. Chrome does the same: closing a host drops its write queue. A
  message posted just before a port disconnect may therefore never reach the
  host. Nothing on the teardown, kill-timer, quit-sweep or SIGTERM-handler
  paths waits on a write, and no thread is ever blocked in one, so a quit
  completes with a non-reading host and megabytes queued for it (tested).
- **A failed write** (EPIPE: the host closed stdin or exited) is seen on a
  global queue. The first one is logged (`NM WRITE FAILED`, errno only),
  recorded in the join as `.writeFailed` before anything else, and the
  teardown then runs on the main actor; the owner hears it through
  `onDisconnect` like any end. ECANCELED from the teardown's own stop is
  ignored. The descriptor has `F_SETNOSIGPIPE`, and `main.swift` ignores
  SIGPIPE process-wide; the test of a host that closed its stdin runs with
  SIGPIPE back at its default, so a write that raised it would kill the
  test host.

The limits (`NativeMessagingHost.OutgoingLimits.standard`; a static that
tests lower so no leg needs 64 MiB of JSON):[^chromium-limits]

| Limit | Value | Why | When exceeded |
|---|---|---|---|
| One message to a host | 64 MiB of JSON body | Chrome's: its renderer refuses any extension message over `kMaxMessageBytes` (64 MiB, "IPC messages will fail at > 128 MiB") with "Message exceeded maximum allowed size of 64MiB.", and the native messaging docs give 64 MiB as the limit to a host. It was 1 MB, a copy of the host-to-browser limit, which refused messages Chrome sends | `messageTooLarge`, Chrome's text |
| Queued and not yet written, per host | 64 MiB + 4 (one maximum frame) | A host that reads at all drains a pipe at memory speed, so bytes only pile up behind one that has stopped. Chrome's queue has no bound; this keeps what a wedged host can make Detour hold to one largest message. A frame counts until it is completely written | `sendQueueFull`, Chrome's `kHostInputOutputError` text "Error when communicating with the native messaging host." |
| One message from a host | 1 MB | Chrome's `kMaximumNativeMessageSize`, which protects the browser from a misbehaving host | The connection ends ("Invalid message length: N") |

What the extension sees when a port message cannot be sent (too large, not
encodable, queue full, host already gone): the port's `messageHandler`
logs it (`extension-manager`, error level, with `logDetail`), releases the
host from the keep-alive, disconnects the host and disconnects the port
with the error. The extension gets `onDisconnect`; WebKit does not hand an
established port's error over (see Gotchas), so the text only reaches the
log. Dropping the message and keeping the port open, which is what Chrome's
synchronous `postMessage` throw amounts to for an oversized message, is not
available (WebKit gives Detour no way to throw into `postMessage`), and a
silently dropped message would leave the host reading later messages with a
hole before them. The exception is a host already going away whose end
is still being joined (it exited or a write failed, and the read loop has not
reached the end of stream): the message is dropped and the port left to the
join's `onDisconnect`, so a reply the host wrote before going is still
delivered. A one-shot `sendNativeMessage` is rejected with the same
error, as before; its single message can never fill the queue.

## Two entry points

| Extension call | Delegate method | Lifetime |
|---|---|---|
| `runtime.sendNativeMessage` | `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)` | A `OneShotNativeRequest` in `activeMessagingHosts`. The first reply, or the host exiting ("Native host has exited."), settles the promise once. Never counts toward the keep-alive. |
| `runtime.connectNative` | `webExtensionController(_:connectUsing:for:completionHandler:)` | A `LiveNativeHost` (host + WebKit port) in `liveNativeHosts`, keyed by (controller, extension). Counts toward the keep-alive. |

Both paths also carry Detour's own traffic: `detourPolyfill` (the
[polyfill layer](./polyfill-layer.md)'s worker transport and the keep-alive
port) and `detourWebSocketRelay` (the [WebSocket relay](./websocket-relay.md)).
Those names never spawn a process.

## The access gate

`nativeMessaging` is granted on every context unconditionally in
`Profile.loadExtensionContext`, because the polyfill bridge in a service
worker *is* `sendNativeMessage`. The real gate is therefore at dispatch:
`ExtensionManager.nativeHostAccess(hostName:manifestPermissions:savedDecision:)`.

| Result | When | Effect |
|---|---|---|
| `.polyfillHost`, `.webSocketRelayHost` | Host name is one of Detour's own | Accepted without the manifest permission; the saved decision is never read |
| `.allowed` | Manifest declares `nativeMessaging`, no saved denial | Host is looked up and spawned |
| `.denied` | Manifest does not declare it, or the context cannot be attributed | Refused: "nativeMessaging permission not declared" / "Unrecognized extension context" |
| `.deniedByUser` | Saved `nativeMessaging` decision is a denial | Refused with Chrome's "Access to the specified native messaging host is forbidden." before any host object exists |

The sender's identity comes from the context object, never from the message:
`extensionIDFromContext` looks the context up, by identity, in the owning
profile's `extensionContexts`. A context the profile no longer lists
(unloaded, or a call in flight across a reload) is refused. Until TASK-90
the port path answered such a connect with `completionHandler(nil)`: a port
with no handlers attached, no host, and no log line.

Turning the permission off in Settings takes effect on the loaded context:
`disconnectRealNativeHosts(for:)` kills running hosts, disconnects their
ports with the forbidden error and rejects pending one-shot replies. How the
saved decision is stored and migrated is on the
[permissions](./permissions.md) page.

## Teardown, exactly once

A connection can end from four directions: the host process exits, the
extension disconnects the port, the context unloads, or a write fails.

- `NativeMessagingHost.disconnect()` (the port telling the host to go away)
  deliberately does **not** fire `onDisconnect`. `connectionEnded` (the host
  going away, see below) fires it once, on the main queue; `teardownProcess`
  is idempotent.
- In `connectUsing`, both `host.onDisconnect` and `port.disconnectHandler`
  call one `releaseHost` closure whose token is *removal from the registry*.
  Only the first removal succeeds, so a host is released from the keep-alive
  once, and a late release from a host whose context has since been reloaded
  cannot disarm a newer host under the same key.
- Paths that end a whole context take the registry entry away first
  (`tearDownNativeConnections`), then disconnect, so every callback that
  follows finds nothing left to release.
- After `disconnect()`, or once `onDisconnect` has run, the owner hears
  nothing more: a message the read loop read but had not yet delivered is
  dropped. Each `connect()` makes its own `Connection` (open flag and join
  state behind `Mutex`es), so a read loop or termination handler from an
  earlier connection cannot touch a later one.

## The host going away

Two signals say a host has gone, and nothing orders them: the read loop
reading the end of the host's stdout, and `Process.terminationHandler`
reporting the exit on a thread of its own. Until TASK-232 the termination
handler reported the disconnect itself, so a host that wrote its reply and
exited at once could have the disconnect reach the owner before the reply
the loop was still reading: `sendNativeMessage` settled with "Native host
has exited." and a port got `onDisconnect` before `onMessage`. With a 256 KB
reply that happened in 6 of 25 runs at the host level, and in 13 of 15
`sendNativeMessage` calls and 7 of 8 ports end to end.[^task-232]

The end of stream is what follows the last message, so the disconnect is now
the join of the two (`NativeHostEnding`, pure, behind the connection's
mutex):[^ending]

| First | Then | Reported |
|---|---|---|
| End of stream | Exit within `exitStatusWait` (0.5 s) | The exit status: `nil` for 0, else "Native host exited with status N" |
| End of stream | Nothing: stdout closed, process alive | `nil` after 0.5 s; the teardown then terminates the process |
| Exit | End of stream within `endOfStreamWait` (5 s) | The exit status |
| Exit | Nothing: a process the host started holds its stdout | The exit status after 5 s, logged as `NM END … after waiting` |
| A failed write to stdin | End of stream within 5 s (or nothing) | The write failure |
| A framing error | | That reason, at once; later signals are ignored |

The report is a main-actor task, as message deliveries are, and the join
reports only after the loop has made its delivery tasks, so every message
the loop read comes first. The 5 s wait is long so that a read loop starved
on a loaded machine still gets to the reply. A failed write is joined like
an exit (the host may have written a reply before it went), and it records
its reason in the join before tearing the process down, so the exit the
teardown causes cannot replace it. A framing error reports at once: the
loop has stopped reading and has already handed on everything it read.
Each connection's read loop runs on a queue of its own, so a loop still
blocked on an earlier connection's pipe cannot hold up the next one. The disconnect reason
itself is only logged and tested: both owners ignore it (the one-shot path
answers with Chrome's "Native host has exited.").

### The owner letting go

Nothing but its owners hold a `NativeMessagingHost`: the read loop, the
termination handler and the end-of-stream waits all refer to it weakly, and
the loop captures only the stdout handle, the `Connection` and the host
name. Releasing the last reference runs the `isolated deinit`, which calls
`disconnect()`: the process is terminated, the blocked read returns the end
of stream, and the loop exits, letting go of the handle. Until TASK-233 the
loop ran `while let self`, holding the host strongly across the blocking
`readData`, so a host that was alive and silent kept its object, and its
process, alive after the owner let go: a one-shot host that answered and then
stayed running outlived the request that removed its `activeMessagingHosts`
entry.[^task-233] The two owners rely on this differently. The one-shot path
lets go once the request settles, which now ends the process. The port path
keeps its host in `liveNativeHosts` and in the port's handlers for as long as
the port is open, so the keep-alive's host is never released early; the port
disconnecting, or a context teardown, calls `disconnect()` explicitly.

### Ending the process

The teardown closes the host's stdin and sends SIGTERM. A host still
running `Termination.grace` (2 s) later is sent SIGKILL; before TASK-241 a
host that ignored or blocked SIGTERM stayed running as a child of Detour
after its port or request was gone.[^task-241] The wait runs on a global
queue and holds the `Process`, never the host, so a teardown from `deinit`
still escalates and the host is not kept alive. It checks
`Process.isRunning` first: that goes false when Foundation reaps the child,
and until the reap the pid is a zombie's and cannot be reused, so a host
that exited on SIGTERM (1Password's does) is sent nothing more. A host that
had already exited when the teardown ran gets no signal at all.

Chrome does it differently on macOS: `~NativeMessageProcessHost` closes the
pipes and posts `base::EnsureProcessTerminated`, which waits up to
`kWaitBeforeKillSeconds = 2` for the exit (kqueue `NOTE_EXIT`) and then
sends SIGKILL; it sends no SIGTERM. The Linux path (`kill_posix.cc`,
`BackgroundReaper`) also waits 2 s and then kills.[^chromium-kill] Detour
keeps its SIGTERM first, so a host that exits on it is unaffected.

### The host's process tree

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

### Quitting

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
that outlives Detour. The tests pass `refusingNewHosts: false`, since the
flag cannot be cleared.
`terminateAllSpawnedHosts(within:)` sends SIGTERM to each running one's
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
- **SIGTERM to Detour**: `installSIGTERMHandler()` (the first thing in
  `applicationDidFinishLaunching`) sets SIGTERM to `SIG_IGN` and handles it
  with a `DispatchSource` on a global queue. That works even when the main
  thread is busy or hung. The handler ends the hosts in the same way, then
  cancels the source (it sees the re-sent signal too, whatever the
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

# Logging

Native hosts exchange secrets. `NativeMessagingHost` used to log 500-byte
payload previews at a persisted level, which put a 1Password account's key
material into the unified log.[^plan] The rules since TASK-1:

| What | Level | Content |
|---|---|---|
| `NM SEND`, `NM RECV`, `NM EOF`, `NM EXIT`, `NM WRITE FAILED`, `NM KILL` (prefix `[1PW-DEBUG]`, category `native-messaging`) | notice (persisted) | Host name and byte count only |
| `Connected to native host …` | info (not persisted) | Host name, binary path, extension id |
| Host stderr | debug, `.private` | Host-controlled text; never persisted |
| `connectNative from <ext> in profile <name> to '<host>': connected / refused: … / failed: …` (category `extension-manager`) | notice for a connect, error otherwise | Rate-limited |

The last row exists because the TASK-90 incident could not be read out of
`log show` afterwards: every line on the connect path was info level or
absent, and a failed `host.connect()` logged nothing at all.[^task-90]
`NativeConnectLogLimiter` logs the first 5 attempts per 60 s per
(profile, extension, host) in full and summarises the rest by outcome on the
next logged attempt, so a reconnect loop cannot evict the history it is the
evidence for. There is no level between notice and error to use:
`Logger.warning` and `Logger.error` both persist as error.

# Gotchas

- **A page's own `port.disconnect()` fires its own `onDisconnect`.** Chrome
  fires `onDisconnect` only at the other end. Shipped WebKit (macOS 26.7)
  runs the caller's listeners synchronously inside the `disconnect()` call,
  for `connectNative` ports and `runtime.connect` ports alike, from a page
  and from a worker, with no `port.error`. Nothing of Detour's is involved:
  the call never leaves the web process before the listeners run, and
  Detour's `disconnectHandler` (release the host, `host.disconnect()`) calls
  nothing back on the port. The cause is `WebExtensionAPIPort::disconnect()`
  calling `fireDisconnectEventIfNeeded()`; WebKit fixed it upstream on
  2026-10-30 (325256@main), not yet in a shipped build.[^webkit-325256] An
  extension that reconnects in `onDisconnect` therefore reconnects after its
  own deliberate disconnect too, starting a fresh host. No workaround:
  `connectNative` cannot be wrapped (see
  [chrome.runtime patching](./chrome-runtime-patching.md)). The
  keep-alive's port watch does not depend on the self-fired event: it wraps
  `disconnect` on the ports it watches (TASK-263, see
  [Native port keep-alive](./native-port-keep-alive.md#the-anchor-task-142)).
  `testWebKitFiresAPagesOwnOnDisconnectInsideConnectNativeDisconnect` and
  `testWebKitFiresTheCallersOwnOnDisconnectInsideRuntimePortDisconnect` pin
  it, so a WebKit that ships the fix fails them; flip them then.[^task-256]
- **A host's exit reason never reaches the extension.** WebKit does not
  deliver a native port's disconnect error to an established port — neither
  `port.error` nor `runtime.lastError` (measured 2026-09-13).[^manager] The
  error only arrives when the *connect* is refused. Detour signals reasons
  with a message sent just before the disconnect where it matters
  (`keepalive-superseded`).
- **WebKit drops native ports silently on a context unload.** No
  `disconnectHandler` fires; see
  [service worker unload rules](../platform/service-worker-unload-rules.md).
  The supersede teardown in the [keep-alive](./native-port-keep-alive.md)
  exists for this.
- **What a message may be differs by entry point, as in Chrome.** Chrome's
  `runtime.json` declares `sendNativeMessage`'s message `type: object`, and
  its argument check (`argument_spec.cc`, `ArgumentType::OBJECT`) refuses an
  array, a function, null and every primitive before anything is sent;
  `Port.postMessage` is `type: any`.[^chromium-runtime] Detour matches: a
  one-shot message that is not a dictionary is refused in the delegate with
  "The 'message' value is invalid, because an object is expected" before any
  host object exists (until TASK-242 it started the host, never wrote to it,
  and left the request unanswered and the process running). A port, and a
  host's reply on either path, carries any JSON value (`sendMessage(Any)`,
  `onMessage(Any)`, fragments allowed). `jsonBody(for:)` checks
  `isValidJSONObject([value])` first, because `data(withJSONObject:)` raises
  an uncatchable Objective-C exception for NaN, infinity or a non-JSON type.
  The `sendNativeMessage` signature cannot be enforced in JS: WebKit
  re-materializes the runtime functions, so the refusal is a rejection or
  `lastError`, not Chrome's synchronous TypeError.[^task-242]
- **WebKit refuses a JS null itself.** Its `[Serialization=JSON] any`
  bindings throw "The 'message' value is invalid, because an object is
  expected" for `port.postMessage(null)` and for
  `sendNativeMessage(host, null, callback)`, before Detour is asked.
  `sendNativeMessage(host, null)` in the promise form reaches the delegate
  with the host name as the message (WebKit shifts its optional arguments)
  and is refused there. Every other value arrives as the JSON-parsed
  Foundation object (`NSString`, `NSNumber`, `__NSCFBoolean`, `NSArray`),
  measured 2026-11-03.
- **`DETOUR_NATIVE_MESSAGING_HOSTS_DIR` is compiled out of Release.** It is
  read on every lookup, not once, so a test can point it at a fixture
  in-process.
- **A write to a dead host must not kill the app.** `Detour/App/main.swift`
  ignores `SIGPIPE` process-wide and the stdin descriptor has
  `F_SETNOSIGPIPE`, so the failure surfaces as EPIPE in the writer, which
  ends the connection (see [writing to the host](#writing-to-the-host)).
- **A failed `Process.run()` closes half the pipes.** Measured on macOS
  26: when the spawn fails (EACCES on a directory), Foundation has already
  closed the child's ends (stdin's read end, stdout's and stderr's write
  ends) through their `FileHandle`s; the parent's three stay open. Closing
  all six handles afterwards is safe: a second `close()` on a handle is a
  no-op and does not close a descriptor number reused in between.[^task-275]
- **Host stderr at EOF.** Foundation keeps calling a `readabilityHandler`
  with empty data after EOF; the handler clears itself, or a host that closes
  stderr and stays alive spins a core.
- **One-shot hosts are not swept with a context.** `activeMessagingHosts`
  records no controller, so `tearDownNativeConnections` leaves them to end
  with their reply or exit.
- **A host that exits leaving a child holding its stdout** is reported gone
  5 s after the exit, and the read loop stays blocked on the pipe until the
  child exits or writes; what it reads then is dropped. Chrome instead keeps
  such a connection open until the end of stream. A wrapper script that
  backgrounds the real host and exits therefore does not work in Detour.
- **The spawning process is what a host can verify.** A host may refuse a
  build it does not trust even though Detour's side logs a successful
  connect; see the trust section of
  [1Password integration](./1password-integration.md).

# Tests

- `NativeMessagingEnforcementTests`: the production path end to end — a real
  `Profile`, WebKit's own `connectNative` / `sendNativeMessage` from an
  extension page, and a fake host found through the Debug override. Covers
  refusal without spawning, live denial and re-grant, isolation between
  extensions, the unlisted-context refusal, and that the built-in hosts keep
  working under a denial.
- `FakeNativeMessagingHost` (in `ExtensionTestSupport.swift`) is a shell
  script that `exec`s `sleep <unique token>`: a real process that stays
  connected and silent. Whether a host was spawned is read off the process
  table by that token. Because of the `exec`, `pgrep` for the script name
  finds nothing. `.echoesCounted` is an echoing host the token can see:
  `exec cat - '<dir>/sleep <token>'` (an empty file, read after stdin).
- Messages that are not objects (TASK-242), from an extension page
  (`NativeMessagingEnforcementTests`) and a service worker
  (`ExtensionPolyfillProfileWiringTests`): a string, a number, an array and
  null from `sendNativeMessage`'s promise and callback forms are refused with
  no process started (a `.silent` host, so a mistaken spawn would be
  counted); a port round-trips a string, a number, an array and a boolean
  through `.echoesCounted` and the host is gone after the disconnect; a
  one-shot host's string or array reply settles the request; the framing
  suite pins the fragments' JSON text and the refusal of NaN, infinity, a
  `Date` and a non-string key.
- `NativeConnectLogLimiterTests`: the limiter with an injected clock.
- `NativeMessagingFramingTests`: the wire bytes of the prefix, and the read
  loop against a real host process — a prefix that claims more than the
  host sends, frames before a truncated one, a zero or over-1 MB prefix, a
  short prefix, and a round trip through an echoing host (a 200 KB body
  spans several pipe reads). `FakeNativeMessagingHost`'s `Behavior` gives
  the host fixed stdout bytes (then closes stdout and sleeps, so its exit
  cannot race the read loop) or `exec cat`.[^framing-tests]
- `NativeMessagingHostLifecycleTests`: how a connection ends, against hosts
  that read one byte of request, answer and then exit (`answersThenExits`),
  exit leaving a `sleep` child on stdout (`answersThenExitsLeavingStdoutOpen`)
  or stay alive (`answersThenStaysAlive`). The reply-then-exit leg runs 50
  times with a 256 KB reply, the size that lost the race before the fix (a
  small reply never did in 25 runs); `endTiming` shortens the waits. The
  join's transitions are tested without a process.[^lifecycle-tests] A host
  that ignores SIGTERM (`silentIgnoringSIGTERM`, `trap '' TERM` before
  `exec sleep`) is still running partway through a shortened
  `Termination.grace` and killed after it, by `disconnect()` and by release;
  `Termination.onKill` shows a `.silent` host (which exits on SIGTERM) and a
  host that already exited are never sent SIGKILL.
  `NativeMessagingEnforcementTests` repeats the reply-then-exit host through
  WebKit's `sendNativeMessage` (15 calls) and `connectNative` (8 ports).
  Releasing a live, silent host ends its process, at the host level and end
  to end through a one-shot `sendNativeMessage`, while a `connectNative`
  port's host that stays alive keeps running until the page disconnects
  (TASK-233).
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
- Writing (TASK-265), in `NativeMessagingHostLifecycleTests`: 4 MB to a
  `.silent` host (which never reads stdin) returns at once with the bytes
  still queued and the host alive, and `disconnect()` ends it; the quit
  sweep with 4 MB queued for a host ignoring SIGTERM returns after its
  bounded wait having killed it; forty messages come back from an echoing
  host in order; a body one byte over the (lowered) limit is refused and
  never written while the connection stays usable; a third 200 KB frame
  behind a non-reading host is refused once the bound is reached; a
  `.closesStdin` host makes the write fail with EPIPE, ending the connection
  with that reason, with SIGPIPE at its default. Each leg with a non-reading
  host arms a 10 s SIGKILL of it, so a regression that blocks the main actor
  fails rather than hangs. `NativeMessagingEnforcementTests` posts 6 MB on a
  `connectNative` port to a `.silent` host from an extension page (the port
  stays open, the page keeps answering, the host ends on disconnect), and
  shows a too-large message and a full queue each disconnect the page's
  port and end the host; `ExtensionPolyfillProfileWiringTests` repeats both
  from a service worker.
- A failed connect (TASK-275), in `NativeMessagingHostLifecycleTests`: 50
  connects whose `run()` fails and 50 refused for quitting (a Debug-only
  `setRefusingNewHostsForTesting` seam, reset in tearDown), with every host
  kept alive, leave the test process's open descriptor count (`fcntl` over
  `getdtablesize()`) within 10 of where it was; before the fix it grew by
  149 and 350. A host refused once connects and echoes once the refusal is
  lifted.
- Framing helpers (`encodeMessage`, `decodeMessage`) are also covered in
  `ExtensionIDDerivationTests`. The log line *text* is not asserted anywhere.

# Related

- [Native port keep-alive](./native-port-keep-alive.md) — what a connected host does to the worker's lifetime
- [WebSocket relay](./websocket-relay.md) — the other built-in port host
- [Permissions](./permissions.md) — the saved `nativeMessaging` decision
- [Console bridge](./console-bridge.md) — the same log-hygiene rules for extension console text
- [Reading runtime logs](../playbooks/reading-runtime-logs.md) — predicates for these categories

[^plan]: 1Password integration plan (reference data, security note, TASK-25 and TASK-44 decisions)
[^manager]: ExtensionManager.swift (nativeHostAccess, sendMessage and connectUsing delegate methods)
[^task-90]: 1Password reconnect loop investigation (connect logging, unlisted-context refusal)
[^task-231-8]: Memory safety audit of raw-pointer code and untrusted-byte parsing
[^framing-tests]: NativeMessagingFramingTests.swift
[^task-232]: TASK-232
[^task-233]: A quiet host process outlives the owner that released it
[^ending]: NativeHostEnding.swift (the join of end of stream and process exit)
[^lifecycle-tests]: NativeMessagingHostLifecycleTests.swift
[^task-241]: Native messaging: a host that ignores SIGTERM is never killed
[^task-243]: Native messaging: quitting Detour may leave live port hosts running
[^task-274]: Native messaging: a wrapper-script host that does not exec leaves its real host running after quit
[^chromium-launch-posix]: Chromium launch_context_posix.cc (LaunchNativeProcess sets no new_process_group)
[^xnu-pids]: XNU kern_fork.c (pid allocation skips live pids, process groups and sessions) and kern_sig.c (killpg1 skips zombies)
[^chromium-kill]: Chromium base/process/kill_mac.cc (EnsureProcessTerminated, kWaitBeforeKillSeconds = 2)
[^chromium-runtime]: Chromium extensions/common/api/runtime.json and extensions/renderer/bindings/argument_spec.cc
[^task-242]: A one-shot sendNativeMessage with a non-object message leaks the host and never settles
[^task-256]: Extensions: a port's onDisconnect fires in the context that called port.disconnect()
[^webkit-325256]: WebKit 325256@main: Port.disconnect() fires onDisconnect on the port that called it
[^task-266]: Native messaging: a host manifest without allowed_origins admits every extension
[^task-265]: Native messaging: writing to a host that stops reading stdin blocks the main thread and freezes the app
[^chromium-limits]: Chromium native_message_process_host.cc (kMaximumNativeMessageSize, the unbounded write queue, kHostInputOutputError) and extensions/renderer/api/messaging/messaging_util.cc (the 64 MiB kMaxMessageBytes)
[^chromium-launcher]: Chromium native_process_launcher.cc and native_messaging_host_manifest.cc (manifest checks, their order and result codes)
[^manifest-tests]: NativeHostManifestValidationTests.swift
[^task-275]: Native messaging: a failed connect leaves the host's pipes and stderr handler behind
