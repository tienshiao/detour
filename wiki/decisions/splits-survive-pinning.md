---
type: Decision
title: Splits survive pinning, and a pinned split lives on the entries
description: Why pinning a whole split keeps it a split, and why a pinned split's group id is stored on the two PinnedEntry objects while their backing tabs carry none.
tags: [tabs, split, pinned, decision, model]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: design
    resource: ../../docs/split-tabs-design.md
    title: Split Tabs design document (sections 10, 11 and 12)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Pinned Split Mutations)
  - id: entry
    resource: ../../Detour/Browser/PinnedEntry.swift
    title: PinnedEntry.swift
  - id: flattener
    resource: ../../Detour/Browser/Sidebar/PinnedTreeFlattener.swift
    title: PinnedTreeFlattener.swift
  - id: record-factory
    resource: ../../Detour/Browser/TabRecord+BrowserTab.swift
    title: TabRecord+BrowserTab.swift
  - id: tests
    resource: ../../DetourTests/SplitTabTests.swift
    title: SplitTabTests.swift
---

# Context

[Splits](./two-pane-splits.md) were defined between *normal* tabs: two adjacent
members of `space.tabs` sharing a `splitGroupID`. A
[pinned entry's](../tabs/pinned-tabs-and-folders.md) backing tab is not in
`space.tabs`, so pinned tabs could not be members. The first sidebar
drag-and-drop implementation therefore made dragging a split row into the
pinned section pin both members and **dissolve** the split.

The design document records that this was superseded ("Originally this
dissolved the split; superseded by §12") but not the discussion that led to the
change; section 10 states the outcome as a decided default: splits form between
normal tabs but survive pinning.

# Decision

**Pinning a split keeps it a split**, and the group concept is mirrored into the
pinned section:

- A pinned split is two `PinnedEntry`s sharing `PinnedEntry.splitGroupID` (and
  `splitFraction`).
- Invariant: exactly two entries, same `folderID`, consecutive in sibling sort
  order, with nothing (entry or folder) sorting between them.
- **While pinned, the group lives only on the entries.** The backing tabs'
  `BrowserTab.splitGroupID` stays nil.
- The group id *value* is carried across pin and unpin, so undo, redo and the
  sidebar diff see one row moving between sections.

Limits kept:

- Splits are never created inside the pinned section. They arrive by pinning an
  existing split (`pinSplitGroup`).
- Pinning a *single* member still separates it first (`pinTab` leaves the
  group).
- Favourites cannot be members.

# Alternatives rejected

**Dissolve on pin.** The original behaviour, replaced as described above.

**Keep the group on the backing tabs.** The design keeps `space.tabs`' invariants
ignorant of pinned groups ("`space.tabs` invariants never see pinned groups").
The code shows a second reason this could not work: a pinned member can be
*dormant*, with no tab at all, and still be a member. `closePinnedTab` makes the
entry dormant without dissolving the group, and the member wakes when the row
is next selected. Only a field on the entry can express that.

# Consequences

- **One resolver hides the difference from the window.**
  `TabStore.splitGroup(containing:in:)` takes a tab id and answers for both
  kinds; for a pinned split it returns the entries' live tabs. Hosting, claim,
  snapshot, refresh and Option-click all key off it and needed no per-call-site
  change.
- `tab.splitGroupID != nil` is **not** a correct "is in a split" test. It is
  false for every pinned split member. Use the resolver.
- A pinned split with a dormant member resolves to one live tab. Selecting the
  row wakes the partner first (`selectTab` activates dormant partner entries),
  so the group then hosts two panes. Callers that see a single member must cope.
- `setSplitFraction` writes to whichever side owns the group, and the window
  reads through `splitFraction(containing:in:)` instead of
  `members[0].splitFraction`.
- **Anything that copies a space must copy the entry fields.** The backing
  tab's row and snapshot carry no group. `TabRecord.init(tab:…)` takes the split
  fields as parameters for this reason, and `deleteSpace`'s undo snapshots
  `splitGroupID` / `splitFraction` on the entry explicitly.
- The [sleep sweep](../tabs/sleeping-and-archiving.md) resolves a pinned split's
  partner through the entries, not through the tabs.
- Pinned mutations had to become group-aware: `movePinnedTabToFolder` moves the
  pair as a block, drop anchors snap out of a pair (`snappedPinnedAnchor`),
  deleting a folder renumbers instead of reparenting with stale sort orders,
  and `sanitizePinnedSplitGroups` runs at load and after order-restoring undos.
- Sort-order ties became dangerous. A restored `sortOrder` that ties with a
  sibling can interleave a pair; undo paths place positionally or re-sanitize.
- Exits mirror the normal-tab rule: unpinning one member, deleting an entry,
  moving an entry to favourites or to another space dissolve the group. Closing
  the tab (making the entry dormant) does not.
- Persistence: `splitGroupID` and `splitFraction` on `pinnedTab` (migration
  v7).
- The sidebar gained `PinnedItem.split` and two more drag payload kinds
  ([drag and drop](../sidebar/drag-and-drop.md)).

# Related

- [Split tabs](../tabs/split-tabs.md): the full invariant list and store API for both kinds.
- [Two-pane splits](./two-pane-splits.md): the decision this extends.
- [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md): levels, sort order and dormancy.
- [Split tab hosting](../tabs/split-tabs-hosting.md): the window code that relies on the single resolver.
