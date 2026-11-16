---
type: Concept
title: Tab opener
description: "The link from a tab to the tab it was opened from (BrowserTab.parentID): which paths set it, the one opener rule (Space.openerTab: a normal, live pinned or live favourite tab) every reader resolves it by (close selection, Back and the back swipe, window.close, reopen and the close undos, Move to Space), the deliberate exceptions, and when the link is cut, re-checked or left dangling."
tags: [tabs, opener, rules, undo]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T21:46:03Z }
sources:
  - id: browsertab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (parentID)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Space.openerTab, liveOpenerID, insertTab, closeTab, closeSplitGroup, reopenClosedTabRecord, moveTab(id:from:to:), addTabInSplit, addSplitInNormalSection, restoreSession)
  - id: insertion
    resource: ../../Detour/Browser/TabInsertion.swift
    title: TabInsertion.swift (tabInsertionIndex)
  - id: close-selection
    resource: ../../Detour/Browser/TabCloseSelection.swift
    title: TabCloseSelection.swift (tabCloseSelectionID)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (parentTab(for:), navigateBackOrCloseChildTab, settleSelectionLeaving, Peek expansion)
  - id: uidelegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
    title: BrowserWindowController+WKUIDelegate.swift (createWebViewWith, openerPlacement, webViewDidClose)
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (Cmd+click, links that open a tab)
  - id: swipe
    resource: ../../Detour/Browser/Window/BrowserWindowController+NavigationSwipe.swift
    title: BrowserWindowController+NavigationSwipe.swift
  - id: closed-record
    resource: ../../Detour/Storage/Models/ClosedTabRecord.swift
    title: ClosedTabRecord.swift (parentID, v26)
  - id: tests-opener
    resource: ../../DetourTests/ClosedTabOpenerTests.swift
    title: ClosedTabOpenerTests.swift
  - id: task-332
    resource: backlog:TASK-332
    title: "Tabs: Reopen Closed Tab restores a child tab's link to its opener"
  - id: task-325
    resource: backlog:TASK-325
    title: The back swipe on a tab opened from another tab closes it and returns to the opener
  - id: task-168
    resource: backlog:TASK-168
    title: A sign-in popup cannot reach the page that opened it or close itself
  - id: task-38
    resource: backlog:TASK-38
    title: Moving a tab to another space
  - id: task-167
    resource: backlog:TASK-167
    title: window.open() hands the page no window back, so an xterm.js terminal link opens an empty tab
  - id: task-358
    resource: backlog:TASK-358
    title: "Tab opener: a pinned or favourite tab's opener is lost at relaunch, and the readers disagree on which openers count"
  - id: task-377
    resource: backlog:TASK-377
    title: "Sidebar: the Back button stays enabled after a child's opener closes or a favourite opener sleeps"
  - id: task-378
    resource: backlog:TASK-378
    title: "Tab opener: a pinned tab or favourite that goes to sleep loses its own opener link"
  - id: checks-377
    resource: ../../docs/harness/task377-back-enabled-checks.py
    title: TASK-377 runtime checks through the automation endpoint (Back's enabled state)
  - id: tests-rule
    resource: ../../DetourTests/TabOpenerRuleTests.swift
    title: TabOpenerRuleTests.swift (TabOpenerRuleTests, TabOpenerWindowTests)
  - id: checks-358
    resource: ../../docs/harness/task358-opener-relaunch-checks.py
    title: TASK-358 runtime checks through the automation endpoint (three launches)
---

# Summary

Every `BrowserTab` can remember the tab it was opened from:
`BrowserTab.parentID`, an id, never an object. The normal-tab list stays
flat; the link only steers a few decisions: where a new tab lands, which
tab is selected after a close, and whether Back (with no history) closes
the tab and returns to its opener.

The link is **resolved when it is read, not kept valid**. Nothing clears a
child's `parentID` when its opener closes, sleeps or moves; each reader
looks the id up in the space it is working in and gets nothing back when it
is gone. Every reader that resolves it uses **one rule**,
`Space.openerTab(id:)` (below). The link is cut explicitly in only two
places: Move to Space, and a tab coming back from a closed-tab record or a
close undo (both through `Space.liveOpenerID`).

This is Detour's own link. It is not the page's `window.opener`, the
JavaScript relationship WebKit keeps between a page and a window it opened
(see [WKWebView delegate order](../platform/wkwebview-delegate-order.md));
a tab can have one without the other, and a tab that sleeps and wakes loses
the `window.opener` but keeps `parentID` (see
[tab lifecycle](./tab-lifecycle.md)).[^task-167]

# Rules

## Where it is set

`TabStore.insertTab(_:in:parentID:)` sets it for the whole `addTab` family,
and computes the insertion index from it in the same call. The other writers
set it directly.

| Path | `parentID` |
|---|---|
| Cmd+click, "Open Link in New Tab", a link that a policy turns into a background tab, Open Link in Quick Detour falling back to a tab | the window's `selectedTabID` |
| A page's `window.open` or `target=_blank` link (`createWebViewWith`) | the tab hosting the web view that asked (`openerPlacement`), searched in the active space first, then every space; a Peek's request is made on behalf of its host. That tab may be a pinned or a favourite's backing tab. The new tab goes into the opener's space |
| A link on a pinned tab or favourite that would have peeked, with Peek turned off (`PeekAnchor`, TASK-307) | the pinned or favourite tab that fired it; the new tab is selected |
| Expanding a [Peek](./peek.md) into a tab | the selected tab (the host) |
| A Peek's Open in Split View, Option-click (`addTabInSplit`) | the anchor tab, for the new pane |
| A split opened from a favourite or lone pinned tab (`addSplitInNormalSection`) | the favourite or pinned tab, for **both** panes, so later children land after the pair ([split tabs](./split-tabs.md)) |
| The command palette, a new window's tab, the Help menu, extensions' `tabs.create`, links from other apps, a Quick Detour moved into a space | nil (a root tab) |
| Session restore at launch | the saved `tab.parentID` column, unchecked, for every row: normal tabs, pinned backing tabs and favourite backing tabs (the last two since TASK-358). Ids are kept, so the link still resolves; an opener rebuilt later in the load (a pinned entry, a favourite) is why it is not checked there |
| Undo Delete Space | the snapshot's `parentID`, unchecked (the tabs come back with their old ids) |
| Reopen Closed Tab, the archive page's restore, Undo Close Tab, Undo Close Both Splits | `space.liveOpenerID(saved)` (below) |

## The opener rule: `Space.openerTab(id:)`

A tab counts as an opener in a space when it is, in that space:

- a **normal tab** of its list,
- a **live pinned tab** (an entry with a backing tab), or
- the **live backing tab of a favourite** of the space's profile (a
  favourite belongs to every space of its profile).

