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
  - id: task-138
    resource: backlog:TASK-138
    title: chrome.history.search returns history from every profile
  - id: task-153
    resource: backlog:TASK-153
    title: chrome.history.search with empty text scans every visit of the profile
  - id: chrome-history-api
    resource: https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/history/history_api.cc
    title: "Chromium, history_api.cc (HistorySearchFunction)"
  - id: history-scope-tests
    resource: ../../DetourTests/ExtensionHistoryScopeTests.swift
    title: ExtensionHistoryScopeTests
  - id: task-152
    resource: backlog:TASK-152
    title: favicon.lookup answers from every profile's history, without a permission check
  - id: favicon-scope-tests
    resource: ../../DetourTests/ExtensionFaviconScopeTests.swift
    title: ExtensionFaviconScopeTests
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
- `history.search` answers from the handler's own profile only; see
  [chrome.history](#chromehistory-is-profile-scoped) below.
- `runtime.getURL('/_favicon/…')` is not a handler request at all: the
  polyfill rewrites it to `detour-favicon://`, and the scheme handler gates it
  on `favicon` and on the profile; see
  [favicons](#favicons-are-profile-scoped) below.
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

## chrome.history is profile-scoped

History belongs to a profile, and so does a handler. `history.search`
therefore reads only the visits of the spaces that use the handler's profile
— the scope `HistoryPageBridge.scope(forProfile:)` gives that profile's
[History page](../features/history-page.md), by the same function — through
`HistoryDatabase.searchURLs`. Before TASK-138 it read the shared `historyURL`
table unfiltered, and an extension in one profile got every other profile's
URLs, titles and visit counts; a test in a real context showed profile A's
worker receiving profile B's URL and the five-visit total of a page A had
visited twice.[^task-138]

| Rule | Detail |
|---|---|
| Scope | The spaces currently using the handler's profile. The last-active space plays no part |
| No scope | An empty list, never everyone's history: the Private profile (it records no visits), a deleted or released profile, a profile no space uses |
| `visitCount`, `typedCount`, `lastVisitTime` | Aggregated from the profile's own visits of the URL. `typedCount` was a constant 0 before |
| `title` | The title the profile's own visit recorded; the URL when it has none it may show ([history database](../architecture/history-database.md)) |
| `text` | Matched like the History page's search: alphanumeric tokens, prefix, OR'd, against the URL text and the profile's own titles. Empty lists everything in the range |
| `startTime` / `endTime` | Milliseconds, half-open `[startTime, endTime)`, select a URL by the profile's own visits |
| `startTime` left out | 24 hours before now, as in Chrome; see [the default range](#the-default-range-is-the-last-24-hours) |
| Order | Newest of the profile's qualifying visits first (with text it was FTS rank, then the shared visit count) |
| Arguments | `query` must be an object and `text` a string; `maxResults` a non-negative integer, the times numbers. Anything else is refused (`history.search: query.text must be a string`), where a lenient parse used to answer `search({})` with the whole history |

The query runs off the main thread and the reply is posted back to it. It
still holds history's one serial queue while it runs, so a
[command palette](../features/command-palette.md) read on the main thread
waits for it; what that costs is measured on
[history database](../architecture/history-database.md).

Not carried over from Chrome: `maxResults: 0` returns nothing (Chrome reads it
as no limit), and an omitted `endTime` is no upper bound (Chrome's is "now",
which differs only for a visit dated in the future).

### The default range is the last 24 hours

A query with no `startTime` (absent or `null`) covers the 24 hours before now.
Until TASK-153 it had no lower bound.

| Query | Range |
|---|---|
| `{ text: '' }`, `{ text: 'inbox' }` | from 24 hours ago, whatever `maxResults` and `endTime` say |
| `{ text: '', startTime: 0 }` | all of the profile's history: 0 or less is no lower bound |
| `{ text: '', startTime: t }` | from `t`, taken as given |
| `{ text: '', endTime: e }` with `e` more than a day ago | nothing: the default start is after the end |

Why Chrome's rule and not "no lower bound":

- It is what an extension written for Chrome expects. Chrome's schema says of
  `startTime` "If property is not specified, it will default to 24 hours", and
  `HistorySearchFunction` sets a one-day range and 100 results first, then
  overwrites each of start, end and count that the query names — so the default
  does not depend on the text or on the other two.[^chrome-history-api]
  `startTime: 0` is how an extension asks for everything.
- `search({ text: '' })` is what new-tab pages and history sidebars call on
  every open. Bounded to a day it read about 3,000 visits instead of 155,000
  on the benchmark history: 15 ms where the unbounded listing took 2.2 s
  before its query was rewritten.[^task-153]

The rule lives where the extension's arguments become a range,
`ExtensionPolyfillHandler.historySearchQuery(from:now:)`. The clock is a
parameter there, and `ExtensionPolyfillHandler.now` is the seam a test sets to
put a visit exactly on the edge (24 hours old is inside, a second older is
not). Because `startTime: 0` still reaches the unbounded query, that query has
to be cheap on its own; it is, for an empty text, since TASK-153.

The other `chrome.history` members need no scoping because they read and
write nothing: `getVisits` answers `[]`, `addUrl`, `deleteUrl`, `deleteRange`
and `deleteAll` resolve without touching the database, and `onVisited` /
`onVisitRemoved` never fire. They make no native request at all, so they are
not permission-gated either. Whoever makes one of them real has to scope it
the same way.

## Favicons are profile-scoped

`chrome.runtime.getURL('/_favicon/?pageUrl=…&size=…')` is Chrome's favicon API
(permission `favicon`). The bundle patches `runtime.getURL` so that path
becomes `detour-favicon://<the context's WebKit host>/_favicon/…`, which
`FaviconSchemeHandler` serves from the history database. The rules — the host
must be an extension of the handler's own profile holding `favicon`, and the
lookup sees only that profile's visits — are on
[favicons](../features/favicons.md#the-extension-route-belongs-to-a-profile).[^task-152]

| Context | What it gets |
|---|---|
| Extension page (popup, options, a page in a tab) | An `<img>` on the rewritten URL shows the icon of a page its profile visited, and a 1×1 transparent pixel otherwise. `fetch` of it is a cross-origin request to a scheme that sends no CORS headers, so only an image (or a `no-cors` request) can use it |
| Extension frame inside a web page | The same, through the handler `Space.makeWebViewConfiguration` registers for the tab |
| Service worker | Nothing it can read. `fetch` of the rewritten URL rejects ("Load failed") whatever the page. The request does reach the scheme handler — its lookup runs, under the same gate and scope — so the failure is on the way back, most likely the missing CORS headers (not investigated). Measured in `ExtensionFaviconScopeTests`; unchanged by TASK-152 |
| The Private profile | The transparent pixel, always: it has no history scope |

There was a second route until TASK-152: a `favicon.lookup` message that
answered any extension with the icon's *URL*, with no permission check and no
scope. Nothing in the bundle sent it — it was left over from the first
favicon attempt — but any context could post it by hand, so it was removed
rather than gated; both transports now get `Unknown polyfill message type`.
A message type nothing sends is still reachable: every `case` in the
handler's dispatch is API surface.

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
`Invalid call to runtime.sendNativeMessage(). <Message>.` — WebKit's prefix is
the visible difference from Chrome, and WebKit also capitalises the first
letter of the text and ends it with a full stop. The relay needs no
permission: it echoes the sender's own text (capped at 2048 characters) to the
sender.

The same rewriting applies to every failure that crosses
`runtime.sendNativeMessage`, which is every polyfill request a **worker**
makes. Measured with `history.search` refused for want of the permission
(native text `history permission not declared`):[^task-138]

| Caller | Form | Text the extension sees |
|---|---|---|
| Extension page | promise | `history permission not declared` |
| Extension page | callback | `Invalid call to runtime.sendNativeMessage(). History permission not declared.` |
| Worker | promise | `Invalid call to runtime.sendNativeMessage(). History permission not declared.` |
| Worker | callback | `Invalid call to runtime.sendNativeMessage(). Invalid call to runtime.sendNativeMessage(). History permission not declared.` |

So a test, or an extension, that looks for a native error text has to search
for it as a substring and ignore case.

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
| [ExtensionHistoryScopeTests](../../DetourTests/ExtensionHistoryScopeTests.swift) | `chrome.history.search` through the same production wiring, one extension in two profiles: isolation, the permission gate, bad arguments and the default range from an extension page and a worker, promise and callback form |
| [ExtensionFaviconScopeTests](../../DetourTests/ExtensionFaviconScopeTests.swift) | `_favicon` through the same wiring: one extension in two profiles, another profile's WebKit host, a tab's handler, the `favicon` permission, the Private profile, what a worker's `fetch` gets, and the removed `favicon.lookup` message from a page and a worker |

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
[^task-138]: chrome.history.search returns history from every profile
[^task-152]: favicon.lookup answers from every profile's history, without a permission check
[^task-153]: chrome.history.search with empty text scans every visit of the profile
[^chrome-history-api]: Chromium, history_api.cc (HistorySearchFunction)
