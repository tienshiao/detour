---
type: Concept
title: Extension pages in tabs
description: A tab showing a webkit-extension:// page is tied to one loaded context's origin, which dies on every context reload and every relaunch; how such tabs, pinned tiles, favourites and closed-tab records are rehomed, restored, refused or closed.
tags: [extensions, tabs, persistence, pinned, favorites]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: page-url
    resource: ../../Detour/Extensions/Runtime/ExtensionPageURL.swift
    title: ExtensionPageURL.swift
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (retargetExtensionPages, pendingExtensionOrigins, resolvePendingExtensionPages)
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (retarget, wake, wakeConfiguration)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (addExtensionTab, makeTab(loading:), restoredTab, rehomedTileURL)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (closePagesOfUnloadedExtension, install)
  - id: refusal
    resource: ../../Detour/Browser/DormantTileRefusal.swift
    title: DormantTileRefusal.swift
  - id: task-14
    resource: backlog:TASK-14
    title: Reload or close open extension pages when their context is reloaded
  - id: task-24
    resource: backlog:TASK-24
    title: Give extension-page tabs a durable identity so they survive a relaunch
  - id: task-28
    resource: backlog:TASK-28
    title: Undoing the close of an extension page tab restores a dead page
  - id: task-30
    resource: backlog:TASK-30
    title: Undo of Delete Tab must rehome extension page URLs
  - id: task-34
    resource: backlog:TASK-34
    title: Moving an extension-page favourite must give a loadable tab
  - id: task-37
    resource: backlog:TASK-37
    title: Activating a dormant pinned entry of a disabled or uninstalled extension gives a dead tab
  - id: task-38
    resource: backlog:TASK-38
    title: Move to Space loses extension pages
  - id: rehost-tests
    resource: ../../DetourTests/ExtensionPageRehostTests.swift
    title: ExtensionPageRehostTests
  - id: persistence-tests
    resource: ../../DetourTests/ExtensionPagePersistenceTests.swift
    title: ExtensionPagePersistenceTests
---

An extension's own pages (options, a full-page UI, anything opened with
`tabs.create(chrome.runtime.getURL(…))`) can live in ordinary tabs, pinned
entries and favourites. Their URLs are `webkit-extension://<UUID>/path`, and
that UUID names one *loaded context*, not the extension. Every rule on this
page follows from the origin being short-lived.

# Summary

- A `webkit-extension://` page can load only in a web view built from the
  serving context's `webViewConfiguration`. A space's own configuration has no
  handler for the scheme. `TabStore.addExtensionTab(in:url:configuration:)`
  takes that configuration for this reason.
- WebKit gives each loaded context a fresh base URL. The origin dies when the
  context is unloaded: on a background-recovery reload, an update, a
  disable → enable, and at every quit.
- A page left on a dead origin is dead twice over. Its native `chrome.*`
  bindings went with the old context, and the
  [polyfill bridge](./polyfill-layer.md) rejects it because the origin
  resolves to no loaded context.
- So the durable identity of an extension page is **(extension id, path)**,
  not its URL.

# Rules

## A context reload rehomes open pages

`Profile.retargetExtensionPages(from:to:)` moves every page on the old origin
onto the new one:

1. Find the pages (`extensionPageLocations`). A page can be in four places: a
   space's tabs, a pinned entry's tab, a favourite's backing tab, a Peek.
2. Rewrite each URL with `rewriteExtensionPageURL`, which carries path, query
   and fragment over in their percent-encoded form. An extension page's query
   often holds a URL of its own, and decoding then re-encoding would change it.
3. `BrowserTab.retarget(to:)`: release the web view, **discard** the cached
   interaction state (restoring it would put the tab back on the dead URL),
   leave the tab sleeping on the new URL.
4. Rewrite the stored `pinnedURL` / favourite `url` too, dormant or not: they
   are what a later activation loads.
5. Post `.spaceTabsNeedRehost` with the affected tab ids, on the *next*
   main-queue turn. Each window re-selects its displayed tab, and the normal
   display path (`claimWebView` → `wakeIfNeeded` → `wake`) rebuilds it.

The existing web view is not navigated, because it was built from the old
context's configuration and cannot load the new origin at all. Dropping it and
letting `wake` rebuild also makes the path correct for a tab whose web view
another window owns, or none
([WebView ownership](../architecture/webview-ownership.md)).

Title and favicon are deliberately kept. This is the same page coming back
from a new internal origin; clearing them would flash a raw
`webkit-extension://<uuid>/…` title and drop an icon that lives at an extension
URL and could not be fetched again.

The deferred notification is what makes each rehosted tab **announced once**.
The caller reloads the context and then announces the profile's live tabs to
it; a synchronous post would wake the displayed tab first, announcing it from
`wake()` and again from the sweep
([Tab and window bridge](./tab-and-window-bridge.md)).

## Waking resolves the owning context

`BrowserTab.wakeConfiguration` picks the configuration by the URL's origin
host: the loaded context whose base URL has that host, else the space's
configuration. Before this rule any slept extension tab woke into the space
configuration and came back dead.[^task-14]

## Disable and uninstall close pages

There is no replacement origin, so the pages are closed, through `TabStore`
so selection, split groups and the sidebar stay consistent
(`closePagesOfUnloadedExtension`):

- a tab is closed; a pinned entry or favourite keeps its tile, dormant;
- the close is **not undoable** and writes no closed-tab record;
- a *disable* keeps the origin registered as pending, so the dormant tiles
  keep their identity and a re-enable moves them;
- an *uninstall* forgets the origins; the next restore drops those tiles;
- an install over an existing extension closes pages in any profile that got
  no replacement context.

## Persistence carries the extension id

