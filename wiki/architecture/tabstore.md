---
type: Component
title: TabStore
description: The state singleton that owns profiles, spaces and tabs — its observer protocol, mutation families, what triggers a save, and the invariants every mutation keeps.
resource: ../../Detour/Browser/TabStore.swift
tags: [architecture, state, tabs, undo]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:20Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift
  - id: window-observer
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabStore.swift
    title: BrowserWindowController+TabStore.swift
  - id: tab-insertion
    resource: ../../Detour/Browser/TabInsertion.swift
    title: TabInsertion.swift
  - id: tabstore-tests
    resource: ../../DetourTests/TabStoreTests.swift
    title: TabStoreTests.swift
  - id: task-40
    resource: backlog:TASK-40
    title: Undo actions registered before Delete Space act on a stale Space object
  - id: task-52
    resource: backlog:TASK-52
    title: Extension contexts are told about a tab when it is placed
  - id: task-88
    resource: backlog:TASK-88
    title: Late titles correct the recorded history visit
  - id: task-91
    resource: backlog:TASK-91
    title: Per-visit titles and pushState visits
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process IOSurface leak and the show budget
---

# Role

`TabStore` is the single owner of browser state. Everything structural —
adding, closing, moving, pinning, splitting, favoriting, archiving — is a
method on it. It notifies observers, registers undo, schedules the session
save, records history visits, and runs the sleep/archive timer. Views and
window controllers read its model objects but change them only through its
methods.

`TabStore.shared` is the app's instance. The initialiser takes the two
databases, the profile data remover, the WebKit storage scope and the history
debounce as parameters, and many test suites build a private store against an
in-memory database rather than touching `shared`.

# How it works

## What it owns

| Property | Notes |
|---|---|
| `profiles: [Profile]` | Includes the built-in Private profile. `private(set)`. |
| `spaces: [Space]` | Normal and incognito spaces together; `nonIncognitoSpaces` filters. `private(set)`. A space appended here announces its live tabs to extensions (`didSet`). |
| `undoManager` | The one browsing `UndoManager`. Windows return it as their own. |
| `lastActiveSpaceID` | Persistence only; live active space is per window. |
| `observers` | Weak `TabStoreObserver` references. |
| `tabSubscriptions` | Per-tab Combine sinks, keyed by tab id. |
| `recentHistoryWrites` | The 30 s history dedup cache, `"url\|spaceID" → time`. |
| `spaceIDsDeletedThisSession` | Keeps the launch history sweep off spaces Undo can still restore. |

Closed-tab records are deliberately **not** held here; the `closedTab` table
is the only store. See
[closed tabs: database only](../decisions/closed-tabs-database-only.md).

## Observer protocol

`TabStoreObserver` is a class-bound protocol; every method has an empty
default, so a conformer implements only what it needs. Observers are held
weakly and dead entries are pruned on each notify.
`BrowserWindowController` is the production observer (one per window).

| Callback | Sent when |
|---|---|
| `tabStoreDidInsertTab(_:at:in:)` | A tab entered `space.tabs`. |
| `tabStoreDidRemoveTab(_:at:in:)` | A tab left `space.tabs` — closed, or handed to another section (`detachTab`). A list change, not a close. |
| `tabStoreDidReorderTabs(in:)` | Order changed; also how split create/separate arrives. |
| `tabStoreDidUpdateTab(_:at:in:)` | A published property of a normal tab changed. |
| `tabStoreDidUpdateSplitLayout(in:)` | Divider fraction only. |
| `tabStoreDidInsertPinnedEntry` / `DidRemovePinnedEntry` / `DidReorderPinnedEntries` / `DidUpdatePinnedEntry` | Pinned section changes. Closing a pinned tab is an **update** (the entry stays, dormant), not a remove. |
| `tabStoreDidPinTab` / `tabStoreDidUnpinTab` | One atomic callback carrying both indices, so the sidebar can animate a move between sections. |
| `tabStoreDidUpdatePinnedFolders(in:)` | Folder tree changed. |
| `tabStoreDidUpdateFavorites(for:)` | A profile's favorites changed. |
| `tabStoreDidUpdateSpaces()` | Space list or a space's identity changed. |
| `tabStoreDidAddProfile(_:)` | A profile was created mid-session. Not sent for profiles loaded by `restoreSession`. |
| `tabStoreDidUpdateClosedTabRecords()` | The `closedTab` table changed. Carries no detail. |

Every window receives every callback. Each space-scoped handler in
`BrowserWindowController` starts with `guard space.id == activeSpaceID`, and
for other spaces only tells the sidebar that an inactive space's content
changed (its [space paging](../sidebar/space-paging.md) pages). A new
space-scoped callback needs that guard too.

