---
type: Component
title: BrowserWindowController
description: The per-window controller — what each of its extension files handles, how it selects a tab and hosts content, and the per-window state it keeps apart from TabStore.
resource: ../../Detour/Browser/Window/BrowserWindowController.swift
tags: [architecture, window, selection, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-12T23:47:17Z }
sources:
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: window-dir
    resource: ../../Detour/Browser/Window
    title: Detour/Browser/Window (extension files)
  - id: browser-web-view
    resource: ../../Detour/Browser/Window/BrowserWebView.swift
    title: BrowserWebView.swift
  - id: side-panel-window
    resource: ../../Detour/Browser/Window/BrowserWindowController+SidePanel.swift
    title: BrowserWindowController+SidePanel.swift
  - id: side-panel-layout
    resource: ../../Detour/Browser/Window/SidePanelLayoutView.swift
    title: SidePanelLayoutView.swift
  - id: task-122
    resource: backlog:TASK-122
    title: Window close hands navigation delegates back to the tabs
  - id: task-128
    resource: backlog:TASK-128
    title: The page takes keyboard focus without a click
  - id: task-76
    resource: backlog:TASK-76
    title: Keys declined by web content no longer beep
---

# Role

One `BrowserWindowController` per browser window. It owns the window's view
tree (sidebar plus content area), the window's own state (active space,
selected tab), and it is the glue between three things: the sidebar's user
actions, [TabStore](./tabstore.md), and the WebKit delegates of the web views
it hosts.

It does not own tabs or spaces. It reads them from `TabStore.shared` (through
`var store`) and asks the store to change them.

# How it works

## Files

The class is split across extension files under
[Detour/Browser/Window](../../Detour/Browser/Window):

| File | Conformance / subject | Handles |
|---|---|---|
| `BrowserWindowController.swift` | Core, `NSWindowDelegate`, `NSMenuItemValidation`, `CommandPaletteDelegate`, `FindBarDelegate`, `WKScriptMessageHandler`, `DownloadManagerObserver`, `NSSplitViewDelegate` | Setup, space switching, `selectTab`, claiming web views, snapshots, split hosting and its animation veneer, find bar, Peek overlay, menu actions, close paths, window events. |
| `+TabStore.swift` | `TabStoreObserver` | Turning store callbacks into sidebar updates and selection repair. |
| `+TabSidebar.swift` | `TabSidebarDelegate` | Every sidebar gesture: select, close, move, pin, split, favorites, folders, spaces, archive. |
| `+Navigation.swift` | `WKNavigationDelegate` | Navigation policy (modifier clicks, Peek, external apps, downloads, CRX installs), commit and failure forwarding, process termination, authentication challenges, blocked-load counting. |
| `+WKUIDelegate.swift` | `WKUIDelegate` | `window.open`, `window.close`, JavaScript dialogs, file upload, media capture permission, return from Picture in Picture. |
| `+ExternalApps.swift` | — | Confirming non-HTTP URL schemes ([external apps](../features/external-apps.md)). |
| `+RecentTabSwitcher.swift` | — | Control+Tab MRU overlay ([tab switching](../tabs/tab-switching.md)). |
| `+SidePanel.swift` | — | Which tabs' live web views the window shows (`sidePanelDisplayedTabs`), the panel it displays, and putting a panel's view beside the content ([side panel](../extensions/side-panel.md)). |
| `SidePanelLayoutView.swift` | `NSView` subclass | The content split item's view: frames the tab content area and, while one shows, an extension side panel and its divider. |
| `BrowserWebView.swift` | `WKWebView` subclass | Pane focus on `becomeFirstResponder`, Cmd+Z routing, mouse button 3 = back, link context menu items. |

`WKExtensionWindowConformance.swift` (in `Detour/Extensions/Runtime/`) makes the
controller a `WKWebExtensionWindow`.

## View tree

```
window.contentView
└── NSSplitViewController.view          (sidebarSplitView)
    ├── sidebarItem  → TabSidebarViewController.view
    └── contentItem  → contentAreaView (SidePanelLayoutView)
                        ├── contentContainerView
                        │    ├── webViewContainer | hostedSplitView | snapshotImageView
                        │    ├── peek overlay + peek web view
                        │    ├── splitDropZoneView, splitRevealOverlay (transient)
                        │    ├── emptyStateLabel
                        │    ├── findBar, linkStatusBar
                        │    └── dragHandle (WindowDragView, top strip)
                        ├── ExtensionSidePanelView (only while a side panel shows)
                        └── SidePanelDividerView (hidden with no panel)
```

`contentAreaView` exists so an extension [side panel](../extensions/side-panel.md)
can sit at the trailing edge. With no panel `contentContainerView` fills it.
With one, the content area is simply narrower: everything listed under it
lays out against its bounds as before, and nothing in it knows about the
panel. The layout view is frame-based too.

