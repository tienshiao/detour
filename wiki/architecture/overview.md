---
type: Overview
title: Architecture overview
description: The whole app on one page — profiles, spaces, tabs and windows, the singletons that hold them, how the parts talk to each other, and the launch sequence.
tags: [architecture, state, startup]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:20Z }
sources:
  - id: architecture-doc
    resource: ../../docs/architecture.md
    title: docs/architecture.md
  - id: claude-md
    resource: ../../CLAUDE.md
    title: CLAUDE.md
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift
  - id: project-yml
    resource: ../../project.yml
    title: project.yml
---

# Summary

Detour is a native macOS browser written in Swift on top of WebKit, with GRDB
(SQLite) for storage and Sparkle for app updates. There is no SwiftUI and no
storyboard: the UI is AppKit built in code.

Four objects carry the model. A **profile** owns the website data (cookies,
storage), the extension controller and the per-profile settings. A **space**
is a named group of tabs that points at one profile. A **tab** wraps an
optional `WKWebView`. A **window** shows one space at a time and one selected
tab of it. Spaces and tabs are global; which space is active and which tab is
selected are per window.

Two rules shape most of the code and are easy to break:

- A tab's web view is in at most one window. Other windows showing the same
  tab draw a snapshot. See [web view ownership](./webview-ownership.md).
- A tab's web view may not exist at all (the tab is asleep) and may not be in
  your window. Never assume `tab.webView` is attached.

# Parts

| Object | Type | Owned by | Page |
|---|---|---|---|
| Profile | `Profile` (class) | `TabStore.profiles` | [Profiles and spaces](./profiles-and-spaces.md) |
| Space | `Space` (class, in `TabStore.swift`) | `TabStore.spaces` | [Profiles and spaces](./profiles-and-spaces.md) |
| Tab | `BrowserTab` (`NSObject`) | `Space.tabs`, a `PinnedEntry`, a `Favorite`, or another tab's `peekTab` | [BrowserTab](./browser-tab.md) |
| Window | `BrowserWindowController` | `AppDelegate.windowControllers` | [BrowserWindowController](./browser-window-controller.md) |

A tab can live in four places, and code that walks "all tabs" has to visit
all four:

1. `space.tabs` — the normal tab list.
2. `space.pinnedEntries[n].tab` — the backing tab of a live
   [pinned entry](../tabs/pinned-tabs-and-folders.md) (nil when the entry is
   dormant).
3. `profile.favorites[n].tab` — the backing tab of a live
   [favorite](../tabs/favorites.md). Favorites belong to the profile, not to a
   space, so this tab is in no space's lists.
4. `hostTab.peekTab` — the tab shown in a [Peek](../tabs/peek.md) overlay.

`Space.displayableTab(id:)` is the one predicate for "is this a tab a window
on this space can show"; it covers the first three. Copies of that test that
forgot favorites dropped a selected favorite on space switch (TASK-54).

## Singletons

| Singleton | File | Holds |
|---|---|---|
| `TabStore.shared` | [TabStore.swift](../../Detour/Browser/TabStore.swift) | Profiles, spaces, the undo manager, save scheduling, sleep/archive timer. See [TabStore](./tabstore.md). |
| `AppDatabase.shared` | [Database.swift](../../Detour/Storage/Database.swift) | `browser.db`: session, profiles, extensions. See [session database](./session-database.md). |
| `HistoryDatabase.shared` | [HistoryDatabase.swift](../../Detour/Storage/HistoryDatabase.swift) | `history.db`. See [history database](./history-database.md). |
| `ExtensionManager.shared` | `Detour/Extensions/Runtime/ExtensionManager.swift` | Installed extensions and their contexts. See [extensions overview](../extensions/overview.md). |
| `ContentBlockerManager.shared` | `Detour/Browser/ContentBlocker/ContentBlockerManager.swift` | Filter lists. See [content blocking](../features/content-blocking.md). |
| `DownloadManager.shared` | `Detour/Browser/Downloads/DownloadManager.swift` | Downloads. See [downloads](../features/downloads.md). |
| `GPUProcessRecycler.shared` | [GPUProcessRecycler.swift](../../Detour/Browser/GPUProcessRecycler.swift) | See [GPU IOSurface limit](../platform/gpu-iosurface-limit.md). |
| `SettingsWindowController.shared` | `Detour/Browser/Settings/SettingsWindowController.swift` | The Settings window. See [settings](../features/settings.md). |

`AppDatabase` and `HistoryDatabase` are structs wrapping a GRDB
`DatabaseQueue`; "singleton" means the `shared` instance. Both, and
`TabStore`, take injected instances in tests (`TabStore(appDB:historyDB:…)`),
so a test can run a private store against an in-memory database.

# How they connect

Four mechanisms, each with one job:

