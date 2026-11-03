---
type: Component
title: Native messaging
description: How Detour runs Chrome native messaging hosts for extensions — host discovery, the access gate at dispatch, the one-shot and port paths, exactly-once teardown, and what may and may not be logged.
resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
tags: [extensions, native-messaging, security, logging]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-03T06:10:00Z }
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
   first whose `name` field equals the requested name:

   | Order | Directory |
   |---|---|
   | 0 (Debug builds only) | `$DETOUR_NATIVE_MESSAGING_HOSTS_DIR` |
   | 1 | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts` |
   | 2 | `~/Library/Application Support/Chromium/NativeMessagingHosts` |
   | 3 | `~/Library/Application Support/Detour/NativeMessagingHosts` |
   | 4 | `/Library/Google/Chrome/NativeMessagingHosts` |

3. If the manifest has `allowed_origins`, it must contain
   `chrome-extension://<extension id>/`. This works with manifests written
   for Chrome because Detour derives the same ids Chrome does (see
   [installer and CRX](./installer-and-crx.md)).
4. The manifest's `path` must be an executable file. It is spawned with the
   origin as its one argument, as Chrome does, with pipes for stdin, stdout
   and stderr.

Framing is a 4-byte little-endian length followed by UTF-8 JSON, capped at
`maxMessageSize` (1 MB) **in both directions**. The read loop runs on a
private serial queue and delivers to the main queue. It reads the prefix
(`Data.littleEndianUInt32()`, byte by byte, no raw-pointer load), refuses 0
or anything above the cap ("Invalid message length: N"), then reads that
many bytes; a short read (the host closed stdout early) disconnects with
"Incomplete message read", and fewer than four prefix bytes is the end of
stream (see [the host going away](#the-host-going-away)). Frames read before
a bad one are delivered first.
See [Strict memory safety](../platform/strict-memory-safety.md).[^task-231-8]

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

# Logging

Native hosts exchange secrets. `NativeMessagingHost` used to log 500-byte
payload previews at a persisted level, which put a 1Password account's key
material into the unified log.[^plan] The rules since TASK-1:

| What | Level | Content |
|---|---|---|
| `NM SEND`, `NM RECV`, `NM EOF`, `NM EXIT`, `NM WRITE FAILED` (prefix `[1PW-DEBUG]`, category `native-messaging`) | notice (persisted) | Host name and byte count only |
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
- **Only JSON objects pass.** A message that is not a dictionary is dropped
  on the way out, and a host reply that is not a JSON object is logged as a
  parse failure and not delivered. Chrome allows any JSON value.
- **A manifest without `allowed_origins` is accepted.** The origin check only
  runs when the key is present. The manifest's `type` is decoded but not
  checked.
- **`DETOUR_NATIVE_MESSAGING_HOSTS_DIR` is compiled out of Release.** It is
  read on every lookup, not once, so a test can point it at a fixture
  in-process.
- **A write to a dead host must not kill the app.** `Detour/App/main.swift`
  ignores `SIGPIPE` process-wide, so the failure surfaces as an error in
  `sendMessage`, which tears the host down and throws `notConnected`.
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
  finds nothing.
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
  join's transitions are tested without a process.[^lifecycle-tests]
  `NativeMessagingEnforcementTests` repeats the reply-then-exit host through
  WebKit's `sendNativeMessage` (15 calls) and `connectNative` (8 ports).
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
[^ending]: NativeHostEnding.swift (the join of end of stream and process exit)
[^lifecycle-tests]: NativeMessagingHostLifecycleTests.swift
