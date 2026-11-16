---
type: Feature
title: Favicons for extensions
description: How the polyfill turns chrome.runtime.getURL('/_favicon/…') into a profile-scoped detour-favicon:// URL, what an extension page, a frame and a worker get from it, and the favicon.lookup message that was removed.
tags: [extensions, polyfill, favicons, profiles]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: favicon-scheme
    resource: ../../Detour/Extensions/Runtime/FaviconSchemeHandler.swift
    title: FaviconSchemeHandler.swift
  - id: task-152
    resource: backlog:TASK-152
    title: favicon.lookup answers from every profile's history, without a permission check
  - id: favicon-scope-tests
    resource: ../../DetourTests/ExtensionFaviconScopeTests.swift
    title: ExtensionFaviconScopeTests
---
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

# Tests

| Suite | Proves |
|---|---|
| [ExtensionFaviconScopeTests](../../DetourTests/ExtensionFaviconScopeTests.swift) | `_favicon` through the production wiring: one extension in two profiles, another profile's WebKit host, a tab's handler, the `favicon` permission, the Private profile, what a worker's `fetch` gets, and the removed `favicon.lookup` message from a page and a worker |

# Related

- [Favicons](../features/favicons.md#the-extension-route-belongs-to-a-profile) — the scheme handler's gate and scope, and the route's known limit.
- [chrome.history](./polyfill-history.md) — the other extension reader of a profile's history, with the same scope.
- [Polyfill layer](./polyfill-layer.md) — the bundle that patches `runtime.getURL`.

[^task-152]: favicon.lookup answers from every profile's history, without a permission check
