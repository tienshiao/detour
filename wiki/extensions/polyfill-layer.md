---
type: Component
title: Polyfill layer
description: The JavaScript bundle Detour evaluates in every extension context and the native handler behind it — how it is injected, how a request reaches Swift and how the sender is verified, with links to the pages on each polyfilled API.
resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
tags: [extensions, polyfill, security, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (polyfill file injection, sendMessage delegate)
  - id: stubs
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillStubs.swift
    title: ExtensionPolyfillStubs.swift
  - id: task-10
    resource: backlog:TASK-10
    title: Verify polyfill bridge sender by context base URL, not extension id
  - id: task-13
    resource: backlog:TASK-13
    title: Give ExtensionPolyfillHandler a profile back-reference
  - id: task-15
    resource: backlog:TASK-15
    title: Polyfill must not replace the chrome/browser globals in service workers
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

# How a call flows

1. An extension calls a polyfilled member (`chrome.history.search(…)`). The
   module calls `__detourPolyfillRequest(type, params)`, which sends
   `{type, params, extensionID}` over the context's transport
   ([injection](#injection)).
2. The native entry point establishes the caller's identity itself and never
   trusts the body's `extensionID`; a mismatch is refused
   ([sender verification](#sender-verification)).
3. `ExtensionPolyfillHandler.dispatch` applies the request's own gates
   (permission, profile scope; [request gates](./polyfill-request-gates.md))
   and runs the request.
4. The reply settles the promise, or the trailing callback through
   `__detourSettle`; a failure reaches the extension verbatim, as a rejection
   or as `runtime.lastError` ([errors](./polyfill-errors.md)).

# How it works

## Injection

| Context | How the bundle gets there | Transport to Swift |
|---|---|---|
| Extension pages: popup, options, extension tabs, offscreen documents, and a background *page* | A `WKUserScript` at document start, all frames, on the controller configuration's `userContentController` (`Profile.extensionController`) | `webkit.messageHandlers.detourPolyfill.postMessage(msg)` → `userContentController(_:didReceive:replyHandler:)` |
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
  ordinary site. Its requests from there are rejected
  ([sender verification](#sender-verification)) and logged once
  per origin, with the host kept private.

## The bundle

`generatePolyfillJS` joins the modules — preamble, console bridge, WebSocket
relay, native-port keep-alive, runtime patches (missing stubs, the update
check, `onInstalled`, the content-script bridge), then one module per API
(idle, notifications, history, management, privacy, webRequest,
`action.getUserSettings`, `storage.managed`, the `permissions` origin-port
wrapper, fontSettings, sessions, search, offscreen, webNavigation), then the
two automation modules below — and wraps them in one `try`/`catch` that records `__detourPolyfillDiag`. The
diagnostics are written to `chrome.storage.local` under `_polyfillDiag`, which
is how a worker's result can be read at all; the API Explorer popup shows them.
`apis.<name>` says which path each gap-filling module took (`native`,
`polyfill`, `absent`, `polyfill-not-visible`, `error: …`).

The last module is the automation endpoint's channel (TASK-228.2,
`AutomationExtensionChannel.polyfillModuleJS`): in the background context
only, it parks `automation.awaitCommand`, acknowledges each command
(`automation.ack`) and sends its result (`automation.result`). The handler
takes those three from the verified extension's background context alone,
in the Private profile only while "Allow agents to use Private windows" is
on (`AutomationPrivateAccess.isAllowed()`), and they do not count as the background's
activity. With the endpoint off a park is answered `stop` at once, so the
cost is one round trip per worker start. Why a park and not a port or a
listener: [automation endpoint: extension contexts](../features/automation-endpoint-extensions.md#the-worker-channel).

Just before it, `ExtensionPolyfillStubs.countingModuleJS` (TASK-228.2 part 2)
wraps the polyfill's own stand-ins (the registry in
`ExtensionPolyfillStubs`: privacy settings, webRequest events,
`storage.managed`, `sessions.getRecentlyClosed`, the never-fired idle,
history and management events, …) to count their calls for the automation
endpoint's compatibility report. It never wraps a function WebKit vends (the
`[native code]` test), keeps `this`, the arguments, the result and the
`_detourPolyfill` marker and the stand-in's own `length` and `name` (an
extension may branch on them), and sends one `automation.stubCalls` batch
per task, never a second while one waits for its reply (calls meanwhile go
in the next batch). The handler answers `stop` while automation is off, and
the context then drops its counts and stops sending, so with automation off
a context costs one stopped request at most. `__detourPolyfillDiag.apis.stubCounting` says how many
members it wrapped. The automation runner also answers a `probe` command
(presence, `typeof`, nativeness per path) for the same report; see
[the compatibility report](../features/automation-endpoint-compat-report.md#2-stubs-and-their-calls).

Preamble helpers every module uses:

| Helper | Purpose |
|---|---|
| `__detourPolyfillRequest(type, params)` | Sends `{type, params, extensionID}` over whichever transport the context has and returns a promise |
| `__detourSettle(promise, callback, passResult)` | Chrome's callback form, including `runtime.lastError` ([errors](./polyfill-errors.md#callback-form-and-runtimelasterror)) |
| `__detourDefine(obj, prop, value)` | Assign, falling back to `defineProperty`; warns and continues on failure |
| `__detourHoldWrapper(name, wrapper)` | Strong root for a patched native wrapper, in `__detourHeldWrappers` |
| `__detourContextKind` | `'worker'`, `'background-page'` or `'page'`, decided once |
| `__detourContextInstance` | A token minted per evaluation, so Swift can tell one start of a context from the next |
| `__detourManifestPermissions()` | The manifest's `permissions` list (not `optional_permissions`), for modules that must stay absent unless asked for (`privacy`, `webRequest`) |
| `__detourDeclaresPermission(name)` | Whether `permissions` or `optional_permissions` lists `name`: the gate of the namespaces an extension may be granted at runtime (notifications, history, the full management) |
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
  later (`onUpdateAvailable`, `notifications.onClicked` / `onClosed` in the
  background; see [notification events](./polyfill-notification-events.md)), a relayed message from a content script
  (`webNavigation` history events), or the keep-alive native port. The other
  polyfill event objects — `idle.onStateChanged`,
  `notifications.onButtonClicked`, `history.onVisited`, `management.on*` —
  accept listeners and never fire: nothing calls their `__extensionDispatch…`
  hooks.
- Worker `console` output is invisible in Web Inspector for these contexts; it
  reaches the unified log through the [console bridge](./console-bridge.md),
  as `<private>` unless `ExtensionConsoleLogPublic` is set.
- Per the project rule, polyfill JavaScript uses `let` / `const`.

# Pages

| Page | What it covers |
|---|---|
| [Request gates](./polyfill-request-gates.md) | Permission checks in the bundle and the handler, and the profile each request acts in |
| [Errors and runtime.lastError](./polyfill-errors.md) | The callback form, the three `lastError` modes, and how a native error reaches the extension verbatim through both transports |
| [chrome.history](./polyfill-history.md) | `history.search`, scoped to the calling profile, with Chrome's 24-hour default range |
| [Favicons](./polyfill-favicons.md) | The `_favicon` URL rewrite and what each kind of context gets from it |
| [chrome.management](./polyfill-management.md) | The permission-free `getSelf`, `uninstallSelf` and `getPermissionWarningsByManifest` |
| [chrome.permissions for history and management](./polyfill-permissions.md) | `permissions.request`, `contains` and `remove` of the two names WebKit refuses as unknown |
| [chrome.notifications](./polyfill-notifications.md) | Call ordering, the `create` signature, what `clear` and `update` answer, what a banner shows |
| [Notification authorization](./polyfill-notification-authorization.md) | The prompt at the first `create`, and the bounded wait for its answer |
| [Notification events](./polyfill-notification-events.md) | `onClicked` / `onClosed` through a parked request, synchronization with Notification Center |
| [Notification ownership](./polyfill-notification-scope.md) | Owners per profile, opaque identifiers, when an owner's notifications go, leftovers at launch |

Modules with pages elsewhere: [offscreen documents](./offscreen-documents.md),
[storage](./storage.md) (`storage.managed`), [permissions](./permissions.md)
(the `permissions` wrappers), [updates](./updates.md) (`onUpdateAvailable`),
[runtime.onInstalled](./runtime-installed-event.md), the
[console bridge](./console-bridge.md), the [WebSocket relay](./websocket-relay.md),
the [native-port keep-alive](./native-port-keep-alive.md).

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
- [Offscreen documents](./offscreen-documents.md), [Storage](./storage.md), [Permissions](./permissions.md), [Updates](./updates.md) — the modules with their own pages.
- [Automation endpoint](../features/automation-endpoint.md) — the consumer of the last two modules.

[^task-10]: Verify polyfill bridge sender by context base URL, not extension id
[^task-13]: Give ExtensionPolyfillHandler a profile back-reference
