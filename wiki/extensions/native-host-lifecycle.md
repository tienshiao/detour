---
type: Component
title: Native host connection lifecycle
description: How a native messaging connection ends exactly once — the four directions an end comes from, the registry-removal token, the join of end of stream and process exit that keeps a host's last reply ahead of its disconnect, and why releasing a host object ends its process.
tags: [extensions, native-messaging, concurrency]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:42:31Z }
sources:
  - id: host
    resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
    title: NativeMessagingHost.swift (disconnect, connectionEnded, the read loop, isolated deinit)
  - id: ending
    resource: ../../Detour/Extensions/Runtime/NativeHostEnding.swift
    title: NativeHostEnding.swift (the join of end of stream and process exit)
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (connectUsing's releaseHost, tearDownNativeConnections, activeMessagingHosts)
  - id: lifecycle-tests
    resource: ../../DetourTests/NativeMessagingHostLifecycleTests.swift
    title: NativeMessagingHostLifecycleTests.swift
  - id: enforcement-tests
    resource: ../../DetourTests/NativeMessagingEnforcementTests.swift
    title: NativeMessagingEnforcementTests.swift
  - id: task-232
    resource: backlog:TASK-232
    title: A host that writes its reply and exits at once can have the exit handled before the reply
  - id: task-233
    resource: backlog:TASK-233
    title: A quiet host process outlives the owner that released it
---

A [native messaging](./native-messaging.md) connection can end in several
ways at once, and each of them must reach the owner exactly once and only
after every message the host sent. This page is about the connection; how
the host *process* is then ended (signals, process groups, quitting) is on
[ending native host processes](./native-host-termination.md).

# Teardown, exactly once

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

# The host going away

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
an exit (the host may have written a reply before it went; see
[writing to a native host](./native-host-writing.md)), and it records
its reason in the join before tearing the process down, so the exit the
teardown causes cannot replace it. A framing error reports at once: the
loop has stopped reading and has already handed on everything it read.
Each connection's read loop runs on a queue of its own, so a loop still
blocked on an earlier connection's pipe cannot hold up the next one. The disconnect reason
itself is only logged and tested: both owners ignore it (the one-shot path
answers with Chrome's "Native host has exited.").

# The owner letting go

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

# Gotchas

- **One-shot hosts are not swept with a context.** `activeMessagingHosts`
  records no controller, so `tearDownNativeConnections` leaves them to end
  with their reply or exit.
- **A host that exits leaving a child holding its stdout** is reported gone
  5 s after the exit, and the read loop stays blocked on the pipe until the
  child exits or writes; what it reads then is dropped. Chrome instead keeps
  such a connection open until the end of stream. A wrapper script that
  backgrounds the real host and exits therefore does not work in Detour.

# Tests

- `NativeMessagingHostLifecycleTests`: how a connection ends, against hosts
  that read one byte of request, answer and then exit (`answersThenExits`),
  exit leaving a `sleep` child on stdout (`answersThenExitsLeavingStdoutOpen`)
  or stay alive (`answersThenStaysAlive`). The reply-then-exit leg runs 50
  times with a 256 KB reply, the size that lost the race before the fix (a
  small reply never did in 25 runs); `endTiming` shortens the waits. The
  join's transitions are tested without a process.[^lifecycle-tests] The
  SIGTERM-ignoring host's legs are on
  [ending native host processes](./native-host-termination.md#tests).
  `NativeMessagingEnforcementTests` repeats the reply-then-exit host through
  WebKit's `sendNativeMessage` (15 calls) and `connectNative` (8 ports).
  Releasing a live, silent host ends its process, at the host level and end
  to end through a one-shot `sendNativeMessage`, while a `connectNative`
  port's host that stays alive keeps running until the page disconnects
  (TASK-233).

# Related

- [Native messaging](./native-messaging.md) — spawn, framing, the two entry points and the access gate
- [Ending native host processes](./native-host-termination.md) — what `teardownProcess` does to the process and its group
- [Writing to a native host](./native-host-writing.md) — the failed write that joins like an exit
- [Native port keep-alive](./native-port-keep-alive.md) — what `releaseHost` releases a host from

[^task-232]: TASK-232
[^ending]: NativeHostEnding.swift (the join of end of stream and process exit)
[^lifecycle-tests]: NativeMessagingHostLifecycleTests.swift
[^task-233]: A quiet host process outlives the owner that released it
