---
id: TASK-17
title: 'Extensions: rate-limit the worker console bridge'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 06:39'
updated_date: '2026-09-12 18:35'
labels:
  - extensions
  - logging
dependencies: []
priority: low
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The polyfill's console bridge (ExtensionAPIPolyfill.consoleJS -> ExtensionPolyfillHandler 'log' case) forwards every console.log/warn/error from extension contexts to Swift one message at a time over the native message bridge (workers) or webkit.messageHandlers (pages), and Swift logs each one. On 2026-09-11 around 20:00 the pre-TASK-15 build forwarded ~950,000 error lines from 1Password's service worker in 55 seconds (~20,000/s; a worker error loop, text was private so the cause is unknown), each a native-messaging round trip and a unified-log write. Add a per-context rate limit on the JS side (e.g. a token bucket per context, ~N messages/s with a burst, plus dedupe of identical consecutive messages with a count) and, as defence in depth, a cap in the Swift handler per extension per second that logs one summary line ('dropped N console messages') when exceeded. Keep the first occurrences so a real error is still visible, and keep ExtensionPolyfillTests' console-bridge tests passing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A context emitting console messages faster than the limit gets its excess dropped or coalesced on the JS side; the bridge sends at most the configured rate plus a summary of what was dropped
- [x] #2 The Swift handler independently caps forwarded console messages per extension per second and logs a single 'dropped N' line instead of N lines
- [x] #3 Identical consecutive messages are coalesced with a repeat count
- [x] #4 ExtensionPolyfillTests cover the limiter (burst allowed, excess dropped with a summary, dedupe count) and the existing console-bridge tests still pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. JS (ExtensionAPIPolyfill.consoleJS): add a per-context limiter between formatting and the bridge send. Token bucket (burst 50, refill 20/s) + consecutive-identical dedupe with a repeat count flushed on message change or after 1s via a single guarded timer. When the bucket is empty, count drops per level and emit ONE '[console bridge] dropped N messages (E errors, W warnings, I info) in the last T s' summary at warn when tokens return, with a single 5s backstop timer so a flood that stops is still reported. The summary bypasses the bucket and the dedupe so it can never be swallowed or loop. _origLog/_origWarn/_origError stay unaffected: only the bridge send is limited. Constants + a reset() test seam exposed as globalThis.__detourConsoleBridge.
2. Swift: new ConsoleBridgeLimiter.swift — pure, injected clock, fixed 1s window, 100 messages/s per extension id; when a window rolls after drops the decision carries the dropped count so the 'log' case emits one log.warning instead of N lines. Message privacy handling untouched. Held per handler (per profile).
3. Tests: ExtensionPolyfillTests gains burst-allowed, excess-dropped-with-summary, dedupe-on-change, dedupe-flushed-by-timer, and original-console-untouched cases; new ConsoleBridgeLimiterTests drives the Swift cap with a fake clock.
4. Build Detour, run ExtensionPolyfillTests + ConsoleBridgeLimiterTests, self-review for summary loops/timer leaks.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented.

JS (ExtensionAPIPolyfill.consoleJS): token bucket BRIDGE_BURST=50 / BRIDGE_REFILL_PER_SEC=20, consecutive-identical dedupe flushed as '<msg> (repeated N times)' on message change or after DEDUPE_FLUSH_MS=1000, and one '[console bridge] dropped N messages (E errors, W warnings, I info) in the last T s' warn per drop episode, emitted when a token returns or by a DROP_SUMMARY_MS=5000 backstop timer. Summaries bypass both the bucket and the dedupe, and emitting one requires a fresh drop, so they cannot feed themselves; the repeat flush DOES go through the bucket so an alternating A,B,A,B flood gets no free send per transition. At most one dedupe timer and one summary timer, both cleared when they fire. _orig* is untouched, so the Web Inspector still sees everything (asserted by a test that shims console.error before the polyfill binds it).

Decisions:
- Formatting still runs before the limiter: dedupe needs the formatted text to compare, so a dropped message pays for formatting. That is in-process work; the round trip and log write the incident was made of are what the limiter removes.
- globalThis.__detourConsoleBridge exposes the constants plus reset() for deterministic tests. Reachable from extension code, but no new capability: the module runs in the extension's own realm, so a deliberate flood can already call __detourPolyfillRequest('log') directly. That is what the native cap is for.
- The repeat suffix can push a message a few chars past MAX_MESSAGE_LENGTH; the native side has no length assumption.

Swift (new ConsoleBridgeLimiter.swift): fixed 1s window, 100 messages per extension per window, clock injected. Over the cap the message is dropped and counted; the first message of the next window returns .allowReportingDropped(count:interval:) and the handler emits one log.warning instead of N lines. Privacy handling untouched, reply is still true (fire-and-forget bridge). Held per handler (per profile), keyed by the verified extension id; Profile.unloadExtension calls the new forgetConsoleRateLimit(for:) so a reloaded context gets a fresh window. Known limit, documented: a flood that stops dead leaves its final tally unreported until the extension logs again — the JS summary covers that case.

Validation: xcodebuild -scheme Detour Debug build succeeded; DetourTests/ConsoleBridgeLimiterTests + DetourTests/ExtensionPolyfillTests = 127 tests, 0 failures (9 + 118), run with TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task17.

New tests: ConsoleBridgeLimiterTests (cap, overflow, roll-and-report, per-extension isolation, sustained flood over 10 windows, backwards clock, forget); ExtensionPolyfillTests gained ForwardsTheWholeBurst, DropsBeyondTheBurstAndSummarizesWhatItDropped, CoalescesARepeatingMessageIntoACount (the 5000-iteration incident shape -> 2 sends), FlushesARepeatCountOnATimer, DoesNotCoalesceAcrossLevels, LimitDoesNotTouchTheContextsOwnConsole. The bridgedLog helper now resets the limiter first and is built on a new bridgedLogs that returns every forwarded message.

Out of scope, not changed: ExtensionPolyfillHandler.dispatch and handleNativeMessage still log.debug once or twice per message before the 'log' case is reached, so a flood still costs those debug writes; console.debug/console.trace are still unwrapped by the bridge.

Code review (medium) fixes: a returning token no longer emits a drop summary every time (at most one per DROP_SUMMARY_MS, deferred ones ride the backstop timer), so a sustained distinct-message flood costs the refill rate, not double it; a dropped '(repeated N times)' flush is charged as N drops so the summary counts every message the log never saw; the native warning names the window age honestly ('in a window opened Xs ago') instead of a self-contradicting rate; limiter init and the test-seam reset() share one resetState(). Two regression tests added; 129 green across ConsoleBridgeLimiterTests + ExtensionPolyfillTests.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Rate-limited the extension console bridge on both sides. In the polyfill (ExtensionAPIPolyfill.consoleJS) a per-context token bucket (burst 50, 20/s) plus dedupe of consecutive identical messages into a '(repeated N times)' line, and one '[console bridge] dropped N messages (E errors, W warnings, I info) in the last T s' warn per drop episode; the extension's own console is untouched, so the Web Inspector still shows everything. Natively, the new pure ConsoleBridgeLimiter caps forwarding at 100 messages per extension per second and the handler's 'log' case emits one 'Dropped N console messages' warning per window instead of N lines, with message privacy unchanged. The 2026-09-11 incident shape — one message repeating ~20,000 times a second — now costs about two bridge sends per second. Verified by a Debug build of the Detour scheme and 127 passing tests (ConsoleBridgeLimiterTests + ExtensionPolyfillTests, including new burst/drop-summary/dedupe/timer-flush cases).
<!-- SECTION:FINAL_SUMMARY:END -->