Not an asleep pinned entry, a dormant favourite, a closed or archived tab,
a tab of another space, or another profile's favourite. The function has one
line per kind, so a kind is added or dropped for every reader at once.

Before TASK-358 the readers disagreed: the close selection and the Move to
Space undo took only a normal tab, `openerTab` also a live pinned tab, and
`window.close()` a favourite's tab too; and `openerPlacement` (a page's
`window.open`) and Peek-off links already made a favourite's tab the parent,
which Back then never resolved.[^task-358]

## Who reads it

| Reader | What it does with the link | Opener |
|---|---|---|
| `BrowserWindowController.parentTab(for:)`: the Back button, Cmd+[, the palette's Back, the [back swipe](./back-swipe-to-opener.md) | with no back item, select the opener and close the child | the rule, in the window's **active** space |
| `BrowserWindowController.canNavigateBack`: whether the sidebar Back button and Navigate › Back (and so the palette's Back) are enabled | history, or `parentTab(for:)` resolving (a Peek: its history) | the rule, through `parentTab(for:)`; refreshed on the tab's `canGoBack` and on every store change that can make an opener resolve or stop (TASK-377) |
| `tabCloseSelectionID` ([close selection](./tab-insertion-and-close-selection.md)), through `settleSelectionLeaving` (Cmd+W, a close from the sidebar, Move to Space leaving the selection) | next sibling, previous sibling, then the opener, then a neighbour | the rule (the window passes `isOpener`); the opener need not be in the list, so the last normal tab returns to a pinned or favourite opener too |
| `webViewDidClose` (a page's `window.close()`, TASK-168) | when the closing tab is the window's selected tab and not in a split, select its opener **ahead of** the close rule's siblings | the rule |
| `Space.liveOpenerID(_:)`: `reopenClosedTabRecord`, the `closeTab` and `closeSplitGroup` undos | keep the saved link only while it resolves in the space the tab returns to | the rule |
| Move to Space (`moveTab(id:from:to:)`) and its undo | keep the link in the destination, and relink on the way home, only while it resolves there | the rule (`liveOpenerID`) |

**Deliberate exceptions**, which read the raw id and not the rule:

| Reader | Uses | Why it is not the rule |
|---|---|---|
| `tabInsertionIndex` ([insertion rule](./tab-insertion-and-close-selection.md)) | where the parent is: a normal tab of the list (after it and its run of children), else at the top after the first run of its children | placement, not resolution: it asks where to put the child, and runs only while the parent is live |
| Sibling matching in `tabCloseSelectionID` | the raw `parentID` | two children of a closed opener are still related, and a sibling is a tab of the list either way |
| `hasOpenChild` (the back swipe's opener-picture cache) | raw id, any normal tab of any space | it decides only how long a picture is kept; keeping one a little longer costs nothing |
| `webViewDidClose`'s order | the opener before siblings | a window that closes itself was opened for its opener (a sign-in popup); the opener kinds are the rule's |

`closeTab` closes normal tabs only. So Back on a pinned tab or favourite
with a `parentID` and no history selects the opener and leaves the tab
alone, and the back swipe keeps WebKit's gesture there.

**The user's decision (2026-11-16, TASK-358):** a favourite counts (Back,
Cmd+[ and the swipe on a child of a favourite close it and select the
favourite, as for a pinned opener); Cmd+W on a child returns to its pinned
or favourite opener after its siblings, ahead of the neighbour, as Back
does; Move to Space keeps the link while it resolves in the destination (a
favourite of its profile, an opener moved there first).

## When the link is cut, re-checked, or left dangling

- **Opener closed, archived, asleep (pinned or a dormant favourite) or moved away**: the child's
  `parentID` is left as it is. `openerTab` stops resolving it, so Back and
  the swipe no longer close to it, and Back is disabled while the child has
  no history; the insertion and close-selection rules still group the child
  with its siblings by that id. The window re-reads Back's enabled state on
  the same store notifications that re-decide the swipe mode (a tab or
  pinned entry inserted, removed, pinned, unpinned, put to sleep or woken;
  the favourites changed). Before TASK-377 it was re-read only when the
  child's `canGoBack` changed, so Back stayed enabled and did
  nothing.[^task-377]
- **The child moves to another space** (`moveTab(id:from:to:)`, TASK-38):
  `parentID` becomes `destination.liveOpenerID(saved)`: the link is kept
  while it resolves in the destination by the rule (a favourite of the
  destination's profile, or an opener moved there before the child), else
  nil and the child arrives as a root tab (the usual case: the opener stays
  behind). Before TASK-358 it was always cut. Undoing the move
  puts the saved link back only while it resolves in the home space
  (a live pinned opener too, since TASK-358). The pinned move
  (`movePinnedEntry`) does not touch the backing tab's link; it simply stops
  resolving in the other space.
- **The child comes back from a record or an undo** (TASK-332): the saved
  id is kept only through `Space.liveOpenerID`. Closed-tab records carry it
  (`closedTab.parentID`, migration v26; see
  [closed tabs and archive](./closed-tabs-and-archive.md)), and the two close
  undos capture it. Before TASK-332 the undos restored it unchecked and left
  `parentTab(for:)` to ignore a dangling one.[^task-332]
- **Identity decides the rest.** Reopen and the close undos build the tab
  with a **new id**, so a reopened or undone opener is a different tab: close
  a child, then its opener, bring both back, and the child is unlinked. Undo
  Delete Space and session restore keep ids, so their links still resolve.
  In Close Both Splits, a pane opened from its partner comes back unlinked:
  the partner is a new tab too.
- **Pinning, or moving to the favourites**, keeps the backing tab's
  `parentID`, and it survives a relaunch: it is saved for pinned and
  favourite backing rows and, since TASK-358, read back for them too. Before,
  restore read it only for normal tabs, so after a relaunch Back on a pinned
  child no longer selected its opener.[^task-358]
- **A pinned tab or favourite going to sleep** (the sleep sweep) keeps its
  link: it stays live but asleep, the same `BrowserTab`, and wakes into it.
- **A pinned tab or favourite going dormant** (Cmd+W, the row's minus
  button, an extension's `tabs.remove`, a space moved to another profile)
  drops its backing tab, and the wake (a click, an unpin, a dormant
  favourite dragged into the tab list) builds a new tab with a new id at its
  home page. The entry or favourite keeps the dropped tab's `parentID`
  (`dormantOpenerID`) and the new tab gets it back through
  `space.liveOpenerID`, in the space it wakes in, as a reopened tab does;
  Undo Close Tab of a pinned tab likewise. A dormant favourite dragged into
  the pinned section hands the link to its entry, and Undo Delete (pinned
  entry) and Undo Delete Space bring a dormant entry back with it. Before
  TASK-378 the woken tab had no link.[^task-378] Limits: it is kept **in
  memory only** (a relaunch with the tile dormant loses it). Keeping it
  across a relaunch is the user's decision (2026-11-16), pending TASK-384:
  new columns on the `pinnedTab` and `favorite` tables, migration v27. A
  favourite woken in another space than its opener's is unlinked; a dormant
  pinned tile dragged to the favourites bar (`addFavoriteFromEntry`) starts
  without the link (TASK-393). The other direction is not kept: the woken
  tab has a new id, so children of the tab that went dormant no longer
  resolve it (TASK-394).

# Runtime check

`docs/harness/task358-opener-relaunch-checks.py` drives a Debug build
through the automation endpoint over three launches of one isolated data
directory: a `target=_blank` child pinned with Cmd+D writes its opener into
its backing row and, after a relaunch, Cmd+[ on it selects the opener; with
the opener's row turned into a favourite's (sqlite3, app quit) and another
relaunch, a normal child has the own swipe with the favourite as
`opener_id`, Cmd+[ closes it to the favourite, and Cmd+W on a lone child of
the favourite returns to it rather than to its neighbour. Trap: a
`target=_blank` click on a favourite (or pinned tab) peeks, so the child of
a favourite is made with a Cmd+click.[^checks-358]

`docs/harness/task377-back-enabled-checks.py` checks Back's enabled state in
one launch: Navigate › Back is refused as disabled on a root tab, the
sidebar button's chevron is drawn darker on a `target=_blank` child, and
after the opener is archived from its row's menu (the child staying
selected) the menu item and Cmd+[ are refused and the chevron is drawn as on
the root tab. The button is read from screenshots (the darkest pixel around
it); the sidebar table hit-tests as a whole, so the opener's row is found by
its place in the list.[^checks-377]

`docs/harness/task378-dormant-opener-checks.py` pins a `target=_blank`
child (Cmd+D), closes it to a dormant tile (Cmd+W), wakes it with a click
(a new tab id) and checks Cmd+[ selects the opener and keeps the pinned tab;
then, dormant again with the opener closed meanwhile, the woken tab has no
opener and Navigate › Back is disabled.[^task-378]

# Where it lives

| What | Where |
|---|---|
| The field | `BrowserTab.parentID` in [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift); `TabRecord.parentID` in the session database |
| Resolution | `Space.openerTab(id:)`, `Space.liveOpenerID(_:)` in [TabStore.swift](../../Detour/Browser/TabStore.swift); `BrowserWindowController.parentTab(for:)` |
| Pure rules | [TabInsertion.swift](../../Detour/Browser/TabInsertion.swift), [TabCloseSelection.swift](../../Detour/Browser/TabCloseSelection.swift) |
| Tests | `TabOpenerRuleTests` (the rule per kind, the relaunch round trips, reopen, close undo and Move to Space with pinned and favourite openers; a pinned tab or favourite keeping its own link across dormancy, its close undo, unpin and the drag to the tab list), `TabOpenerWindowTests` (Back, Cmd+W, `window.close()` and the swipe mode with pinned and favourite openers; Back's enabled state, button and menu, as an opener closes, goes dormant, is removed or moves away and back), `TabInsertionTests`, `TabCloseSelectionTests`, `ClosedTabOpenerTests` (written, kept, dropped on reopen and on a close undo, v26), `MoveTabToSpaceTests`, `NavigationSwipeTests`, `PageOpenedWindowTests` |

# Related

- [Tab insertion and close selection](./tab-insertion-and-close-selection.md) — the two pure rules that read the link.
- [Back swipe to the opener](./back-swipe-to-opener.md) — closing a child by swiping, per pane.
- [Closed tabs and archive](./closed-tabs-and-archive.md) — the record's `parentID` and the close undos.
- [Tab lifecycle](./tab-lifecycle.md) — the creation paths in full.
- [Browser undo](../architecture/browser-undo.md) — the undos that re-check the link.
- [Profiles and spaces](../architecture/profiles-and-spaces.md) — Move to Space.

[^task-332]: "Tabs: Reopen Closed Tab restores a child tab's link to its opener"
[^task-167]: window.open() hands the page no window back, so an xterm.js terminal link opens an empty tab
[^task-358]: Tab opener: a pinned or favourite tab's opener is lost at relaunch, and the readers disagree on which openers count
[^checks-358]: TASK-358 runtime checks through the automation endpoint (three launches)
[^task-377]: Sidebar: the Back button stays enabled after a child's opener closes or a favourite opener sleeps
[^checks-377]: TASK-377 runtime checks through the automation endpoint (Back's enabled state)
[^task-378]: Tab opener: a pinned tab or favourite that goes to sleep loses its own opener link
