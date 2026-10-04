---
type: Decision
title: Observer protocol for the store, Combine for the tab
description: TabStore announces structural changes through the TabStoreObserver protocol, while each BrowserTab publishes its own state with @Published.
tags: [decision, architecture, state, combine]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:20Z }
sources:
  - id: architecture-doc
    resource: ../../docs/architecture.md
    title: docs/architecture.md ("Key Design Decisions")
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (TabStoreObserver, subscribeToTab)
  - id: window-observer
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabStore.swift
    title: BrowserWindowController+TabStore.swift
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift
---

# Context

Two kinds of change need to reach the UI:

- **Structural** changes to the model: a tab inserted, removed or moved; an
  entry pinned or unpinned; a space added. These belong to
  [TabStore](../architecture/tabstore.md).
- **Per-tab** changes: a title, a URL, loading progress, a favicon. These
  originate in a `WKWebView` and belong to one
  [BrowserTab](../architecture/browser-tab.md).

Both could be delivered the same way. They are not.

# Decision

Use two mechanisms, split along that line.

1. `TabStore` notifies through `TabStoreObserver`, a class-bound protocol
   with one method per kind of change, each carrying the affected object, its
   index and its space.
2. `BrowserTab` exposes `@Published` properties. The store, the owning
   window and the extension layer subscribe to them.

The reasons recorded in `docs/architecture.md`:

- For the store: fine-grained callbacks ("insert at index", "remove at
  index") map directly onto table view animations, which a stream of values
  does not express cleanly.
- For the tab: `@Published` maps naturally onto KVO on `WKWebView`
  properties, and `AnyCancellable` gives automatic cleanup.

No other rationale is written down in the sources, and none is added here.

# Alternatives rejected

Only one is named in the sources: publishing store changes with Combine. It
was rejected for the reason above. The sources do not record any comparison
with other approaches (a single "state changed" notification with diffing,
`NotificationCenter` for everything, or `@Observable`).

# Consequences

What follows from the choice, as seen in the code today:

- **Callbacks can be atomic.** `tabStoreDidPinTab(_:fromIndex:toIndex:in:)`
  describes a move between two sections in one call, with both indices,
  instead of a remove followed by an unrelated insert.
- **Delivery is synchronous and on the mutation's call stack.**
  `notifyObservers` calls each observer directly, after the model is in its
  new state. An observer that changes selection in response can re-enter the
  sidebar, which is why row selection is set under
  `suppressingSelectionCallbacks`.
- **Every observer gets every callback.** There is no per-space subscription.
  Each handler in `BrowserWindowController` starts by checking
  `space.id == activeSpaceID`.
- **No initial value.** A new observer learns nothing until the next change;
  a window reads the store's current state itself when it is created or
  switches space.
- **Observers are weak**, held in `WeakObserver` boxes and pruned on each
  notify, so a closed window needs no explicit removal to avoid a leak
  (though `windowWillClose` removes itself anyway).
- **Adding a callback is cheap for conformers.** Every method has an empty
  default in a protocol extension.
- **The store is itself a Combine subscriber.** `subscribeToTab` turns a
  tab's published changes into `tabStoreDidUpdateTab` /
  `tabStoreDidUpdatePinnedEntry` callbacks, so views that only care about
  rows need one mechanism, not two. Those sinks are stored per tab id in
  `tabSubscriptions` and must be removed when a tab leaves the store.

One drift worth knowing: the window controller's insert, remove and reorder
handlers now mostly pass the whole section state to
`tabSidebar.applyState(…)` and let the sidebar work out the animation, rather
than animating from the callback's index. The indices are still used for
single-row reloads and for picking the next selection after a removal. The
recorded reason for the protocol (indices drive animations) describes the
original design more than the current sidebar; see
[sidebar overview](../sidebar/overview.md).

# Related

- [TabStore](../architecture/tabstore.md) — the protocol and the subscriptions.
- [BrowserTab](../architecture/browser-tab.md) — the published properties.
- [Architecture overview](../architecture/overview.md) — the four communication mechanisms side by side.
- [Sidebar drag and drop](../sidebar/drag-and-drop.md) — the drop transaction that batches several store mutations into one table update.
