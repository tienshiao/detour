---
type: Platform Quirk
title: Patching WebKit's chrome.* wrappers
description: WebKit vends chrome.* objects from a weak wrapper cache and serves many members through class callbacks, so a JavaScript patch can vanish at the next garbage collection or never take at all; which members can be patched, how to keep a patch alive, and what must be done natively instead.
tags: [extensions, webkit, polyfill, javascriptcore, quirk]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T18:50:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: docs-patching
    resource: ../../docs/chrome-runtime-patching.md
    title: docs/chrome-runtime-patching.md (the full reference, with the IDL tables)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: task-15
    resource: backlog:TASK-15
    title: Polyfill must not replace the chrome/browser globals in service workers
  - id: task-23
    resource: backlog:TASK-23
    title: Callback-form polyfill APIs must route rejections to runtime.lastError
  - id: task-60
    resource: backlog:TASK-60
    title: Chase the one-off timing flake in the polyfill getUserSettings coverage
  - id: task-75
    resource: backlog:TASK-75
    title: Origin patterns with a port make chrome.permissions calls throw in WebKit
  - id: task-123
    resource: backlog:TASK-123
    title: Defer an update while the extension is busy and fire runtime.onUpdateAvailable
  - id: task-29
    resource: backlog:TASK-29
    title: runtime.onInstalled parity gaps left by TASK-22
  - id: integration-tests
    resource: ../../DetourTests/ExtensionPolyfillIntegrationTests.swift
    title: ExtensionPolyfillIntegrationTests
  - id: task-132-1
    resource: backlog:TASK-132.1
    title: "Spike: can WebKit's native sidePanel be used (own-property probe)"
  - id: task-132-9
    resource: backlog:TASK-132.9
    title: runtime.getContexts and runtime.ContextType
  - id: get-contexts-tests
    resource: ../../DetourTests/ExtensionRuntimeGetContextsTests.swift
    title: ExtensionRuntimeGetContextsTests (testThePatchSurvivesGarbageCollection)
  - id: side-panel-tests
    resource: ../../DetourTests/ExtensionSidePanelTests.swift
    title: ExtensionSidePanelTests (the tabs.getCurrent canary)
---

The [polyfill layer](./polyfill-layer.md) works by patching members onto the
`chrome.*` objects WebKit vends. Those objects are not ordinary JavaScript
objects. A patch that looks fine can disappear seconds later with no error, or
be accepted and silently ignored. Everything below was learned by probing a
real extension context; the IDL tables are in
[docs/chrome-runtime-patching.md](../../docs/chrome-runtime-patching.md).

# Behavior

## Wrappers are weakly cached

`chrome` and `browser` are set on the global object once per frame, and that
namespace wrapper is strongly held. Everything beneath is different:
`chrome.runtime`, `chrome.action`, `chrome.storage` and the rest are produced
on each read by a native getter that wraps one C++ object through a **weak**
wrapper cache (`JSWebExtensionWrapper::wrap`). Nothing else holds the wrapper.

So `chrome.action.getUserSettings = fn` sets an own property on a wrapper that
the next garbage collection frees. The following read mints a fresh wrapper
for the same C++ object, without the patch. Measured: the polyfill's
`getUserSettings` disappeared after about a million allocations, and a
`WeakRef` to the patched wrapper read back `undefined`.[^task-60] It showed up
as a one-in-fifty test flake and was a real production bug for long-lived
pages.

## Four kinds of member

| Kind | Examples | Own property on the wrapper |
|---|---|---|
| Static function | `runtime.getURL`, most methods of a sub-API | Shadows the native function. Patchable. |
| Static value | `chrome.runtime`, `chrome.i18n`, `chrome.extension`, `chrome.dom` | The native getter still answers the read. An own property changes nothing about *which* object comes back. |
| `[MainWorldOnly]` / `[Dynamic]`, served by the class's `getProperty` callback | Most namespaces on `chrome` (`action`, `storage`, `tabs`, `permissions`, `webNavigation`, …); `runtime.onInstalled`, `runtime.sendNativeMessage`, `runtime.connectNative`, `runtime.lastError` | The callback wins over an own property. |
| Members *inside* one of those namespaces | `action.getUserSettings`, `storage.managed`, `permissions.contains`, `webRequest.onAuthRequired` | Patchable in place, for as long as that wrapper is alive. |

