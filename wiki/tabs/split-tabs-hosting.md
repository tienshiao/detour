---
type: Component
title: Split tab hosting in the window
description: How BrowserWindowController shows a split (a frame-based NSSplitView of two pane containers), what the focused pane is, how hosting converges after store changes, and the gestures and animations that form and break a split.
resource: ../../Detour/Browser/Window/BrowserWindowController.swift
tags: [tabs, split, window, appkit, nssplitview, focus]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:08:00Z }
sources:
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: store-observer
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabStore.swift
    title: BrowserWindowController+TabStore.swift
  - id: window-sidebar
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (Option-click branch)
  - id: drop-zone
    resource: ../../Detour/Browser/Window/SplitDropZoneView.swift
    title: SplitDropZoneView.swift
  - id: webview
    resource: ../../Detour/Browser/Window/BrowserWebView.swift
    title: BrowserWebView.swift (becomeFirstResponder)
  - id: browsertab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (WebViewContainerView)
  - id: constants
    resource: ../../Detour/Browser/Shared/UIConstants.swift
    title: UIConstants.swift (split pane geometry)
  - id: design
    resource: ../../docs/split-tabs-design.md
    title: Split Tabs design document (sections 5, 7, 8, 11, 13)
  - id: drop-tests
    resource: ../../DetourTests/SplitDropZoneTests.swift
    title: SplitDropZoneTests.swift
  - id: notes
    resource: "Agent session notes, 2026 (not in the repository)"
    title: Runtime debug harness notes (NSSplitView setPosition finding)
---

# Role

[Split tabs](./split-tabs.md) are a store concept: two tabs sharing a group id.
This page is the window's half. When the selected tab is in a group,
`BrowserWindowController` hosts both members' web view containers side by side
in an `NSSplitView` inside the content area, tracks which pane has focus, and
re-converges whenever the store changes the group under it.

# How it works

## Hosting

`claimWebView(for:)` resolves `splitMembers(of:)` through
`TabStore.splitGroup(containing:in:)` and branches: two members go to
`claimSplitWebViews`, anything else to `claimSingleWebView`. Because that store
function resolves normal and pinned splits alike, no hosting code has a
"pinned" case.

`claimSplitWebViews` builds a private `HostedSplitView` (vertical,
`translatesAutoresizingMaskIntoConstraints = true`, autoresizing width and
height), adds each member's `webViewContainer` as an arranged subview, and
inserts it into `contentContainerView` below the drag handle. It is stored in
`hostedSplitView`.

- The divider is an invisible strip `UIConstants.splitPaneGap` (8 pt) thick
  (`drawDivider` is empty), which also gives the resize cursor a wide grab area.
- The split view is inset from the content area by `splitPaneInset` so the
  panes read as rounded, shadowed cards. In fullscreen it is full bleed, square
  and without shadow.
- The controller is the delegate of this split view only, and every delegate
  method still guards on `splitView === hostedSplitView`: the window's
  sidebar/content split belongs to its own `NSSplitViewController`.

## Why frame-based, never Auto Layout

**A tab's web view and its container are laid out by frames.** WebKit's docked
Web Inspector attaches as a *sibling* of the web view inside the container, and
Auto Layout around the web view breaks it. `NSSplitView` manages its arranged
subviews' frames directly, which is why it was chosen. Both bets were checked in
a throwaway app before the window work started (2026-07-11): the docked
inspector attaches inside a pane's container and survives divider moves with no
Auto Layout complaints, and clicking a pane reliably fires
`becomeFirstResponder` on the `WKWebView` subclass.[^design]

Do not add constraints to a pane container or the hosted split view. The Peek
web view and the snapshot image view do use constraints; they are not tab
containers.

`WebViewContainerView` (in [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift))
exists for the same reason: it clips each subview to the card's corner radius
in `didAddSubview`, so an inspector that attaches *after* the pane chrome was
applied is clipped too. The container's own layer must not clip, because
`masksToBounds` would kill the pane's shadow.

