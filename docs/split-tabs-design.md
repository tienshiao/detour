# Split Tabs — Design

Two webviews side by side inside one logical "tab" (one sidebar row). Created by
dragging a tab onto the left/right edge of another tab row in the sidebar, onto
the left/right edge of the web content area, or by **Option-clicking a link**.
Broken apart by dragging a member out to its own row, or via a **Separate Tabs**
menu item. **A top-level tab has at most one split (2 panes) — product decision,
not just a v1 limit.** Peek is preserved and spans the whole split.

## 1. Review of current tab handling (what we're building on)

The recent cleanups (`b9ef265`, `81154a4`) put most of the machinery where split
tabs need it:

**Works in our favor:**

- **Pure drop resolver** (`SidebarDragDrop.swift`): drops resolve through
  `validateSidebarDrop` / `sidebarDropDestination` / `resolveSidebarDrop` — pure,
  tested enums. Split creation is a new destination + command case, per the
  existing CLAUDE.md instruction ("extend the resolver enums + tests").
- **ID-based drag payloads**: `SidebarDragPayload` carries `itemID/spaceID/sidebarID`,
  so a webview-area drop target can consume the *same* pasteboard type and resolve
  the dragged tab by ID.
- **`performDropTransaction`**: split create/break are multi-mutation drops
  (reorder + group assignment); the batching mechanism already exists.
- **Derived `ownsWebView`**: ownership is computed from the view hierarchy, not a
  hand-synced flag — generalizing from "container is direct subview" to
  "container is a descendant" is a one-line change instead of a 6-site audit.
- **Peek precedent**: `displayTab` indirection, a second webview hosted in the
  content area, secondary favicon in `TabCellView` (`peekFaviconImageView`) — the
  display pipeline already tolerates "this tab shows something extra".
- **Backing-tab persistence pattern**: pinned entries and favorites persist their
  live tabs as `tab` rows (sentinel sortOrder). Precedent for tabs owned by a
  container — though splits won't need it (see §3).

**Gaps (all confirmed greenfield):**

- No drop target exists anywhere on the web content area (`contentContainerView`
  has zero drag registration). New work, but no conflicts either.
- `NSTableView.DropOperation` can't express left/right-edge drops — needs drop-x
  geometry on top of the existing row/operation model.
- Single-webview assumptions in `BrowserWindowController`: `claimWebView` /
  `showSnapshot` / `removeContentViews` / `webView(in:)` / script-handler wiring /
  `linkStatusBar` anchoring all assume one live container per tab.
- One row per tab in `SidebarLayout` row math; the diff engine keys on tab IDs.

## 2. Data model — decision

**A split is two adjacent normal tabs sharing a `splitGroupID`, not a container
object.** Both members stay first-class `BrowserTab`s in `space.tabs`.

```swift
// BrowserTab
var splitGroupID: UUID?      // nil = not in a split
```

**Invariant: members of a group are contiguous in `space.tabs`, in visual order
(left pane first). A group has exactly 2 members — one split per top-level tab,
by product decision; a group of 1 is dissolved immediately.** TabStore enforces this in every mutation; `assertSplitInvariants()`
in DEBUG.

Why not the alternatives:

- *Peek-style (`tab.splitPartner`)*: hides the second pane from everything keyed
  on `space.tabs` — extensions (WKWebExtension `tabs` API must enumerate both
  panes; 1Password filling the right pane needs it to be a real tab), history
  recording, sleep/archive, close/undo. Peek gets away with it because it's a
  transient overlay; split panes are long-lived pages.
- *Container object in a heterogeneous `space.tabs`*: touches every index-math
  call site, observer payload, and persistence loop for no v1 benefit. The
  groupID model degrades to exactly today's model when no splits exist.

**Sidebar item layer.** The sidebar renders *items*, computed by a pure flattener
(same pattern as `flattenPinnedTree`):

```swift
enum TabListItem: Equatable {
    case single(BrowserTab)
    case split(groupID: UUID, members: [BrowserTab])
}
func tabListItems(from tabs: [BrowserTab]) -> [TabListItem]
// + pure helpers: itemIndex(forTabIndex:), tabIndex(forItemIndex:), itemID(_:)
```

