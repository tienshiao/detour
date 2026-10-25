---
type: Concept
title: Incognito (Private windows)
description: "How Private browsing is built — one built-in Private profile with a non-persistent store, one throwaway space per Private window, and the list of things that are and are not kept."
tags: [architecture, privacy, profiles, incognito]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T09:48:28Z }
sources:
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift
  - id: palette
    resource: ../../Detour/Browser/CommandPalette/CommandPaletteView.swift
    title: CommandPaletteView.swift (gatherTabInfos)
  - id: palette-scope
    resource: ../../Detour/Browser/CommandPalette/PaletteTabScope.swift
    title: PaletteTabScope.swift
  - id: task-137
    resource: backlog:TASK-137
    title: A normal window's open-tab suggestions include tabs from open Private windows
  - id: downloads
    resource: ../../Detour/Browser/Downloads/DownloadManager.swift
    title: DownloadManager.swift
  - id: task-73
    resource: backlog:TASK-73
    title: Private profile extension pages run in the profile's ephemeral store
  - id: task-74
    resource: backlog:TASK-74
    title: Extensions are off in the Private profile unless allowed
  - id: task-38
    resource: backlog:TASK-38
    title: Moving a tab to another space
  - id: task-148
    resource: backlog:TASK-148
    title: Private window downloads are not saved and are listed only in their window
  - id: task-156
    resource: backlog:TASK-156
    title: A Private window's download still running when the window closes is cancelled, after asking
  - id: private-notes
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on the Private profile and extensions
---

# Summary

There is no separate "incognito mode" in the code. A Private window is an
ordinary `BrowserWindowController` whose space belongs to a special profile.
The profile's `isIncognito` flag is what every rule keys on:

```
Private window ──► its own Space ("Private", created with the window)
                        └──► the built-in Private Profile (one, shared)
                                   └──► WKWebsiteDataStore.nonPersistent()
```

`Space.isIncognito` is just `profile?.isIncognito ?? false`.

# Rules

## The profile

- One built-in profile with the fixed id
  `TabStore.incognitoProfileID` (`00000000-0000-0000-0000-000000000001`),
  named "Private".
- Its **row is saved** in the `profile` table, because it has settings
  (search engine, user agent, content blocking) the user can edit. Its
  website data is not.
- `isIncognito` is not a column. `TabStore.ensureIncognitoProfile()` sets it
  on the loaded profile with that id, or creates the profile. It runs in
  `restoreSession` right after the profiles load.
- It cannot be deleted (`deleteProfile` refuses the id) and its data is never
  scheduled for removal.
- `dataStore` is `.nonPersistent()`. `extensionController` uses a
  non-persistent configuration, and extension pages in it run in the same
  ephemeral store (TASK-73).

**The store is per profile, not per window.** `dataStore` is a lazy property
on the one Private profile object, so every Private window shares cookies
and logins, and they survive closing the Private window. They are gone when
the app quits. Loaded extension contexts for the Private profile also live
until quit.[^private-notes]

## The window and its space

- `BrowserWindowController(incognito: true)` calls
  `TabStore.addIncognitoSpace()`, which creates a new space on the Private
  profile. Each Private window gets its own space and never switches away
  from it.
- The window is forced to dark appearance and titled "Private Browsing".
- `windowShouldClose` asks before closing a Private window whose downloads
  are still running (see Downloads below).
- On `windowWillClose` the window calls `removeIncognitoSpace(id:)`, which
  removes the space and **tears down** every tab. The teardown is explicit
  because an undo closure may still retain the space; without it the web
  views would keep playing audio and stay in memory.
- `addIncognitoSpace` and `removeIncognitoSpace` register no undo and
  schedule no save.

## What is not kept

