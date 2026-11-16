---
type: Component
title: Native messaging
description: How Detour runs Chrome native messaging hosts for extensions — host discovery and spawn, framing, the access gate at dispatch, the one-shot and port paths, and what may and may not be logged, with links to the pages on writing to a host, how a connection ends and how host processes are ended.
resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
tags: [extensions, native-messaging, security, logging]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:59:43Z }
sources:
  - id: lifecycle-tests
    resource: ../../DetourTests/NativeMessagingHostLifecycleTests.swift
    title: NativeMessagingHostLifecycleTests.swift (the failed-connect legs)
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
  - id: chromium-launcher
    resource: https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/native_process_launcher.cc
    title: Chromium native_process_launcher.cc and native_messaging_host_manifest.cc (manifest checks, their order and result codes)
  - id: manifest-tests
    resource: ../../DetourTests/NativeHostManifestValidationTests.swift
    title: NativeHostManifestValidationTests.swift
  - id: task-275
    resource: backlog:TASK-275
    title: "Native messaging: a failed connect leaves the host's pipes and stderr handler behind"
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
  - id: task-281
    resource: backlog:TASK-281
    title: "Native messaging: a broken host manifest in Chrome's or Chromium's folder hides a valid one in Detour's own folder"
---

# Role

`NativeMessagingHost` runs **one** native messaging host process and speaks
Chrome's stdio protocol to it. `ExtensionManager`, as the
`WKWebExtensionControllerDelegate` of every profile's controller, decides
whether a host may be started, owns the running hosts, and reports their
coming and going to the [keep-alive](./native-port-keep-alive.md). 1Password's
desktop-app channel is the main user (see
[1Password integration](./1password-integration.md)).