`SidebarLayout` functions switch from `tabCount` to `itemCount`;
`.normalTab(index)` becomes an item index. `diffSidebarState` keys tab-section
rows on item IDs (`tab.id` for singles, `groupID` for splits — stable across
member navigation). Merging two rows into a split diffs as remove A + remove B +
insert G (fade); acceptable, and batched under `performDropTransaction`.

`TabInsertion.tabInsertionIndex` gains a final "snap out of group interiors"
step so a new child tab never lands between two group members (pure, tested).

## 3. Persistence

Two new columns on `tab` (new migration; DEBUG wipes via
`eraseDatabaseOnSchemaChange`):

```
splitGroupID  TEXT NULL
splitFraction DOUBLE NULL   -- left pane's width fraction; both members store it, first wins
```

No new table — a `splitGroup` table only earns its keep if we later do N panes or
orientation. Load-time sanity pass: groupIDs that aren't shared by exactly 2
adjacent rows are cleared (defends against partial writes).

`ClosedTabRecord`: unchanged. Reopen (Cmd+Shift+T) restores as a normal single
tab. Undo of an interactive close *does* capture `splitGroupID` in the closure and
rejoins if the partner still exists (cheap: it's just re-setting the ID and
re-inserting adjacent).

## 4. TabStore API

All follow the house shape: mutate → `registerUndo` → `notifyObservers` →
`scheduleSave()`.

```swift
func createSplit(draggedTabID: UUID, targetTabID: UUID, edge: SplitEdge, in space: Space)
    // moves dragged adjacent to target (left edge → before, right → after),
    // assigns fresh groupID to both, fraction 0.5. Rejects if either is already
    // in a group (v1), pinned, or a favorite-backed tab.
func separateSplit(groupID: UUID, in space: Space)
    // clears both members' groupID; they remain adjacent as two rows.
func removeTabFromSplit(tabID: UUID, toGapIndex: Int, in space: Space)
    // clears groupID, moves to gap, dissolves the group (partner's ID cleared too).
func setSplitFraction(groupID: UUID, fraction: Double, in space: Space)
    // clamped ~0.2...0.8; no undo; debounced save only.
func addTabInSplit(with tabID: UUID, url: URL, in space: Space) -> BrowserTab?
    // Option-click path: creates a NEW tab immediately after `tabID`, groups the
    // two, loads url. Returns nil (caller falls back) if `tabID` is already
    // grouped, pinned, or favorite-backed.
```

Adjusted existing behavior:

- `closeTab`: if the closed tab was in a group, clear the survivor's groupID
  (auto-dissolve). Undo captures the groupID (see §3).
- `moveTab` / `.reorderNormalTab`: dragging a **split row** moves both members as
  a contiguous unit (new drag payload kind, §6). Gap indices for other drops are
  item-gap indices translated through the flattener helpers.
- `pinTab` on a split member: implicit `removeTabFromSplit` first (single
  transaction).
- `sleepStaleTabs` / `archiveStaleTabs`: the existing "never touch the selected
  tab" guard extends to "never touch any member of the selected tab's group" —
  otherwise a visible pane goes blank or vanishes.

New observer callback: `tabStoreDidUpdateSplitLayout(in space: Space)` (fraction
changes only — sidebar ignores it, non-owning windows may use it to refresh
snapshots lazily). Structural changes reuse the existing insert/remove/reorder
callbacks, since group membership changes always coincide with them.

## 5. Window layer (`BrowserWindowController`)

