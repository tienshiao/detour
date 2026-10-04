---
type: Component
title: Extension console bridge
description: How console output and uncaught errors from extension contexts reach the unified log, why the text is private by default, and the two rate limiters that keep an extension's error loop from flooding the log.
tags: [extensions, logging, diagnostics, security]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:48:49Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (consoleJS)
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (the "log" case, consoleLogIsPublic)
  - id: limiter
    resource: ../../Detour/Extensions/Runtime/ConsoleBridgeLimiter.swift
    title: ConsoleBridgeLimiter.swift
  - id: limiter-tests
    resource: ../../DetourTests/ConsoleBridgeLimiterTests.swift
    title: ConsoleBridgeLimiterTests.swift
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (errorsDidUpdate observer)
  - id: task-1
    resource: backlog:TASK-1
    title: 1Password extension log hygiene
  - id: task-16
    resource: backlog:TASK-16
    title: Native keep-alive (note on info lines ageing out of the log store)
  - id: task-17
    resource: backlog:TASK-17
    title: Rate-limit the worker console bridge
  - id: task-90
    resource: backlog:TASK-90
    title: 1Password reconnect loop investigation (sustained-rate cap, flood report)
---

# Role

WebKit logs an extension's console output and exceptions privately. When a
background script throws during evaluation, all Detour sees is "The
background content failed to load due to an error". The console bridge puts
the extension's own words into the unified log, so a failure in a build that
cannot run under a debugger (1Password only trusts the signed build) can
still be diagnosed from `log show`.

It runs wherever the [polyfill layer](./polyfill-layer.md) is injected:
service workers, background pages, popups, options pages, extension tabs and
offscreen documents. It does not run in content scripts.

# How it works

1. **Wrap.** `consoleJS` replaces `console.log`, `info`, `warn` and `error`.
   The original is called first, so the Web Inspector still shows everything.
   `console.debug` and `console.trace` are not bridged.
2. **Report errors.** `error` and `unhandledrejection` listeners forward
   `[uncaught exception] (file:line:col) Name: message` and
   `[unhandled rejection] …`.
3. **Format.** An `Error` or `DOMException` becomes `name: message`, its own
   enumerable properties, then the stack (`JSON.stringify` alone gives `{}`).
   Errors nested in objects become `{name, message, stack}`. Each argument is
   formatted in isolation (`[unserializable]` on failure), the whole message
   is capped at 8192 characters, and nothing here can throw into extension
   code.
4. **Limit in JS** (see below), then send
   `__detourPolyfillRequest('log', {level, message})`: a script message in
   pages, `sendNativeMessage` to `detourPolyfill` in workers. The promise's
   rejection is swallowed, or the unhandled-rejection reporter would feed
   itself for as long as the bridge keeps failing.
5. **Limit natively**, then log in category `extension-polyfill` as
   `[SW <extension id>] <message>`. The `SW` prefix is used for every context
   kind, not only workers.

| `console` method | Log level | Persisted |
|---|---|---|
| `log`, `info` | info | No; memory only, gone within minutes[^task-16] |
| `warn`, `error`, uncaught exception, unhandled rejection | error | Yes |

# Privacy

Extension console text is arbitrary extension data; 1Password logs native
messaging responses. The message is therefore `.private`: it reads
`<private>` in `log show` and is visible only with a debugger attached.

To read it for one debugging session, either launch with
`-ExtensionConsoleLogPublic YES` (argument domain, nothing persisted) or set
the `ExtensionConsoleLogPublic` default on `com.detourbrowser.mac` and delete
it afterwards. `consoleLogIsPublic` is **read once per launch** and logs a
notice when on. It cannot be switched on for a process that is already
misbehaving; relaunching usually destroys the state under investigation.

# The two limiters

| | JS (`consoleJS`, per context) | Native (`ConsoleBridgeLimiter`, per profile and extension) |
|---|---|---|
| Burst | 50 | 100 |
| Sustained | 20 per second | 5 per second |
| Dedupe | Consecutive identical `(level, message)` collapse into `… (repeated N times)`, flushed on change or after 1 s | None |
| Drop report | `[console bridge] dropped N messages (E errors, W warnings, I info) in the last T s`, at most one per 5 s | `[console bridge] dropped N messages from <ext> …`, at most one per 30 s and once when dropping stops |
| Flood report | None | One **error** line after 60 s of unbroken dropping, naming extension and profile; a new incident only after 60 s of quiet |

