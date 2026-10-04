---
type: Feature
title: Favourites
description: Per-profile tiles above the tab list, each with an optional backing tab that lives on the profile rather than in any space; how they are selected, moved, parked, peeked and kept visible to extensions.
tags: [tabs, favorites, sidebar, profile, peek]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: model
    resource: ../../Detour/Browser/Favorite.swift
    title: Favorite.swift
  - id: bar
    resource: ../../Detour/Browser/Sidebar/FavoritesBarView.swift
    title: FavoritesBarView.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Favorites section, saveNow, restoreSession)
  - id: window-sidebar
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift
  - id: record-factory
    resource: ../../Detour/Browser/TabRecord+BrowserTab.swift
    title: TabRecord+BrowserTab.swift
  - id: task-34
    resource: backlog:TASK-34
    title: Moving an extension-page favourite into the tab list or pinned section must give a loadable tab
  - id: task-42
    resource: backlog:TASK-42
    title: Cross-host link clicks in a favourite's tab should open a Peek, matching pinned tabs
  - id: task-47
    resource: backlog:TASK-47
    title: Show a peek favicon badge on a favourite tile that has a parked Peek
  - id: task-50
    resource: backlog:TASK-50
    title: Register favourite and Peek backing tabs with the extension contexts (Google Calendar favourite runaway CPU)
  - id: task-53
    resource: backlog:TASK-53
    title: Tiles show the globe placeholder instead of favicons on first launch
  - id: task-54
    resource: backlog:TASK-54
    title: Switching away and back drops a favourite backing tab as the space's selected tab
  - id: task-58
    resource: backlog:TASK-58
    title: A live favourite moved back into the tab list or pinned section keeps a stale spaceID
---

# What it does

A favourite is a small tile in the grid at the top of a space's sidebar page.
Clicking it opens its page; the page stays alive behind the tile like a
[pinned tab](./pinned-tabs-and-folders.md) does. Favourites belong to the
**profile**: every space that shares the profile shows the same tiles, and the
same live page.

| Gesture | Effect |
|---|---|
| Click | activates a dormant favourite (builds its tab) and selects it |
| Double-click | also reloads the favourite's own URL (`loadRecordedURL(fav.url)`), the way back "home" |
| Cmd+W while selected | discards the backing tab; the tile stays, dormant; the window deselects |
| Context menu "Remove from Favorites" | removes the tile and tears down its tab |
| Drag a tab or pinned row onto the bar | the live tab moves under a new favourite |
| Drag a tile into the tab list or pinned section | the favourite becomes a tab or a pinned entry |
| Drag a tile within the bar | reorder |

# How it works

## Model

`Favorite` (id, `url`, `title`, `faviconURL`, published `favicon`, `sortOrder`,
optional `tab`) lives in `Profile.favorites`. A favourite with `tab == nil` is
dormant. The code spells it `Favorite`; comments and tasks say "favourite".

## The backing tab is in no space

**A favourite's backing tab is not in `space.tabs` and not in
`space.pinnedEntries`.** It hangs off `Favorite.tab` on the profile. This is the
single most common source of bugs in this area: any "is this tab part of the
space" test that only looks at the two lists silently drops a selected
favourite.[^task-54]

- `Space.displayableTab(id:)` is the one membership rule (pinned, then
  favourite, then normal). `selectedTab`, `selectTab`'s guard and
  `tabToSelectOnEntry()` all use it, so a selected favourite survives a space
  switch and a relaunch.
- `TabStore.tab(hosting:in:)`, `TabStore.favorite(backedBy:)` and
  `Profile.favoriteTabs` are the lookups that include favourites.
- When a favourite is selected the sidebar table has no row to highlight; the
  window deselects the table and highlights the tile.
- Cmd+Option+Up/Down does not stop on favourites. The Control+Tab switcher does
  list live ones ([tab switching](./tab-switching.md)).

## `spaceID` of a favourite's tab

`BrowserTab.spaceID` decides which configuration `wake()` builds from, so it
must always name a live space of the tab's profile. A favourite's tab keeps the
space it was brought to life in, until:[^task-58]

- it is dragged into a space's tab list or pinned section: `adoptSpace` rehomes
  it onto that space. The restore paths refuse a space of another profile;
- its space is deleted: `rehomeFavoriteTabs` moves it onto another space of the
  profile, or returns the favourite to a dormant tile when none is left;
- its space is moved to another profile (`updateSpace`): the favourite is
  deactivated. This is not reversed by undoing the edit.

After a relaunch the tab's `spaceID` is the first non-incognito space that uses
the profile, not necessarily the one it was activated in.

## Moves between sections

A live tab moves **as the same object**, with its web view and its extension
registration; only the pinned flag is announced when it flips. A dormant
favourite has no tab to move, so one is built.

- `moveTabToFavorites(id:from:profileID:at:)` is the drop onto the bar. It
  checks the tab has a URL *before* detaching it: a detached tab that then
  failed to be listed would sit in no section, still live and still registered.
- `addFavoriteFromEntry` is the dormant-pinned-tile path; the window adds the
  favourite first and detaches the entry only on success.
- `restoreFavoriteAsTab` / `restoreFavoriteAsPinned` are the drags out of the
  bar. The tab insert is snapped out of [split groups](./split-tabs.md).
- Only lone normal tabs and lone pinned entries can be favourited by drag
  (`FavoritesBarView.canFavorite`, an allow-list). Folders, split rows and
  split members cannot. Favourites are never split members.
