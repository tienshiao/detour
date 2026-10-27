---
type: Concept
title: Profiles and spaces
description: "A profile owns website data, extensions and settings; a space is a tab group that points at one profile; the active space is per window."
tags: [architecture, profiles, spaces, undo]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T04:55:17Z }
sources:
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Space, space and profile mutations)
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (setActiveSpace)
  - id: tab-lifecycle-doc
    resource: ../../docs/tab-lifecycle.md
    title: docs/tab-lifecycle.md
  - id: task-35
    resource: backlog:TASK-35
    title: Undo of Delete Space / Edit Space after its profile was deleted crashes
  - id: task-40
    resource: backlog:TASK-40
    title: Undo actions registered before Delete Space act on a stale Space object
  - id: task-38
    resource: backlog:TASK-38
    title: Moving a tab to another space
  - id: task-54
    resource: backlog:TASK-54
    title: A favourite's backing tab as the space's selected tab
  - id: task-58
    resource: backlog:TASK-58
    title: A live favourite restored into another space takes that space as its spaceID
  - id: task-87
    resource: backlog:TASK-87
    title: History delete and the launch sweep of deleted spaces
  - id: private-notes
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on the Private profile and extensions
---

# Summary

A **profile** is the unit of isolation: it owns a `WKWebsiteDataStore`, a
`WKWebExtensionController`, the favorites bar and the browsing settings. A
**space** is a named, coloured group of tabs that references exactly one
profile. Several spaces can share a profile and therefore share cookies,
logins, extensions and favorites. Which space a window shows is the window's
own state.

# Rules

## Profile

`Profile` ([Profile.swift](../../Detour/Browser/Profile.swift)) holds:

- Settings: `userAgentMode` / `customUserAgent`, `searchEngine`,
  `searchSuggestionsEnabled`, `archiveThreshold`, `sleepThreshold`,
  `isPerTabIsolation`, and the content blocker switches.
- `favorites: [Favorite]` — the favorites bar is per profile, so every space
  of the profile shows the same tiles.
- `lazy var dataStore` — `WKWebsiteDataStore(forIdentifier:)` for a normal
  profile, `.nonPersistent()` for the Private profile and for a profile
  flagged `isDeleted`.
- `lazy var extensionController` — configured with the same identifier, with
  `ExtensionManager.shared` as its delegate, the polyfill script and the
  polyfill message handler installed on its `webViewConfiguration`.
- `extensionContexts: [String: WKWebExtensionContext]` — the contexts loaded
  in this profile, keyed by extension id.

Both lazy properties matter for ordering: nothing on disk exists for a
profile until one of them is first read. The identifier is not always the
profile id; see [profile data removal](./profile-data-removal.md) for
`WebKitStorageScope`.

`isIncognito` is **not** a database column. `Profile.from(record:)` builds
every profile with `isIncognito == false`; `TabStore.ensureIncognitoProfile()`
then sets the flag on the profile whose id is `TabStore.incognitoProfileID`.
`restoreSession` calls it right after loading the profiles, before anything
reads a data store. Code that builds a `Profile` from a record by another
route must do the same, or the Private profile gets a persistent store. See
[incognito](./incognito.md).

The extension controller's web views (background page, popup, options,
offscreen) do not inherit `defaultWebsiteDataStore` on the WebKit Detour ships
against; `Profile` sets `config.webViewConfiguration.websiteDataStore`
explicitly so extension pages live in the profile's store. The history of
that line is in [data store and ITP](../extensions/data-store-and-itp.md).

`isPerTabIsolation` makes `Space.makeWebViewConfiguration()` hand every new
web view its own `.nonPersistent()` store. Extensions probably cannot see
such tabs, by the same WebKit gate that hides private pages from a context
without private-data access; this is suspected, not confirmed.[^private-notes]

## Space

`Space` is a class declared in
[TabStore.swift](../../Detour/Browser/TabStore.swift). It holds `tabs`,
`pinnedEntries`, `pinnedFolders`, `selectedTabID`, `profileID` and a strong
`profile` reference.

