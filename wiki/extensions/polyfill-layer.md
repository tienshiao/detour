---
type: Component
title: Polyfill layer
description: The JavaScript bundle Detour evaluates in every extension context and the native handler behind it — how it is injected, how a request reaches Swift, how the sender is verified, and how callback-style calls get runtime.lastError.
resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
tags: [extensions, polyfill, security, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T09:42:23Z }
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
  - id: task-255
    resource: backlog:TASK-255
    title: "Extensions: native polyfill errors read differently from the worker and from a page"
  - id: task-262
    resource: backlog:TASK-262
    title: "Extensions: polyfill error envelope edge cases (browser.runtime.lastError identity, envelope key collision)"
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
  - id: task-234
    resource: backlog:TASK-234
    title: notifications.clear issued while notifications.create is still adding the notification is lost
  - id: notification-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionNotificationManager.swift
    title: ExtensionNotificationManager.swift
  - id: task-238
    resource: backlog:TASK-238
    title: "Extensions: one profile's notifications are visible to and clearable by the same extension in another profile"
  - id: task-239
    resource: backlog:TASK-239
    title: "Extensions: the notifications API is available without the notifications permission"
  - id: task-251
    resource: backlog:TASK-251
    title: "Extensions: the history and management namespaces exist for extensions without the permission"
  - id: task-250
    resource: backlog:TASK-250
    title: "Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions"
  - id: task-257
    resource: backlog:TASK-257
    title: "Extensions: management.uninstallSelf and management.getPermissionWarningsByManifest are missing"
  - id: task-267
    resource: backlog:TASK-267
    title: "Extensions: management.uninstallSelf with showConfirmDialog can show its app-modal alert again and again with no user action"
  - id: chromium-management-api
    resource: https://source.chromium.org/chromium/chromium/src/+/main:extensions/browser/api/management/management_api.cc
    title: "Chromium: management_api.cc (Uninstall, GetPermissionWarningsByManifest) and management_api_constants.h"
  - id: chromium-api-features
    resource: https://github.com/chromium/chromium/blob/main/extensions/common/api/_api_features.json
    title: "Chromium, extensions/common/api/_api_features.json (management.getSelf etc. have no dependency)"
  - id: task-240
    resource: backlog:TASK-240
    title: "Extensions: notifications.clear and notifications.update diverge from Chrome"
  - id: task-254
    resource: backlog:TASK-254
    title: "Extensions: notifications.create(null, options) is treated as create(options) with empty options"
  - id: task-269
    resource: backlog:TASK-269
    title: "Extensions: notifications.create with an empty id keeps it instead of generating one"
  - id: chrome-notifications-api
    resource: https://developer.chrome.com/docs/extensions/reference/api/notifications
    title: chrome.notifications API reference
  - id: task-253
    resource: backlog:TASK-253
    title: "Extensions: Detour never requests notification permission, so extension notifications may never be shown"
  - id: task-247
    resource: backlog:TASK-247
    title: "Extensions: notifications.onClicked and onClosed are never delivered to the extension"
  - id: task-264
    resource: backlog:TASK-264
    title: "Extensions: a Private-profile extension stops receiving notifications.onClicked and onClosed once a Private session starts or ends"
  - id: task-270
    resource: backlog:TASK-270
    title: "Extensions: revoking the notifications permission leaves the extension's notifications and event wait in place"
  - id: task-271
    resource: backlog:TASK-271
    title: "Extensions: a notifications.update whose add fails also removes the notification it was updating"
  - id: task-272
    resource: backlog:TASK-272
    title: "Extensions: notification entries outlive the banner when macOS takes it away without a dismiss"
  - id: chromium-mac-notification-service
    resource: https://source.chromium.org/chromium/chromium/src/+/main:chrome/services/mac_notifications/mac_notification_service_un.mm
    title: "Chromium: mac_notification_service_un.mm (shouldPreventNotificationDismissalAfterDefaultAction, SynchronizeNotifications), chrome/browser/notifications/mac/notification_utils.cc (by_user)"
  - id: chromium-notifications-clear
    resource: https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/extensions/api/notifications/
    title: "Chromium: notifications_api.cc (clear), extension_notification_handler.cc (OnClose), notification_ui_manager_impl.cc (CancelById)"
  - id: task-248
    resource: backlog:TASK-248
    title: "Extensions: notifications left from an earlier launch stay in Notification Center and can no longer be cleared"
  - id: task-273
    resource: backlog:TASK-273
    title: "Extensions: an unanswered notification authorization prompt stalls notifications.create in every profile"
  - id: task-276
    resource: backlog:TASK-276
    title: "Docs: fix the permission-scope and notification-ordering descriptions the review found wrong"
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

## Per-request gates

WebKit does not permission-check APIs it does not implement, so the handler
does:

- `history.search`, `management.getAll`, `management.setEnabled` and every
  `notifications.*` request require the manifest permission
  (`hasPermission`), checked before anything else the request is
  answered with.[^task-239]