| Thing | Where it is stopped |
|---|---|
| The space and its tabs in the session | `saveNow` filters `isIncognito` spaces. |
| Closed-tab records | `closeTab` pushes a record only for non-incognito spaces. Undo Close Tab still works within the session. |
| History visits and title corrections | `recordHistoryVisit` returns early; `HistoryTitleUpdatePolicy` refuses. |
| The History page | `HistoryPageBridge.scope(for:)` returns nil and the page is told `incognito: true`. |
| `chrome.history.search` from an extension running in Private | `HistoryPageBridge.scope(forProfile:)` returns nil and the extension gets an empty list, never another profile's history ([polyfill layer](../extensions/polyfill-layer.md)). |
| Per-site switches (content blocking, picture in picture, dev mode) | `SiteSettingsStore` keeps the Private profile's values in memory only and drops them when the last Private space is removed ([site settings](./site-settings.md), TASK-195). |
| "Always allow" for external apps | `ExternalAppPermissionStore` keeps a Private decision in memory for the session only; the prompt offers no "remember" option. |
| `runtime.onInstalled` for extensions | Never delivered or recorded for the Private profile. |
| Auto-archive | `archiveStaleTabs` skips incognito spaces. |
| Favorites of the Private profile | `saveNow` skips incognito profiles when saving favorites. |
| Download records | `DownloadScope.isPersisted`: a download started in a Private window is never written to the `download` table. See below. |

## Downloads

A download started in a Private window carries
`DownloadScope.incognito(spaceID:)`, the window's own space (TASK-148):

- it is **never saved**: not by the debounced save, not by the flush at app
  termination;
- it is **listed only in that window's** downloads popover, and only that
  window's badge shows it. Other Private windows and normal windows never see
  it, and a Private window does not list normal downloads;
- it **leaves the list when the window closes**. `DownloadManager` observes
  the store and drops the downloads of an incognito space that is gone;