**Hosting.** When the selected tab is in a group, the content area hosts an
`NSSplitView` (vertical divider, `.thin`) whose two arranged subviews are the
members' `webViewContainer`s. NSSplitView manages child frames directly (no Auto
Layout inside), which preserves the frame-based-layout constraint that keeps the
docked Web Inspector working (`claimWebView`'s existing comment). Divider drags →
`setSplitFraction` (debounced). The split view itself is added exactly where the
single container goes today (`positioned: .below, relativeTo: dragHandle`).

**Ownership.** `claimWebView(for:)` generalizes to claim *all* panes of the
selected item: wire `navigationDelegate`/`uiDelegate`/the 3 script message
handlers per pane webview (loop over members), parent both containers into the
split view. `ownsWebView` becomes
`selectedTab?.webViewContainer?.isDescendant(of: contentContainerView) == true`.
Handoff snapshots capture the whole split view (`snapshotImage(of: splitView)`),
so the non-owning window shows one dimmed image of both panes — `showSnapshot`
is unchanged. `removeContentViews()` and `webView(in:)` learn to walk into the
split view; the skip-list is unchanged (the split view is torn down like a
container).

**Focused pane.** `selectedTabID` always identifies a *specific member* (the
focused pane), never the group — so the address bar, nav buttons, find bar,
`displayTab`, peek, and extension `tabActivatedNotification` all keep their
existing single-tab semantics untouched. Selecting the split row from the
sidebar selects the group's remembered-focused member (last focused; default
left). Focus moves between panes when a pane's webview becomes first responder
— `BrowserWebView` (subclass already exists) overrides `becomeFirstResponder()`
to notify its window controller, which updates `selectedTabID` +
`bindDisplayTab()` without re-running the content-view swap (both panes are
already up). Visual affordance: the unfocused pane gets a subtle dimmed overlay
or the focused pane a hairline accent border (pick during implementation).

**Chrome bindings.** `bindDisplayTab()` targets the focused pane (no change —
it already binds `displayTab`). `linkStatusBar` anchors to the focused pane's
webview. Cmd+F targets the focused pane. Cmd+W closes the focused pane; the
window then selects the surviving partner (special-cased ahead of the index
fallback).

## 6. Sidebar rendering & drag/drop

**Split row.** One `TabCellView`-style row per group, rendered as **two equal
halves** around a divider centered in the row: each member gets favicon + title
on its side, in visual pane order, with the focused member's title emphasized.
**Each half has its own hover close button that closes that pane** (dissolving
the group); the whole-split close lives in the context menu (**Close Both Splits**,
one transaction) and Cmd+W closes the focused pane. Selection highlight applies
when `selectedTabID ∈ group`.

**Payload & source extensions** (`SidebarDragDrop.swift`):

```swift
SidebarDragPayload.Kind: + case splitGroup      // whole-row drag (itemID = groupID)
                         + case splitMember     // one pane dragged (itemID = tabID)
SidebarDragSource:  + case splitGroup(itemIndex: Int, groupID: UUID)
                    + case splitMember(tabID: UUID, groupID: UUID)
SidebarDropDestination: + case intoSplit(targetTabID: UUID, edge: SplitEdge)
SidebarDropCommand: + case createSplit(draggedTabID: UUID, targetTabID: UUID, edge: SplitEdge)
                    + case reorderSplitGroup(groupID: UUID, toGapIndex: Int)
                    + case removeFromSplit(tabID: UUID, toGapIndex: Int)
enum SplitEdge { case left, right }
```

Which member a drag grabs: `DraggableTableView` already overrides `mouseDown`;
it stashes the down-point, and `pasteboardWriterForRow` uses the x-offset within
the row to emit `.splitMember` (over a favicon segment) vs `.splitGroup`
(elsewhere on the row). A pure helper decides:
`splitDragKind(forX:rowWidth:) -> …` (tested).

**Edge-drop creation.** `NSTableView.DropOperation` can't express left/right, so
`validateDrop` passes the drag x-position into the pure layer:

- Accept `.on` for normal-tab rows when the payload is a `normalTab` (today `.on`
  is folder-only). New pure function
  `splitEdge(forX x: CGFloat, rowWidth: CGFloat) -> SplitEdge?` — left ~40% →
  `.left`, right ~40% → `.right`, middle band → retarget to the nearest `.above`
  gap (plain reorder), so precise row-insertion drops stay easy to hit.