Why a protocol and not a Combine publisher:
[observer protocol over Combine](../decisions/observer-protocol-over-combine.md).

## Mutation families

| Family | Entry points |
|---|---|
| Profiles | `addProfile`, `updateProfile`, `deleteProfile`, `ensureIncognitoProfile` |
| Spaces | `addSpace`, `deleteSpace`, `updateSpace`, `moveSpace`, `ensureDefaultSpace`, `addIncognitoSpace`, `removeIncognitoSpace` |
| Normal tabs | `addTab(in:url:)`, `addTab(in:internalPage:)`, `addTab(in:webView:)`, `addExtensionTab`, `closeTab`, `moveTab(from:to:in:)`, `moveTab(id:toGapIndex:in:)`, `detachTab` |
| Across spaces | `moveTab(id:from:to:)`, `movePinnedEntry(id:from:to:)`, `canMoveTab`, `moveTabRefusal` |
| Splits | `createSplit`, `addTabInSplit`, `separateSplit`, `removeTabFromSplit`, `closeSplitGroup`, `setSplitFraction`, and the pinned variants |
| Pinned | `pinTab`, `pinURL`, `unpinTab`, `closePinnedTab`, `deletePinnedEntry`, `activatePinnedEntry`, folder add/delete/rename/move |
| Favorites | `addFavorite`, `moveTabToFavorites`, `activateFavorite`, `deactivateFavorite`, `removeFavorite`, `restoreFavoriteAsTab`, `restoreFavoriteAsPinned`, `reorderFavorite` |
| Closed tabs | `reopenClosedTab`, `restoreClosedTab`, `deleteClosedTabRecord`, `clearClosedTabRecords`, `archiveEntries` |
| Timers | `startArchiveTimer`, `sleepStaleTabs`, `archiveStaleTabs` |
| History | `recordHistoryVisit`, `updateHistoryTitle`, `historyDidDelete`, `sweepHistoryOfDeletedSpaces` |

The rules behind each family are on the tab pages:
[tab lifecycle](../tabs/tab-lifecycle.md),
[insertion and close selection](../tabs/tab-insertion-and-close-selection.md),
[split tabs](../tabs/split-tabs.md),
[pinned tabs and folders](../tabs/pinned-tabs-and-folders.md),
[favorites](../tabs/favorites.md),
[closed tabs and archive](../tabs/closed-tabs-and-archive.md),
[sleeping and archiving](../tabs/sleeping-and-archiving.md).

Two store-level facts about `addTab`:

- `addTab(in:url:)` cannot open a `detour://` internal page, on purpose: its
  callers include an extension's `tabs.create` and web content's
  `window.open`. `addTab(in:internalPage:)` is the only way in.
- `addExtensionTab` builds the web view from the **extension context's**
  configuration. A `webkit-extension://` URL cannot load in a configuration
  made by `Space.makeWebViewConfiguration()`.

## Shape of a mutation

Almost every mutation follows the same order, and the order is load-bearing:

1. Capture what undo needs (interaction state via
   `currentInteractionStateData()` must be read **before** teardown).
2. Mutate the model.
3. `registerUndo(actionName:)` with a closure that performs the inverse and
   registers its own redo.
4. `notifyObservers`.
5. `scheduleSave()`.

`closeTab` adds: push the `ClosedTabRecord` first, then drop the tab's
subscriptions, remove it from the list, `tab.teardown()`, leave its split
group — and only then notify. Observers therefore see a tab that is already
torn down; teardown is what reports the close to extension contexts, not the
remove callback.

Undo closures capture **ids**, and resolve the space and tab when they run.
Undo of Delete Space rebuilds a space's tabs as new objects with the old ids,
so a captured tab object can be an orphan by the time its undo runs
(TASK-40). The one deliberate exception is the Delete Space undo itself,
which retains the `Space` instance.

## Per-tab subscriptions

`subscribeToTab` is called wherever a tab enters the store's care (insert,
restore, undo rebuild). It installs sinks on the tab's `@Published`
properties:

| Property | Effect |
|---|---|
| `title`, `peekFavicon`, `isPlayingAudio`, `isMuted` | Notify (`tabStoreDidUpdateTab` or `…DidUpdatePinnedEntry`). |
| `url`, `favicon` | Notify and `scheduleSave()`. |
| `isLoading` | Notify; on `false`, `recordHistoryVisit`. |
| `url`, debounced 1 s | `recordSameDocumentNavigationIfNeeded` (pushState visits). |
| `title`, debounced 1 s | `updateHistoryTitle` (late title correction). |
| `estimatedProgress`, throttled 100 ms | Notify. |
| `isLoadProgressStalled` | Notify. |