- `makeWebViewConfiguration()` is the single place an ordinary tab's web
  view configuration is built (an extension page uses its extension
  context's configuration instead): the profile's data store, the profile's extension
  controller, the link-hover and editable-focus user scripts, content rule
  lists, and the Chrome Web Store install scripts. A configuration is chosen
  only when a web view is created — at tab creation and at `wake()` — so
  changing anything a configuration carries means sleeping the tab and
  letting it wake.
- `usableProfile` is nil when the profile is missing or deleted. In that case
  `dataStore` returns a throwaway `.nonPersistent()` store and no extension
  controller is attached, rather than crashing or recreating storage for a
  deleted profile (TASK-35).
- `displayableTab(id:)` and `tabToSelectOnEntry()` are the only definitions
  of "a tab of this space" and "what a window selects on entering it". Both
  include the profile's favorite backing tabs (TASK-54).
- Setting `tabs` or `pinnedEntries` runs
  `ExtensionTabLifecycle.didPlace(listed:)`: entering a list is what reports
  a tab to extension contexts. See
  [tab and window bridge](../extensions/tab-and-window-bridge.md).

## Active space is per window

`BrowserWindowController.activeSpaceID` and `selectedTabID` are window state.
Two windows can show different spaces, or the same space with different
selected tabs.

`space.selectedTabID` is a single value shared by every window on the space.
Each window writes it when it selects a tab, and reads it only when entering
the space, so the last window to select wins at the next launch.
`TabStore.lastActiveSpaceID` is the same idea for spaces: it is written by
the last non-incognito window to switch space and is used for persistence and
as the default for a new window, never as live state.

`setActiveSpace(id:)` stamps the outgoing tab as deselected **before** moving
`activeSpaceID`. After the move `selectedTab` resolves in the new space, so a
later stamp would miss the tab and it would never
[sleep](../tabs/sleeping-and-archiving.md).

## Space lifecycle

| Operation | `TabStore` method | Notes |
|---|---|---|
| Create | `addSpace(name:emoji:colorHex:profileID:)` | Registers an "Add Space" undo. |
| Default | `ensureDefaultSpace()` | Only when there are no spaces; creates "Home" on the first non-incognito profile, minting a "Default" profile if needed. `profiles.first` can be the Private profile on a session-less launch, which is why it is skipped explicitly. |
| Edit | `updateSpace(id:name:emoji:colorHex:profileID:)` | A profile change is a rebuild, see below. |
| Reorder | `moveSpace(from:to:)` | |
| Delete | `deleteSpace(id:)` | Returns `SpaceDeletionResult`. Refused while a link route or the Default targets the space (`.blockedByLinkRoutes`, [Link Routes](../features/link-routing.md)). Refuses the last space, and the last **normal** space even while a Private window's space makes `spaces.count` larger (a review fix in TASK-191.1: before it, deleting the last persistent space with a Private window open left the next launch no saved session, and it made a new "Home" space). An undo of Add Space or redo of Delete Space that routes refuse posts `spaceDeletionBlockedNotification` and keeps its entry. |
| Move a tab between spaces | `moveTab(id:from:to:)`, `movePinnedEntry(id:from:to:)` | See below. |

### Changing a space's profile

Existing web views were built from the old profile's configuration. For each
tab and pinned backing tab of the space, `updateSpace`:

1. calls `ExtensionTabLifecycle.didClose(tab)` so the old profile's contexts
   do not keep a phantom open tab (TASK-50);
2. calls `tab.sleep(force: true)` — forced, so a tab playing audio is paused
   and rebound like any other;

then returns the old profile's live favorites bound to this space to dormant
tiles, and posts `spaceTabsNeedRehost`. Each window on the space re-selects
its own displayed tab, which wakes it from the new profile's configuration.
The favorite deactivation is not reversed by undoing the edit.

### Deleting a space, and undo

`deleteSpace` snapshots every tab, pinned entry and folder as value structs
(including interaction state, read before teardown), saves the space's
closed-tab rows, tears the tabs down, and registers a "Delete Space" undo
that rebuilds everything from the snapshots: the selected tab live, the rest
sleeping, the same shape `restoreSession` produces.

Three details are deliberate:

- **The `Space` object survives.** The undo closure retains the instance and
  re-inserts that same object, with its three lists emptied in between. Undo
  actions registered before the delete (Close Tab, Move Tab, Pin, folder
  actions) captured that instance, and they must act on the space the windows
  show after the delete is undone (TASK-40). The rebuilt **tabs and entries**
  are new objects with the old ids, so undo closures elsewhere capture ids,
  not tab objects.
- **Closed-tab rows are re-inserted with their original ids**, so Reopen
  Closed Tab keeps its order. See
  [closed tabs and archive](../tabs/closed-tabs-and-archive.md).
- **History is not deleted with the space.** The undo brings the space back
  under the same id and its visits must still be there. Visits of spaces that
  no longer exist are swept at the next launch; `spaceIDsDeletedThisSession`
  keeps a space deleted in this session out of that sweep (TASK-87).

Favorite backing tabs that were brought to life in the deleted space are
moved onto another space of the same profile (`rehomeFavoriteTabs`), or made
dormant when none is left. Their `spaceID` would otherwise name a space that
no longer resolves and the next wake would build the page from a bare
configuration (TASK-58).

The profile is never deleted with the space.

### Moving a tab to another space

`moveTab(id:from:to:)` carries the tab object itself; it is not a close and
leaves no closed-tab record.

- Same profile: the tab keeps its web view, so back/forward list, scroll and
  form state survive. Extensions get a move, not a close and reopen.
- Different profile: the web view has to go. The tab is slept (forced) and
  wakes from the destination's configuration. Its `parentID` is cleared.
- Across the incognito boundary: refused (`canMove`). An incognito tab's
  interaction state landing in a persistent space would be written to the
  session database.
- An extension page crossing profiles is retargeted onto the destination
  profile's origin for the same extension, or the move is refused when that
  profile cannot serve it. `canMoveTab` and `moveTabRefusal` answer
  beforehand without mutating.

## Deleting a profile

`TabStore.deleteProfile(id:)` refuses the Private profile, the last normal
profile, and any profile a space still uses. It also clears the whole undo
stack: undo closures hold spaces, spaces hold their profile strongly, and
`UndoManager` cannot drop only the actions that mention one profile
(TASK-35). The rest of the sequence is on
[profile data removal](./profile-data-removal.md).

# Where it lives

| What | Where |
|---|---|
| `Profile`, `UserAgentMode`, `ArchiveThreshold`, `SleepThreshold`, `SearchEngine` | [Profile.swift](../../Detour/Browser/Profile.swift) |
| `Space`, space and profile mutations | [TabStore.swift](../../Detour/Browser/TabStore.swift) |
| Per-window active space | `BrowserWindowController.setActiveSpace(id:selectTab:)` |
| Settings UI | `ProfilesSettingsViewController`, `SpacesSettingsViewController` under `Detour/Browser/Settings/` |
| Tests | `TabStoreTests`, `UndoAfterDeleteSpaceTests`, `ProfileDeletionUndoTests`, `MoveTabToSpaceTests`, `PinnedTabMoveTests`, `SpaceEntrySelectionTests`, `FavoriteSpaceHandoffTests` |

A test-harness trap from TASK-40: a test body never turns the run loop, so
`UndoManager.groupsByEvent` never closes its automatic group.
`UndoAfterDeleteSpaceTests` sets `groupsByEvent = false` and wraps each
action in an explicit group.[^task-40]

# Related

- [TabStore](./tabstore.md) — the mutation API these operations belong to.
- [Incognito](./incognito.md) — the built-in Private profile.
- [Profile data removal](./profile-data-removal.md) — what deleting a profile removes.
- [Persistence](./persistence.md) — how profiles and spaces are saved.
- [Extension manager](../extensions/extension-manager.md) — per-profile contexts.
- [Favorites](../tabs/favorites.md) — the per-profile tiles.

[^private-notes]: Session notes on the Private profile and extensions
[^task-40]: Undo actions registered before Delete Space act on a stale Space object