Content views are added `positioned: .below, relativeTo: dragHandle`, so the
drag strip stays on top. The tab's container is laid out with **frames and
autoresizing masks**, never constraints: Auto Layout on a `WKWebView` breaks
the docked Web Inspector. See [AppKit gotchas](../platform/appkit-gotchas.md).

An empty `NSToolbar` is installed only so the traffic lights sit inside the
sidebar area.

`removeContentViews()` removes everything from `contentContainerView` except
a fixed list of chrome views. A new permanent subview of the content area
must be added to that exclusion list or it disappears on the next tab switch.

## Per-window state

| Property | Meaning |
|---|---|
| `activeSpaceID` | The space this window shows. |
| `selectedTabID` | The **focused pane**. In a split it names one member, never the group. |
| `selectedTab` | Resolved through `Space.displayableTab(id:)`. |
| `displayTab` | The presented Peek if there is one, else `selectedTab`; what the address bar describes. |
| `extensionActiveTab` | What extensions call the active tab (the Peek while one is up). |
| `ownsWebView` | Derived: is the selected tab's container a descendant of this window's content area? |
| `displayedSidePanel` | Derived: the extension side panel whose view is in `contentAreaView`, if any. The window does not choose it; `ExtensionSidePanelController.reconcile()` does, for all windows at once. |
| `isIncognito`, `incognitoSpaceID` | Set at creation; an incognito window never changes space. |
| `commandPaletteNavigatesInPlace` | Which of the two [command palette](../features/command-palette.md) modes is open. |
| `lastFocusedSplitMember` | Per split group, the pane to focus on re-select. |

Two Combine sets rebind on selection: `activeTabSubscriptions` (window title)
and `displayTabSubscriptions` (address bar text, secure lock, reload and
back/forward buttons).

## `selectTab(id:)`

The one path that changes what a window shows. In order:

1. Resolve the id through `displayableTab`; an unknown id is a no-op.
2. Dismiss the command palette.
3. Leave the previous tab: start Picture in Picture if it plays audio, hide
   the Peek UI, stamp `lastDeselectedAt` and capture its switcher preview
   (`stampDeselected`, for both panes of a split).
4. `removeContentViews()`.
5. Set `selectedTabID` and `space.selectedTabID`.
6. Wake what is needed: a dormant partner of a pinned split is activated;
   every split member is un-stamped and woken.
7. Rebind chrome, push state to the sidebar and set its row selection
   (under `suppressingSelectionCallbacks`, so the table's selection callback
   does not re-enter `selectTab`).
8. **Claim or snapshot**: claim the web view if this window is key, or if no
   member's container is hosted anywhere; otherwise show a snapshot.
9. Restore the tab's Peek, announce the active tab to extensions, and give
   the page keyboard focus when nothing else holds it (TASK-128).
   `announceExtensionActiveTabIfChanged` also settles the side panels, since
   the same paths change which tab a panel shows with.

`selectTab` is not idempotent for a live tab: it re-parents content, dismisses
the palette, cycles Picture in Picture and re-announces activation. Callers
that only need hosting to match the model use `refreshSplitHostingIfNeeded()`
or `ensureOwnsWebView()` instead.

`deselectAllTabs()` is the empty state: no selection, the "tab peace" label,
disabled navigation buttons.

## Claiming content

`claimWebView(for:)` wakes any member with no web view, then hosts one
container (`claimSingleWebView`) or two in an `NSSplitView`
(`claimSplitWebViews`), then calls `loadIfStalled()` on each member as a
safety net for a web view with no content. The single-owner mechanics are on
[web view ownership](./webview-ownership.md); the split view on
[split tabs hosting](../tabs/split-tabs-hosting.md).

`wireOwnedWebView` makes the window the `navigationDelegate` and `uiDelegate`
of a web view it hosts and registers itself for the `linkHover` and
`editableFieldFocus` script messages. Two consequences:

