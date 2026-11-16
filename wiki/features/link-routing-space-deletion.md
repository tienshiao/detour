---
type: Concept
title: Space deletion blocked by Link Routes
description: "Why a space that a link route or the Default targets cannot be deleted (TabStore.deleteSpace returns .blockedByLinkRoutes before tearing anything down), what the sidebar, the Spaces pane and a refused undo or redo each do, the one-step bounce that puts a refused undo entry back, the alert and its Open Links Settings… button, and the runtime check with its undo-group trap."
tags: [links, spaces, undo]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:20Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (deleteSpace, SpaceDeletionResult, deleteSpaceFromUndoStack, reRegisterRunningUndoEntry)
  - id: resolver
    resource: ../../Detour/Browser/LinkRouting/LinkRouteResolver.swift
    title: LinkRouteResolver.swift (linkRoutesTargeting)
  - id: store
    resource: ../../Detour/Browser/LinkRouting/LinkRouteStore.swift
    title: LinkRouteStore.swift (references(toSpace:))
  - id: alert
    resource: ../../Detour/Browser/LinkRouting/SpaceDeletionBlockedAlert.swift
    title: SpaceDeletionBlockedAlert.swift
  - id: store-tests
    resource: ../../DetourTests/LinkRouteStoreTests.swift
    title: LinkRouteStoreTests.swift
  - id: task-191-1
    resource: backlog:TASK-191.1
    title: "TASK-191.1: route model, matching rule and storage"
  - id: task-191-3
    resource: backlog:TASK-191.3
    title: "TASK-191.3: Settings UI to add, edit, reorder and remove routes"
  - id: harness
    resource: ../../docs/harness/task191-1-harness.patch
    title: TASK-191.1 runtime harness
---

A space that a link route or the Default targets cannot be deleted. User
decision 2026-10-25: deletion is blocked, rather than leaving broken
routes.[^task-191-1] Every way of deleting a space (the sidebar, Settings >
Spaces, an undo of Add Space or a redo of Delete Space) is refused with an
alert naming the routes. Part of [Link Routes](./link-routing.md).

# The rule

`linkRoutesTargeting(spaceID:routes:defaultTarget:)` (pure) and
`LinkRouteStore.references(toSpace:)` return `LinkRouteReferences` (the routes
in order, and whether the Default targets it). `TabStore.deleteSpace(id:)`
returns `SpaceDeletionResult`: `.deleted`, `.notDeleted` (unknown or last
space) or `.blockedByLinkRoutes(references)`, checked before anything is torn
down or any undo registered.

| Caller | What it does on a block |
|---|---|
| Sidebar space menu, Delete Space (`BrowserWindowController.tabSidebarDidRequestDeleteSpace`) | Checks the routes **first**, before "close or move all tabs" and the confirmation, so nobody closes every tab only to be refused; handles a block from `deleteSpace` too. |
| Settings > Spaces "−" (`SpacesSettingsViewController.deleteSpaceClicked`) | Shows the alert and leaves the list and selection alone. |
| Undo of Add Space, redo of Delete Space (`TabStore.deleteSpaceFromUndoStack`) | Post `TabStore.spaceDeletionBlockedNotification` (a `SpaceDeletionBlock`: space id, name, references; read with `TabStore.spaceDeletionBlock(from:)`). Every `BrowserWindowController` observes it; the frontmost browser window in `NSApp.orderedWindows` shows the alert, from the run loop (`RunLoop.main.perform`, default mode) once the undo has returned. Not from a main-queue block: a modal alert run inside one holds the main queue, and every main-queue block and main-actor job with it, until it is dismissed. The entry is put back, so Cmd+Z (or Cmd+Shift+Z) tries again once the routes change. A direct `deleteSpace` posts nothing: its caller reads the result. |

A Private window's space is never a route target, so closing a Private
window (`removeIncognitoSpace`) does not consult the routes.

