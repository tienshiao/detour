---
type: Component
title: Polyfill layer
description: The JavaScript bundle Detour evaluates in every extension context and the native handler behind it — how it is injected, how a request reaches Swift, how the sender is verified, and how callback-style calls get runtime.lastError.
resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
tags: [extensions, polyfill, security, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T18:50:00Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: handler-side-panel
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler+SidePanel.swift
    title: ExtensionPolyfillHandler+SidePanel.swift (sidePanel.* messages)
  - id: handler-open-contexts
    resource: ../../Detour/Extensions/Runtime/ExtensionOpenContexts.swift
    title: ExtensionOpenContexts.swift (runtime.getContexts)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (polyfill file injection, sendMessage delegate)
  - id: task-10
    resource: backlog:TASK-10
    title: Verify polyfill bridge sender by context base URL, not extension id
  - id: task-13
    resource: backlog:TASK-13
    title: Give ExtensionPolyfillHandler a profile back-reference
  - id: task-15
    resource: backlog:TASK-15
    title: Polyfill must not replace the chrome/browser globals in service workers
  - id: task-23
    resource: backlog:TASK-23
    title: Callback-form polyfill APIs must route rejections to runtime.lastError
  - id: task-3
    resource: backlog:TASK-3
    title: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
  - id: task-64
    resource: backlog:TASK-64
    title: The onInstalled claim handler accepts a claim from any page of the extension
  - id: docs-patching
    resource: ../../docs/chrome-runtime-patching.md
    title: docs/chrome-runtime-patching.md
  - id: polyfill-tests
    resource: ../../DetourTests/ExtensionPolyfillTests.swift
    title: ExtensionPolyfillTests
  - id: integration-tests
    resource: ../../DetourTests/ExtensionPolyfillIntegrationTests.swift
    title: ExtensionPolyfillIntegrationTests
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests
---

`ExtensionAPIPolyfill` generates one JavaScript bundle (`polyfillJS`) that runs
in every extension-owned context and fills the gaps in WebKit's `chrome.*`.
`ExtensionPolyfillHandler` is its native side, one per
[profile](../architecture/profiles-and-spaces.md). The bundle never reaches web
pages. What it may and may not patch is governed by WebKit's wrappers
([Chrome runtime patching](./chrome-runtime-patching.md)).

# How it works

## Injection

| Context | How the bundle gets there | Transport to Swift |
|---|---|---|
| Extension pages: popup, options, extension tabs, offscreen documents, side panels, and a background *page* | A `WKUserScript` at document start, all frames, on the controller configuration's `userContentController` (`Profile.extensionController`) | `webkit.messageHandlers.detourPolyfill.postMessage(msg)` → `userContentController(_:didReceive:replyHandler:)` |
| Service worker | No user script reaches a worker. `ExtensionManager.injectServiceWorkerPolyfill` writes the bundle next to the worker file in the *installed copy* and prepends an import to the worker source: `importScripts('_detour_polyfill.js')` for a classic worker, `import './_detour_polyfill_module.js'` for a module worker | `browser.runtime.sendNativeMessage('detourPolyfill', msg)` → the controller delegate's `sendMessage` → `handleNativeMessage` |
| Content scripts | `_detour_content_polyfill.js` (`contentPolyfillJS`, a much smaller script) is written to the installed copy and inserted first in every manifest `content_scripts[].js` list | None. It sends `runtime.sendMessage` to the background, where `contentPolyfillBridgeJS` forwards to Swift |

Things that follow from this:

- The installed copy under `<data>/Extensions/<id>/` is **modified**: the
  worker file gains a first line and, when the manifest declares content
  scripts, `manifest.json` is rewritten (pretty printed, sorted keys). The source folder of an unpacked extension is not
  touched. Both edits are idempotent, and the polyfill files are rewritten at
  every launch when their content changed (`writeIfChanged`), so a new build of
  Detour updates them without a reinstall.
- The worker polyfill file sits beside the worker script, because
  `importScripts` resolves relative to the worker file, not the extension root.
- Only manifest-declared content scripts with a `js` list get the content
  polyfill.
- The user script runs in **every frame** of every web view built from the
  extension configuration, including an extension tab the user navigated to an
  ordinary site. Its requests from there are rejected (below) and logged once
  per origin, with the host kept private.

## The bundle

`generatePolyfillJS` joins the modules — preamble, console bridge, WebSocket
relay, native-port keep-alive, runtime patches, then one module per API — and
wraps them in one `try`/`catch` that records `__detourPolyfillDiag`. The
diagnostics are written to `chrome.storage.local` under `_polyfillDiag`, which
is how a worker's result can be read at all; the API Explorer popup shows them.
`apis.<name>` says which path each gap-filling module took (`native`,
`polyfill`, `absent`, `polyfill-not-visible`, `error: …`).

Two modules have native state large enough for their own handler files and
pages:

| Module | Diag key | Native side | Page |
|---|---|---|---|
| `runtimeGetContextsJS` | `apis.runtimeGetContexts` | `ExtensionPolyfillHandler.openContexts` in `ExtensionOpenContexts.swift` | [runtime.getContexts](./runtime-get-contexts.md) |
| `sidePanelJS` | `apis.sidePanel` | `handleSidePanelRequest` in `ExtensionPolyfillHandler+SidePanel.swift`, which only forwards to the profile's `ExtensionSidePanelController` | [Side panel](./side-panel.md) |

They also show two patterns the older modules did not need:

- **Ordering.** `sidePanelJS` chains the calls of one context so they reach
  Detour in call order, because each first resolves a tab id asynchronously.
- **Timing.** `runtimeGetContextsJS` sends its request in the call itself,
  before anything is awaited, so the answer is the state at the moment of the
  call.

Preamble helpers every module uses:

| Helper | Purpose |
|---|---|
| `__detourPolyfillRequest(type, params)` | Sends `{type, params, extensionID}` over whichever transport the context has and returns a promise |
| `__detourSettle(promise, callback, passResult)` | Chrome's callback form, including `runtime.lastError` (below) |
| `__detourDefine(obj, prop, value)` | Assign, falling back to `defineProperty`; warns and continues on failure |
| `__detourHoldWrapper(name, wrapper)` | Strong root for a patched native wrapper, in `__detourHeldWrappers` |
| `__detourContextKind` | `'worker'`, `'background-page'` or `'page'`, decided once |
| `__detourContextInstance` | A token minted per evaluation, so Swift can tell one start of a context from the next |
| `__detourManifestPermissions()` | The manifest's declared permissions, for modules that must stay absent unless asked for |
| `__detourNativeness(fn)` | `'native'`, `'non-native'` or `'missing'`, by the `[native code]` check |

`__detourContextKind` matters because a `ServiceWorkerGlobalScope` check alone
calls an extension's background *page* an ordinary page. A background page is
the top-level document at the manifest's `background.page` path (resolved
against the extension root), or at `/_generated_background_page.html`, where
WebKit hosts a `background.scripts` list.