- Payloads from another window's sidebar are rejected by `sidebarID`
  ([drag and drop](../sidebar/drag-and-drop.md)).
- **Favourite mutations register no undo.**[^task-34]

A dormant favourite of an extension page obeys the same rules as a dormant
pinned tile: it opens only while the extension is enabled, a disabled
extension's page may only become a dormant pinned entry, an uninstalled one's
may go nowhere. Sidebar drop validation asks
`TabStore.favoriteDropTargets(id:profileID:)` and a refused click shows the
[refusal toast](./pinned-tabs-and-folders.md).

## Peeks from a favourite

A favourite's tab is anchored to `Favorite.url` exactly as a pinned tab is
anchored to its home URL: links leaving that host open in a [Peek](./peek.md)
(`PeekAnchor.anchorURL` checks pinned entries first, then favourites).[^task-42]

A Peek that was open when the user switched away is parked on the backing tab
(`peekURL`, `peekInteractionState`, `peekFaviconURL`) and survives a relaunch.
The tile then shows a small chip with the Peek's favicon in its top-right
corner, so a click that will drop the user into an overlay from an earlier
session is not a surprise.[^task-47] The chip reads
`BrowserTab.displayPeekFavicon` and subscribes to the tab's `$peekFavicon`; the
window mirrors a live Peek's favicon onto the host so every window's tile sees
it.

## Favicons

`Favorite.favicon` is `@Published` and downloaded whenever it is nil,
*regardless of the backing tab*. Each tile subscribes to both the favourite's
and the tab's favicon publishers. The design it replaced, one
`onFaviconDownloaded` closure, only ever reached the tile that registered last,
and a favourite restored with a sleeping tab never fetched its own icon at all:
tiles showed the globe until a second window was opened.[^task-53] See
[favicons](../features/favicons.md).

## Extensions

A favourite's web view is built from the profile's configuration, so content
scripts run in it, and the tab must therefore be known to the extension
contexts. `Favorite.tab`'s and `Profile.favorites`' `didSet` report it on
placement ([tab and window bridge](../extensions/tab-and-window-bridge.md)).

This was found the hard way. With the tab unregistered, every
`runtime.sendMessage` from a content script failed inside WebKit with "Tab not
found"; 1Password's rejection reporter then reported its own failed
report in a loop, and a Google Calendar favourite's web content process ran at
about 120% CPU and grew to 5 GB while the page never finished loading.[^task-50]
An extension's `tabs.remove` on a favourite's tab deactivates the favourite.

## Sleep

Favourites' tabs are skipped by the idle sleep rule and sleep only under the
show-budget rule ([sleeping](./sleeping-and-archiving.md)). They are never
archived and never write a closed-tab record.

## Persistence

`favorite` rows are saved per profile with `tabID`. The backing tab is a `tab`
row with `sortOrder = -2`, hosted under the first persistent space that uses
the profile, written through the same `TabRecord` factory as every other tab
(peek columns included). On restore the backing tab always comes back asleep.

**Order matters in `restoreSession`:** favourites are loaded *after* the spaces
loop, because the host space must already exist. When they were loaded earlier
the backing tab was never recreated and its row was garbage-collected by the
next save. A profile with no space left restores its favourites dormant.

# Edge cases

- Closing the selected favourite deselects rather than picking a neighbour:
  there is no "next tab" for something that is not in the list.
- Removing a favourite whose tab hosted a Peek tears the Peek down too
  (`teardown()` cascades). Before that, "Remove from Favorites" could strand a
  Peek on screen with no way to dismiss it.[^task-42]
- The peek chip and the favicon are decorative for hit-testing
  (`FavoriteTileView.hitTest`). A plain non-opaque subview there would become
  the hit view and turn a click on the badge corner into a window drag.
- The "Drop to add favorite" hint overlays the space header while the bar is
  empty; it never changes the list's layout.

# Tests

`FavoriteFaviconTests`, `FavoritePeekPersistenceTests`,
`FavoriteSpaceHandoffTests`, `FavoriteTileBadgeTests`,
`ExtensionPageFavoriteTests`, `SpaceEntrySelectionTests`,
`ExtensionTabLifecycleTests`, `SidebarDragDropTests`.

# Related

- [Pinned tabs and folders](./pinned-tabs-and-folders.md): the per-space counterpart; same dormant, anchor and refusal rules.
- [Peek](./peek.md): the overlay favourites' links open in.
- [Profiles and spaces](../architecture/profiles-and-spaces.md): why favourites are shared between spaces.
- [Sidebar drag and drop](../sidebar/drag-and-drop.md): the payloads and the drop hint.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md): the placement rule that registers the backing tab.
- [Favicons](../features/favicons.md): the loader behind tiles and tabs.

[^task-34]: Moving an extension-page favourite into the tab list or pinned section must give a loadable tab
[^task-42]: Cross-host link clicks in a favourite's tab should open a Peek, matching pinned tabs
[^task-47]: Show a peek favicon badge on a favourite tile that has a parked Peek
[^task-50]: Register favourite and Peek backing tabs with the extension contexts (Google Calendar favourite runaway CPU)
[^task-53]: Tiles show the globe placeholder instead of favicons on first launch
[^task-54]: Switching away and back drops a favourite backing tab as the space's selected tab
[^task-58]: A live favourite moved back into the tab list or pinned section keeps a stale spaceID