## Tiling and the divider fraction

`applySplitFraction(_:to:)` frames **both panes explicitly** with
`splitPaneRects` and only then calls `setPosition`. `NSSplitView.setPosition`
resizes the divider's neighbours from their *current* frames. A container
carrying a stale frame from an earlier hosting (it was the left pane before the
group re-formed with it on the right) collapsed to zero width and showed as a
dead white half until the window was resized.[^notes]

- If the split view has no geometry yet (window restore selects a split before
  the first layout pass) the fraction is parked in `pendingSplitFraction` and
  applied on the first real resize, instead of letting the 50/50 default be
  committed over the saved value.
- `splitViewDidResizeSubviews` ignores its own layout passes
  (`isApplyingSplitLayout`), applies a pending fraction, **self-repairs** panes
  that fail to tile the bounds (`panesAreMistiled`, 1 pt tolerance) by
  re-applying the stored fraction, and otherwise schedules a commit.
- The commit is debounced 0.3 s and calls `TabStore.setSplitFraction`. It
  resolves the group when scheduled, so a flush during teardown still writes to
  the right group. `removeContentViews` and `windowWillClose` flush it
  (`flushPendingSplitFractionCommit`) so a tab switch inside the debounce window
  does not lose the divider position.
- A commit needs two arranged subviews. A pinned member going dormant pulls its
  container out and stretches the survivor to full width; without the guard that
  stretch would be saved as the group's fraction.
- The delegate limits the divider to 20%…80%, matching the store's clamp.

`resetSplitPaneChrome` strips the border, radius and shadow from a container
returning to single hosting and **restores its autoresizing mask**: NSSplitView
overwrites pane masks, and a container re-hosted with the leftover mask keeps a
fixed size instead of tracking window resizes.

## Ownership with two panes

- `ownsWebView` is derived, not stored: the selected tab's container
  `isDescendant(of: contentContainerView)`. Descendant, because a pane sits one
  level deeper than a single tab's container.
- `removeContentViews` dismantles the split view pane by pane before removing
  it, so each container ends with **no superview**. "Has a superview" means
  "hosted in some window" to `selectTab` and to
  [the sleep sweep](./sleeping-and-archiving.md).
- The `webViewOwnershipChanged` notification carries `tabIDs` (every claimed
  pane) as well as `tabID` (the focused one). Other windows match on
  intersection with *their* selected tab's group, because two windows showing
  the same split may have different panes focused.
- The handed-over snapshot is of the whole split view composed at its inset
  frame (`snapshotWithinSuperview`), so a non-owning window shows one dimmed
  image of both panes that maps 1:1 onto its content area.
- `selectTab` claims only if the window is key or no member's container is
  hosted elsewhere; otherwise it shows the snapshot. See
  [web view ownership](../architecture/webview-ownership.md).

## The focused pane

**`selectedTabID` always names one member, never the group.** The address bar,
navigation buttons, find bar, `displayTab`, the Peek and the extension-visible
active tab all keep single-tab semantics because of that.

- Focus follows first responder. `BrowserWebView.becomeFirstResponder` calls
  `browserWebViewDidBecomeFirstResponder`, which retargets `selectedTabID` and
  the space's `selectedTabID`, rebinds the chrome (`bindSelectedTabChrome`),
  re-anchors the link status bar, redraws the focus border and announces the
  activation to extensions. It does **not** re-run the content swap; both panes
  are already up.
- It does nothing while a Peek is open. The overlay is modal over both panes;
  mouse paths cannot reach a pane, but keyboard key-view cycling can.
- `lastFocusedSplitMember[groupID]` remembers the pane per window, in memory.
  Clicking the split's sidebar row selects the remembered member (default: the
  row's representative, which is the selected member or else the left pane).
- The focused pane is marked by a 2 pt border, black in light mode and white in
  dark. The colour is baked into the layer as a `CGColor`, so
  `HostedSplitView.viewDidChangeEffectiveAppearance` re-runs
  `updateSplitPaneFocus`.