## Sender verification

Every request carries an `extensionID` in its body. **It is never trusted.**
Each entry point establishes the identity itself and rejects when it cannot:

| Entry | Identity comes from | Rejection |
|---|---|---|
| Web view | The frame's security origin, resolved through `profile.extensionID(forOriginScheme:host:)`, i.e. the loaded context whose `baseURL` has that host | `Unrecognized extension origin` |
| Worker | The `WKWebExtensionContext` WebKit hands the delegate, matched by identity against the profile's `extensionContexts` | `Unrecognized extension context` |

Then `dispatch` compares the verified id with the body's. A non-empty body id
that differs is an impersonation attempt: `Extension identity mismatch`. An
empty one carries no claim (the polyfill stamps `''` where `chrome.runtime.id`
is unavailable).

Why it is built this way: the first version looked the frame's origin host up
as if it were the extension id. WebKit gives each context a
`webkit-extension://<random UUID>/` base URL unrelated to `uniqueIdentifier`,
so the lookup never matched and the code fell back to the body's id — any
extension page could act as any other installed extension.[^task-10] The
handler now holds a weak reference to its profile, and a released profile
attributes nothing.[^task-13]

Other consequences:

- A context reloaded mid-session has a new origin, so pages left on the old
  one are rejected. That is why [extension pages](./extension-pages.md) are
  rehomed on reload.
- A message to the `detourPolyfill` host that is not an object is rejected in
  the delegate rather than falling through to the real native-host path, which
  would look for a host program of that name.
- Identity is not enough for requests that belong to the background context
  alone (`runtime.claimInstalledEvent`, `runtime.awaitUpdateAvailable`). Those
  also check the `PolyfillSender`; see
  [runtime.onInstalled](./runtime-installed-event.md) for the rule and its
  known limit.

## Per-request gates

WebKit does not permission-check APIs it does not implement, so the handler
does:

- `history.search`, `management.getAll`, `management.setEnabled` require the
  manifest permission (`hasPermission`).
- `offscreen.*` uses only the handler's own profile's context.
- `sidePanel.*` requires the manifest's `sidePanel` permission, which WebKit
  does not know; a tab arrives as a handle and is refused unless this profile
  lists it. `sidePanel.closeSelf` is honoured only from the main frame of a
  web view that is one of this profile's panels, which is why `dispatch` is
  handed the sending web view.
- `runtime.getContexts` has no permission gate, as in Chrome. It can only
  answer with the verified extension's contexts in the handler's own profile.
- `sessions.restore` and `search.query` act in `targetSpace()`: the last-active
  space when it belongs to this profile, else the profile's first space, never
  another profile's.
- Gap-filling namespaces that Chrome leaves undefined without a permission
  (`privacy`, `webRequest`) are installed only when the manifest declares it,
  so feature detection stays truthful.[^task-3] `sidePanel` follows the same
  rule.