- `userContentController.add(self, name:)` **retains** the controller.
  `removeContentViews()` and `windowWillClose` remove the handlers; without
  that a closed window stays alive and keeps reacting to notifications.
  Both only reach web views still in the window's content area. A web view
  released from under the window — `TabStore.closeTab` on the window's
  selected tab tears the tab down *before* it notifies (an extension's
  `tabs.remove`, another window's close), or a forced sleep — is gone from
  the view tree by then, so `BrowserTab.releaseWebView` removes the
  `ownedScriptHandlerNames` handlers itself. Before that, such a window's
  controller outlived its window: found on 2026-10-04 as a
  `BrowserWindowController` still in `NSApp.windows` many test suites after
  its window closed, held only by a `ScriptMessageHandlerDelegate`
  (`leaks --traceTree`), and pinned by
  `ExtensionSidePanelTests.testAWindowWhoseSelectedTabTheStoreClosedIsReleased`.
- The window stays navigation delegate of every web view it ever hosted;
  nothing clears it on tab switch. Delegate callbacks therefore act on
  `tab(owning: webView)`, never on `selectedTab` — a load still in flight
  after a tab switch would otherwise be attributed to the wrong tab. On close
  the window hands each web view back to its tab
  (`handBackNavigationDelegates`, TASK-122).

## Reacting to the store

`+TabStore.swift` follows one pattern: ignore other spaces, call
`tabSidebar.applyState(…)`, then `refreshSplitHostingIfNeeded()` when the
change could alter how many panes the selected group has.

Selection repair after a removal is split in two on purpose:

- A window that closes a tab itself settles selection **before** asking the
  store (`settleSelectionLeaving(tabAt:in:)`, inside
  `settlingSelectionForClose` so no Picture in Picture starts for a tab about
  to be torn down). The next tab comes from
  [`tabCloseSelectionID`](../tabs/tab-insertion-and-close-selection.md).
- `tabStoreDidRemoveTab` only steps in when the removed tab is *still*
  selected, which means the removal came from elsewhere (an extension's
  `tabs.remove`, an undo, another window). It picks the adjacent tab.

Closing a pinned tab arrives as `tabStoreDidUpdatePinnedEntry` with
`entry.tab == nil`, not as a remove.

## Window events

| Event | What happens |
|---|---|
| `windowDidBecomeKey` | Tells `ExtensionManager` the active space, claims the selected tab's web view, restores its Peek. |
| Occlusion change to visible | Counts a show against the hosted tabs' show budget (`noteShown`). |
| `windowWillClose` | Saves Peek state, stamps the tab deselected, removes script handlers, hands back navigation delegates, `store.saveNow()`, removes observers, removes the incognito space if this is a Private window, and last closes the window's own side panels (`ExtensionSidePanelController.windowWillClose`). |
| `showWindow` (first time) | Puts keyboard focus on the page, or on nothing, never on a sidebar control. |

`keyDown` swallows keys that web content already declined, so they do not
beep (TASK-76), and handles Esc for the Peek. See
[keyboard focus](../sidebar/keyboard-focus.md).

The window object is a `BrowserWindow`. Its `performKeyEquivalent` offers a
key equivalent that nothing in the view tree took to the extensions'
[command shortcuts](../extensions/command-shortcuts.md), after the page and
after Detour's own menu.

## Menu actions

Main menu items target the responder chain with selectors on this class
(`newTab(_:)`, `closeCurrentTab(_:)`, `reopenClosedTab(_:)`, `nextSpace(_:)`
and so on; the menu is built in [app shell](./app-shell.md)).
`validateMenuItem` disables space switching, pinning and the archive items in
a Private window, and retitles Undo/Redo from the store's undo manager unless
the page has an editable field focused.

`closeCurrentTab` has a fixed precedence: an open Peek closes first; with no
selection the window closes; a pinned tab goes dormant; a favorite is
deactivated; otherwise the tab closes.

# Gotchas

- `window.open()` never goes through `decidePolicyFor`; it arrives at
  `createWebViewWith`. Policy that must cover scripted opens (the internal
  page refusal, the Peek rule) is duplicated there. It returns the new
  tab's web view, made from the configuration WebKit supplies; returning nil
  leaves the page's `window.open()` with null. See
  [WKWebView delegate order](../platform/wkwebview-delegate-order.md).
- `handleSpaceTabsNeedRehost` leaves a window alone when the notification
  names tabs and none of them is displayed here, precisely because
  `selectTab` has side effects.
- Only non-incognito windows whose creation did not cascade from another
  browser window set the frame autosave name. Autosave names are scoped by
  data directory (`UserDefaultsScope`), see
  [profile data removal](./profile-data-removal.md).
- A web content process that dies leaves a white, unresponsive view with no
  further callback. `webViewWebContentProcessDidTerminate` reloads, capped by
  `BrowserTab.noteProcessTermination()` so a page that kills its process on
  every load does not loop. A termination the tab asked for itself
  (`isTerminatingUnresponsiveProcess`) is skipped: the tab issues the load
  when the kill returns
  ([unresponsive web process](../platform/unresponsive-web-process.md)).

# Tests

Window behaviour that matters is tested without driving the UI:
`InitialWindowFocusTests`, `CommandPaletteFocusTests`,
`UnhandledKeyFallthroughTests`, `ExtensionActiveTabTests`,
`SpaceEntrySelectionTests`, `SplitTabTests`, `SidebarVisibilityStateTests`,
`ProductionDefaultsIsolationTests`. Layout, hosting and animation are checked
at runtime; see [runtime verification](../playbooks/runtime-verification.md).

# Related

- [Web view ownership](./webview-ownership.md) — claim, snapshot, transfer.
- [BrowserTab](./browser-tab.md) — the object it hosts.
- [Sidebar overview](../sidebar/overview.md) — the other half of the window.
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — the two-pane case.
- [Peek](../tabs/peek.md) — the overlay it presents.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — the window as seen by extensions.
- [Side panel](../extensions/side-panel.md) — the pane beside the content area.