- `validateSidebarDrop` gains the edge-aware `.on` case; `resolveSidebarDrop`
  maps `(.normalTab source, .intoSplit dest)` → `.createSplit`. Split rows,
  pinned entries, folders, favorites, and already-grouped sources are rejected as
  split targets/sources in v1.
- Highlight: `.sourceList` feedback only draws whole-row `.on` highlight. Add a
  half-row overlay view (rounded rect over the left/right half of
  `rect(ofRow:)`) drawn by the sidebar VC during validate; cheap and removable.

**Drops resolve to delegate calls** (`TabSidebarDelegate` additions):

```swift
tabSidebar(_:didRequestCreateSplit draggedTabID:UUID, withTabID:UUID, edge:SplitEdge)
tabSidebar(_:didRequestSeparateSplit groupID:UUID)
tabSidebar(_:didRemoveTabFromSplit tabID:UUID, toGapIndex:Int)
tabSidebar(_:didMoveSplitGroup groupID:UUID, toGapIndex:Int)
```

Create/break drops wrap in `performDropTransaction` (they're reorder + group
mutations); the transaction's single `applyPendingState` animates the row merge.

**Breaking apart by drag.** Dragging a `.splitMember` payload to any normal-tab
gap resolves to `.removeFromSplit` — the member becomes its own row where
dropped. (Dropping a member onto *another* tab's edge — leave-and-rejoin — is
explicitly v2; resolver returns nil.)

**Context menu** (`menuNeedsUpdate`): split rows get **Separate Tabs** (→
`separateSplit`), plus the standard items re-targeted sensibly (Copy URL copies
the focused member's; Move to Space moves both; Pin/Archive hidden in v1).
Normal tab rows gain **Split with Next Tab** only if we want a keyboard-free
creation path — optional, DnD and menu separation are the required surfaces.

## 7. Web-content-area edge drops

New `SplitDropZoneView`: a transparent overlay added to `contentContainerView`
(above the webview, below `dragHandle`) **only while a sidebar tab drag session
is active** — the sidebar already broadcasts session start/end
(`draggingSession(_:willBeginAt:)` / `endedAt`, currently used for
`setDragSessionActive`); route the same signal through the delegate to the
window controller. Because the overlay only exists during our own local drag,
it never interferes with WKWebView's native drop handling (files into pages,
etc.).

- Registers for `tabReorderPasteboardType`; accepts only `normalTab` payloads
  whose `spaceID` matches the window's active space (mirrors
  `localDragPayload` rules; cross-window rejected via `sidebarID` in v1).
- `draggingUpdated` computes the zone: left ~30% of the content width → `.left`,
  right ~30% → `.right`, middle → no-op (reject). Shows a translucent rounded
  rect over the half where the pane would land (the standard "drop preview"
  affordance).
- Drop → `TabStore.createSplit(draggedTabID:, targetTabID: <window's selectedTabID's
  pane under the split — i.e. the currently selected tab>, edge:)`. If the
  selected tab is already a split (v1: 2-pane max), the zones don't activate.

## 8. Option-click: open link in split

Handled in `decidePolicyFor` (`BrowserWindowController+Navigation.swift`)
alongside the existing Cmd+click (new tab, line 8) and Shift+click (peek,
line 15) branches.

