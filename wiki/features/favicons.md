---
type: Component
title: Favicons
description: "How a tab finds its icon (an optimistic /favicon.ico guess, an early link report from a private content world, an end-of-load lookup), and the two shared loaders that hand icons to AppKit and to web views."
tags: [favicons, webkit, sidebar, caching, content-world]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
sources:
  - id: loader
    resource: ../../Detour/Browser/Shared/FaviconLoader.swift
    title: FaviconLoader.swift
  - id: link-bridge
    resource: ../../Detour/Browser/Shared/FaviconLinkBridge.swift
    title: FaviconLinkBridge.swift
  - id: png-loader
    resource: ../../Detour/Browser/Shared/FaviconPNGLoader.swift
    title: FaviconPNGLoader.swift
  - id: scheme-handler
    resource: ../../Detour/Extensions/Runtime/FaviconSchemeHandler.swift
    title: FaviconSchemeHandler.swift
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (setupObservers, fetchFavicon, pageDidReportFaviconLink, downloadFavicon)
  - id: task-112
    resource: backlog:TASK-112
    title: Some sites never get their favicon, and their sidebar rows show a stray grey box
  - id: task-53
    resource: backlog:TASK-53
    title: Favourites tiles show the globe placeholder instead of favicons on first launch
  - id: task-86
    resource: backlog:TASK-86
    title: Profile-scoped History page in a tab
  - id: task-98
    resource: backlog:TASK-98
    title: FavoriteFaviconTests fails intermittently on a clean tree
  - id: link-bridge-tests
    resource: ../../DetourTests/FaviconLinkBridgeTests.swift
    title: FaviconLinkBridgeTests.swift
  - id: favorite-favicon-tests
    resource: ../../DetourTests/FavoriteFaviconTests.swift
    title: FavoriteFaviconTests.swift
---

# Role

Detour stores no favicon image data anywhere. It persists favicon **URLs**
(on tabs, pinned entries, favourites and `historyURL` rows) and downloads the
image again when it needs one. Three pieces do the work:

| Piece | Produces | Used by |
|---|---|---|
| `BrowserTab`'s favicon pipeline | `tab.favicon` and `tab.faviconURL` | sidebar rows, tiles, the history row written at recording time |
| `FaviconLoader` | an `NSImage` for a favicon URL | tabs, pinned entries, favourites, palette rows |
| `FaviconPNGLoader` | image **bytes** for a *page* URL | `detour-favicon://` (extensions) and `detour://history/favicon` |

# How it works

## How a tab finds its icon

Three sources, in the order they usually land:

1. **Optimistic guess.** On the first URL of a new host the tab bumps
   `faviconGeneration` and downloads `<scheme>://<host>/favicon.ico`. It
   happens in `load(_:)` for programmatic navigations and in the `webView.url`
   observer for everything else. The observer also clears the old icon on a
   host change.
2. **Early link report.** `FaviconLinkBridge` injects a user script at
   document start, main frame only, in the private content world
   `DetourFavicon`. A `MutationObserver` on the whole document reports the
   first `link[rel~='icon'], link[rel='shortcut icon']` href whenever a
   `<link>` is added, removed or has its `href`/`rel` changed. The shared
   handler maps the web view to its tab through a weak-to-weak table
   (`FaviconLinkBridge.register`, called from `BrowserTab.webView`'s `didSet`
   and from the two initialisers that take a web view) and calls
   `pageDidReportFaviconLink(_:originHost:)`.
3. **End-of-load lookup.** When `isLoading` goes false, `fetchFavicon()`
   evaluates the same selector in the page and downloads the result if it
   differs from `faviconURL`. Kept as a fallback.

`downloadFavicon(from:generation:optimistic:)` applies a result only if the
generation is still current. A page-declared icon marks
`declaredFaviconGeneration`, and an optimistic result for that generation is
then discarded, so a slow `/favicon.ico` cannot replace the declared icon.

## Why the early report exists

Before TASK-112 only steps 1 and 3 existed. A tab opened in the background
loads in a hidden web view, and when several hidden pages load at once WebKit
can leave some of them loading until they are first shown. The icon link is
in the DOM long before that, but the lookup waited for `isLoading` to go
false.[^task-112] Two concrete failures:

- `raycast.com`: `/favicon.ico` is a 404; the real icon is only in
  `<link rel=icon>`.
- `swift.org/documentation/`: a JavaScript redirect to `docs.swift.org`. The
  guess for the first host succeeds, the host change clears it, the guess for
  the second host is a 404.

A standalone `WKWebView` spike reproduced the stall with no extensions and no
content blocker when ten pages were opened together, and not with two. Hosting
the web views in an off-screen or hidden window did not help; only actually
showing the tab did. So the stall is WebKit behaviour for hidden pages, and
the fix belongs in the favicon pipeline.[^task-112] The general rule: **do not
gate a background tab's metadata on `isLoading == false`**. See
[hidden web view load stalls](../platform/hidden-webview-load-stalls.md).

## FaviconLoader

Downloads with `URLSession.shared`, requires HTTP 200, decodes with
`NSImage(data:)`, and delivers on the main thread. Successful decodes are kept
in an `NSCache` keyed by favicon URL, and concurrent requests for one URL are
coalesced onto a single fetch. **Failures are not cached**, so a 404 is
retried by the next caller. `fetch` is a replaceable closure used as a test
seam.

