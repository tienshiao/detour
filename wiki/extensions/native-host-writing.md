---
type: Component
title: Writing to a native host
description: How Detour sends messages to a native messaging host without ever blocking — the per-connection DispatchIO stdin writer, the size and queue limits and why they are Chrome's, what a failed write does, and what the extension sees when a message cannot be sent.
tags: [extensions, native-messaging, concurrency]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:42:31Z }
sources:
  - id: host
    resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
    title: NativeMessagingHost.swift (StdinWriter, OutgoingLimits, sendMessage)
  - id: manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (the connectUsing port's messageHandler)
  - id: main
    resource: ../../Detour/App/main.swift
    title: main.swift (SIGPIPE ignored process-wide)
  - id: task-265
    resource: backlog:TASK-265
    title: "Native messaging: writing to a host that stops reading stdin blocks the main thread and freezes the app"
  - id: chromium-limits
    resource: https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/native_message_process_host.cc
    title: Chromium native_message_process_host.cc (kMaximumNativeMessageSize, the unbounded write queue, kHostInputOutputError) and extensions/renderer/api/messaging/messaging_util.cc (the 64 MiB kMaxMessageBytes)
  - id: lifecycle-tests
    resource: ../../DetourTests/NativeMessagingHostLifecycleTests.swift
    title: NativeMessagingHostLifecycleTests.swift
  - id: enforcement-tests
    resource: ../../DetourTests/NativeMessagingEnforcementTests.swift
    title: NativeMessagingEnforcementTests.swift
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests.swift
---

`sendMessage` on a [native messaging](./native-messaging.md) host encodes the
message and queues the frame; it never writes in place. A host that stops
reading its stdin can therefore never block the main thread or a quit; what
it costs Detour is bounded to one largest message.

# Role

Until TASK-265 `sendMessage` wrote with a blocking `FileHandle.write` on the
main actor, so a host that stopped reading its stdin froze the app once the
pipe's 64 KB buffer was full, and a normal quit hung with it
(`applicationWillTerminate` could not run; only the SIGTERM path still ended
hosts).[^task-265]

# How it works

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
  How the teardown and the quit end the process is on
  [ending native host processes](./native-host-termination.md).
- **A failed write** (EPIPE: the host closed stdin or exited) is seen on a
  global queue. The first one is logged (`NM WRITE FAILED`, errno only),
  recorded in the join as `.writeFailed` before anything else, and the
  teardown then runs on the main actor; the owner hears it through
  `onDisconnect` like any end (see
  [the host going away](./native-host-lifecycle.md#the-host-going-away)).
  ECANCELED from the teardown's own stop is
  ignored. The descriptor has `F_SETNOSIGPIPE`, and `main.swift` ignores
  SIGPIPE process-wide; the test of a host that closed its stdin runs with
  SIGPIPE back at its default, so a write that raised it would kill the
  test host.

## Limits

The limits (`NativeMessagingHost.OutgoingLimits.standard`; a static that
tests lower so no leg needs 64 MiB of JSON):[^chromium-limits]

| Limit | Value | Why | When exceeded |
|---|---|---|---|
| One message to a host | 64 MiB of JSON body | Chrome's: its renderer refuses any extension message over `kMaxMessageBytes` (64 MiB, "IPC messages will fail at > 128 MiB") with "Message exceeded maximum allowed size of 64MiB.", and the native messaging docs give 64 MiB as the limit to a host. It was 1 MB, a copy of the host-to-browser limit, which refused messages Chrome sends | `messageTooLarge`, Chrome's text |
| Queued and not yet written, per host | 64 MiB + 4 (one maximum frame) | A host that reads at all drains a pipe at memory speed, so bytes only pile up behind one that has stopped. Chrome's queue has no bound; this keeps what a wedged host can make Detour hold to one largest message. A frame counts until it is completely written | `sendQueueFull`, Chrome's `kHostInputOutputError` text "Error when communicating with the native messaging host." |
| One message from a host | 1 MB | Chrome's `kMaximumNativeMessageSize`, which protects the browser from a misbehaving host | The connection ends ("Invalid message length: N") |

## When a message cannot be sent

What the extension sees when a port message cannot be sent (too large, not
encodable, queue full, host already gone): the port's `messageHandler`
logs it (`extension-manager`, error level, with `logDetail`), releases the
host from the keep-alive, disconnects the host and disconnects the port
with the error. The extension gets `onDisconnect`; WebKit does not hand an
established port's error over (see
[WebKit extension ports](../platform/webkit-extension-ports.md#a-disconnect-error-never-reaches-an-established-port)),
so the text only reaches the
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

# Gotchas

- **A write to a dead host must not kill the app.** `Detour/App/main.swift`
  ignores `SIGPIPE` process-wide and the stdin descriptor has
  `F_SETNOSIGPIPE`, so the failure surfaces as EPIPE in the writer, which
  ends the connection (see [the writer](#how-it-works) above).

# Tests

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

# Related

- [Native messaging](./native-messaging.md) — spawn, framing, the access gate and logging
- [Native host connection lifecycle](./native-host-lifecycle.md) — how a failed write is joined with the host's other end signals
- [Ending native host processes](./native-host-termination.md) — the teardown and quit paths that never wait on a write
- [App shell](../architecture/app-shell.md) — `main.swift`, where SIGPIPE is ignored

[^task-265]: Native messaging: writing to a host that stops reading stdin blocks the main thread and freezes the app
[^chromium-limits]: Chromium native_message_process_host.cc (kMaximumNativeMessageSize, the unbounded write queue, kHostInputOutputError) and extensions/renderer/api/messaging/messaging_util.cc (the 64 MiB kMaxMessageBytes)
