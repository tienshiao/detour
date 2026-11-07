---
id: TASK-265
title: >-
  Native messaging: writing to a host that stops reading stdin blocks the main
  thread and freezes the app
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T02:37:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - wiki/extensions/native-messaging.md
priority: medium
type: bug
ordinal: 312000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`NativeMessagingHost.sendMessage` writes the framed message with a blocking `fileHandleForWriting.write(contentsOf:)` (NativeMessagingHost.swift ~290), called on the main actor from both the one-shot path and the port `messageHandler` (ExtensionManager.swift ~3216-3224). A host that is busy or wedged and stops draining stdin, plus an extension posting more than the pipe buffer (~64 KB, up to the 1 MB cap), blocks the main thread inside `write`: the UI freezes, and a normal quit hangs too because `applicationWillTerminate` cannot run (only the SIGTERM path still ends hosts). TASK-242 widened what reaches this path (any JSON value on ports).

Related: the port path uses `try?`, so `messageTooLarge` / `invalidMessage` are dropped without a word to the extension or the log. The browser-to-host cap is 1 MB "in both directions"; Chrome allows much larger browser-to-host messages (64 MiB in current docs). Decide whether to raise it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A host that never reads stdin while the extension posts several MB does not block the main thread: the UI stays responsive and a normal quit completes
- [x] #2 Messages to one host keep their order
- [x] #3 A port message that cannot be sent (too large, not encodable, host gone) is logged and the extension learns of it (port disconnect with an error, or Chrome's behaviour, recorded in the task)
- [x] #4 The browser-to-host size limit is a deliberate value with its reason recorded in the wiki native-messaging page
- [x] #5 Tests cover a non-reading fake host with a large message
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. NativeMessagingHost: replace the blocking stdin write with a per-connection StdinWriter (nonisolated, Sendable; DispatchIO stream channel on the write fd, so nothing blocks a thread; state behind a Mutex). Writes are submitted in order on the one channel (order per host kept). Teardown closes the channel with .stop: pending writes are abandoned (Chrome drops its write queue when it closes the pipes) and the fd is closed in the channel's cleanup handler. The SIGTERM/quit sweep and kill timer are untouched and never wait on the writer.
2. A write error (EPIPE: host closed stdin or exited) is reported once from the writer's queue: logged (NM WRITE FAILED), recorded in the NativeHostEnding join as .writeFailed, and the teardown runs on the main actor, as before. SIGPIPE: ignored process-wide (main.swift) plus F_SETNOSIGPIPE on the write fd.
3. Limits: browser->host message cap raised to Chrome's 64 MiB (renderer kMaxMessageBytes, 'Message exceeded maximum allowed size of 64MiB.'); host->browser stays 1 MB. Queued-unwritten bytes bounded at one maximum frame (64 MiB + 4); a message that would exceed it is refused (sendQueueFull, Chrome's kHostInputOutputError text). Limits injectable via a static for tests.
4. Port path: a message that cannot be sent (too large, not encodable, queue full, host gone) is logged and the port is disconnected with the error (host torn down, keep-alive released). One-shot path unchanged (already rejects the request).
5. Tests: lifecycle (non-reading .silent host + several MB: sendMessage returns at once, host alive, disconnect abandons the writes; quit sweep with pending writes completes; order through an echo host; queue bound; too large; a host that closes stdin -> write failure reported, no SIGPIPE) and enforcement end to end (page posts several MB to a silent host; lowered limits -> port onDisconnect + host gone). Safety SIGKILL timer so a regression fails instead of hanging.
6. Wiki native-messaging page (limits and reasons, writer, quit), log line; review, verify, finalize.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (2026-11-06):
- Writer: per-connection StdinWriter (nonisolated final class, Sendable, counters in a Synchronization.Mutex) owning a DispatchIO stream channel on the stdin fd. No thread ever blocks in a write; stream-channel writes go out in submission order, so per-host order holds. Teardown closes the channel with .stop: queued writes are abandoned (Chrome's ~NativeMessageProcessHost also drops its write_queue_ when it closes the pipes), the fd is closed in the channel's cleanup handler (which holds the FileHandle so the number cannot be reused mid-write). Quit sweep, SIGTERM handler, 2 s kill timer and registry Mutex are unchanged and never wait on a write.
- SIGPIPE: main.swift already ignores it process-wide; the stdin fd now also gets F_SETNOSIGPIPE. A failed write (EPIPE) is reported once from the writer's queue: NM WRITE FAILED logged (errno only), .writeFailed recorded in the join first, teardown hops to the main actor (same as the old in-place failure path).
- Size limit browser->host: raised from 1 MB to Chrome's 64 MiB (renderer messaging_util.cc kMaxMessageBytes, 'Message exceeded maximum allowed size of 64MiB.'; Chrome docs: 'The maximum size of the message sent to the native messaging host is 64 MiB.'). Host->browser stays 1 MB (kMaximumNativeMessageSize). Recorded in wiki/extensions/native-messaging.md.
- Queue bound: at most one maximum frame (64 MiB + 4 bytes) queued and not completely written per host; Chrome's queue is unbounded. A message that would exceed it throws sendQueueFull (Chrome's kHostInputOutputError text 'Error when communicating with the native messaging host.').
- AC3 behaviour: a port message that cannot be sent (too large, not JSON, queue full, host gone) is logged at error level in extension-manager (with logDetail) and the port is disconnected with that error, the host torn down and released from the keep-alive. WebKit does not deliver an established port's disconnect error, so the extension sees onDisconnect only. Chrome instead throws synchronously from postMessage for an oversized message and keeps the port; Detour cannot throw into WebKit's postMessage, and silently dropping would leave a hole in the message stream. A write that fails after queuing ends the port through the existing join -> onDisconnect path. One-shot sendNativeMessage: rejected with the error, as before.
- OutgoingLimits is a main-actor static that tests lower, so no test needs 64 MiB of JSON; testTheMessageLimitsAreChromes pins the standard values.

