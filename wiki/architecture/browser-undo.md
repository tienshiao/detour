---
type: Concept
title: Browser undo
description: "Detour's undo of browsing actions: the one app-wide UndoManager on TabStore, which mutations register an entry and which do not, how closures capture spaces (the instance) and tabs (by id), grouping, when the stack is cleared, how a closed Private window's entries leave it, the identity and deleted-profile pitfalls, and which window answers Edit > Undo."
tags: [architecture, undo, state, menus]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T09:55:23Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (undoManager, registerUndo, PrivateUndoEntry, dropUndoEntries, removeIncognitoSpace, reRegisterRunningUndoEntry, every registering mutation, deleteProfile)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (undoManager, browserUndo:, undoTarget, handleTabRestoredByUndo)
  - id: webview
    resource: ../../Detour/Browser/Window/BrowserWebView.swift
    title: BrowserWebView.swift (the page's own undo manager, editingPage(in:))
  - id: quick-detour-window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift (browserUndo:, page only)
  - id: launcher
    resource: ../../Detour/Browser/QuickDetour/QuickDetourLauncher.swift
    title: QuickDetourLauncher.swift (browserUndo:, the field's typing)
  - id: field-undo
    resource: ../../Detour/Commands/FieldUndo.swift
    title: FieldUndo.swift (the launcher's, Settings' and the popup's own undo)
  - id: settings
    resource: ../../Detour/Browser/Settings/SettingsWindowController.swift
    title: SettingsWindowController.swift (browserUndo:, its fields' typing)
  - id: site-search-form
    resource: ../../Detour/Browser/Settings/SearchSettingsViewController.swift
    title: SearchSettingsViewController.swift (SiteSearchForm's browserUndo:, the sheet's fields)
  - id: add-profile
    resource: ../../Detour/Browser/Sidebar/AddProfileViewController.swift
    title: AddProfileViewController.swift (browserUndo:, the Add Profile sheet's field)
  - id: popup
    resource: ../../Detour/Extensions/UI/ExtensionPopoverController.swift
    title: ExtensionPopoverController.swift (PopupContentView's browserUndo:, the popup page's edits)
  - id: commands
    resource: ../../Detour/Commands/BrowserCommands.swift
    title: BrowserCommands.swift (edit.undo, edit.redo)
  - id: appdelegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (applicationWillTerminate)
  - id: tests-delete-space
    resource: ../../DetourTests/UndoAfterDeleteSpaceTests.swift
    title: UndoAfterDeleteSpaceTests.swift
  - id: tests-profile
    resource: ../../DetourTests/ProfileDeletionUndoTests.swift
    title: ProfileDeletionUndoTests.swift
  - id: tests-routing
    resource: ../../DetourTests/PageUndoRoutingTests.swift
    title: PageUndoRoutingTests.swift
  - id: tests-private
    resource: ../../DetourTests/PrivateWindowUndoTests.swift
    title: PrivateWindowUndoTests.swift (PrivateWindowUndoTests, PrivateWindowUndoWindowTests)
  - id: harness-357
    resource: ../../docs/harness/task357-private-undo-checks.py
    title: task357-private-undo-checks.py (the runtime check through the automation endpoint)
  - id: page-undo
    resource: ../platform/page-key-equivalents-and-undo.md
    title: A page's key equivalents and its undo
  - id: task-40
    resource: backlog:TASK-40
    title: Undo actions registered before Delete Space act on a stale Space object
  - id: task-35
    resource: backlog:TASK-35
    title: Undo of Delete Space / Edit Space after its profile was deleted crashes
  - id: task-119
    resource: backlog:TASK-119
    title: Archived Tabs page; close undos skip consumed records
  - id: task-28
    resource: backlog:TASK-28
    title: Undoing the close of an extension page tab restores a dead page
  - id: task-345
    resource: backlog:TASK-345
    title: "Undo and redo: a page gets ⌘Z and ⇧⌘Z first, and Edit › Undo/Redo reach the page's own undo while editing"
  - id: task-346
    resource: backlog:TASK-346
    title: "Quick Detour launcher: ⌘Z in its field undoes the typing, never Detour's closed-tab list"
  - id: task-349
    resource: backlog:TASK-349
    title: "Undo: ⌘Z in Settings text fields and extension popups reaches the browser window's closed-tab undo"
  - id: tests-settings-popup
    resource: ../../DetourTests/SettingsAndPopupUndoTests.swift
    title: SettingsAndPopupUndoTests.swift
  - id: task-193-1
    resource: backlog:TASK-193.1
    title: "Quick Detour: the window, its single tab and the palette that opens it"
  - id: task-357
    resource: backlog:TASK-357
    title: "Private windows: their undo entries outlive the window and can rebuild a Private tab nobody sees"
  - id: incognito
    resource: ./incognito.md
    title: Incognito (Private windows)
  - id: task-360
    resource: backlog:TASK-360
    title: "Undo: Move Space's undo stores positions in the space list, which Private windows shift"
---

# Summary

Structural browsing actions (tabs, pinned entries, folders, splits, spaces)
are undone through **one `UndoManager`**, `TabStore.undoManager`. It is app
wide: every `BrowserWindowController` returns it as its `undoManager` and
runs it from Edit > Undo, so Cmd+Z in any browser window undoes the newest
action wherever it happened, in another window or another space included
(a closed Private window's actions excepted).
It is not the `NSWindow`'s own undo manager (AppKit asks only the window's
delegate for that), which the window's text fields type into; Edit > Undo
does not reach that one, so with focus in the palette or the find bar
Cmd+Z still undoes the browser's list.

It is not the only undo in the app. Each page (`BrowserWebView`) keeps its
own undo manager for its edits, and Edit > Undo runs exactly one of the two:
the focused page's while an editable element in it has the keys, else the
browser's. The key reaches the page first; the rule and WebKit's side of it
are on [A page's key equivalents and its undo](../platform/page-key-equivalents-and-undo.md)
(TASK-345). This page is about the browser's list.

# Rules

## Registering an entry

Every registering mutation follows the store's order
([TabStore](./tabstore.md#shape-of-a-mutation)): capture what the inverse
needs (a tab's interaction state before teardown), mutate, then
`registerUndo(actionName:in:handler:)`, which registers the closure and
names it. `in:` lists the spaces the closure acts in (both for Move to
Space); it is not optional, so every new registration has to say. An entry of a normal space has the store as target; an entry of
a Private space gets its own target
([below](#a-private-windows-entries-go-with-the-window)). The handler performs the inverse and, as
AppKit does for a registration made while undoing, its own registration of
the forward action lands on the redo stack. A handler that finds nothing to
do (below) returns without registering, so that entry has no redo.

| Area | Action names (Edit shows "Undo …") |
|---|---|
| Spaces | Add Space, Delete Space, Edit Space, Move Space |
| Normal tabs | Close Tab, Archive Tab (the sidebar's Archive items; a redo stays an archive), Move Tab, Move to Space |
| Splits | Split Tabs, Open in Split, Separate Tabs, Move Tab Out of Split, Close Both Splits, Pin Split, Unpin Split |
| Pinned | Pin Tab, Unpin Tab, Close Tab (made dormant), Delete Tab, Rename, Move Tab, Move to Space |
| Pinned folders | New Folder, Delete Folder, Rename Folder, Move Folder |
| Peek | Close Peek ([Peek](../tabs/peek.md)) |

Registers **nothing**: the automatic archive sweep (`registersUndo: false`)
and a close that could never be reopened (`undoable: false`), see
[tab lifecycle](../tabs/tab-lifecycle.md); Reopen Closed Tab and the
Archived Tabs page's restore; sleeping, waking and activating a dormant
entry; favourite mutations ([favourites](../tabs/favorites.md)); a split's
divider fraction; adding or removing a Private window's space; profile
changes; an Arc import. The Spaces pane in Settings goes through the same
`addSpace`, `updateSpace`, `deleteSpace` and `moveSpace`, so its changes are
on the stack.

An undone close (Close Tab, Close Both Splits, a pinned close, Close Peek)
posts `.tabRestoredByUndo`; each window whose active space is the tab's
selects it.

## Grouping

Detour never opens an undo group itself. `UndoManager.groupsByEvent` is on
(the default), so everything registered during one pass of the event loop
is one entry, named by the last `setActionName`. From the code, not
measured: Archive Tabs Below, which closes several tabs from one menu
action, comes back with one Cmd+Z, as does a sidebar drop that issues several
mutations. Measured: two tabs closed through the
automation endpoint's `run_menu_item` with no event between them came back
with one Cmd+Z, where two real Cmd+W presses make two entries
([page undo](../platform/page-key-equivalents-and-undo.md)).

Actions that must be one entry whatever the event loop does are one
closure: `closeSplitGroup` closes both members under a single "Close Both
Splits", since two `closeTab` undos could not pair up (each mints new ids).

A test body never turns the run loop, so the automatic group never closes:
the undo tests set `groupsByEvent = false` and group each action
explicitly. A harness must never end the automatic group by hand
(NSUndoManager throws; see
[space deletion and link routes](../features/link-routing-space-deletion.md)).

## Capture: the space by instance, everything else by id

- Most closures capture the **`Space` object** (Close Tab, Move Tab, Pin,
  the split, pinned and folder actions, Close Peek). Undo Delete Space
  therefore re-inserts **the same instance** it removed (captured strongly,
  its three lists emptied in between), so every older closure still acts
  on the space the windows show (TASK-40).[^task-40]
- **Tabs, pinned entries and folders are captured by id** and looked up
  when the closure runs. Undo Delete Space rebuilds them as new objects with
  the old ids, so a captured object could be an orphan by then.
- Move to Space resolves **both spaces by id** at undo time; Add Space and
  Edit Space work on the space id too.
- **Move Space records the space's id and its place among the normal
  spaces** (`stablePosition(of:)`: every normal space, plus the moved one),
  never an index into `spaces`, which holds the Private windows' spaces too.
  The undo and redo put it before the normal space now at that place, or
  after the last one (`moveSpace(id:toStablePosition:)`). The old index pair
  drifted when a Private window closed between the move and its undo: N, B, C
  came back as N, C, B (confirmed by a failing test; a window opening only
  appends, which never shifted the indexes).[^task-360]
- A tab that comes back from a close undo is a **new tab with a new id**
  (`restoredTab`). Its redo closes `restored.id`; a split partner closed
  separately cannot rejoin by id; a child whose opener was closed and undone
  comes back unlinked ([tab opener](../tabs/tab-opener.md)).

## Undo that finds nothing to do

- **Consumed closed-tab record.** A close undo first asks
  `AppDatabase.hasClosedTab(tabID:)`; once the record was reopened,
  restored from the archive page, deleted or cleared, the undo does nothing
  (else a duplicate tab).[^task-119] Private closes push no record and
  always undo. Details on [closed tabs and archive](../tabs/closed-tabs-and-archive.md#close-undo).
- **An extension page whose extension is disabled or uninstalled since**
  yields no tab: the undo does nothing and leaves the record to Reopen
  Closed Tab.[^task-28]
- **A refused space deletion.** Undo of Add Space (and redo of Delete
  Space) can be refused by a link route; the entry is put back on its
  stack with a one-step bounce (`reRegisterRunningUndoEntry`, which carries
  the replaced entry's spaces, TASK-361), described on
  [space deletion and link routes](../features/link-routing-space-deletion.md).

## When the stack is cleared

`removeAllActions()` has three callers:

| Caller | Why |
|---|---|
| `TabStore.deleteProfile` | Closures hold spaces, spaces hold their profile strongly, and `UndoManager` cannot drop only the entries that mention one profile; an undo must never rebuild a space onto a deleted profile's removed storage (TASK-35).[^task-35] Undo Delete Space and Undo Edit Space also check that their profile still exists and do nothing (no redo) when it does not. See [profile data removal](./profile-data-removal.md). |
| `applicationWillTerminate` | The stack does not outlive the session. |
| The automation endpoint's staging | Seeding a world is not something to undo. |

## A Private window's entries go with the window

The stack is shared, so a close in a Private window is undoable from any
browser window **while the Private window is open**. When it closes,
`removeIncognitoSpace` first calls `dropUndoEntries(ofPrivateSpace:)`, which
takes every undo and redo entry acting in that space off both stacks and
leaves every other entry, normal windows' and other Private windows', where
it was (TASK-357).[^task-357]

- **Per-entry target.** `registerUndo` registers an action in a Private
  space against a `PrivateUndoEntry` of its own (the spaces it acts in, and
  the handler), which the store tracks weakly. Dropping one empties its
  handler, releasing the page's URL, title and back/forward list at once,
  then `UndoManager.removeAllActions(withTarget:)` removes it; that call
  also removes a group it leaves empty (measured).
- **Not while a group is open.** On an open group the same call leaves an
  empty group behind, which the next Cmd+Z then spends doing nothing
  (measured). The group of an event stays open until the next event ends
  it, so it is open when the window closes in the event that registered in
  that space, and, with no event at all, whenever the
  [automation endpoint](../features/automation-endpoint.md) drives the app
  (measured below). The removal then waits for the first of: the group
  closing (`NSUndoManagerDidCloseUndoGroup`, then one main-queue hop, since
  the group reaches the stack only after the notification), or an undo or
  redo starting (`willUndo`/`willRedo`): Undo closes the open group itself
  and runs it at once, so the entries are taken off there and the undo
  reaches the action below. Until then the dropped entries do nothing.
  A store released while the removal waits (only a test's) removes those
  observers in its `isolated deinit`; before TASK-363 NotificationCenter
  kept them.
- **`UndoManager` does not retain a target** (measured), so the entry's
  closure holds it.
- **Guards.** No entry is registered for a Private space already gone (an
  empty group from the same event can remain, with no name), and a Private
  entry's handler runs only while each of its spaces is still in `spaces`,
  registering no redo otherwise.
- A Move to Space between two Private windows (the store allows it; no
  Private window offers the menu) lists both spaces and goes with either.

Before the fix, measured in a test against the old code and in the
running app (`docs/harness/task357-private-undo-checks.py`, driven through
the automation endpoint): after the Private window closed, Undo Close Tab
from a normal window rebuilt the Private tab with a live web view on the
Private profile's store, in the removed space no window shows, and posted
`.tabRestoredByUndo` for that space; the app requested the Private page
from the local server again, and the first Cmd+Z went to that invisible tab
rather than to the normal close below it. Since the session's reset had
already run, whatever that page stored would have stayed in the store the
next Private session reuses. The same harness against the fix: the first
Cmd+Z brings back the normal tab, the Private page is never requested
again, and Undo is then disabled. A first cut that polled for the group to
close (2 s) left the endpoint's still-open group in place, and its first
Cmd+Z did nothing; hence the notifications.

## Which window answers Edit > Undo

Edit > Undo and Redo send `browserUndo:` / `browserRedo:` (not AppKit's
`undo:`) to the first responder, so AppKit asks the key window's chain,
then the main window's.

| Key window | Runs | Never runs |
|---|---|---|
| A browser window | the focused page's undo while it edits (`undoTarget(focusedPageIsEditing:isKeyWindow:)` is `.page`), else `TabStore.undoManager` (focus in the palette or the find bar included) | — |
| A [Quick Detour](../features/quick-detour-window.md) or quarantine window | its page's undo while a field in it has the keys; otherwise the item is disabled | `TabStore`'s list (TASK-193.1, TASK-345) |
| The [Quick Detour launcher](../features/quick-detour-launcher.md) panel | the palette field's typing | `TabStore`'s list: before TASK-346 the item fell through to the main browser window and reopened a closed tab behind the panel[^task-346] |
| Settings | the typing in its field with the keys (`SettingsWindowController`) | `TabStore`'s list. Settings is the main window while it is key, so the actions never reached a browser window from it; before TASK-349 nothing answered them: disabled, still titled from the browser window that validated them last ("Undo Close Tab"), and the typing could not be undone[^task-349] |
| A sheet on Settings with a field (Add Site Search, Add Profile) | its fields' typing, on the sheet's own undo manager (`SiteSearchForm`, `AddProfileViewController`, in the fields' chain) | `TabStore`'s list. Settings' controller cannot answer for it: AppKit disables a menu action aimed at a window with a sheet attached (measured: "Undo Typing", disabled) |
| An extension's action popup | the popup page's edits, which WebKit registers with the web view's undo manager (the popover window's), answered by its `PopupContentView`; with the popover window itself first responder, by the browser window's fallback below | `TabStore`'s list: the popover window is key but never main, and its own next responder is the window it is shown from, so before TASK-349 ⌘Z in the popup reopened a closed tab in the browser window behind it |
| Any other window that is not a browser window, has the keys and does not answer (the Downloads, site settings and emoji picker popovers, none with a text field) | the browser window's `browserUndo:` (through the popover window's next responder, or as the main window's), which runs **that key window's** own undo (`nonBrowserKeyWindow` + `FieldUndo`; only when the key window's chain hands Undo to this controller, or to nothing in a window that is not main, so a command addressed to a browser window stays its own): nothing for those popovers, disabled and titled "Undo" | `TabStore`'s list; before TASK-349 ⌘Z there reopened a closed tab. Doing nothing there is the user's decision (2026-11-16)[^task-349] |

The item's title and enabled state come from the same choice
(`BrowserCommands.undo` / `.redo`: "Undo Typing" from the page, "Undo
Close Tab" from the store). Neither is offered in the command palette. The
launcher, Settings, its sheets and the popup share one rule,
`FieldUndo`: the undo manager of the first responder in that window (the
field editor's, or the popup web view's), undo or redo when it can, titled
from it, disabled with nothing, and never `TabStore.undoManager`. The
browser window's own `browserUndo:` applies it too, to the key window,
whenever the key window is not a browser window: a safety net for any
popover, panel or sheet that does not answer the actions itself.[^task-349]

# Where it lives

| What | Where |
|---|---|
| The manager, `registerUndo`, `PrivateUndoEntry`, `dropUndoEntries`, `reRegisterRunningUndoEntry`, every registering mutation | [TabStore.swift](../../Detour/Browser/TabStore.swift) |
| `undoManager` override, `browserUndo:`, `UndoTarget`, `handleTabRestoredByUndo` | [BrowserWindowController.swift](../../Detour/Browser/Window/BrowserWindowController.swift) |
| The page's undo manager, `editingPage(in:)` | [BrowserWebView.swift](../../Detour/Browser/Window/BrowserWebView.swift) |
| Quick Detour and launcher responders | [QuickDetourWindowController.swift](../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift), [QuickDetourLauncher.swift](../../Detour/Browser/QuickDetour/QuickDetourLauncher.swift) |
| The field-undo rule; Settings, its sheets and the popup; the fallback (`nonBrowserKeyWindow`, in BrowserWindowController.swift) | [FieldUndo.swift](../../Detour/Commands/FieldUndo.swift), [SettingsWindowController.swift](../../Detour/Browser/Settings/SettingsWindowController.swift), [SearchSettingsViewController.swift](../../Detour/Browser/Settings/SearchSettingsViewController.swift) (`SiteSearchForm`), [AddProfileViewController.swift](../../Detour/Browser/Sidebar/AddProfileViewController.swift), [ExtensionPopoverController.swift](../../Detour/Extensions/UI/ExtensionPopoverController.swift) (`PopupContentView`) |
| Tests | `UndoAfterDeleteSpaceTests`, `ProfileDeletionUndoTests`, `PrivateWindowUndoTests` (Move Space across Private windows too), `PrivateWindowUndoWindowTests`, `PageUndoRoutingTests`, `ExtensionPageUndoTests`, `ClosedTabOpenerTests`, `ClosedPeekTests`, `MoveTabToSpaceTests`, `LinkRouteStoreTests`, `QuickDetourLauncherTests`, `SettingsAndPopupUndoTests`, `TabStoreTests` |

# Related

- [TabStore](./tabstore.md) — the mutation shape every undo follows.
- [A page's key equivalents and its undo](../platform/page-key-equivalents-and-undo.md) — the page-first rule and WebKit's page undo.
- [Profiles and spaces](./profiles-and-spaces.md) — Delete Space and its undo, Move to Space.
- [Closed tabs and archive](../tabs/closed-tabs-and-archive.md) — close undos and the records they consume.
- [Split tabs](../tabs/split-tabs.md) — the split undo rules.
- [Tab opener](../tabs/tab-opener.md) — the link the close undos re-check.
- [Incognito](./incognito.md) — what else a Private window's close removes.

[^task-40]: Undo actions registered before Delete Space act on a stale Space object
[^task-119]: Archived Tabs page; close undos skip consumed records
[^task-28]: Undoing the close of an extension page tab restores a dead page
[^task-35]: Undo of Delete Space / Edit Space after its profile was deleted crashes
[^task-346]: "Quick Detour launcher: ⌘Z in its field undoes the typing, never Detour's closed-tab list"
[^task-357]: Private windows: their undo entries outlive the window and can rebuild a Private tab nobody sees
[^task-360]: "Undo: Move Space's undo stores positions in the space list, which Private windows shift"
[^task-349]: "Undo: ⌘Z in Settings text fields and extension popups reaches the browser window's closed-tab undo"