The notify closure looks the tab up in each space's pinned entries, then its
tabs. A **favorite's** backing tab is in neither, so its changes produce no
observer callback; favorite tiles subscribe to what they show themselves.

The subscription reads `tab.spaceID` when a visit is recorded rather than
capturing a space, so a tab rehomed onto another space keeps its subscription
and records under the space it is in now.

The history rules these sinks drive — the 30 s dedup, the 60 s title
correction window, back/forward item identity for pushState — are pure
policies (`HistoryTitleUpdatePolicy`, `SameDocumentVisitPolicy`) at the bottom
of the file and are described on
[history recording and search](../features/history-recording-and-search.md).

## Persistence triggers

`scheduleSave()` debounces `saveNow()` by 1 second on the main queue.
`saveNow()` runs immediately on app termination, on window close, and at the
start of `deleteProfile`. Details and the write order are on
[persistence](./persistence.md).

# Invariants

- **Split members are contiguous.** Two tabs sharing `splitGroupID` are
  adjacent in `space.tabs`, left pane first. Every insertion index is passed
  through `snappedToSplitGroupBoundary`; `moveTab` moves the whole block;
  close, pin and detach dissolve a group left with one member.
  `sanitizeSplitGroups` repairs at load and after an undo rebuild.
- **A pinned split lives on the entries.** While pinned, `splitGroupID` is on
  the two `PinnedEntry`s; the backing tabs' `splitGroupID` stays nil.
  `splitGroup(containing:in:)` resolves both kinds.
- **At least one space.** `deleteSpace` refuses the last one. The guard
  counts incognito spaces, so "one" can be a Private window's space.
  `forceRemoveSpace` skips the guard and is for test teardown only.
- **A space's profile exists.** `deleteProfile` refuses a profile a space
  uses; `updateSpace` refuses an unknown profile id.
- **Incognito never reaches disk.** `saveNow` filters incognito spaces out;
  `closeTab` pushes no closed-tab record for them; `recordHistoryVisit`
  returns early; tabs cannot move across the incognito boundary.
- **A tab with a web view from a profile's configuration is registered with
  that profile's extension contexts.** Placement in a list is what registers
  it (`Space.tabs` / `pinnedEntries` / `Profile.favorites` `didSet`, TASK-52),
  and `BrowserWindowController.assertExtensionRegistered` checks it in debug
  builds.
- **`tab.spaceID` names a live space of the tab's profile.** `wake()` resolves
  the configuration through it. Favorite backing tabs are rehomed when their
  space is deleted.

# Gotchas

- `sleepStaleTabs` decides "on screen" two ways: `lastDeselectedAt == nil`
  (selected somewhere) or `webViewContainer.superview != nil` (hosted
  somewhere). Two windows on one space share one `lastDeselectedAt`, so the
  timestamp alone would let one window's deselect sleep the tab the other is
  showing.
- `closeTab(…, undoable: false)` neither records nor registers undo (a page
  that can never be reopened). `registersUndo: false` records but registers
  no undo (the automatic archive sweep, which must not fill the undo stack).
- `moveTab(from:to:in:)` has no `source == destination` shortcut. Source is a
  pre-removal index and destination a post-removal one; for a non-first split
  member equal numbers can be a real move. `resolveTabMove` owns the no-op
  check.
- `updateProfile` posts the string-named `"UserAgentDidChange"`
  notification on every profile edit, not only user agent edits.
- The sleep show-budget constants are read from the environment once, at
  first use: `DETOUR_SLEEP_SHOW_BUDGET` and
  `DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS` (TASK-104).

# Tests

`TabStoreTests` covers the core mutations. Around it: `SplitTabTests`,
`TabInsertionTests`, `TabCloseSelectionTests`, `MoveTabToSpaceTests`,
`PinnedTabMoveTests`, `UndoAfterDeleteSpaceTests`, `ProfileDeletionUndoTests`,
`SleepShowBudgetTests`, `ArchivedTabRestoreTests`, `HistoryTitleUpdateTests`,
`SameDocumentVisitTests`, `TabRecordFactoryTests`. State and rule changes
here are test-first by project policy (see `CLAUDE.md`).

# Related

- [Architecture overview](./overview.md) — where the store sits.
- [Profiles and spaces](./profiles-and-spaces.md) — the space and profile mutations in detail.
- [BrowserTab](./browser-tab.md) — the object the subscriptions watch.
- [BrowserWindowController](./browser-window-controller.md) — the observer.
- [Persistence](./persistence.md) — `saveNow` and `restoreSession`.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — the extension seam the list setters feed.