Why both: the JS limiter lives in the extension's own realm. A context that
loaded before an update, one whose `console` the extension replaced, or a
page posting `{type: "log"}` to the bridge directly is not limited by it. The
native limiter is keyed by the *verified* extension id and is the one that
protects the log. Both are token buckets with an injected clock.

The reply to a dropped message is still `true`: the bridge is
fire-and-forget, and a rejection would only make the polyfill noisier.

# Why the numbers are what they are

- **2026-09-11.** A 1Password worker error loop forwarded about 950,000 lines
  in 55 seconds, each a native-messaging round trip and a log write. TASK-17
  added the JS bucket, the dedupe, and a native fixed window of 100 per
  second.[^task-17]
- **2026-09-19.** A different loop ran at a flat 20 errors per second for
  hours. That is a fifth of the per-second cap, so the native limiter never
  engaged, and a cycle of five alternating messages passes the JS dedupe and
  the JS refill rate untouched. The cost was about 1,200 persisted writes a
  minute, which evicted the rest of Detour's log history and left the
  incident's own beginning unreadable.[^task-90] The native limiter became a
  token bucket with a sustained rate; the same loop is now cut to 5 per
  second (in the test, 20 per second for 120 s admits exactly 699 messages
  and drops 1,701).
- **The reaction to a flood is logging only.** Restarting the worker was
  rejected: in that incident a restarted worker re-entered the loop within a
  minute, and an automatic restart invites a restart loop on top of the
  message loop. A user-visible notice was rejected because there is nothing
  the user could do about it.[^task-90]

# Gotchas

- **Formatting runs before the limiter**, because dedupe compares formatted
  text. A dropped message still pays for formatting; the round trip and the
  log write are what the limiter removes.
- **A native flood that stops dead leaves its last tally unreported** until
  the extension logs again. The JS summary's backstop timer covers that case.
- **Both summaries start with `[console bridge]`** so one predicate finds
  both halves of an incident.
- **`forgetConsoleRateLimit(for:)`** is called from `Profile.unloadExtension`:
  a reloaded context starts with a full bucket and can be reported on again.
- **A stack frame inside Detour's polyfill file** in a bridged
  `console.error` is the bridge's wrapper, not the source of the error.
- **Text can still be recovered without the public flag** when the extension
  keeps its own diagnostics; see
  [WebKit helper diagnostics](../playbooks/webkit-helper-diagnostics.md).
- `globalThis.__detourConsoleBridge` exposes the JS constants and a `reset()`
  for tests. Extension code can reach it, which grants nothing: a deliberate
  flood can call the bridge directly, and that is what the native cap is for.

# Related log hygiene

`Profile`'s `errorsDidUpdate` observer (category `EXT-LOAD`) logs each
`WKWebExtensionContext` error once. WebKit's `errors` array is cumulative,
consolidates repeats and may be cleared, so the dedupe is by error content
(`domain#code#description`), rebuilt from the current array on every
notification. Recovery from a background-load failure is deliberately *not*
gated by that dedupe.

The rule for the whole extension subsystem since TASK-1: no log statement
writes a native messaging payload, a polyfill message body, or host stderr at
a persisted level with public privacy. See
[native messaging](./native-messaging.md).

# Tests

- `ConsoleBridgeLimiterTests` — burst, refill, sustained flood, every drop
  eventually reported, flood reported once, a new incident after quiet,
  per-extension isolation, a clock going backwards.
- `ExtensionPolyfillTests` — the JS side, observed by stubbing
  `__detourPolyfillRequest` and calling `console.*`: error formatting, the
  whole burst forwarded, drops summarised, repeats coalesced (5,000
  identical messages become two sends), the timer flush, and that the
  context's own console is untouched.

# Related

- [Polyfill layer](./polyfill-layer.md) — the transport the bridge rides on
- [Reading runtime logs](../playbooks/reading-runtime-logs.md) — predicates and the `<private>` trap
- [Data store and ITP](./data-store-and-itp.md) — the incident behind the sustained-rate cap
- [Diagnosing extension problems](../playbooks/diagnosing-extension-problems.md) — what the bridged lines usually mean
- [Native messaging](./native-messaging.md) — the connect log, limited the same way

[^task-16]: Native keep-alive (note on info lines ageing out of the log store)
[^task-17]: Rate-limit the worker console bridge
[^task-90]: 1Password reconnect loop investigation (sustained-rate cap, flood report)