| Mechanism | Used for | Why this one |
|---|---|---|
| `TabStoreObserver` protocol | Structural changes to spaces, tabs, pinned entries, favorites | Callbacks carry indices that map onto table animations. See [observer protocol over Combine](../decisions/observer-protocol-over-combine.md). |
| `@Published` on `BrowserTab` | Per-tab state: title, URL, loading, favicon, audio | Mirrors KVO on `WKWebView`; subscribers are the store (to notify and save), the window (chrome), and extension forwarding. |
| Delegates | User actions flowing up: `TabSidebarDelegate` (sidebar to window), `CommandPaletteDelegate`, `FindBarDelegate` | One receiver, typed. See [sidebar overview](../sidebar/overview.md). |
| `NotificationCenter` | Cross-window events with no natural owner | See the table below. |

The direction is always: a view asks its window controller through a
delegate, the window controller calls a `TabStore` mutation, the store
mutates and notifies every observer, and each window updates its own sidebar
and content. Windows never mutate `space.tabs` themselves.

Notifications in the browser core:

| Name | Posted by | Effect |
|---|---|---|
| `webViewOwnershipChanged` | The window that just took a tab's web view | Other windows showing that tab switch to a snapshot. |
| `spaceTabsNeedRehost` | `TabStore.updateSpace` (profile swap), `Profile.retargetExtensionPages` | Windows on the space re-select their displayed tab so it wakes from the new configuration. |
| `tabRestoredByUndo` | Undo of Close Tab | The window on that space selects the restored tab. |
| `"UserAgentDidChange"` (string literal) | `TabStore.updateProfile` | Every `BrowserTab` of the profile re-applies its user agent. |
| `contentBlockerRulesDidChange` | `ContentBlockerManager` | Windows re-apply rule lists to the web views they own. |

`ExtensionManager` posts several more (`extensionsDidChangeNotification`,
`tabShouldSelectNotification` and others); those belong to the
[extension pages](../extensions/overview.md).

Undo is one `UndoManager` on `TabStore`. `BrowserWindowController.undoManager`
returns it, and `BrowserWebView.performKeyEquivalent` routes Cmd+Z to it
unless the page has an editable field focused.

## Launch sequence

`AppDelegate.applicationDidFinishLaunching`, in order:

1. `setupMainMenu()`.
2. Open `AppDatabase.shared` and `HistoryDatabase.shared` (migrations run
   here).
3. `TabStore.shared.retryPendingProfileDataRemovals()` — must precede
   anything that creates a profile's data store or extension controller. See
   [profile data removal](./profile-data-removal.md).
4. Schedule, 5 s later, `HistoryDatabase.expireOldVisits()` and
   `TabStore.sweepHistoryOfDeletedSpaces()`.
5. `ContentBlockerManager.shared.initialize()`.
6. `ExtensionManager.shared.initialize()`, then
   `ExtensionUpdater.shared.startPeriodicChecks()`.
7. Create and show the first `BrowserWindowController`.
8. `TabStore.shared.restoreSession()`, then `ensureDefaultSpace()`.
9. `startArchiveTimer()` and `GPUProcessRecycler.shared.start()`.
10. Set the window's active space and selected tab from the restored session.

The window exists **before** the session is restored. It becomes a
`TabStoreObserver` in its initialiser and is given its space in step 10.
Extension contexts load asynchronously after step 6, which is why restore
cannot rewrite extension page URLs itself and registers
[pending origins](../extensions/extension-pages.md) instead.

Steps 3, 4 (the sweep) and the updater start are skipped in the XCTest host.
See [app shell](./app-shell.md).

## Where each area's pages are

| Area | Start at |
|---|---|
| State, ownership, persistence | this directory |
| Tab rules: lifecycle, pinning, splits, archive | [tab lifecycle](../tabs/tab-lifecycle.md) |
| Sidebar rows, drag and drop, focus | [sidebar overview](../sidebar/overview.md) |
| Command palette, history page, downloads, blocking | [command palette](../features/command-palette.md) |
| Web Extensions | [extensions overview](../extensions/overview.md) |
| WebKit and AppKit behaviour | [AppKit gotchas](../platform/appkit-gotchas.md) |
| Building, verifying, debugging | [build and test](../playbooks/build-and-test.md) |

# Disagreements between the docs and the code

- `docs/architecture.md` lists the launch steps in a different order (history
  expiry first, no extension manager, window before the content blocker).
  The order above is what `AppDelegate` does.
- `CLAUDE.md` and `docs/architecture.md` say "macOS 14+". `project.yml` sets
  the deployment target to macOS 15.4.
- `docs/architecture.md` names six singletons; the table above adds the ones
  added since (`ExtensionManager`, `GPUProcessRecycler`).

# Related

- [TabStore](./tabstore.md) — the state singleton in detail.
- [Persistence](./persistence.md) — what is saved and when.
- [Web view ownership](./webview-ownership.md) — the one-owner rule.
- [App shell](./app-shell.md) — `AppDelegate`, menus, launch switches.