- one **still running is cancelled** when the window closes, and its partial
  file removed (TASK-156). Nothing else would stop it: WebKit keeps a
  download transferring after its web view is gone, and the Private profile's
  store outlives the window.[^task-156] The window asks first ("N downloads
  are in progress. Closing this Private window cancels them."), and the quit
  confirmation says the same for every Private window. A window closed
  without the question (an extension's `windows.remove`) has its downloads
  cancelled all the same, when its space is removed;
- the **file of a finished download stays** in `~/Downloads`, as in Safari
  and Chrome.

This is per window, unlike the Private profile's cookies, which every Private
window shares until quit. The mechanics are on
[downloads](../features/downloads.md).

## What crosses the boundary: nothing may move

`TabStore.canMove(from:to:)` refuses any tab or pinned entry move where the
two spaces differ in `isIncognito`. An incognito tab carries its web view and
its whole interaction state; landing in a persistent space would write that
to the session database (TASK-38). The sidebar does not offer the menu in a
Private window; the store-level refusal is the invariant behind it.

## What other windows see of a Private window's tabs: nothing

The command palette offers open tabs as "Switch to Tab" rows, as the top hit
and as an inline completion. `PaletteTabScope.offeredSpaceIDs` decides which
spaces those tabs may come from:

| Palette's window | Spaces whose tabs it is handed |
|---|---|
| Normal | every non-incognito space |
| Private | its own space and no other, not even another Private window's |

A window counts as Private when its profile says so **or** when the space it
is showing is incognito, so a missing profile cannot widen the list.
`CommandPaletteView.gatherTabInfos` is the only place that builds the
pipeline's tab list, and it goes through this rule for the empty-query list
and for typed queries alike.

Before TASK-137 the filter only narrowed the list when the palette's own
window was Private; a normal window was handed every space in
`TabStore.spaces`, so a Private tab's URL, title and favicon could be listed,
completed inline, and switched to from another window. Found by reading the
code and fixed with unit tests; the leak itself was never observed in the
running app.[^task-137]

## UI restrictions in a Private window

Disabled or hidden: switching space (menu, shortcuts and swipe), the add
space button, editing the space, pinning, the Archived Tabs page and its
menu items, and Move to Space. The sidebar shows only the window's own
space, and `tabStoreDidUpdateSpaces` never switches a Private window to
another space.

## Extensions

Extensions are **off** in the Private profile unless the user allows each
one. A missing `profileExtension` row means "on" for every profile except
this one (`AppDatabase.extensionEnabledByDefault(inProfile:)`). A context
loaded into the Private profile gets `hasAccessToPrivateData = true`;
without it WebKit hides Private windows and tabs from the context and
delivers no events to a worker running in an ephemeral store. Private
windows answer `isPrivate(for:)` with true. Details:
[private profile extensions](../extensions/private-profile-extensions.md) and
[private extensions opt-in](../decisions/private-extensions-opt-in.md).

# Not covered by Private browsing

Read from the code; none of these was exercised at runtime for this page.

- **Shared network caches.** Favicon downloads and search suggestions go
  through `URLSession.shared`, whose cache and cookie storage are the app's,
  not the profile's.

# Not the same thing: per-tab isolation

`Profile.isPerTabIsolation` gives every new web view of a normal profile its
own `.nonPersistent()` store. It is a setting on a persistent profile: its
spaces are saved, its history is recorded, and `isIncognito` is false.

# Where it lives

| What | Where |
|---|---|
| `incognitoProfileID`, `ensureIncognitoProfile`, `addIncognitoSpace`, `removeIncognitoSpace`, `canMove` | [TabStore.swift](../../Detour/Browser/TabStore.swift) |
| The non-persistent store and controller | `Profile.dataStore`, `Profile.extensionController` in [Profile.swift](../../Detour/Browser/Profile.swift) |
| Window setup and teardown | `BrowserWindowController.init(incognito:)`, `windowWillClose` |
| Menu validation | `BrowserWindowController.validateMenuItem` |
| Entry points | File > New Private Window (Cmd+Shift+N) and the Dock menu, `AppDelegate.createNewIncognitoWindow` |
| Download scope rules | `DownloadScope` in [DownloadManager.swift](../../Detour/Browser/Downloads/DownloadManager.swift), `BrowserWindowController.downloadScope` |
| Downloads in flight at close | `PrivateDownloadClosePolicy` in [PrivateDownloadClosePolicy.swift](../../Detour/Browser/Downloads/PrivateDownloadClosePolicy.swift), `BrowserWindowController.windowShouldClose`, `AppDelegate.applicationShouldTerminate` |
| The palette's open-tab scope | `PaletteTabScope` in [PaletteTabScope.swift](../../Detour/Browser/CommandPalette/PaletteTabScope.swift), called by `CommandPaletteView.gatherTabInfos` |
| Tests | `ExtensionPrivateDefaultTests`, `ExtensionPrivateStoreTests`, `MoveTabToSpaceTests`, `ExternalAppPermissionTests`, `TabStoreTests`, `DownloadManagerTests`, `DownloadWindowScopeTests`, `PrivateDownloadClosePolicyTests`, `PrivateDownloadCloseWindowTests`, `PrivateDownloadTransferTests`, `PaletteTabScopeTests`, `PaletteTabScopeWiringTests` |

# Related

- [Profiles and spaces](./profiles-and-spaces.md) — the model this is a special case of.
- [Persistence](./persistence.md) — what the session save writes.
- [Private profile extensions](../extensions/private-profile-extensions.md) — the extension side.
- [Data store and ITP](../extensions/data-store-and-itp.md) — why extension pages need the profile's store set explicitly.
- [History page](../features/history-page.md) — its incognito reply.
- [Downloads](../features/downloads.md) — the per-window download list and what happens to it on close.
- [Suggestion pipeline](../features/suggestion-pipeline.md) — where the palette's open-tab candidates come from.

[^private-notes]: Session notes on the Private profile and extensions
[^task-156]: A Private window's download still running when the window closes is cancelled, after asking
[^task-137]: A normal window's open-tab suggestions include tabs from open Private windows