`selectTab` treats the group as the unit: it wakes every member, clears
`lastDeselectedAt` on each, and for a pinned split first activates a dormant
partner entry so the group resolves to two live panes. `stampDeselected` stamps
every member on the way out.

## Converging after store changes

A structural change that does not pass through `selectTab` (a pane closed from
the sidebar, Separate Tabs, a split formed around the selected tab, a pin or
unpin) leaves the hosted view out of date. `refreshSplitHostingIfNeeded()`
compares what is hosted with what the store says and re-claims on a mismatch.
The store observer calls it after: tab removal, reorder, pinned entry removal
and update, pin, unpin, and pinned folder updates.

Trap: when those observers restore the sidebar's row highlight they wrap it in
`tabSidebar.suppressingSelectionCallbacks`. An unguarded programmatic selection
fires the table's selection callback, which calls `selectTab`, whose pinned-split
wake would resurrect a partner the user deliberately closed.

## Closing panes

- Cmd+W closes the focused pane; `settleSelectionLeaving` selects the surviving
  partner ahead of the generic close rule.
- Each half of the sidebar row has its own hover close button.
- "Close Both Splits" (context menu) settles selection off the pair first, then
  calls `closeSplitGroup`.
- In a pinned split, closing the focused pane makes that entry dormant and
  selects the partner; the group survives.

## Forming a split

| Gesture | Path |
|---|---|
| Drop a tab on the left or right 40% of another tab's sidebar row | sidebar resolver → `didRequestCreateSplit` ([drag and drop](../sidebar/drag-and-drop.md)) |
| Drop a tab on the left or right 30% of the web content area | `SplitDropZoneView` → `performContentAreaSplitDrop` → `didRequestCreateSplit` |
| Option+click a link | `addTabInSplit`, new pane on the right, focused |
| Context menu "Split with Next Tab" | `createSplit` with the next tab on the right |

**Content-area drops.** `SplitDropZoneView` is a transparent overlay that exists
only while a *local sidebar tab drag* is live: the sidebar's drag-session
begin/end callbacks drive `installSplitDropZone` / `removeSplitDropZone`. It can
therefore never shadow `WKWebView`'s own drop handling (files dropped on
pages).

- It is installed only when `splitDropTargetTabID` is non-nil: the selected tab
  must be an ungrouped normal tab.
- Zone and validation are pure functions: `splitContentDropEdge(forX:width:)`
  and `validateContentSplitDrop` (a lone normal tab from this window's sidebar
  and the active space, not onto itself). The preview uses the same
  `splitPaneRects` as the real tiling, so it shows exactly where the pane will
  land.
- `onDrop` re-resolves the dragged tab in `space.tabs`: another window sharing
  the space may have closed, pinned or split it during the drag.
- **It has no `hitTest` override, on purpose.** The overlay only exists while
  the mouse is captured by the drag, and a nil-returning `hitTest` risks
  excluding it from AppKit's drag-destination discovery.
- It is in `removeContentViews`' keep-list. A store mutation from another
  window mid-drag would otherwise detach it, and the stale property would block
  reinstalling it for the rest of the drag.
- The drop goes through the sidebar's `performDropTransaction` even though it
  is one store call: it diffs as a row merge, and the table cannot take
  structural updates while the drag session is still live.

**Option+click.** In `decidePolicy`, after Cmd and Shift and *before* the
`shouldPerformDownload` check, because WebKit flags Option-clicked links as
downloads. This retires Option-click-to-download; the context menu's "Download
Linked File" remains. The clicked pane is resolved from the firing web view, not
from the selection:

- clicked tab not in a split: `addTabInSplit`, and the new right pane is
  selected;
- clicked tab already in a split: the **other pane** loads the URL;
- a lone pinned tab or a favourite (cannot join a group): a background tab, as
  for Cmd+click;