Two separate questions hide in that table and must not be conflated:

- **Precedence** — which object does a read return? For static values and
  callback-served members, always WebKit's. Pinning a *different* object under
  `chrome.runtime` is accepted by `Object.defineProperty` and ignored on
  reads.[^task-15]
- **Lifetime** — does the wrapper WebKit returns still carry my patch? Only if
  something holds a strong reference to it, so the weak cache keeps handing
  back the same object.

Pinning `chrome.runtime` works because the own property is a strong reference
to the *same* wrapper WebKit vends, not because it wins the read. The
reference document's Option 1 first described it as taking precedence over
the static getter; the probes showed otherwise, and it now says so.

## Members that cannot be patched at all

- `runtime.connectNative` is re-materialized on every read. Assignment and
  `defineProperty` complete without throwing; the read-back equals neither the
  value written nor the previous read (probed 2026-09-11 in a module service
  worker).[^task-15]
- `runtime.lastError` reports as `{ value: null, writable: false,
  configurable: true }`, and `defineProperty`, assignment and `delete` all
  complete with no effect (probed 2026-09-12 in an extension page and a module
  worker). A write must be verified by reading it back.[^task-23]
- `runtime.reload` cannot be shadowed: the TASK-123 work found it to be a
  read-only static value of the runtime wrapper, where an own property is
  masked.[^task-123] WebKit's reload unloads and reloads the same context
  object, keeps its base URL and calls no delegate method, so its only trace
  for the host is the background context starting again.

## Other measured facts

- `chrome.permissions === browser.permissions`, and `browser.runtime ===
  chrome.runtime`: WebKit vends one object under both globals (measured
  2026-09-20 and 2026-09-12).[^task-75][^task-23] The polyfill still handles
  the two-object case, since that identity is an implementation detail.
- When WebKit vends nothing for a namespace — `chrome.webRequest` on
  macOS 26 — there is nothing to shadow, and an own property on `chrome` is
  read normally. That is how the full `webRequest` stub is installed.
- `chrome.sidePanel` is the same case. Released WebKit compiles it out, and a
  probe on macOS 26.7 found that an own property defined on `chrome` under
  that name sticks in the worker and in an extension page, survives
  allocation churn, and is visible as `browser.sidePanel`.[^task-132-1]
- `tabs.getCurrent()` answers `null`, not Chrome's `undefined`, in an
  extension page that is not a tab (measured in a side panel, promise and
  callback forms; `ExtensionSidePanelTests` keeps a canary on it). It is a
  member inside a namespace, so it is patched in place and `tabs` is rooted.
- An event object such as `runtime.onInstalled` is itself a weakly cached
  wrapper. Its methods (`addListener`, …) live on its class, so own properties
  under those names shadow them while the wrapper is held. Measured with a
  real page: WebKit's dispatch reached a control listener added through the
  native method and not the listener added through the shadow.[^task-29]

# Why it matters here