Since deletion is blocked, a broken route (its space gone) only comes from
a space removed some other way; the resolver skips it and the Links pane
shows it ([broken routes](./link-routing-links-pane.md#broken-routes)).

# Putting a refused undo entry back

`UndoManager` cannot put an entry back on the stack it is running from:
whatever is registered while undoing lands on the redo stack (and while
redoing on the undo stack), and a plain registration after the undo returns
would land right but clear the redo stack. `reRegisterRunningUndoEntry`
therefore registers a one-step bounce on the opposite stack and runs it from
the main queue straight away (`redo()` after an undo, `undo()` after a redo);
run that way, its registration of the original handler lands where the entry
came from, and neither stack is otherwise changed. It skips the bounce if an
undo group is open by then. Before this, a refused undo or redo did nothing,
showed nothing, and was gone (review finding, 2026-10-25).[^task-191-1]

# The alert

`SpaceDeletionBlockedAlert` is an `NSAlert`: "“Work” can’t be deleted", then
one line per route (`linkRouteSummary`: "Domain is …", "URL contains “…”",
"URL is …", "Links from Mail", with the app's name looked up from the bundle
ID) and "The Default route" when it applies. Buttons: **OK** (the default)
and **Open Links Settings…** (TASK-191.3), which opens Settings on the Links
pane with the routes and the Default that target the space highlighted
(`SettingsWindowController.showLinksPane(highlightingSpaceID:)`; see
[Opened from the blocked-deletion alert](./link-routing-links-pane.md#opened-from-the-blocked-deletion-alert)).[^task-191-3]
The same `run(spaceName:spaceID:references:)` serves the sidebar, the Spaces
pane and the undo/redo refusal (`SpaceDeletionBlock` carries the space id).

# Runtime check

Harness `docs/harness/task191-1-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1911`, 2026-10-25.[^harness] The sidebar's own
`deleteSpaceClicked:` action and the Settings pane's "−" both raised the
alert naming the route, and the space survived; with a source-app route and
the Default on another space the alert listed "Links from Mail" and "The
Default route"; after removing the route, the sidebar asked "Delete
“Routed”?" and the space went. A relaunch read the route and the Default
back and still refused. (The migration steps of the same run are on
[the store page](./link-routing-store.md#storage).)

Second run, same day, screen unlocked, light and dark (`NSApp.appearance`
pinned by `DETOUR_VERIFY_APPEARANCE`): the alert captured by its own window
number from the sidebar and from the Settings pane, and an undo step: add a
space, route to it, Edit > Undo Add Space (the menu item's own action) shows
the alert, the space stays and the stacks read as before (Undo Add Space,
nothing to redo); after the route is removed the same undo deletes it. The
redo path (delete, undo, Default to the space, Redo) behaves the same. With
Detour in the background the Edit menu's items are disabled (no key window),
so the harness then sends the item's action to the window controller.

**Harness trap: never end an automatic undo group by hand.** A first
version of the undo step called `endUndoGrouping` on the `groupsByEvent`
group (the harness posts no events, so AppKit never closes it). NSUndoManager
then refused the next registration with an ObjC exception ("must begin a
group before registering undo"); thrown through the harness's Swift task and
caught by AppKit, it left a stale executor in thread-local storage, and the
next `MainActor.assumeIsolated` outside a task (the GPU reapers' 30 s timers,
`RecentTabSwitcher`'s observer) crashed in `swift_task_isCurrentExecutor`
seconds later, far from the cause. Turning event grouping off and grouping
each step by hand, as the unit tests do, fixed it; the exception shows in the
unified log as `_registerUndoObject:: NSUndoManager ... is in invalid state`.

# Tests

`LinkRouteStoreTests`: blocked and allowed deletion, a refused undo of Add
Space and redo of Delete Space posting the notification and keeping the
entry with the other stack untouched, the alert text and its two buttons.

# Related

- [Link Routes](./link-routing.md): the hub.
- [Profiles and spaces](../architecture/profiles-and-spaces.md): space deletion and its other refusals.
- [TabStore](../architecture/tabstore.md): `deleteSpace`'s invariants.
- [Browser undo](../architecture/browser-undo.md): the undo stack the bounce puts entries back on.
- [The Links pane](./link-routing-links-pane.md): where the alert's button leads.

[^task-191-1]: TASK-191.1: route model, matching rule and storage
[^task-191-3]: TASK-191.3: Settings UI to add, edit, reorder and remove routes
[^harness]: TASK-191.1 runtime harness