Migration v8 added a nullable `extensionID` column to `tab`, `pinnedTab`,
`favorite` and `closedTab`. The URL column already holds the path.

At save, the id comes from `Profile.extensionID(forPageURL:)`: the loaded
context claiming the URL's host, else `pendingExtensionOrigins`. No tab
carries an identity property; a tab that navigates away simply stops matching.

At restore, `classifyPersistedExtensionPage` decides:

| Class | Meaning | Open tab | Pinned entry, favourite | Closed-tab record |
|---|---|---|---|---|
| `.notExtensionPage` | Ordinary URL | As always | As always | As always |
| `.restorable` | Installed and enabled in the profile | Restored sleeping, without interaction state | Kept | Kept |
| `.disabled` | Installed, not enabled there | Dropped | Kept dormant | Kept, skipped by Reopen |
| `.unavailable` | Not installed, or no id | Dropped | Dropped | Deleted when a Reopen scan reaches it |

A row saved before ids were recorded got the sentinel
`ExtensionPageURL.unknownExtensionID` from the migration's back-fill. It
classifies as `.disabled`, so an upgrade did not silently delete every
extension-page pin the user had. Nothing ever enables that id.

## Pending origins

Contexts load asynchronously, always after `TabStore.restoreSession`
([ExtensionManager](./extension-manager.md)). Restore therefore cannot rewrite
URLs. It leaves kept pages sleeping on the dead origin and records
`pendingExtensionOrigins[deadHost] = extensionID`.

`Profile.resolvePendingExtensionPages` runs right after contexts load (launch,
enable, install), before tabs are announced. It is `retargetExtensionPages`
with the pending origin as the old base, so it covers every container.

Until then:

- `BrowserTab.wake` on a pending origin builds the web view but loads nothing
  (`isAwaitingExtensionContext`). A load into the fallback configuration would
  only produce an error page.
- A save still writes the extension id, from the pending map, so quitting
  before contexts load loses nothing.

## Rebuilding from captured state

Reopen Closed Tab, the close undos, Delete Space and Delete Tab undos all
rebuild from something captured earlier. They capture the extension id at
close time and go through `TabStore.restoredTab` / `rehomedTileURL`:

- an enabled extension's page comes back **sleeping** on the live origin (or
  on a pending one), without its interaction state;
- a disabled or uninstalled extension's page yields no tab. A single undo then
  does nothing, registers no redo, and leaves the record.

`TabStore.makeTab(loading:)` is the one constructor for a tile that has no web
view yet. It creates an extension page sleeping, so `wake` resolves the right
configuration.

## Dormant tiles are refused, never dropped

Activating or unpinning a dormant tile whose extension is off or gone returns
false and changes nothing. `TabStore.dormantTileRefusal` classifies the reason
(`DormantTileRefusal.extensionDisabled(name:)` / `.extensionUnavailable`) and
the window shows a toast at the user-driven call sites. Dropping a tile on a
click would delete it behind the user's back and could break pinned-split
invariants; the next restore drops uninstalled ones.[^task-37]

Favourite moves follow the same classification (`FavoriteDropTargets`): an
uninstalled extension's favourite cannot be dragged anywhere, and a disabled
one's dormant favourite may only become a pinned entry.[^task-34]

## Move to Space

Within one profile the tab object moves and keeps its web view. Across
profiles it is retargeted onto the destination profile's origin for that
extension, or refused with a toast when the extension is not enabled there.
Moves across the incognito boundary are refused.[^task-38]

# Gotchas

- A Peek cannot show an extension page: its web view is built from the space
  configuration.
- If an extension is enabled but its `WKWebExtension` fails to load, its
  restored pages stay pending and display as an empty page, not an error page.
- The window registers its owned-pane script message handlers on the web
  view's `userContentController`. For an extension tab that controller is
  shared by every extension page of the profile.[^task-14]
- The relaunch behaviour is verified by round-tripping an in-memory database
  through `restoreSession` against real contexts with fresh base URLs, not by
  quitting and relaunching the app.[^task-24]

# Where it lives

- [ExtensionPageURL.swift](../../Detour/Extensions/Runtime/ExtensionPageURL.swift) — the pure functions and `PersistedExtensionPage`.
- [Profile.swift](../../Detour/Browser/Profile.swift) — locations, retarget, pending origins.
- [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift) — `retarget`, `wake`, `wakeConfiguration`.
- [TabStore.swift](../../Detour/Browser/TabStore.swift) — restore, rebuild helpers, refusals.
- Tests: `ExtensionPageURLTests`, [ExtensionPageRehostTests](../../DetourTests/ExtensionPageRehostTests.swift), [ExtensionPagePersistenceTests](../../DetourTests/ExtensionPagePersistenceTests.swift), `ExtensionPageUndoTests`, `ExtensionPageFavoriteTests`, `MoveTabToSpaceTests`.

# Related

- [Storage](./storage.md) — the same per-load origin loses IndexedDB, and the proposed stable base URL.
- [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md), [Favorites](../tabs/favorites.md) — dormant tiles.
- [Closed tabs and archive](../tabs/closed-tabs-and-archive.md) — the records that carry `extensionID`.
- [Sleeping and archiving](../tabs/sleeping-and-archiving.md) — what a sleeping tab is.
- [Popup and options UI](./popup-and-options-ui.md) — how an options tab is opened and reused.

[^task-14]: Reload or close open extension pages when their context is reloaded
[^task-24]: Give extension-page tabs a durable identity so they survive a relaunch
[^task-34]: Moving an extension-page favourite must give a loadable tab
[^task-37]: Activating a dormant pinned entry of a disabled or uninstalled extension gives a dead tab
[^task-38]: Move to Space loses extension pages