| Goal | What works |
|---|---|
| Add a member to `chrome.runtime` (e.g. `requestUpdateCheck`, `getContexts`, `ContextType`), or wrap `runtime.getURL` | Patch the wrapper, then pin it: `Object.defineProperty(chrome, 'runtime', { value: runtime, … })` (`missingStubsJS`). `runtimeGetContextsJS` roots the same wrapper a second time, below |
| Add a member to `chrome.action`, `chrome.storage`, `chrome.permissions`, a native `chrome.webRequest` | Patch in place, root with `__detourHoldWrapper(name, wrapper)`, re-read the namespace and check the patch is visible |
| Add events to `chrome.webNavigation` | Patch in place and root it as an own property on `chrome` (`webNavigationJS`). That `defineProperty` looks like a no-op and is load-bearing. |
| Replace a whole missing namespace (`idle`, `offscreen`, `privacy`, `sidePanel`, …) | `__detourDefine(chrome, name, obj)` |
| Take over `runtime.onInstalled` | Shadow the four listener methods on the event wrapper and hold the wrapper; never touch `chrome.runtime` for it |
| Intercept `connectNative`, set `lastError`, intercept `reload` | Not possible from JavaScript. Do it natively: the delegate's `connectUsing`, the `runtime.lastErrorRelay` round trip, the background-restart heuristic in [Updates](./updates.md) |

## The runtime wrapper is rooted twice

`chrome.runtime` was first kept alive only by the pin: the own property on
`chrome` that holds the wrapper WebKit vends. `runtimeGetContextsJS` adds
`getContexts` and `ContextType` to that wrapper, only when absent, and also
roots it under the key `runtime` in `__detourHeldWrappers` (a distinct
`browser.runtime` under `browserRuntime`).[^task-132-9] The second root does
not depend on the pin having taken, and it makes the wrapper addressable, so
a test can assert `__detourHeldWrappers.runtime === chrome.runtime` before
and after a forced collection
(`ExtensionRuntimeGetContextsTests.testThePatchSurvivesGarbageCollection`),
the same identity check the other rooted namespaces get.

# Workaround

- Patch members in place on the wrapper WebKit vends. Never substitute another
  object for a namespace, and never reassign `chrome` or `browser` — that
  disconnects the context from runtime messaging
  ([never replace chrome globals](../decisions/never-replace-chrome-globals.md)).
- Root every patched wrapper. `__detourHeldWrappers` is non-enumerable and
  non-writable so extension code that enumerates or clears globals cannot drop
  a root, and keyed so a test can assert `__detourHeldWrappers.action ===
  chrome.action`.
- After patching, read the namespace again and compare. If the patch is not
  what a fresh read answers with, release the root and record
  `polyfill-not-visible` in `__detourPolyfillDiag.apis`. A patch that is
  silently not in force is worse than none.
- When wrapping a native function, keep the original reachable
  (`wrapper._detourNative`) and mark the wrapper (`_detourPortWrapper`), so a
  second run of the polyfill does not wrap its own wrapper.
- Guard a patch with a test that forces a collection.
  `testActionGetUserSettingsSurvivesGarbageCollection` churns garbage until a
  control `WeakRef` clears, then reads the API back.
- Treat every reading here as a measurement of one WebKit build. The
  integration tests pin several of them (which gap-filling modules report
  `polyfill`, that `getAllFrames` is native), so a WebKit change is noticed.

# Related

- [Polyfill layer](./polyfill-layer.md) — the code these rules constrain.
- [runtime.onInstalled](./runtime-installed-event.md) — the event-wrapper shadowing in use.
- [Native port keep-alive](./native-port-keep-alive.md) — what replaced wrapping `connectNative`.
- [WebKit source lookup](../platform/webkit-source-lookup.md) — reading the IDL and wrapper sources.

[^task-15]: Polyfill must not replace the chrome/browser globals in service workers
[^task-23]: Callback-form polyfill APIs must route rejections to runtime.lastError
[^task-60]: Chase the one-off timing flake in the polyfill getUserSettings coverage
[^task-75]: Origin patterns with a port make chrome.permissions calls throw in WebKit
[^task-123]: Defer an update while the extension is busy and fire runtime.onUpdateAvailable
[^task-29]: runtime.onInstalled parity gaps left by TASK-22
[^task-132-1]: Spike: can WebKit's native sidePanel be used (own-property probe)
[^task-132-9]: runtime.getContexts and runtime.ContextType