Pinned entries and favourites call it themselves for their stored
`faviconURL` so a dormant one (no backing tab) still has an icon.
`Favorite.favicon` is `@Published` and downloaded whenever it is nil,
whatever the state of the backing tab; tiles subscribe to both the favourite's
and the backing tab's publishers. Before TASK-53 a favourite restored with a
sleeping backing tab never downloaded its own icon, and the first window's
tiles stayed on the globe.[^task-53] See [favorites](../tabs/favorites.md).

## FaviconPNGLoader

Serves bytes to web views. The caller names a **page** URL; the icon URL is
resolved natively through `HistoryDatabase.faviconURL(for:)` (exact URL, then
the most recently visited entry with the same host), so a caller can never
point it at a host of its own choosing.

- The cache (200 entries) is keyed by the resolved favicon URL plus size, not
  by page URL: a hundred history rows of one site fetch one icon.
- In-flight requests are coalesced.
- **Failures are cached** as empty data for the session, transient network
  failures included, so a history full of one site whose icon 404s does not
  refetch per row.[^task-86]
- With a `size`, the image is re-encoded to a PNG of that size. Bytes `NSImage`
  cannot decode (some SVG and ICO variants) either pass through
  (`undecodablePassesThrough`, the extension route) or fail (the History page,
  whose response is labelled PNG under `nosniff`).
- Only `http`/`https` icon URLs are fetched. Lookups run on a utility queue.

| Route | Gate | No icon |
|---|---|---|
| `detour-favicon://<extension host>/?pageUrl=…&size=…` (`FaviconSchemeHandler`) | the extension's WebKit host must have been granted the `favicon` manifest permission at load time | a 1×1 transparent PNG, so the extension's `<img>` shows nothing |
| `detour://history/favicon?pageUrl=…&size=…` | served only into the internal History document | a 404; the page hides the image |

# Invariants

- A favicon download never lands on a page the tab has left:
  `faviconGeneration` is bumped on every host change, on an error page and on
  an internal page.
- A link report is honoured only from a main frame whose origin host equals
  the host of the page the tab is showing, and never for an error page or an
  internal page.
- `FaviconLinkBridge.iconLinkSelector` is the single selector, shared by the
  early report and the end-of-load lookup.
- The link handler lives in a private content world: page script can neither
  see it nor patch the observer.
- An internal page shows an SF Symbol (`InternalPage.symbolName`); nothing is
  fetched for a `detour://` URL.

# Gotchas

- **`FaviconLinkBridge.install` must stay idempotent.** A configuration
  reaches `BrowserTab.makeWebView` more than once, and adding a handler name
  twice in one world raises.
- **Host-keyed, not page-keyed.** The optimistic guess and the icon reset fire
  on host changes only. Two pages of one host with different icons rely on the
  link report or the end-of-load lookup.
- **`faviconCancellables` holds more than favicon subscriptions**: the
  load-stall timer subscription is stored there too.
- **The two loaders disagree on failure caching** (see above). Do not assume a
  miss in one implies anything about the other.
- **Process-global state in tests.** `FaviconLoader.shared` is shared by every
  suite. `FavoriteFaviconTests` fails intermittently on a clean tree, two of
  its four tests; the cause was not established.[^task-98] Use the `fetch` seam
  and `resetForTesting()`.
- The grey box that TASK-112 also reported on affected rows was the tab cell's
  progress bar on a row still loading, not a stray layer; see
  [tab cell](../sidebar/tab-cell.md).

# Tests

- `FaviconLinkBridgeTests` - a `stall://` scheme handler holds one image open
  so the load never ends: an icon arrives while loading, a link added by
  script, a changed `href`, a late optimistic guess, the origin guard. The
  three behaviour tests fail with the bridge disabled.[^task-112]
- `FavoriteFaviconTests` - restore with a sleeping backing tab, two tiles for
  one favourite, a dormant download, rebinding on a tab swap.
- `HistoryDatabaseTests` - `faviconURL(for:)`: exact match, host fallback,
  most recent entry for a host.
- `InternalPageIntegrationTests` and `HistoryDeletionIntegrationTests` replace
  `FaviconPNGLoader.fetch` so the History page's rows never reach the network.

# Related

- [Hidden web view load stalls](../platform/hidden-webview-load-stalls.md) - why a background load may not finish until shown.
- [Tab cell](../sidebar/tab-cell.md) - where the icon and the loading indicator are drawn.
- [Favorites](../tabs/favorites.md) and [pinned tabs and folders](../tabs/pinned-tabs-and-folders.md) - dormant items that load their own icons.
- [History page](./history-page.md) - the `favicon` route's consumer.
- [Internal pages](./internal-pages.md) - the other bridge that uses a private content world.
- [Permissions](../extensions/permissions.md) - the `favicon` permission behind `detour-favicon://`.
- [BrowserTab](../architecture/browser-tab.md) - the published properties this pipeline writes.

[^task-53]: Favourites tiles show the globe placeholder instead of favicons on first launch
[^task-86]: Profile-scoped History page in a tab
[^task-98]: FavoriteFaviconTests fails intermittently on a clean tree
[^task-112]: Some sites never get their favicon, and their sidebar rows show a stray grey box