**Ordering constraint:** WebKit sets `navigationAction.shouldPerformDownload`
for Alt-clicked links (Safari's "Option-click downloads" convention), and the
current policy method honors it. The Option branch must test
`.linkActivated` + `.option` **before** the `shouldPerformDownload` check —
which deliberately retires Option-click-to-download (the context menu's
"Download Linked File" still covers it).

**Pane resolution:** like the existing `tab(owning:)` helper, the branch
resolves the *clicked* pane from the `webView` parameter rather than assuming
`selectedTab` — in a split, a link can be Option-clicked in the unfocused pane.

Behavior:

- **Clicked tab not in a split** (and is a normal tab): `store.addTabInSplit(
  with: clickedTab.id, url:)` — new pane opens on the **right**, gets focus.
- **Clicked tab already in a split**: navigate the **other pane** to the URL
  ("send to other pane"). Respects the one-split-per-tab rule and makes
  Option-click a productive cross-pane gesture instead of a dead end.
- **Pinned tab / favorite** (can't join groups): fall back to Cmd+click
  behavior — background tab via `addTab(in:url:parentID:)`.
- Modifier precedence when combined: Cmd wins (new tab), then Shift (peek),
  then Option (split) — i.e. the existing branch order with Option appended
  before the download check.

## 9. Interactions with existing systems

- **Peek**: preserved, and **spans the whole split**. `PeekOverlayView` +
  the peek webview already cover the full `contentContainerView`, so this is
  the default behavior — no layout change. Rules in a split:
  - Shift+click in *either* pane opens the peek; it attaches to the clicked
    pane's `BrowserTab.peekTab` (also focusing that pane), so persistence
    (`peekURL`/`peekInteractionState` columns) is untouched.
  - The overlay is modal over both panes: clicks land on the overlay, so pane
    focus can't change while a peek is open (no `displayTab` rebind churn).
    Esc/close behavior is unchanged.
  - One peek at a time (existing `peekOverlayView == nil` guard). A saved peek
    on the unfocused pane stays dormant until that pane is focused —
    `restorePeekOverlayIfNeeded()` keys off `selectedTab` and needs no change.
  - The pinned-tab cross-host peek intercept also covers pinned split
    members (§12).

  **Follow-up (separate effort): extensions in peek views.** Split panes are
  extension-visible *because* they're real tabs in `space.tabs`; peek tabs are
  not, and today are invisible to the WKWebExtension layer. Peek should get
  fully functional extensions too. Known work items:
  - Call `context.didOpenTab(peekTab)` on every extension context when the
    peek webview is created (mirror of `BrowserTab.wake()`), and the
    corresponding close notification when the peek is dismissed/discarded —
    without this, content-script messaging (e.g. 1Password fill) has no tab
    binding.
  - Include `peekTab`s in whatever enumerates tabs for the extension adapter
    (the nav-callback resolver `tab(owning:)` already does this — the
    extension side needs the same treatment).
  - Decide active-tab semantics: while a peek is open, `displayTab` is the
    peek, so extension "active tab" (toolbar popups, `activeTab` grants)
    should probably target the peek; revert on close.
  - `expandPeekToNewTab()` must hand over without a spurious close/reopen pair.
  - Per the repo rule: corresponding tests + API Explorer coverage when the
    extension surface changes.
- **Extensions**: both panes are real tabs → `tabs` API enumerates both; focus
  changes post `tabActivatedNotification` as today. No new extension API surface
  in v1 (so no API Explorer/test updates required yet).
- **Sleep/archive**: guarded via group-aware selected check (§4).
- **Profile swap / favorites rebinding**: members are plain normal tabs; existing
  per-window refresh logic applies. Favorite-backed and pinned tabs can't join
  groups, so the sentinel-sortOrder paths never see groupIDs.
- **Incognito**: no special handling; groups just aren't persisted (incognito
  spaces never save).
- **Multi-window**: same space in two windows — one owns both pane webviews, the
  other shows a single snapshot of the whole split view. Ownership transfer on
  focus is the existing notification flow with the generalized claim.

## 10. Decided defaults (flag if you disagree)

1. **One split per top-level tab — 2 panes max, permanent product decision.**
   (The groupID model would extend to N, but nothing should be built assuming
   it.)
2. **Vertical divider only** (side-by-side), no horizontal splits.
3. Sidebar split row: **each half's close button closes its own pane**; the
   context menu's **Close Both Splits** closes both (one transaction); **Cmd+W closes
   the focused pane**.
4. **Splits form between normal tabs, but survive pinning.** Dragging a whole
   split row into the pinned section pins both members as two adjacent entries
   that keep the group — a **pinned split** (§12). Pinning a *single* member
   (favicon-segment drag, Pin menu item) still separates it first; favorites
   and peek tabs still can't be split members. Splits are never *created*
   inside the pinned section in v1 — they only arrive there by pinning an
   existing split.
5. Splits are **per-space, same-space only** (cross-space edge drops rejected,
   consistent with existing DnD rules).
6. Reopened closed tabs come back **unsplit**; interactive-close *undo* rejoins.
7. **Option-click** creates/targets splits and no longer downloads the link
   (Safari convention traded away; context menu still offers Download Linked
   File).

## 11. Phasing

Spike results (Jul 11, 2026): both phase 2 bets verified in a throwaway
NSSplitView app — the docked Web Inspector attaches inside a pane's container
and survives divider moves with zero Auto Layout complaints, and pane clicks
reliably fire `becomeFirstResponder` on the WKWebView subclass.

1. **DONE (Jul 11, 2026). Model + sidebar row (no DnD):** `splitGroupID`, TabStore mutations + undo +
   invariants, migration, `tabListItems` flattener + item-based `SidebarLayout` +
   diff, split row rendering, **Separate Tabs** menu item, group-aware
   sleep/archive guards. Tests: flattener, layout math, TabStore mutations,
   insertion snapping. Creation path for testing: temporary context-menu item.
2. **DONE (Jul 11, 2026). Window display:** NSSplitView hosting, generalized claim/release/snapshot,
   focused-pane tracking via `becomeFirstResponder`, chrome/find/status-bar
   binding, Cmd+W semantics, divider → fraction persistence. **Option-click**
   branch in `decidePolicyFor` (+ `addTabInSplit` from phase 1) — this is the
   first end-to-end creation path, ahead of any DnD. Peek-in-split rules
   verified here (mostly free). Implementation notes: focused-pane affordance is
   a hairline accent border on the focused container (`updateSplitPaneFocus`);
   panes render as rounded cards inset from the content area with an invisible
   gap divider (`HostedSplitView`), matching the content-area drop-zone preview
   geometry (`UIConstants.splitPaneInset`/`splitPaneGap`/`splitPaneCornerRadius`);
   the ownership notification now carries `tabIDs` (all claimed panes) and
   windows match on group intersection, since two windows showing the same
   split may focus different members; structural changes that bypass
   `selectTab` (pane closed, Separate Tabs, split formed around the selection)
   converge through `refreshSplitHostingIfNeeded()` from the store observers.
3. **DONE (Jul 12, 2026). Sidebar DnD:** payload kinds, resolver cases + tests, edge-drop validate
   geometry + half-row highlight, member drag-out, split-row unit reorder,
   `performDropTransaction` wiring. Implementation notes:
   - Geometry stays in the pure layer: `rowDropZone(forX:y:rowSize:)` maps an
     `.on` proposal to `.splitEdge(left/right)` (outer 40% bands) or
     `.reorderGap(offset:)` (middle band → nearest gap by vertical half);
     `splitRowDragKind(forX:rowWidth:)` gives each half's leading 34pt (the
     favicon segment) to a `.splitMember` drag, the rest to `.splitGroup`.
     `DraggableTableView` stashes the mouse-down point for the pasteboard writer.
   - `validateSidebarDrop`/`sidebarDropDestination` take `tabItems` + `dropZone`;
     a new `.acceptIntoSplit(edge:)` validation drives a half-row accent overlay
     (added to the table during validate, cleared via `draggingExited`/`Ended`
     hooks — the delegate is never told a drag left the table).
   - `removeTabFromSplit` now takes a PRE-removal gap, matching
     `moveTab(id:toGapIndex:)`; `createSplit`'s undo converts its stored index
     at fire time (the dragged tab may sit before or after the restore gap).
   - `createSplit`/`removeFromSplit` drops wrap in `performDropTransaction`
     even though they're single store mutations: they diff as remove+insert
     (row merge/split), and NSTableView does not survive structural batch
     updates issued while the drag session is still live — the transaction
     defers the table update past the session's end. Selection is captured
     before the drop and re-selected after (remove+insert loses it; moveRow
     wouldn't).
   - Dragging a whole split row into the pinned section (or onto a folder)
     pins BOTH members in visual order (`.pinSplitGroup`, one transaction).
     Originally this dissolved the split; superseded by §12 — the group is
     preserved as a pinned split.
   - v1 rejections enforced in validation + resolver: split MEMBERS can't
     pin, enter folders, or become favorites by drag; split rows can't become
     favorites; grouped sources and split rows can't be edge-drop targets;
     member-onto-edge (leave-and-rejoin) is v2.
   - `DraggableTableView`'s `draggingExited`/`draggingEnded` overrides (overlay
     cleanup) must NOT call super unguarded: NSView declares the
     NSDraggingDestination methods (so overrides compile) but NSTableView does
     not implement them all — an unrecognized-selector exception during drag
     teardown kills the session-end callbacks and strands the favorites drop
     zone. Guard with `instancesRespond(to:)`.