Review: /code-review --fix ran on the diff. Fixed: (1) the port catch no longer ends the port on .notConnected while the host's end is still being joined (host.isConnected), so a final reply the host wrote before exiting is still delivered and an ordinary exit race is not logged at error level; (2) the killing(_:after:) safety helper is shared in ExtensionTestSupport. Added after review: the service-worker transport test (CLAUDE.md both-transports rule). Not changed: a queued write that fails with EPIPE after the host exits makes the join report 'Native host write failed' instead of the exit status (logs only; both owners ignore the reason); each frame is copied twice on the main actor (Data frame + DispatchData), ~128 MiB transient for a 64 MiB message; the SIGPIPE test sets SIG_DFL process-wide for <1 s (intentional, it is the test's point).

Tests (all on main, -derivedDataPath .derived): ExtensionIDDerivationTests 11, ExtensionPolyfillProfileWiringTests 67 (13 skipped: gated measurement legs), NativeHostManifestValidationTests 18, NativeMessagingEnforcementTests 26, NativeMessagingFramingTests 12, NativeMessagingHostLifecycleTests 27: 161 run, 0 failures. New: lifecycle x7 (4 MB to a non-reading host returns at once with the bytes queued; quit sweep with 4 MB queued for a non-reading SIGTERM-ignoring host returns after its 0.5 s wait having killed it; 40 echoed messages in order; over-limit refused and never written; queue bound refuses the third 200 KB frame; closed-stdin host -> EPIPE ends the connection with SIGPIPE at SIG_DFL; limits pinned), enforcement x2 (page: 6 MB to a .silent host, port stays open and page keeps answering; too large / queue full each disconnect the port and end the host), wiring x1 (the same from a service worker). Each non-reading leg arms a SIGKILL safety timer so a regression fails instead of hanging.

Runtime: Debug build launched via launch-detour.sh with DETOUR_DATA_DIR=DetourVerifyT265; it launched and ran normally (only the usual state-restoration/constraint noise in the log, no native-messaging lines since no extension uses a host there); stopped by PID with SIGTERM; defaults keys and data dir removed. Not verified at runtime: an actual NSApp.terminate quit with a wedged host and a real extension (AC1's quit is covered by the main actor never blocking plus the sweep test with writes queued); 1Password in the signed build (its messages are small and go through the same writer).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
NativeMessagingHost no longer writes to a host's stdin on the main actor. Each connection has a StdinWriter (nonisolated, Sendable, Mutex state) owning a DispatchIO stream channel, so sendMessage only queues: a host that stops reading can no longer freeze the UI or the quit, and messages keep their order. Teardown stops the channel, which abandons queued writes as Chrome does; the quit sweep, SIGTERM handler and kill timer never wait on a write. A failed write (EPIPE, with F_SETNOSIGPIPE on the fd) ends the connection through the existing join. Limits: browser->host is now Chrome's 64 MiB (it was a copy of the 1 MB host->browser cap), and queued bytes per host are bounded at one maximum frame. A port message that cannot be sent is logged and disconnects the port with Chrome's text (WebKit hands the extension only onDisconnect), unless the host is already ending, when the join's disconnect delivers its last reply first. 161 tests in 6 suites pass, with new legs against non-reading hosts from a page, a worker and the host level. Follow-ups: the exit-vs-write-failure reason priority, and dropping one frame copy for large messages.
<!-- SECTION:FINAL_SUMMARY:END -->