- `history.search` answers from the handler's own profile only; see
  [chrome.history](#chromehistory-is-profile-scoped) below.
- `runtime.getURL('/_favicon/…')` is not a handler request at all: the
  polyfill rewrites it to `detour-favicon://`, and the scheme handler gates it
  on `favicon` and on the profile; see
  [favicons](#favicons-are-profile-scoped) below.
- `offscreen.*` uses only the handler's own profile's context.
- `sessions.restore` and `search.query` act in `targetSpace()`, which is
  `tabs.create`'s rule (`ExtensionManager.newTabSpace(for:)`): a normal
  profile's most recently used space, never another profile's (TASK-226;
  before, the global last active space when it was this profile's, else the
  profile's first). See [opening a tab](./tab-and-window-bridge.md#opening-a-tab).
- Gap-filling namespaces that Chrome leaves undefined without a permission
  (`privacy`, `webRequest`, `notifications`, `history`) are installed only when the
  manifest declares it, so feature detection stays truthful.[^task-3] Before
  TASK-239 `notifications` was installed for every extension and the handler
  served it unchecked. Both sides gate: the bundle gate is what the extension
  sees, the handler's is what holds against a caller that goes straight to
  `__detourPolyfillRequest`. Without the permission WebKit vends no
  `notifications` namespace of its own either (measured from a page and a
  worker in `ExtensionNotificationOrderingTests`).[^task-239]
- `history` and `management` were installed whole for every extension until
  TASK-251, gated only in the handler. Now `history` is absent without its
  permission, and `management` without its permission holds `getSelf` alone.
  Chromium's `extensions/common/api/_api_features.json` gives `management` the
  dependency `permission:management` but gives `getSelf`, `uninstallSelf` and
  `getPermissionWarningsByManifest` empty dependencies, and since TASK-257
  Detour implements all three ([below](#the-permission-free-management-methods)).
  WebKit vends neither namespace (measured from a
  page and a worker in `ExtensionHistoryScopeTests`: with neither permission
  `chrome.history` is undefined and `chrome.management` has only Detour's
  permission-free methods).[^task-251] In a plain `WKWebView` (the `ExtensionPolyfillTests`
  harness) `browser` is a separate object from `chrome`, so the alias can only
  be checked in a real context.
- Since TASK-250 those three namespaces also install for a permission listed
  only under `optional_permissions`, and the handler refuses each call until
  the profile's context holds the grant, and again after a revocation. Chrome
  adds a granted namespace to running contexts; installing ours on a later
  event would leave a restarted worker's top-level code without it. The rule
  and the WebKit behaviour behind it are in
  [Permissions](./permissions.md#permissions-the-polyfill-gates).[^task-250]

## The permission-free management methods

`getSelf`, `uninstallSelf` and `getPermissionWarningsByManifest` are in
`chrome.management` with or without the `management` permission, as in
Chrome.[^task-257]

`uninstallSelf(options?, callback?)` goes to
`ExtensionManager.uninstallSelf`, which ends in `uninstall(id:)`, the path
Settings' Uninstall button takes. It acts only on the verified caller.

| Rule | Detail |
|---|---|
| Scope | Every profile. Detour installs an extension once and each profile only turns it on or off, so an uninstall cannot be per profile. Chrome's profiles install separately, so Chrome removes it from the calling profile only |
| `showConfirmDialog: true` | An `NSAlert` in the Settings style: "Uninstall "X"?", saying the extension asked, Uninstall / Cancel. Tests answer it through `uninstallSelfConfirmationAnswerOverride`. A second call while one alert is up is refused |
| Cancel | Rejects with Chromium's `kUninstallCanceledError`: `Extension <id> uninstall canceled by user.` |
| Order | The reply (`undefined`) goes first, and the uninstall runs on the next main-actor turn. The uninstall unloads the caller's worker and closes its pages, so the reply may still never arrive. Chrome uninstalls first and then answers |
| Arguments | `options` absent, null or an object; `showConfirmDialog` absent, null or a boolean. Anything else is refused (`management.uninstallSelf: options must be an object`) |
| A second dialog | Refused at once, with the cancel text, while the extension's alert is up. The claim is taken before the alert's task runs, because WebKit can hand two messages over in one batch. A call without a dialog is not affected |
| After a Cancel | For 10 minutes from the Cancel (`ExtensionManager.uninstallSelfCancelCooldown`), the extension's requests for the dialog are refused at once with the cancel text and no alert. Per extension; a call without a dialog is not affected; the clock is `ExtensionManager.now`, a test seam; a time before the Cancel (clock set back) does not refuse; `uninstall(id:)` forgets the Cancel[^task-267] |
| Not carried over | Chrome refuses a dialog without a user gesture (`kGestureNeededForUninstallError`). The polyfill has no gesture signal, so Detour shows the dialog anyway, and the cooldown above stands in for the gesture check |

Without the cooldown a worker that called again after every Cancel kept the
app-modal alert up, naming itself with its manifest's name at a moment it
chose. Chrome's gesture check still lets a user retry at once; a block for the
whole session would refuse a deliberate retry until relaunch. Ten minutes caps
a looping worker at one alert per period, which leaves time to remove or turn
off the extension in Settings. `permissions.request` prompts for `history` and
`management` cannot loop this way: a denial is saved, and later requests are
refused without asking.[^task-267]

`getPermissionWarningsByManifest(manifestStr)` returns the lines Detour's
install prompt shows for the manifest: its required permissions, each through
`ExtensionPermissionDescriptions.describe`, then its `host_permissions`
(`<all_urls>` reads "All websites"). It leaves out `optional_permissions`, as
Chrome does. `ExtensionPermissionDescriptions.warnings` builds the list, and
the prompt's `formatForAlert` uses the same host wording.

This is not Chrome's list. Chrome leaves out permissions that carry no warning
(`storage`, `alarms`), merges hosts and adds content-script matches. Detour's
prompt names every permission it is asked for, so this list does too. Errors
use Chromium's `management_api_constants.h` texts:

| Input | Error |
|---|---|
| Malformed JSON, or JSON that is not an object | `Failed to parse manifest.` Chrome uses its JSON parser's message for malformed JSON. Detour does not reproduce that message |
| An object `ExtensionManifest` cannot decode (no `name`, `version` or `manifest_version`) | `Failed to create extension from manifest.` |
| Not a string | `management.getPermissionWarningsByManifest: manifestStr must be a string` |

Both are tested from a page and a worker, in the promise and the callback
form, in `ExtensionManagementSelfTests`.

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

## chrome.notifications applies calls in the order they were made

`ExtensionNotificationManager` (one shared instance for every profile; each
profile's handler reaches it through `notificationManager`) records a notification when `create` is
called, before `UNUserNotificationCenter.add` returns. An extension that does
not await `create` before `clear` or `update` therefore gets what it asked
for:[^task-234]

| Calls, none awaited | Result |
|---|---|
| `create('x')`, `clear('x')` | The clear drops the entry at once and removes the notification; when the `add` returns, the manager removes it once more, because the clear's removal can reach the center before the notification does. `getAll` does not list it |
| `create('x')`, `update('x')` | The update finds the entry and re-creates it; `wasUpdated` is `true` and the update's content shows |
| `create('x')`, `clear('x')`, `create('x')` | The clear drops the entry with its UNNotification identifier, so the second `create` gets a new identifier. When the first `add` returns it finds no entry under its own identifier and removes only that identifier's notification; the second `add` shows the second one, which stands. A first create still waiting for authorization finds its entry gone and never adds.[^task-276] Generations decide `create('x')`, `create('x')` with no clear between: the second keeps the identifier, so the first `add` finds a newer generation, leaves the entry alone and lets the newer `add` replace what it showed |

`getAll` lists a notification whose `add` is still in flight. A failed `add`
of a `create` drops the entry only if no later `create` or `update` has
replaced it, and also removes any notification shown under that id, so
`getAll` and the screen agree. A failed `add` of an `update` answers
`wasUpdated: false` and puts back the entry the update replaced, so the
notification the create (or an earlier update) showed stays listed, shown and
merged into by the next update, as in Chrome.[^task-271] Each update entry
keeps the entries it replaced, newest first, as fallbacks; one whose `add`
fails, or is skipped because it was superseded during the authorization wait,
is dropped from them (nothing of it shows), and one whose `add` succeeds
discards the older ones, so the list lasts only while adds are in flight.
Before TASK-234 the entry was recorded only after `add` returned, so a clear issued
meanwhile found nothing and the notification came back.

Rejected: serializing the operations per notification id. It would also make
calls apply in order, but it needs a queue per id, makes `clear` wait for the
`add`, and still has to decide what `getAll` says in between.

The manager talks to the center through `ExtensionNotificationCenter` (`add`,
`removeNotifications`, `authorizationStatus`, `requestAuthorization`,
`deliveredIdentifiers`, `pendingIdentifiers`), a seam
for tests: `HeldNotificationCenter` holds every `add`, and optionally every
authorization prompt, until the test releases it.[^notification-manager]

## Notifications left by an earlier launch are removed at launch

The manager's map from identifier to owner lives in memory only, so a
notification still in Notification Center after a relaunch belongs to nobody:
a click on it is ignored and the extension's `clear` cannot reach it. At
launch `AppDelegate` calls `removeLeftoverNotifications()`, which lists
delivered and pending identifiers and removes every one shaped like an
extension notification of any build:[^task-248]

| Form | Builds | Matched by |
|---|---|---|
| `detour-ext-notification.v3\|<UUID>` | since TASK-238's second pass | prefix |
| `detour-ext-notification.v2\|<profile>\|<ext>\|<id>` | TASK-238's first pass | prefix |
| `<extension id>:<id>` | before TASK-238 | the id must be 32 letters a–p (a CRX key's) or a UUID string (an unpacked extension with no key), anchored at the start |

- Nothing else in Detour posts a UNNotification today (downloads and the
  updater do not; Sparkle could only with gentle reminders, which Detour does
  not enable), but the legacy form is still anchored on the extension id's
  shape rather than "anything with a colon", so a later poster is safe unless
  its identifiers start with such an id and a colon.
- Identifiers this launch has an entry for are kept: the filter runs after the
  listing returns, so a create made while it was in flight survives. No need
  to run before the first extension loads.
- Not gated on authorization: listing never prompts.
- Skipped in the XCTest host (launch runs before the bundle installs its fake
  center) and whenever another process with Detour's bundle id is running:
  the production app and a `DETOUR_DATA_DIR` run share one Notification
  Center, and one would take the other's live notifications for leftovers.
  A run that skips it says so in a `notice` log line.

`create(notificationId?, options, callback?)` follows Chrome's signature: a
`null` or `undefined` id counts as absent, so the options are used and an id is
generated. Only a non-null object in the first slot means the id was left out
(`typeof null` is `'object'`, which once made `create(null, options)` create
an empty notification).[^task-254]
An empty id is generated too, as Chrome's is for one "not set or empty":
`ExtensionNotificationManager.create` replaces `""` with a fresh UUID, so
`create('', …)` twice makes two notifications and `getAll` never lists `""`.
Before, the empty id was kept and every such create replaced the last.[^task-269]

## chrome.notifications asks for authorization at the first create

Detour asks for notification authorization the first time any extension calls
`notifications.create` (a product decision; at install or from Settings were
the alternatives), and that create waits for the user's answer. Before
TASK-253 nothing asked, so on a fresh install `create` reported success and
nothing appeared.[^task-253]

- Every create and update asks the center for the status first, so a change
  the user makes in System Settings applies to the next call. `provisional`
  counts as allowed (`ephemeral` is unavailable on macOS).
- One check at a time: creates and updates arriving while the status query or
  the prompt is in flight wait on that check, so one prompt answers them all.
  They resume in call order (a list of continuations; awaiting a shared
  `Task`'s `value` resumed four waiters in reverse order, which reorders the
  adds).
- The entry is recorded before the wait, as before the `add`, so a `clear`
  during the wait answers true and an `update` merges into the waiting
  create. A create cleared or superseded during the wait never calls `add`:
  the superseding update or create adds its own, and skipping the stale one
  keeps it from landing after the newer content.
- Not allowed (declined now or earlier): `create` answers its id, as Chrome
  does when the OS blocks notifications, but nothing is shown and the entry
  goes, so `getAll` does not list it and `clear` and `update` answer false
  for it. A notification shown earlier under that identifier is taken away,
  since the extension no longer has it.
- The prompt is a banner ("“Detour” Notifications", Allow / Don't Allow). The
  unified log shows it as a NotificationCenter record with
  `app:"com.apple.notificationcenter.askpermissions" req:"com.detourbrowser.mac"`.
  On the development Mac the bundle id was still not determined in the TASK-253
  run, which is why earlier runs saw `add` succeed with nothing on screen.
  A Debug build shares `com.detourbrowser.mac` with the installed app, so
  answering a Debug build's prompt sets the installed app's permission too.
- The wait for the answer is bounded (TASK-273). Once the prompt has been up
  for `authorizationAnswerTimeout` (5 s), every create and update waiting on
  it is answered, a create with its id and an update with true,
  and one joining that check later is answered at once. Each stays recorded
  (listed, clearable, updatable) and is shown when the user allows
  notifications, or dropped as above if they decline. Before, a prompt the
  user ignored into Notification Center left every `await create(...)` in
  every profile hanging.[^task-273]
  - Why answer rather than refuse: Chrome's `create` answers once the
    notification is handed to its display service and never waits on the OS
    permission, so answering is the closest match. The 5 s still lets a user
    who answers the prompt at once give the real answer, and it is well inside
    WebKit's 30 s unload timer for a worker whose reply is pending.
  - The timeout is scheduled only when the status is not determined, right
    before the prompt, through the `scheduleAuthorizationTimeout` seam, so
    tests fire it by hand. A check that only reads the status (every create
    once allowed) schedules none. A timeout that fires after its check
    finished does nothing (checks are numbered).
- While the prompt is up, at most `authorizationWaitLimit` (32) of one
  owner's creates and updates wait on it; another owner's are counted
  separately, and a burst joining a status-only check is never limited.
  Shows cleared or superseded while waiting still count, as each still holds
  a waiting task. One more is
  settled as a failed `add` would be: a create answers its id but is neither
  listed nor added, and an update answers false and puts back the entry it
  replaced (the TASK-271 fallback). Without the limit an extension creating in
  a loop, which the early answers make fast, would pile up waiting tasks and
  update fallbacks until the user answered.[^task-273]

## chrome.notifications events reach the background through a parked request

`notifications.onClicked` and `onClosed` fire in the background context of the
owner (profile and extension) whose notification it was, and nowhere
else.[^task-247] There is no push channel into a context (see Gotchas), so the
first `addListener` on either parks a `notifications.awaitEvent` request,
which the manager answers with the owner's unacknowledged events
`{events: [{seq, kind, notificationId, byUser?}]}`. The polyfill dispatches
them in order and parks again with `ack` = the last `seq`.

| Event | Fires |
|---|---|
| Click on the banner (`UNNotificationDefaultActionIdentifier`) | `onClicked(id)`, then `onClosed(id, true)`, in one answer; the entry goes (macOS takes a clicked banner away) |
| User dismisses it (`UNNotificationDismissActionIdentifier`) | `onClosed(id, true)`; the entry goes, so `clear`/`update` answer false and `getAll` leaves it out |
| The center stops listing it without a report (Clear All?, system pruning) | `onClosed(id, true)` at the next synchronization; the entry goes |
| The extension's `clear` finds it | `onClosed(id, false)` |
| Unload of the extension, end of the profile or Private session, not-allowed or failed add | nothing |

- **Dismissals need a category.** Every notification carries the
  `detour-ext-notification` category with `.customDismissAction`
  (`ExtensionNotificationManager.dismissCategory`); without it macOS never
  reports a dismissal. The system center registers it alongside any other
  category (`setNotificationCategories` replaces the set). The registration
  is awaited before the first authorization check, so no banner is shown
  before its category exists.
- **Chrome's clear fires `onClosed(byUser false)`.** `notifications.clear` →
  `ExtensionNotificationDisplayHelper::Close` → the display service →
  `NotificationUIManagerImpl::CancelById` → `MessageCenter::RemoveNotification(id,
  /* by_user */ false)` → `ExtensionNotificationHandler::OnClose`, which sends
  `onClosed` with `by_user`.[^chromium-notifications-clear] That is the
  message-center path; Chrome's native macOS bridge was not traced.
- **Acknowledged, not answered.** An event stays in the per-owner backlog
  (at most 32, oldest dropped) until a park acknowledges it. A parked reply
  whose worker WebKit has unloaded goes nowhere and nothing says so; the next
  incarnation's first park acknowledges nothing and receives the events again.
  The polyfill skips a `seq` it has already dispatched.
- **The park keeps nothing alive.** It is a pending `runtime.sendNativeMessage`,
  not a port or a permission request, so WebKit's idle unload ignores it.
  Measured: a worker parked and left alone was replaced by a new incarnation
  within 45 s (the gated leg `testAClickAfterTheWorkerUnloadsWakesItAndIsDelivered`,
  `TEST_RUNNER_NOTIFICATION_UNLOAD_LEG=1`). So parking for every listening
  extension is safe, and parking only while it has live notifications was
  not needed.
- **An event wakes the background.** Once an owner has parked this launch, each
  event calls `loadBackgroundContent` on its context (a no-op while it is
  loaded), as Chrome starts a worker for an event it listens to. The new
  worker's top-level `addListener` parks and drains the backlog. An owner
  that never parked is never woken; its events wait in the backlog.
- **A newer incarnation supersedes.** The park carries `__detourContextInstance`.
  A token not seen before settles the parked request with "superseded" and
  takes its place; from then on an older token is refused, so an old worker
  still running beside its replacement (`runtime.reload()`) cannot take the
  park back and ping-pong.
- **Background only.** The handler refuses `awaitEvent` from any sender that
  fails `senderIsBackgroundContext`. Chrome fires these events in every
  context with a listener; Detour does not deliver them to popups, options
  pages or extension tabs. A page's park would need its own slot per page
  instance and nothing tells the manager a page closed, so dead pages'
  replies would pile up; extensions handle clicks in the background in
  practice. Rejected for now, not ruled out.
- **A refused wait stops, with one exception.** A refusal for "not the
  background", "superseded", "unloaded" or "profile gone" is final for that
  context. A refusal for the permission (an optional `notifications` not yet
  granted) is retried at the next `create`/`update`/`clear`/`getAll` while a
  listener exists, so the grant does not leave the worker deaf until restart.
- **A Private session boundary leaves the park standing.** The Private
  profile's contexts stay loaded between sessions, so a session starting or
  ending (`removeSession(profileID:)`) takes the notifications and the
  events queued for them but keeps each owner's park, incarnation history
  and "listens" flag. Only unloading the extension (`removeAll(for:)`) and
  deleting the profile (`removeAll(profileID:)`) answer the park "unloaded"
  and forget the channel. Before TASK-264 the boundary used `removeAll(profileID:)`
  too: the live worker took "unloaded" as final, never parked again, and
  every later click and close waited unheard in the backlog until WebKit
  restarted it.[^task-264]
- **Losing the permission answers the park with the refusal.** When
  `notifications` stops being active for an extension in a profile (the
  Settings switch off, a prompt answered Deny, or the extension's own
  `permissions.remove` of the optional permission), its notifications there
  go, with their queued events, and the park is answered with the handler's
  permission refusal ("denied by the user" or "is optional and has not been
  granted"), which the polyfill retries after a later grant. "Unloaded" would
  have stopped the worker for good. The incarnation history stays, so the
  same worker's re-park is accepted. Before TASK-270 nothing happened: the
  banners stayed, a click on one still fired `onClicked` through the park
  admitted before the revocation, and the extension could not `clear` them
  (refused for the permission). No `onClosed` fires for the notifications
  taken away: the extension no longer holds the permission whose events those
  are.[^task-270]
- **The banner going ends the notification.** macOS removes a banner when
  its default action is clicked; Chrome keeps its own only by setting the
  private `shouldPreventNotificationDismissalAfterDefaultAction` on the
  content,[^chromium-mac-notification-service] which Detour does not. Before
  TASK-272 a click kept the entry, so an extension using `create(null, …)`
  that never cleared grew the entries all session, `getAll` listed banners
  no longer shown, and a later `update` brought the banner back. A click now
  drops the entry, asks the center to remove the identifier too (should
  macOS ever keep the banner, nothing could clear it otherwise), and fires
  `onClicked` then `onClosed(byUser true)`: what
  Chrome reports when a notification leaves Notification Center without a
  dismissal (its `SynchronizeNotifications` turns every such one into a
  close, and every macOS close reaches the extension with `by_user`
  true).[^task-272] An update whose `add` is in flight when the click comes
  finds no entry when it lands and takes the banner it re-showed away, as
  after a clear during the `add`; it still answers `wasUpdated: true`.
- **Synchronization catches the rest.** `synchronizeWithCenter()` lists the
  center's delivered and pending identifiers and closes (`onClosed(byUser
  true)`, entry dropped, identifier removed from the center in case the
  listing missed it) every entry it does not list, like Chrome's
  `SynchronizeNotifications`. Pending is listed before delivered: a request
  only moves from pending to delivered, so one moving between the two calls
  is still seen. It runs at every `create` (coalesced, and at most once per
  5 s, so an extension that never clears cannot outgrow what is on screen
  and one re-creating a progress notification does not list usernoted at
  every call) and every 10 minutes (Chrome's `kSynchronizationInterval`)
  while there are entries.
  Only entries whose own `add` succeeded at least 5 s ago are checked: the
  center may list a notification a moment after `add` answers, and an entry
  with an `add` in flight (an update over a banner the center lost) shows
  it again, as Chrome skips pending content. An entry cleared, clicked,
  replaced or removed with its owner while the listing was in flight is
  skipped, so a revoked owner gets no `onClosed`. The clock is injectable
  (`now`).
- **What "Clear All" reports was not measured.** Producing a real banner
  from a Debug build needs notification authorization for
  `com.detourbrowser.mac`, which on the development Mac was still
  undetermined (no usernoted records for it); answering that prompt also
  sets the installed app's permission, which is the user's decision, and
  Clear All would have to be driven in the Notification Center the running
  production Detour shares. The design holds either way: a reported
  dismissal closes through `handleResponse`, an unreported one at the next
  synchronization. Chrome polling at all suggests some removals go
  unreported.
- `onButtonClicked` still never fires: buttons are not shown.

The manager-level behaviour is in `ExtensionNotificationEventManagerTests`, the
real-worker behaviour (profile isolation, byUser, backlog before the park,
`runtime.reload()` superseding, a Private worker hearing events across session
boundaries, the Settings switch and `permissions.remove` taking the
notifications and the wait) in `ExtensionNotificationEventDeliveryTests`.

## chrome.notifications is scoped by profile

The system center has one delegate, so one manager serves every profile, and
every notification belongs to an `Owner`: the handler's profile plus the
verified extension id, never anything from the request body. The same
extension installed in two profiles, the Private one included, is two owners.
Before TASK-238 the key was the extension id alone, so a normal-profile copy
listed, cleared and updated what its Private copy had created, and the reverse
also held.[^task-238]

| What | Scoped how |
|---|---|
| `getAll` | lists only the calling owner's entries |
| `clear`, `update` | find the owner's own notification; another profile's notification with the same id is untouched (both answer false and take nothing away) |
| The UNNotification identifier | opaque: `detour-ext-notification.v3\|<random UUID>`, one per notification, mapped back to (owner, id) by the manager only. Each owner's notification has its own, so one profile's `create` never replaces the other's banner and one profile's `clear` never takes it away. An `update` keeps the identifier (the center replaces the banner); a notification cleared and created again gets a new one |
| A click or close | `handleResponse` resolves the identifier to its owner and id and returns it; a close drops only that entry |

The identifier is opaque because usernoted keeps delivered identifiers on
disk. The first TASK-238 draft used
`detour-ext-notification.v2|<profile UUID>|<extension id>|<id>`; for Private
the profile UUID is the well-known constant `TabStore.incognitoProfileID`, so
the system's store would have recorded which notifications came from Private,
and what the extension called them. The content handed to the center carries
only title, body and subtitle: no `threadIdentifier`, no `userInfo`.[^task-238]

Identifiers from earlier builds (`<extensionID>:<notificationID>` before
TASK-238, the v2 form) match no entry, so a click or close on one still on
screen is ignored. The map lives in memory only, so the same holds for a v3
identifier left over from an earlier launch.

### An owner's notifications go with its scope

Entries would otherwise outlive what created them, and the Private profile's
id is a constant, so a Private session's notifications would carry over into
the next one. They are taken away, from `getAll` and off screen (delivered
and pending), when:

| When | Called from | Manager call |
|---|---|---|
| The extension is unloaded from a profile: disabled there, uninstalled, updated, or its context reloaded by background recovery | `Profile.unloadExtension` → handler `removeNotifications(ofExtension:)` | `removeAll(for: owner)` |
| The profile is deleted | `TabStore.deleteProfile`, after `unloadAllExtensions` → handler `removeAllNotifications()` | `removeAll(profileID:)` |
| The Private session ends: the last Private window's space is removed, or the last Private Quick Detour closes or switches profile | `TabStore.endPrivateSessionIfUnused()`, the one place that also calls `siteSettings.discardPrivateSession()` | `removeSession(profileID: incognitoProfileID)` on the Private profile's handler (`removeSessionNotifications()`): the notifications and their queued events go, the workers' parks stand (TASK-264) |
| A Private session starts (a Private window's space or a Private Quick Detour, when none was live): the Private profile's contexts stay loaded between sessions, so a worker can create one while no Private page is open | `TabStore.startPrivateSessionIfNeeded()`, from `addIncognitoSpace` and `openQuickDetourTab` | the same |
| The app quits, which ends the Private session without closing its windows | `applicationWillTerminate` → `TabStore.removePrivateProfileNotifications()`; best effort, the request may not reach usernoted before exit | the same |
| `notifications` stops being active for the extension in the profile (`permissionIsActive`): a Settings switch or prompt answer, or the extension's `permissions.remove`. Decisions are per extension, so a removal in one profile clears the saved grant and every profile's context loses it | `ExtensionManager.applySavedDecisions` (from `setPermissionDecision` and `clearRemovedGrants`) and `contextDidLoseGrants` → `revokeNotificationsWhereNotPermitted` → each profile's handler `revokeNotificationsIfNotPermitted(ofExtension:)`, which does nothing while the permission is active | `revoke(for: owner, refusal:)`: the notifications and queued events go, the park is answered with the permission refusal, the channel stays (TASK-270) |

A notification whose `add` is still in flight when its owner goes is taken
away again when the `add` returns, as after a `clear`. The handler's removals
use the shared manager only if something created it this launch
(`sharedIfCreated`), so ending a session never sets up the system center.
A persistent profile's notifications still on screen when the app quits stay
there until dismissed; the next launch cannot map their identifiers back, so
a click on one is ignored and `clear` or `create` with the same id no longer
reaches it (before TASK-238 the fixed `<extensionID>:<id>` identifier did,
by accident).

### What clear and update answer, and what a notification shows

As in Chrome, whose `clear` "resolves to indicate whether a matching
notification existed"[^chrome-notifications-api] (Chromium's
`NotificationsClearFunction` answers the display helper's `Close`), `clear`
answers true only when the owner had the notification, one whose `create` is
still in flight included, and false for a missing, already cleared or refused
id and for another owner's. Before TASK-240 it always answered true.

`update` merges the given options into the notification's, as Chromium's
`NotificationsUpdateFunction` copies the existing notification and
`UpdateNotification` applies only the fields passed: an update that sets only
`message` keeps the title. The entry keeps the merged options, so updates
compose, one made while the `create` is in flight included; a `null` field
counts as not given. Before TASK-240 the update replaced the whole options
object.[^task-240]

The content follows Chrome's macOS bridge (`CreateMacNotificationContext`
returns `context_message` for a notification that needs no origin attribution):

| Option | Shown as |
|---|---|
| `title` | title |
| `message` | body |
| `contextMessage` | subtitle |
| `iconUrl` | nothing: the banner shows Detour's icon. An attachment would need the extension-relative URL loaded into a file first. Before TASK-240 the URL itself was the subtitle |
| `imageUrl`, `buttons`, `items`, `progress`, `priority`, `eventTime`, `requireInteraction`, `silent` | nothing (no sound is ever set, so `silent` holds by default) |

`handleResponse` returns the resolved response, and nothing delivers it yet:
`notifications.onClicked` and `onClosed` never fire (see Gotchas). Delivery
would start there and go to the returned owner's profile only.

## Callback form and `runtime.lastError`

Every promise-backed polyfill API takes an optional trailing callback and
routes through `__detourSettle`. With no callback the promise is returned
untouched. With one, a rejection must run the callback with no arguments while
`chrome.runtime.lastError` is `{ message }`, as Chrome does. How that is
achieved depends on the runtime object (`__detourCallbackLastError.lastMode`):

| Mode | When | What happens |
|---|---|---|
| `js` | `lastError` can be redefined, verified by reading it back | A getter is installed for the callback and the original restored; an unread error is reported as `Unchecked runtime.lastError: …` |
| `native-relay` | WebKit's real runtime | The message is bounced off Detour through the callback form of `runtime.sendNativeMessage` with type `runtime.lastErrorRelay`. The native side always fails with that text, so WebKit runs the callback inside its own `lastError` scope; the relay's callback first puts the original text back on WebKit's `lastError` object (below) |
| `console` | Neither is possible | The callback runs without `lastError`; the message goes to `console.error` |

WebKit's `runtime.lastError` reports as a configurable data property, yet
`defineProperty`, assignment and `delete` all complete without effect and reads
stay `null`. A "configurable" check is therefore not enough; the write has to
be read back.[^task-23]

## Error text from both transports

WebKit rewrites every error that crosses `runtime.sendNativeMessage`
(`toErrorString` in WebKit's `WebExtensionUtilities.cpp`): it trims dots from
both ends of the text, capitalises the first letter, and makes it
`Invalid call to runtime.sendNativeMessage(). <Text>.` Before TASK-255 the
extension saw that rewrite on three of the four legs. Measured with
`history.search` refused for want of the permission (native text
`history permission not declared`):[^task-138]

| Caller | Form | Text before TASK-255 |
|---|---|---|
| Extension page | promise | `history permission not declared` |
| Extension page | callback | `Invalid call to runtime.sendNativeMessage(). History permission not declared.` |
| Worker | promise | `Invalid call to runtime.sendNativeMessage(). History permission not declared.` |
| Worker | callback | `Invalid call to runtime.sendNativeMessage(). Invalid call to runtime.sendNativeMessage(). History permission not declared.` |

Now every leg reads `history permission not declared`, the handler's text
verbatim:[^task-255]

- **Worker requests** set `errorEnvelope: true`. `handleNativeMessage` then
  answers a failure as a *successful* reply
  `{ __detourPolyfillError: <text> }` (`ExtensionPolyfillHandler.errorEnvelopeKey`),
  and `__detourPolyfillRequest` rejects with that text. Stripping the prefix
  alone would not do: the capital letter and the trimmed dots cannot be undone.
  The relay ignores the flag, since it must fail for WebKit to set `lastError`.
- **A success on the envelope path is wrapped too**, as
  `{ __detourPolyfillOk: true, value: <result> }` (`successEnvelopeKey`,
  `replySuccess`; `value` is left out for a nil result, which reads as
  `undefined`). Otherwise a handler result that is a map with the error key
  (notification ids are the extension's own keys in `notifications.getAll`)
  would be read as a failure. The polyfill rejects a reply in neither shape
  with `Malformed polyfill reply`, so a test stub of the worker's
  `sendNativeMessage` must answer with the success envelope.[^task-262]
  The delegate's own refusals before the handler (`Unrecognized extension
  context`, `No polyfill handler for profile`) use the same
  `ExtensionPolyfillHandler.replyFailure`.
- **An error WebKit still delivers as one** (a non-object payload, WebKit's
  own limits such as too many active native message requests) loses exactly
  `Invalid call to runtime.sendNativeMessage(). ` and the full stop WebKit
  appended. Any other text is left as it is. The capital stays.
- **The callback form**: WebKit's `lastError` is a JS `Error` made per report
  (`makeErrorValue` in `WebExtensionAPIRuntime.cpp`) whose `message` is an own,
  configurable property. Inside the relay's callback the polyfill reads it and
  redefines `message` as the original text, then runs the extension's
  callback. In a worker `browser.runtime` is the same object as
  `chrome.runtime`, and both hand back the same `lastError` object, so
  `browser.runtime.lastError.message` reads the original text as well
  (measured in the test host, TASK-262). Reading `lastError` marks it checked for WebKit, so **in
  `native-relay` mode nothing reports an unchecked `lastError` any more**.
  Reporting it from the polyfill, keyed on reads of `message`, was tried and
  rejected: no read of WebKit's native getter can be observed, so a callback
  that handles the error with `if (chrome.runtime.lastError) return;` would be
  reported as unchecked. A false report on correct code was judged worse than
  no report on code that ignores the error; the handler still logs every
  failure on the Swift side.

Real `runtime.sendNativeMessage` and `connectNative` calls to native hosts do
not go through `__detourPolyfillRequest` and keep WebKit's text.

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
  later (`onUpdateAvailable`, `notifications.onClicked` / `onClosed` in the
  background), a relayed message from a content script
  (`webNavigation` history events), or the keep-alive native port. The other
  polyfill event objects — `idle.onStateChanged`,
  `notifications.onButtonClicked`, `history.onVisited`, `management.on*` —
  accept listeners and never fire: nothing calls their `__extensionDispatch…`
  hooks.
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
| [ExtensionNotificationManagerTests](../../DetourTests/ExtensionNotificationManagerTests.swift) | The `notifications` call orderings above against `HeldNotificationCenter`: clear or update while the `add` is in flight, create–clear–create, an `add` answering out of order or failing, another extension's clear; the same extension in another profile (getAll, clear, update, click and close resolution, legacy identifiers); opaque identifiers; `removeAll` and its hooks (Private session end in a `TabStore` of its own, profile deletion); a Private session boundary leaving a parked wait standing |
| [ExtensionNotificationOrderingTests](../../DetourTests/ExtensionNotificationOrderingTests.swift) | The same orderings from an extension page and its worker through the production wiring, with the profile's handler on a held center; one extension in two persistent profiles, and in a persistent profile plus the built-in Private profile, sharing one manager, from both transports and in both directions; the Private session ending in the shared store, and unloading the extension from one profile |
| [ExtensionFaviconScopeTests](../../DetourTests/ExtensionFaviconScopeTests.swift) | `_favicon` through the same wiring: one extension in two profiles, another profile's WebKit host, a tab's handler, the `favicon` permission, the Private profile, what a worker's `fetch` gets, and the removed `favicon.lookup` message from a page and a worker |

A new or changed API needs all three kinds, from both transports; the policy is
in `CLAUDE.md` and the reasoning in [testing extensions](./testing-extensions.md).

# Related

- [Chrome runtime patching](./chrome-runtime-patching.md) — which members can be patched at all.
- [Web Extension support](./overview.md) — the full list of polyfilled APIs.
- [Native messaging](./native-messaging.md) — the other thing the `sendMessage` delegate routes.
- [Offscreen documents](./offscreen-documents.md), [Storage](./storage.md), [Permissions](./permissions.md), [Updates](./updates.md) — the modules with their own pages.

[^task-10]: Verify polyfill bridge sender by context base URL, not extension id
[^task-13]: Give ExtensionPolyfillHandler a profile back-reference
[^task-23]: Callback-form polyfill APIs must route rejections to runtime.lastError
[^task-3]: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
[^task-138]: chrome.history.search returns history from every profile
[^task-255]: Extensions: native polyfill errors read differently from the worker and from a page
[^task-262]: Extensions: polyfill error envelope edge cases (browser.runtime.lastError identity, envelope key collision)
[^task-152]: favicon.lookup answers from every profile's history, without a permission check
[^task-153]: chrome.history.search with empty text scans every visit of the profile
[^chrome-history-api]: Chromium, history_api.cc (HistorySearchFunction)
[^task-234]: notifications.clear issued while notifications.create is still adding the notification is lost
[^notification-manager]: ExtensionNotificationManager.swift
[^task-238]: Extensions: one profile's notifications are visible to and clearable by the same extension in another profile
[^task-239]: Extensions: the notifications API is available without the notifications permission
[^task-251]: Extensions: the history and management namespaces exist for extensions without the permission
[^task-250]: Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions
[^task-257]: Extensions: management.uninstallSelf and management.getPermissionWarningsByManifest are missing
[^task-267]: Extensions: management.uninstallSelf with showConfirmDialog can show its app-modal alert again and again with no user action
[^task-240]: Extensions: notifications.clear and notifications.update diverge from Chrome
[^task-254]: Extensions: notifications.create(null, options) is treated as create(options) with empty options
[^task-269]: Extensions: notifications.create with an empty id keeps it instead of generating one
[^chrome-notifications-api]: chrome.notifications API reference
[^task-247]: Extensions: notifications.onClicked and onClosed are never delivered to the extension
[^task-264]: Extensions: a Private-profile extension stops receiving notifications.onClicked and onClosed once a Private session starts or ends
[^task-270]: Extensions: revoking the notifications permission leaves the extension's notifications and event wait in place
[^task-271]: Extensions: a notifications.update whose add fails also removes the notification it was updating
[^task-272]: Extensions: notification entries outlive the banner when macOS takes it away without a dismiss
[^chromium-mac-notification-service]: Chromium: mac_notification_service_un.mm (shouldPreventNotificationDismissalAfterDefaultAction, SynchronizeNotifications), chrome/browser/notifications/mac/notification_utils.cc (by_user)
[^chromium-notifications-clear]: Chromium: notifications_api.cc (clear), extension_notification_handler.cc (OnClose), notification_ui_manager_impl.cc (CancelById)
[^task-248]: Extensions: notifications left from an earlier launch stay in Notification Center and can no longer be cleared
[^task-253]: Extensions: Detour never requests notification permission, so extension notifications may never be shown
[^task-273]: Extensions: an unanswered notification authorization prompt stalls notifications.create in every profile
[^task-276]: Docs: fix the permission-scope and notification-ordering descriptions the review found wrong