4. **DONE (Jul 13, 2026). Content-area DnD:** `SplitDropZoneView`, session-active plumbing through the
   delegate, zone preview, drop → `createSplit`. Implementation notes:
   - The sidebar's drag-session begin/end callbacks
     (`draggingSession(_:willBeginAt:)` / `endedAt`) now also fire a new
     `dragSessionDidChangeActive` delegate signal (ungated on activePageIndex so
     the begin/end pair always balances); the window controller installs the
     overlay on start and removes it on end, so it exists ONLY during our own
     local drag and never shadows WKWebView's native drop handling.
   - The overlay installs only when `splitDropTargetTabID` is non-nil — the
     selected tab must be an ungrouped normal tab (pinned/favorite backing tabs
     aren't in `space.tabs`; a grouped selection rejects, one split per tab).
   - Zone + validation are pure functions in `SplitDropZoneView.swift`
     (`splitContentDropEdge(forX:width:)` — outer 30% bands, strict boundaries;
     `validateContentSplitDrop` — mirrors `localDragPayload`: lone normal tab,
     same sidebarID + active space, not onto itself), unit-tested in
     `SplitDropZoneTests`. The view decodes the payload once on
     `draggingEntered` and reuses a single layer-backed accent preview (styling
     shared with the sidebar overlay via `UIConstants.splitDropAccent*`). No
     `hitTest` override: the overlay only exists while the mouse is captured by
     the drag (no clicks to pass through), and a nil-returning `hitTest` risks
     excluding the view from AppKit's undocumented drag-destination discovery.
   - Review fixes: `removeContentViews()`'s keep-list includes the zone (a
     shared-space mutation from another window mid-drag would otherwise detach
     it, and the stale property blocks reinstall for the rest of the drag);
     `onDrop` re-resolves the dragged tab in `space.tabs` before accepting
     (mirrors `resolveDragSource` — acceptance feedback must match whether
     `createSplit` will act, e.g. when another window closed the dragged tab
     mid-drag); the session-begin delegate signal fires before `willBeginAt`'s
     drag-image guard so it can't be skipped while `endedAt`'s is unconditional.
   - The drop routes through the sidebar's `performContentAreaSplitDrop`, which
     wraps the `createSplit` in `performDropTransaction` — same row-merge diff
     hazard as the sidebar's own `.createSplit` drop, deferred past the live drag
     session; selection is re-applied via `selectedTabIDForCurrentRow()`.