- while a Peek is open the branch does not run, so Option-click still downloads
  inside a Peek.

## Formation and separation animations

Live views are never animated. The claim path re-runs within a tick of a split
drop (the sidebar's deferred selection restore calls `selectTab`), and both
directions tear content down and rebuild it. So each transition plays a
cosmetic **veneer** of snapshot cards above the already-final layout: any
interruption degrades to an instant snap over correct content.

- One-shot flags `animateNextSplitClaim` and `animateNextSplitSeparation` are
  armed as `flag = true; defer { flag = false }` around the store call in the
  gesture's sidebar-delegate method. Observers run synchronously inside the
  mutation, so the claim consumes the flag in the same stack frame; the `defer`
  covers gestures that never claim. Undo is deliberately not animated.
- `splitRevealOverlay` / `splitRevealOverlayMemberIDs` serve both directions.
  A re-claim of the same content keeps the animation and re-lifts the overlay;
  any other claim removes it. `removeContentViews` spares it.
- A frame-change observer on the content container removes it: the cards
  animate toward frames captured at install, and the separation veneer is
  opaque, so a resize (window, or the sidebar collapsing) would leave it
  covering the live page.
- Timing: 0.22 s ease-out, then a 0.12 s fade.
- Separation snapshots each pane's *web view*, not its container, so the focus
  border does not bake into the expanding card.

The sidebar row morphs in step; that half is in
[tab cell](../sidebar/tab-cell.md).

# Invariants

- `selectedTabID` is a member id, never a group id.
- A hosted container has a superview; an unhosted one has none.
- Pane containers and the hosted split view are frame-based.
- `hostedSplitView` is cleared when `removeContentViews` dismantles the split
  view. `hostedSplitMatches` still checks the superview rather than trusting
  the property.
- In the window that owns the web views, hosting matches
  `store.splitGroup(containing: selectedTabID)` once a store observer returns.

# Gotchas

- `claimWebView`'s refresh branch (already hosting these panes) runs on every
  `windowDidBecomeKey`. It must stay cheap and must not count as a "show" for
  the sleep budget.
- A pane entering picture-in-picture is kept parented as a direct subview with
  its autoresizing mask cleared for 0.5 s so WebKit can capture the animation
  origin; the next claim restores the mask.
- Content-blocker rule changes and the window-close handler cleanup iterate
  `splitMembers(of:)`. Anything that touches "the owned web view" must do the
  same, or the unfocused pane is skipped.
- The Peek overlay covers the whole content area, so it spans both panes.

# Tests

`SplitDropZoneTests` covers the pure geometry and validation
(`splitContentDropEdge`, `splitPaneRects`, `validateContentSplitDrop`).
`PeekAnchorTests` covers pane resolution for links. **No unit test builds the
hosted `NSSplitView`**: claim, focus tracking, tiling repair and the veneers
are only checked in the running app. After changing them, exercise a real split
with `/verify` ([runtime verification](../playbooks/runtime-verification.md)):
form by drop and by Option-click, drag the divider, switch away and back,
resize, dock the Web Inspector in one pane, open the same space in a second
window.

# Related

- [Split tabs](./split-tabs.md): the store model and invariants this hosts.
- [Two-pane splits](../decisions/two-pane-splits.md): why focus stays single-tab.
- [Web view ownership](../architecture/webview-ownership.md): claim, snapshot and transfer for the single-pane case.
- [BrowserWindowController](../architecture/browser-window-controller.md): the rest of the controller.
- [AppKit gotchas](../platform/appkit-gotchas.md): the `setPosition` and Auto Layout traps in general form.
- [Sidebar drag and drop](../sidebar/drag-and-drop.md): row edge drops and member drags.
- [Peek](./peek.md): the overlay that spans a split.

[^design]: Split Tabs design document (sections 5, 7, 8, 11, 13)
[^notes]: Runtime debug harness notes (NSSplitView setPosition finding)
