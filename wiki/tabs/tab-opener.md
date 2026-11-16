---
type: Concept
title: Tab opener
description: "The link from a tab to the tab it was opened from (BrowserTab.parentID): which paths set it, the readers (insertion, close selection, Back and the back swipe, window.close, reopen and the close undos, Move to Space) and the different openers each accepts, and when the link is cut, re-checked or left dangling."
tags: [tabs, opener, rules, undo]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:59:43Z }
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
is gone. The link is cut explicitly in only two places: Move to Space, and a
tab coming back from a closed-tab record or a close undo
(`Space.liveOpenerID`).

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
| Session restore at launch | the saved `tab.parentID` column, for normal tabs |
| Undo Delete Space | the snapshot's `parentID`, unchecked (the tabs come back with their old ids) |
| Reopen Closed Tab, the archive page's restore, Undo Close Tab, Undo Close Both Splits | `space.liveOpenerID(saved)` (below) |

## Who reads it, and which opener each accepts

The readers do not share one resolver, and they accept different openers
(one shared rule, or each difference recorded as deliberate, is planned in
TASK-358[^task-358]):

| Reader | What it does with the link | Opener it accepts |
|---|---|---|
| `tabInsertionIndex` ([insertion rule](./tab-insertion-and-close-selection.md)) | a child lands after its parent and the run of siblings below it | a normal tab of the list; for a pinned or missing parent, after the first run of that parent's children (0 with none). Siblings match on the raw id |
| `tabCloseSelectionID` ([close selection](./tab-insertion-and-close-selection.md)) | next sibling, previous sibling, then the parent | the parent only when it is a **normal** tab of the list; siblings match on the raw id, so two children of a closed opener are still siblings |
| `BrowserWindowController.parentTab(for:)` → `Space.openerTab(id:)`: the Back button (and its enabled state), Cmd+[, the palette's Back, the [back swipe](./back-swipe-to-opener.md) | with no back item, select the opener and close the child | a normal tab or a **live pinned** tab of the window's **active** space. Not a favourite, an asleep pinned entry, a closed or archived tab, or a tab of another space |
| `hasOpenChild` (the back swipe's opener-picture cache) | keep the opener's picture while some child of it is open | raw id, any normal tab of **any** space |
| `webViewDidClose` (a page's `window.close()`, TASK-168) | when the closing tab is the window's selected tab and not in a split, select its opener ahead of the close rule's siblings | any `displayableTab` of the space: normal, live pinned, **or a favourite's tab** |
| `Space.liveOpenerID(_:)`: `reopenClosedTabRecord`, the `closeTab` and `closeSplitGroup` undos | keep the saved link only while `openerTab` still resolves it in the space the tab returns to | as `openerTab` |
| The Move to Space undo | relink the returning tab | only a **normal** tab of the home space (`home.tabs.contains`); a live pinned opener is not relinked |

`closeTab` closes normal tabs only. So Back on a pinned tab with a
`parentID` and no history selects the opener and leaves the pinned tab
alone, and the back swipe keeps WebKit's gesture there.

## When the link is cut, re-checked, or left dangling

- **Opener closed, archived, asleep (pinned) or moved away**: the child's
  `parentID` is left as it is. `openerTab` stops resolving it, so Back and
  the swipe no longer close to it; the insertion and close-selection rules
  still group the child with its siblings by that id.
- **The child moves to another space** (`moveTab(id:from:to:)`, TASK-38):
  `parentID` is set to nil, since the opener stays behind; the child arrives
  as a root tab. Undoing the move puts the saved link back only while the
  opener is still a normal tab of the home space. The pinned move
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
- **Pinning** keeps the backing tab's `parentID` in memory. It is saved for
  pinned and favourite backing rows but read back at launch only for normal
  tabs, so a pinned tab's link does not survive a relaunch. Keeping it
  across a relaunch (or recording why not) is planned in
  TASK-358.[^task-358]

# Where it lives

| What | Where |
|---|---|
| The field | `BrowserTab.parentID` in [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift); `TabRecord.parentID` in the session database |
| Resolution | `Space.openerTab(id:)`, `Space.liveOpenerID(_:)` in [TabStore.swift](../../Detour/Browser/TabStore.swift); `BrowserWindowController.parentTab(for:)` |
| Pure rules | [TabInsertion.swift](../../Detour/Browser/TabInsertion.swift), [TabCloseSelection.swift](../../Detour/Browser/TabCloseSelection.swift) |
| Tests | `TabInsertionTests`, `TabCloseSelectionTests`, `ClosedTabOpenerTests` (written, kept, dropped on reopen and on a close undo, v26), `MoveTabToSpaceTests`, `NavigationSwipeTests`, `PageOpenedWindowTests` |

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