5. **Pinned splits (§12):** entry-level groups, pin/unpin preserving the split,
   pinned split row rendering, group-aware pinned reorder + DnD matrix.

## 12. Pinned splits

Pinning a split keeps it a split. The group concept extends to the pinned
section as a mirror of the normal-tab model:

**Model.** A pinned split is **two `PinnedEntry`s sharing
`PinnedEntry.splitGroupID`** (+ `splitFraction`, both store it, first wins).
Invariant: exactly 2 entries, **same `folderID`, consecutive in sibling sort
order** (nothing — entry or folder — sorts between them at their level).
While pinned, group membership lives ONLY on the entries; the backing
`BrowserTab.splitGroupID` stays nil (`space.tabs` invariants never see pinned
groups). The groupID value is carried across pin/unpin so undo/redo and the
sidebar diff (item ID = groupID in both sections) treat it as the same row
moving between sections.

**TabStore.**

```swift
func pinSplitGroup(groupID: UUID, in: Space)            // both tabs → 2 entries, group + fraction kept
func unpinSplitGroup(groupID: UUID, toGapIndex: Int, in: Space)  // both entries → adjacent tabs, group restored
func separatePinnedSplit(groupID: UUID, in: Space)      // context-menu Separate: clears both entries' group
func removePinnedEntryFromSplit(entryID: UUID, folderID: UUID?, beforeItemID: UUID?, in: Space)
    // member-segment drag to a pinned gap: dissolve + move the lone entry
```

