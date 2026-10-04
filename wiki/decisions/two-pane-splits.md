---
type: Decision
title: A split is two adjacent tabs sharing a group id, two panes at most
description: Why a split tab is modelled as a shared splitGroupID on two ordinary tabs rather than a container object or a partner pointer, and why it is limited to two side-by-side panes.
tags: [tabs, split, decision, model]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: design
    resource: ../../docs/split-tabs-design.md
    title: Split Tabs design document (sections 1, 2, 3, 5, 10)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift
  - id: items
    resource: ../../Detour/Browser/Sidebar/TabListItems.swift
    title: TabListItems.swift
  - id: browsertab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (splitGroupID, splitFraction)
---

# Context

Split tabs put two pages side by side under one sidebar row. When the feature
was designed (July 2026) the tab model was a flat `space.tabs` array of
`BrowserTab`, and a great deal was keyed on that array: sidebar row math, the
observer callbacks, session persistence, sleep and archive sweeps, close and
undo, history recording, and the extension `tabs` API. The window assumed one
live web view container per selected tab. The [Peek](../tabs/peek.md) already
existed as a precedent for "a tab that shows something extra".

# Decision

**A split is two adjacent normal tabs that share a `splitGroupID`. It is not an
object.** Both members stay first-class `BrowserTab`s in `space.tabs`.

- `BrowserTab.splitGroupID: UUID?` (nil when not in a split) and
  `splitFraction: Double?` (the left pane's width share, stored on both
  members).
- Invariant: the members of a group are contiguous in `space.tabs`, in visual
  order, and there are exactly two.
- **Two panes at most, one split per tab.** This is a product decision, not a
  first-version limit. The group-id model would extend to more members, but
  nothing should be built assuming it will.
- Side by side only; no horizontal splits.
- In the window, `selectedTabID` always names one member (the focused pane),
  never the group.
- A split is per space. Its members are two tabs of the same space.

# Alternatives rejected

**A partner pointer, Peek-style (`tab.splitPartner`).** The second pane would
be hidden from everything keyed on `space.tabs`: extensions (the `tabs` API
must enumerate both panes, and a password manager filling the right pane needs
it to be a real tab), history recording, sleep and archive, close and undo. The
Peek gets away with that shape because it is a transient overlay. Split panes
are long-lived pages.

**A container object in a heterogeneous `space.tabs`.** It would touch every
index-math call site, every observer payload and every persistence loop, for no
benefit in the first version. The group-id model degrades to exactly the
previous model when no split exists.

**A `splitGroup` table.** Two nullable columns on `tab` are enough. A table only
earns its keep with more than two panes or an orientation to store.

# Consequences

What the choice bought:

- Code that iterates `space.tabs` kept working unchanged: each pane is recorded
  in history, saved, slept and listed to extensions as an ordinary tab.
- Address bar, navigation buttons, find bar, Peek and the extension-visible
  active tab kept their single-tab semantics, because the selection is always
  one member.
- Persistence is two columns (migration v6).

What it costs:

- **The invariant is not structural, so every mutation has to keep it.**
  Insertions snap out of group interiors, moves carry the pair as a block, every
  exit path dissolves a group of one. The full list is on
  [split tabs](../tabs/split-tabs.md). A new mutation of `space.tabs` that
  ignores groups can break one.
- Because data can violate the invariant, load paths sanitize
  (`sanitizeSplitGroups`) and rendering never trusts it (`tabListItems` renders
  a run of one as a plain row). `validSplitGroupIDs` rejects a group of three as
  firmly as a group of one.
- The sidebar needed an *item* layer between tabs and rows: `TabListItem` and
  the conversions in `TabListItems.swift`. A row index is an item index, never
  a tab index ([row layout](../sidebar/row-layout.md)).
- The window had to learn to host two containers and track a focused pane
  ([split tab hosting](../tabs/split-tabs-hosting.md)).
- "Is this tab in a split" has two answers once pinned splits exist; see
  [splits survive pinning](./splits-survive-pinning.md).

Behaviours chosen along with it:

- A closed-tab record has no group field. Reopen Closed Tab brings a member back
  unsplit; only the *undo* of an interactive close rejoins.
- Option+click creates or targets a split, and no longer downloads the link.
  The context menu's "Download Linked File" still does.
- Favourites and Peeks cannot be split members.

# Related

- [Split tabs](../tabs/split-tabs.md): the invariants and the store API that enforce this decision.
- [Split tab hosting](../tabs/split-tabs-hosting.md): the window side.
- [Splits survive pinning](./splits-survive-pinning.md): the later extension of the model to the pinned section.
- [TabStore](../architecture/tabstore.md): where the invariants are kept.
