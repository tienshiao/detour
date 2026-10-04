---
type: Decision
title: ID-based drag payloads and pure drop resolvers
description: Sidebar drag pasteboards carry stable IDs resolved at drop time, and every drop decision is a pure function over enums, replacing row-number payloads handled inline in the view controller.
tags: [sidebar, drag-and-drop, decision, testing]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:41:30Z }
sources:
  - id: commit-b9ef265
    resource: commit:b9ef265
    title: "Sidebar: ID-based drag payloads, pure drop resolver, drag fixes (2026-07-10)"
  - id: dragdrop
    resource: ../../Detour/Browser/Sidebar/SidebarDragDrop.swift
    title: SidebarDragDrop.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift
  - id: claude-md
    resource: ../../CLAUDE.md
    title: CLAUDE.md, "Sidebar Drag & Drop" and "Test-Driven Development"
  - id: design
    resource: ../../docs/split-tabs-design.md
    title: Split tabs design, section 6
  - id: dragdrop-tests
    resource: ../../DetourTests/SidebarDragDropTests.swift
    title: SidebarDragDropTests.swift
---

# Context

The sidebar's rows are an `NSTableView`, and AppKit's table drag API speaks
in row indexes. The first implementation put row numbers on the pasteboard
and decided each drop inline in `TabSidebarViewController`'s
`validateDrop` / `acceptDrop`.[^commit-b9ef265]

Three properties of the app make a row number a bad thing to carry for the
length of a drag:

- **Rows shift while the pointer is down.** A background tab can close, an
  extension can remove or create a tab, a pinned folder can collapse. The
  sidebar applies those changes immediately, so the row that was dragged may
  now hold something else.
- **Several windows show the same store.** Each window has its own sidebar
  and table, over spaces that live in the shared
  [TabStore](../architecture/tabstore.md). A row number from one window's
  table means nothing in another's.
- **A row is not a tab.** A [split](../tabs/split-tabs.md) is one row over
  two tabs, and a pinned row is a position in a flattened tree
  ([row layout](../sidebar/row-layout.md)). Index arithmetic in the drop
  handler has to be right in several index spaces at once.

The same change also found context menus holding a tab *index* that went
stale while the menu was open, which "could crash or target the wrong
tab".[^commit-b9ef265] It is the same defect in a different gesture.

# Decision

1. **Pasteboards carry IDs.** `SidebarDragPayload` holds a `kind`, the
   dragged item's `itemID`, the `spaceID` it was dragged from and the
   `sidebarID` of the sidebar it came from; `FavoriteDragPayload` holds a
   `favoriteID` and `sidebarID`. Both are `Codable` and travel as a JSON
   string.
2. **The source is resolved at drop time.** `resolveDragSource` looks the ID
   up in the current model. A missing item refuses the drop; a split that
   dissolved mid-drag degrades to a plain tab or entry drag.
3. **Foreign drags are rejected by identity.** `payload.isLocal(sidebarID:spaceID:)`
   is the single definition of "a drag from this window's sidebar in the
   active space".
4. **Drop logic is pure.** `validateSidebarDrop`, `sidebarDropDestination`
   and `resolveSidebarDrop` take enums and value types (`SidebarRow`,
   `SidebarDropOperation`, `SidebarDragSource`, `SidebarDropDestination`) and
   return a `SidebarDropValidation` or a `SidebarDropCommand`. They do not
   import a table view; `SidebarDropOperation` exists only to mirror
   `NSTableView.DropOperation` without depending on it.
5. **The view controller is a dispatcher.** `acceptDrop` decodes, resolves,
   and switches over the command to issue `TabSidebarDelegate` calls, which
   name the dragged item by ID.
6. **Multi-mutation drops are one transaction**
   (`performDropTransaction`), so the table animates once.

The pipeline is described step by step in
[sidebar drag and drop](../sidebar/drag-and-drop.md).

# Alternatives rejected

- **Row-number payloads** — the previous implementation. Replaced "so drops
  stay valid when rows shift mid-drag, and cross-window drops are rejected
  via `sidebarID`".[^commit-b9ef265]
- **Drop decisions inline in the table delegate** — also the previous
  implementation. The commit moved them into pure, tested functions
  "dispatched from a slimmed-down `acceptDrop`".[^commit-b9ef265]

No other alternative is recorded in the sources. In particular nothing
records a decision about deferring store changes for the whole length of a
drag; the code does not do that (`isDragging` covers only a drop
transaction).

# Consequences

- **Drop behaviour is unit-testable without AppKit.** `SidebarDragDropTests`
  builds `PinnedItem` and `TabListItem` arrays and asserts on returned enum
  values. `CLAUDE.md` makes this the required route: extend the resolver
  enums and the suite, then make the pure function pass.
- **New surfaces extend enums.** Split tabs added `splitGroup` /
  `splitMember` kinds, an `.intoSplit` destination, and
  `createSplit` / `removeFromSplit` commands; pinned splits added two more
  kinds and five commands. `resolveSidebarDrop`'s switch is exhaustive, so
  each addition forces a decision for every source and destination pair.
  The [split tabs design](../../docs/split-tabs-design.md) was written
  against this structure.
- **Geometry had to become data.** `NSTableView` only reports "on" or
  "above", so the pointer position is reduced to a `RowDropZone` before the
  pure layer sees it, and what part of a split row a drag grabbed to a
  `SplitRowDragKind`. Both reductions are pure and tested.
- **Other drop targets reuse the gate.** The content-area split drop zone
  (`validateContentSplitDrop`) and the favorites bar
  (`favoritableTabPayload`) decode the same payload and apply the same
  sidebar check.
- **Allow-lists for new kinds.** A consumer that only understands some
  kinds must name them (`FavoritesBarView.canFavorite`), so a kind added
  later is rejected rather than mishandled.
- **Cost:** the resolver works in item space while the delegate and store
  work in tab space, so every gap index needs an explicit conversion at the
  boundary. See [row layout](../sidebar/row-layout.md).

# Related

- [Sidebar drag and drop](../sidebar/drag-and-drop.md) — the pipeline in full.
- [Sidebar row layout](../sidebar/row-layout.md) — the index spaces the resolver reads.
- [Two-pane splits](./two-pane-splits.md) — the split model the later enum cases serve.
- [Observer protocol over Combine](./observer-protocol-over-combine.md) — how store changes reach the sidebar during and after a drop.

[^commit-b9ef265]: Sidebar: ID-based drag payloads, pure drop resolver, drag fixes (2026-07-10)