## Callback form and `runtime.lastError`

Every promise-backed polyfill API takes an optional trailing callback and
routes through `__detourSettle`. With no callback the promise is returned
untouched. With one, a rejection must run the callback with no arguments while
`chrome.runtime.lastError` is `{ message }`, as Chrome does. How that is
achieved depends on the runtime object (`__detourCallbackLastError.lastMode`):

| Mode | When | What happens |
|---|---|---|
| `js` | `lastError` can be redefined, verified by reading it back | A getter is installed for the callback and the original restored; an unread error is reported as `Unchecked runtime.lastError: …` |
| `native-relay` | WebKit's real runtime | The message is bounced off Detour through the callback form of `runtime.sendNativeMessage` with type `runtime.lastErrorRelay`. The native side always fails with that text, so WebKit runs the callback inside its own `lastError` scope |
| `console` | Neither is possible | The callback runs without `lastError`; the message goes to `console.error` |

WebKit's `runtime.lastError` reports as a configurable data property, yet
`defineProperty`, assignment and `delete` all complete without effect and reads
stay `null`. A "configurable" check is therefore not enough; the write has to
be read back.[^task-23] In `native-relay` mode the extension sees
`Invalid call to runtime.sendNativeMessage(). <message>.` — WebKit's prefix is
the one visible difference from Chrome. The relay needs no permission: it
echoes the sender's own text (capped at 2048 characters) to the sender.

An exception thrown by the callback is rethrown on a fresh task, so it is an
uncaught error rather than an unhandled rejection.

# Invariants

- `globalThis.chrome` and `globalThis.browser` are never reassigned
  ([never replace chrome globals](../decisions/never-replace-chrome-globals.md)).
- A native API is left alone; a module fills in only what is missing. The two
  exceptions are deliberate: `offscreen` shadows whatever is there and records
  that it did, and `permissions` wraps three native methods.
- A patch on a weakly cached wrapper is rooted and then checked by a fresh
  read. If the read does not show it, the module releases the root and reports
  `…-not-visible` instead of pretending.
- A module builds its namespace in a local and publishes it last, inside its
  own `try`/`catch`, so a failure leaves the namespace absent rather than half
  built and does not skip later modules.
- Running the bundle twice in one realm is harmless (`_detourPolyfill` tags).

# Gotchas

- **There is no push channel into a context.** WebKit offers the host no way
  to call into a worker. Events Detour originates are delivered by one of:
  a claim at context start (`onInstalled`), a parked request that is answered
  later (`onUpdateAvailable`), a relayed message from a content script
  (`webNavigation` history events), or the keep-alive native port. The other
  polyfill event objects — `idle.onStateChanged`, `notifications.onClicked`
  and friends, `history.onVisited`, `management.on*` — accept listeners and
  never fire: nothing calls their `__extensionDispatch…` hooks.
- `history.search` uses `HistoryDatabase.searchHistoryGlobal`, which has no
  profile filter.
- `sessions.restore` answers with `tab.id.hashValue`, not the id WebKit uses
  for that tab.
- Worker `console` output is invisible in Web Inspector for these contexts; it
  reaches the unified log through the [console bridge](./console-bridge.md),
  as `<private>` unless `ExtensionConsoleLogPublic` is set.
- Per the project rule, polyfill JavaScript uses `let` / `const`.

# Tests

| Suite | Proves |
|---|---|
| [ExtensionPolyfillTests](../../DetourTests/ExtensionPolyfillTests.swift) | The JavaScript against a bare web view with shimmed `chrome`; handler cases; sender verification with stub origins |
| [ExtensionPolyfillIntegrationTests](../../DetourTests/ExtensionPolyfillIntegrationTests.swift) | A real `WKWebExtensionContext`: what WebKit's wrappers actually do, garbage-collection survival, real origins |
| [ExtensionPolyfillProfileWiringTests](../../DetourTests/ExtensionPolyfillProfileWiringTests.swift) | The production wiring in `Profile.extensionController`, with no test-side setup: deleting the wiring fails it |

A new or changed API needs all three kinds, from both transports; the policy is
in `CLAUDE.md` and the reasoning in [testing extensions](./testing-extensions.md).

# Related

- [Chrome runtime patching](./chrome-runtime-patching.md) — which members can be patched at all.
- [Web Extension support](./overview.md) — the full list of polyfilled APIs.
- [Native messaging](./native-messaging.md) — the other thing the `sendMessage` delegate routes.
- [Offscreen documents](./offscreen-documents.md), [Side panel](./side-panel.md), [runtime.getContexts](./runtime-get-contexts.md), [Storage](./storage.md), [Permissions](./permissions.md), [Updates](./updates.md) — the modules with their own pages.

[^task-10]: Verify polyfill bridge sender by context base URL, not extension id
[^task-13]: Give ExtensionPolyfillHandler a profile back-reference
[^task-23]: Callback-form polyfill APIs must route rejections to runtime.lastError
[^task-3]: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
