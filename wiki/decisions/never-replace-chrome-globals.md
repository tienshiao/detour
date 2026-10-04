---
type: Decision
title: The polyfill patches members and never replaces chrome or browser
description: Replacing the chrome/browser globals with a Proxy silently disconnected service workers from runtime messaging; the polyfill therefore patches members in place, and anything that cannot be patched is handled natively.
tags: [extensions, polyfill, webkit, decision, messaging]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: task-15
    resource: backlog:TASK-15
    title: Polyfill must not replace the chrome/browser globals in service workers
  - id: docs-patching
    resource: ../../docs/chrome-runtime-patching.md
    title: docs/chrome-runtime-patching.md ("Option 2 — DO NOT USE")
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: task-16
    resource: backlog:TASK-16
    title: Keep the background worker alive while a native messaging host is connected, native-side
  - id: task-23
    resource: backlog:TASK-23
    title: Callback-form polyfill APIs must route rejections to runtime.lastError
  - id: task-123
    resource: backlog:TASK-123
    title: Defer an update while the extension is busy and fire runtime.onUpdateAvailable
  - id: notes-1password
    resource: "Agent session notes, 2026-09-12 (not in the repository)"
    title: 1Password integration — the TASK-15 root cause and how it was found
  - id: polyfill-tests
    resource: ../../DetourTests/ExtensionPolyfillTests.swift
    title: ExtensionPolyfillTests (testKeepAliveLeavesGlobalsUntouchedWhenConnectNativeIsNotPatchable)
  - id: integration-tests
    resource: ../../DetourTests/ExtensionPolyfillIntegrationTests.swift
    title: ExtensionPolyfillIntegrationTests (testRuntimeSendMessageReachesWorkerRunningThePolyfill)
---

`globalThis.chrome` and `globalThis.browser` in an extension context must stay
the objects WebKit installed. The [polyfill](../extensions/polyfill-layer.md)
may add or patch members on them and on the namespaces beneath; it may never
substitute its own object. The rule came from one bug that took every
extension's messaging down without a single error.

# Context

The first native-port keep-alive needed to wrap `runtime.connectNative`.
WebKit's runtime object rejected the direct patch, so the polyfill fell back
to replacing `globalThis.chrome` and `globalThis.browser` with a `Proxy` in
service workers, returning a patched `runtime`.

WebKit's runtime-message dispatcher
(`WebExtensionContextProxy::enumerateFramesAndNamespaceObjects`) finds a
context's `onMessage` listeners by reading the `browser` global, then
`chrome`, from each extension frame or worker and unwrapping it with
`toWebExtensionAPINamespace`. A Proxy cannot be unwrapped. The worker is
skipped, no listener "handles" the message, and
`internalDispatchRuntimeMessageEvent` sends the sender the empty default
reply.[^task-15]

The symptom: every `chrome.runtime.sendMessage` to the worker — from a popup,
options page, offscreen document or content script — resolved `undefined`
with no `lastError`, within about 2–20 ms. No exception, no log line. It
affected every extension with a service worker. 1Password's popup showed
"Oops, something went wrong while loading", because its `get-popup-config`
request got no reply.

It was found with a temporary tracer module in the polyfill (wrapping
`runtime.sendMessage`, plus a raw `onMessage` listener, logged through the
[console bridge](../extensions/console-bridge.md)): page-side callbacks
resolved `undefined` while no worker listener ever ran. WebKit's source
confirmed the unwrap path.[^notes-1password]

# Decision

Never reassign `globalThis.chrome` or `globalThis.browser`, in any context.
Patch members in place on the wrappers WebKit vends. When a member cannot be
patched from JavaScript, do the work natively instead.

The preamble's `if (!g.chrome) g.chrome = {}` is not an exception: it only
creates a global that does not exist.

# Alternatives rejected

| Alternative | Why not |
|---|---|
| A `Proxy` (or any stand-in) for the globals | Breaks runtime message dispatch, as above |
| Pin a *substitute* `runtime` object on the real namespace (`Object.defineProperty(chrome, 'runtime', { value: proxy })`) | Implemented and probed: `defineProperty` accepts it and reads keep returning the native runtime. Pinning only works with the same wrapper WebKit vends.[^task-15] |
| Patch `runtime.connectNative` directly | WebKit re-materializes it on every read; the write is accepted and never visible.[^task-15] |
| Keep the keep-alive in JavaScript at all | With no way to wrap `connectNative` it was inert; workers had been cycling every two minutes even with the old wrapper in place |

# Consequences

- Whatever needs to intercept an unpatchable member moved to Swift:
  - the keep-alive only *calls* `connectNative` to open its own port, and
    Detour counts real hosts and drives the pings
    ([native port keep-alive](../extensions/native-port-keep-alive.md));[^task-16]
  - `runtime.lastError` for callback-style polyfill calls is set by WebKit
    itself, through a native round trip that always fails
    ([Polyfill layer](../extensions/polyfill-layer.md));[^task-23]
  - a `runtime.reload()` is recognised by the background context restarting
    ([Updates](../extensions/updates.md)).[^task-123]
- Modules that need a namespace re-read it at each use and cache nothing:
  `__detourResolveNativeRuntime` hands back the namespace to call
  `connectNative` *on*, and never a bound or stored copy.
- `runtime.onInstalled` is taken over by shadowing methods on the event
  object, leaving `chrome.runtime` alone
  ([runtime.onInstalled](../extensions/runtime-installed-event.md)).
- Two tests guard the rule:
  - `ExtensionPolyfillTests.testKeepAliveLeavesGlobalsUntouchedWhenConnectNativeIsNotPatchable`
    asserts the globals keep their identity against a fake namespace whose
    `connectNative` cannot be patched;
  - `ExtensionPolyfillIntegrationTests.testRuntimeSendMessageReachesWorkerRunningThePolyfill`
    sends a real `runtime.sendMessage` from an extension page to a real module
    worker running the polyfill. Grafting the old global swap back in makes it
    return `reply = nil`, `lastError = nil`, the popup's exact symptom.
- A general lesson for diagnosis: a `sendMessage` that resolves `undefined`
  with no `lastError` and almost instantly means no listener was reached, not
  that the listener answered nothing
  ([diagnosing extension problems](../playbooks/diagnosing-extension-problems.md)).

# Related

- [Chrome runtime patching](../extensions/chrome-runtime-patching.md) — what can be patched in place, and how to keep a patch alive.
- [Native WebExtension with polyfills](./native-webextension-with-polyfills.md) — the decision this constraint lives inside.
- [1Password integration](../extensions/1password-integration.md) — the popup failure in context.
- [WebKit source lookup](../platform/webkit-source-lookup.md) — how the dispatcher code was read.

[^task-15]: Polyfill must not replace the chrome/browser globals in service workers
[^task-16]: Keep the background worker alive while a native messaging host is connected, native-side
[^task-23]: Callback-form polyfill APIs must route rejections to runtime.lastError
[^task-123]: Defer an update while the extension is busy and fire runtime.onUpdateAvailable
[^notes-1password]: 1Password integration — the TASK-15 root cause and how it was found