Three parts of the host have pages of their own (see [Pages](#pages)):
[writing to a host](./native-host-writing.md), how a
[connection ends](./native-host-lifecycle.md), and
[ending host processes](./native-host-termination.md). WebKit's side of
the ports is on [WebKit extension ports](../platform/webkit-extension-ports.md).

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

   **The order is to change (TASK-281).** Chrome reads only its own folder,
   so there one vendor's broken file never hides another's; in Detour a
   stale or broken manifest in Chrome's folder hides a valid one installed
   in Detour's own. The user decided on 2026-11-15 that Detour's own folder
   will be searched first, then Chrome's and Chromium's, then `/Library`,
   with the first file found still deciding: a host installed for Detour
   always wins, and Chrome's folder stays the fallback that lets hosts such
   as 1Password work without installing for Detour (every other Chromium
   browser reads only its own folder). Planned in TASK-281; the table above
   is today's order.[^task-281]
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
   is [quitting](./native-host-termination.md#quitting), or `run()` fails, e.g. on a `path` that is a
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

## Framing

Framing is a 4-byte little-endian length followed by UTF-8 JSON. A host
may send at most `maxIncomingMessageSize` (1 MB); Detour sends a host at
most 64 MiB (see [writing to a native host](./native-host-writing.md)). The read loop runs on a
private serial queue and delivers to the main queue. It reads the prefix
(`Data.littleEndianUInt32()`, byte by byte, no raw-pointer load), refuses 0
or anything above the cap ("Invalid message length: N"), then reads that
many bytes; a short read (the host closed stdout early) disconnects with
"Incomplete message read", and fewer than four prefix bytes is the end of
stream (see [the host going away](./native-host-lifecycle.md#the-host-going-away)). Frames read before
a bad one are delivered first.
See [Strict memory safety](../platform/strict-memory-safety.md).[^task-231-8]

## Two entry points

| Extension call | Delegate method | Lifetime |
|---|---|---|
| `runtime.sendNativeMessage` | `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)` | A `OneShotNativeRequest` in `activeMessagingHosts`. The first reply, or the host exiting ("Native host has exited."), settles the promise once. Never counts toward the keep-alive. |
| `runtime.connectNative` | `webExtensionController(_:connectUsing:for:completionHandler:)` | A `LiveNativeHost` (host + WebKit port) in `liveNativeHosts`, keyed by (controller, extension). Counts toward the keep-alive. |

Both paths also carry Detour's own traffic: `detourPolyfill` (the
[polyfill layer](./polyfill-layer.md)'s worker transport and the keep-alive
port), `detourKeepAliveAnchor` (the keep-alive's
[anchor port](./native-port-keep-alive.md#the-anchor-task-142)) and
`detourWebSocketRelay` (the [WebSocket relay](./websocket-relay.md)).
Those names never spawn a process. The anchor and the relay are port-only:
a one-shot `sendNativeMessage` to either is refused ("… is a port-only
host").

## The access gate

`nativeMessaging` is granted on every context unconditionally in
`Profile.loadExtensionContext`, because the polyfill bridge in a service
worker *is* `sendNativeMessage`. The real gate is therefore at dispatch:
`ExtensionManager.nativeHostAccess(hostName:manifestPermissions:savedDecision:)`.

| Result | When | Effect |
|---|---|---|
| `.polyfillHost`, `.keepAliveAnchorHost`, `.webSocketRelayHost` | Host name is one of Detour's own | Accepted without the manifest permission; the saved decision is never read |
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

# Pages

| Page | What it covers |
|---|---|
| [Writing to a native host](./native-host-writing.md) | The non-blocking `DispatchIO` stdin writer, the 64 MiB message and queue limits, a failed write, what the extension sees when a message cannot be sent |
| [Native host connection lifecycle](./native-host-lifecycle.md) | Ending a connection exactly once, the join of end of stream and exit that keeps the last reply ahead of the disconnect, the owner letting go |
| [Ending native host processes](./native-host-termination.md) | SIGTERM then SIGKILL, the host's process group, the spawned-host registry, quitting and SIGTERM to Detour |
| [WebKit extension ports](../platform/webkit-extension-ports.md) | WebKit's port bookkeeping: wiped port entries, the self-fired `onDisconnect`, silent drops on a context unload, undelivered disconnect errors |

# Logging

Native hosts exchange secrets. `NativeMessagingHost` used to log 500-byte
payload previews at a persisted level, which put a 1Password account's key
material into the unified log.[^plan] The rules since TASK-1:

| What | Level | Content |
|---|---|---|
| `NM SEND`, `NM RECV`, `NM EOF` (prefix `[1PW-DEBUG]`, category `native-messaging`) | notice (persisted) | Host name and byte count only |
| `NM EXIT`, `NM WRITE FAILED`, `NM KILL`, `NM GROUP`, `NM END` (same prefix and category) | notice (persisted) | Host name and an exit status and reason, an errno or a fixed sentence; never payload |
| `NM QUIT`, `Signal N: ending native hosts before exiting` (no prefix) | notice (persisted) | Host counts |
| `NM SEND REFUSED` (warning), the connect refusals (`Rejecting native host name …`, `Refusing native host …`, `Origin validation failed …`, `Native host binary not found …`), `NM RECV … failed to parse as JSON`, `NM KILL … failed`, `NM TERM … failed` | error (a warning persists as error) | Host name, extension id, manifest directory or binary path, byte counts, errno; never payload |
| `Connected to native host …`, `Disconnecting native host …` | info (not persisted) | Host name, binary path, extension id |
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

- **WebKit's port bookkeeping.** A page's own `port.disconnect()` fires its
  own `onDisconnect`, a host's exit reason never reaches an established
  port, and a context unload drops native ports without a callback: see
  [WebKit extension ports](../platform/webkit-extension-ports.md).
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
- **A write to a dead host must not kill the app**: see
  [writing to a native host](./native-host-writing.md#gotchas).
- **A failed `Process.run()` closes half the pipes.** Measured on macOS
  26: when the spawn fails (EACCES on a directory), Foundation has already
  closed the child's ends (stdin's read end, stdout's and stderr's write
  ends) through their `FileHandle`s; the parent's three stay open. Closing
  all six handles afterwards is safe: a second `close()` on a handle is a
  no-op and does not close a descriptor number reused in between.[^task-275]
- **Host stderr at EOF.** Foundation keeps calling a `readabilityHandler`
  with empty data after EOF; the handler clears itself, or a host that closes
  stderr and stays alive spins a core.
- **One-shot hosts are not swept with a context**, and **a host that exits
  leaving a child holding its stdout** is reported gone after 5 s: see
  [the connection lifecycle](./native-host-lifecycle.md#gotchas).
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
- A failed connect (TASK-275), in `NativeMessagingHostLifecycleTests`: 50
  connects whose `run()` fails and 50 refused for quitting (a Debug-only
  `setRefusingNewHostsForTesting` seam, reset in tearDown), with every host
  kept alive, leave the test process's open descriptor count (`fcntl` over
  `getdtablesize()`) within 10 of where it was; before the fix it grew by
  149 and 350. A host refused once connects and echoes once the refusal is
  lifted.
- Framing helpers (`encodeMessage`, `decodeMessage`) are also covered in
  `ExtensionIDDerivationTests`. The log line *text* is not asserted anywhere.
- Writing (TASK-265), connection ends (TASK-232, TASK-233), SIGTERM and
  process trees (TASK-241, TASK-274) and quitting (TASK-277) are listed on
  [writing](./native-host-writing.md#tests),
  [the connection lifecycle](./native-host-lifecycle.md#tests) and
  [ending host processes](./native-host-termination.md#tests).

# Related

- [Writing to a native host](./native-host-writing.md) — the stdin writer and its limits
- [Native host connection lifecycle](./native-host-lifecycle.md) — how a connection ends
- [Ending native host processes](./native-host-termination.md) — signals, process groups, quitting
- [WebKit extension ports](../platform/webkit-extension-ports.md) — what WebKit does with the ports these hosts sit behind
- [Native port keep-alive](./native-port-keep-alive.md) — what a connected host does to the worker's lifetime
- [WebSocket relay](./websocket-relay.md) — the other built-in port host
- [Permissions](./permissions.md) — the saved `nativeMessaging` decision
- [Console bridge](./console-bridge.md) — the same log-hygiene rules for extension console text
- [Reading runtime logs](../playbooks/reading-runtime-logs.md) — predicates for these categories

[^plan]: 1Password integration plan (reference data, security note, TASK-25 and TASK-44 decisions)
[^task-90]: 1Password reconnect loop investigation (connect logging, unlisted-context refusal)
[^task-231-8]: Memory safety audit of raw-pointer code and untrusted-byte parsing
[^framing-tests]: NativeMessagingFramingTests.swift
[^chromium-runtime]: Chromium extensions/common/api/runtime.json and extensions/renderer/bindings/argument_spec.cc
[^task-242]: A one-shot sendNativeMessage with a non-object message leaks the host and never settles
[^task-266]: Native messaging: a host manifest without allowed_origins admits every extension
[^chromium-launcher]: Chromium native_process_launcher.cc and native_messaging_host_manifest.cc (manifest checks, their order and result codes)
[^manifest-tests]: NativeHostManifestValidationTests.swift
[^task-275]: Native messaging: a failed connect leaves the host's pipes and stderr handler behind
[^task-281]: Native messaging: a broken host manifest in Chrome's or Chromium's folder hides a valid one in Detour's own folder