- `splitGroup(containing:in:)` generalizes: a tab backing a grouped pinned
  entry resolves to the group with members = the entries' **live** tabs. All
  window hosting (claim/snapshot/refresh/Option-click send-to-other-pane)
  keys off this one function and needs no per-call-site changes.
- `setSplitFraction` writes to whichever side owns the group (tab members or
  pinned entries); the window reads the fraction through a store helper
  instead of `members[0].splitFraction`.
- Member-exit dissolution mirrors `leaveSplitGroup`: `unpinTab` (single
  member), `deletePinnedEntry`, `detachPinnedEntry` (→ favorite) clear the
  partner's group. `closePinnedTab` does NOT dissolve — a dormant member
  stays in the group and re-wakes on selection.
- `movePinnedTabToFolder` moves a grouped entry's **whole pair** as a block
  (the pinned analog of `moveTab`'s block move), and snaps a `beforeItemID`
  anchor that names the RIGHT member of a group to the LEFT member so nothing
  can land inside a group. `movePinnedFolder` gets the same anchor snap.
- Dormant entries participate: `unpinSplitGroup` materializes a tab for a
  dormant member exactly like `unpinTab` does.

**Persistence.** Migration v7 adds `splitGroupID TEXT` / `splitFraction
DOUBLE` to `pinnedTab`. Load-time `sanitizePinnedSplitGroups` clears groups
that aren't exactly 2 same-folder, sort-adjacent entries.

**Selection & hosting.** Selecting a pinned split wakes BOTH sides:
`selectTab` activates dormant partner entries (the pinned analog of the
sleeping-member wake), then the generalized `splitGroup` makes
`claimSplitWebViews` host both panes. `lastFocusedSplitMember` works
unchanged (keyed by groupID). Focused-pane Cmd+W / per-half close = the
existing pinned close semantics (live → dormant, dormant → delete entry;
delete dissolves, dormant doesn't). The pinned cross-host peek intercept now
also applies to split members.

**Sidebar.** `PinnedItem` gains `.split(groupID:entries:depth:)`; grouping
happens per sibling level inside `flattenPinnedTree` (adjacent sorted entries
sharing a groupID merge; a run of 1 renders as a plain entry — same defensive
rule as `tabListItems`). The selected-entry exposure for collapsed folders
exposes the whole `.split` item when the selected entry is a split member with
a valid adjacent partner (single-row exposure hid the partner from drag
semantics); partnerless/invalid groups fall back to the single row. `itemIDAtDropIndex` returns the group's FIRST entry ID so
drop anchors resolve to real sibling entries and naturally snap before the
group; `pinnedItemID` returns the groupID (diff identity).

**DnD matrix (v1).** Payload kinds `.pinnedSplitGroup` (row) /
`.pinnedSplitMember` (favicon segment), mirroring the normal-split kinds:

- split row → pinned gap / folder: `.pinSplitGroup` now preserves the group
  (one store call + one anchor move, single transaction).
- pinned split row → pinned gap / folder: reorder as a unit.
- pinned split row → normal-tab gap: `.unpinSplitGroup` — the split comes
  back as a normal split row.
- pinned split member → normal-tab gap: unpin that member alone (dissolves).
- pinned split member → pinned gap: `.removeFromPinnedSplit` (own pinned row).
- Rejected: pinned splits/members → favorites; anything → pinned-row split
  edges (no split creation in the pinned section); member → folder `.on`.
