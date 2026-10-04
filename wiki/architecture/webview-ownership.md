---
type: Concept
title: Web view ownership
description: A tab's web view is hosted by at most one window; the others draw a dimmed snapshot, and hosting moves to whichever window becomes key.
tags: [architecture, webkit, window, multi-window]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T18:50:00Z }
sources:
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (claim, snapshot, ownership notification)
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (webViewContainer)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (sleepStaleTabs)
  - id: ownership-doc
    resource: ../../docs/webview-ownership.md
    title: docs/webview-ownership.md
  - id: switcher
    resource: ../../Detour/Browser/Window/BrowserWindowController+RecentTabSwitcher.swift
    title: BrowserWindowController+RecentTabSwitcher.swift
  - id: side-panel-window
    resource: ../../Detour/Browser/Window/BrowserWindowController+SidePanel.swift
    title: BrowserWindowController+SidePanel.swift (sidePanelDisplayedTabs)
  - id: side-panel-tests
    resource: ../../DetourTests/ExtensionSidePanelTests.swift
    title: ExtensionSidePanelTests (testATabShownInTwoWindowsShowsItsPanelOnlyWhereItsWebViewIs)
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process IOSurface leak and the show budget
---

# Summary

Spaces and tabs are global, windows are independent, so two windows can
select the same tab. A `WKWebView` is an `NSView` and has one superview. The
window that is key hosts the tab's live web view; any other window showing
that tab draws a snapshot image at half opacity. When a window becomes key it
takes the web view.

"Owning" is not stored anywhere. `BrowserWindowController.ownsWebView` is
derived from the view hierarchy: the selected tab's `webViewContainer` is a
descendant of this window's `contentContainerView`. It cannot drift out of
sync with what is on screen.

# Rules

## What moves

The unit that is hosted and moved is `BrowserTab.webViewContainer`, not the
web view. WebKit docks the Web Inspector as a sibling of the web view inside
that container, so moving the container keeps the inspector with the tab. A
split moves as a whole: both pane containers inside one `NSSplitView`.

## When a window claims

`claimWebView(for:)` runs when:

- the window becomes key (`windowDidBecomeKey`);
- `selectTab(id:)` runs in the key window;
- `selectTab(id:)` runs in a background window **and** no member's container
  is parented anywhere (nobody is hosting it, so there is nothing to
  snapshot and nothing to steal);
- a page action needs the live view: navigate, reload, back, forward and the
  command palette's load all call `ensureOwnsWebView()` first;
- split hosting has to converge (`refreshSplitHostingIfNeeded()`), but only
  in a window that already owns.

In every other case `selectTab` calls `showSnapshot(for:)`.

## How a transfer happens

1. The claimant wakes any member with no web view.
2. If the container is already in this window, it only refreshes the frame
   and returns. No notification, and no show is counted.
3. Otherwise the **claimant** takes a bitmap of what the previous owner is
   displaying — the container, or the whole split view when the pane sits in
   one — with `cacheDisplay`, composed at its frame inside its superview so
   the image maps 1:1 onto a content area.
4. It removes the container from its old superview, wires itself as
   navigation and UI delegate and script message handler
   (`wireOwnedWebView`), and adds the container to its own content area.
5. It posts `webViewOwnershipChanged` with `tabID` (the focused pane),
   `tabIDs` (every member) and the `snapshot`.
6. Every other window whose selected tab's group intersects `tabIDs`, and
   which was showing live content, hides its Peek UI, stores the snapshot as
   `localSnapshot` and shows it.

Both sides then settle the extension side panels: `claimWebView` ends with
`settleSidePanels()`, and so does the window that lost the web view. A tab's
[side panel](../extensions/side-panel.md) follows the live web view to the
claiming window without reloading.

Step 6 matches on **group membership**, not on the focused tab id. Two
windows on the same split can have different panes focused, and claiming
either pane takes the whole hosted view.

By the time the notification arrives the container has already been
reparented, so `ownsWebView` is already false in the losing window. It tells
"I was the owner" by `snapshotImageView == nil`.

## The snapshot view

`showSnapshot(for:)` installs an `NSImageView` at 50% opacity. Its image is
the handed-over `localSnapshot`, or, when there is none, a fresh render of
the tab's live web view wherever it is currently parented
(`liveSnapshot(for:)`). The second case is a background window selecting a
tab that another window hosts. For a sleeping tab there is no image and the
pane is empty.

`selectTab` clears `localSnapshot`, so a snapshot is never reused for a
different tab. It takes no bitmap of the tab it leaves; the per-switch
picture is the Control+Tab preview, which uses `takeSnapshot`.

## What "not owning" disables

- `restoreWebContentFocus()` does nothing unless `webView.window === window`.
- Content blocker rule changes are re-applied only by the owning window.
- The show-budget count on window un-occlusion counts only owned panes.
- The Peek overlay is hidden; it is restored when the window becomes key.
- A tab's extension side panel is not shown. `sidePanelDisplayedTabs` is empty
  in a window that does not own, so the panel shows only beside the live page.
  The window's own (window-scoped) panel is unaffected.

## Hosted nowhere

"The container has a superview" means "some window is hosting this tab".
Two things depend on that reading:

- `TabStore.sleepStaleTabs` never sleeps a tab whose container has a
  superview. Two windows on one space share a single `lastDeselectedAt`; the
  window that deselects stamps it while the other may still be showing the
  tab, and sleeping it would blank that window.
- `removeContentViews()` takes a split view apart before removing it, so the
  pane containers end up with no superview, the same as a single tab's
  container after a handoff.

The one exception is the Picture in Picture hold: a tab that starts PiP on
switch-away stays parented for about half a second (`pipContentView`) so
WebKit can capture the video's on-screen frame, then is removed.

## Sleeping is a separate axis

A sleeping tab has `webView == nil`; ownership is about where a live web
view is parented. Selecting a sleeping tab wakes it first, and the window
that woke it hosts it because nobody else could. See
[BrowserTab](./browser-tab.md) and
[sleeping and archiving](../tabs/sleeping-and-archiving.md).

# Rules of thumb

1. `tab.webView` is nil only when the tab is asleep. In a window that does
   not own the tab it is a live object parented in **another** window. Test
   `webView.window === window` (or `ownsWebView`), not `webView != nil`.
2. Host and move `webViewContainer`, never the bare web view.
3. Before acting on the page from a window, call `ensureOwnsWebView()`.
4. Do not keep a tab's container parented after you stop showing it; other
   code reads a superview as "on screen somewhere".
5. A claim is a hidden-to-visible transition for the page, and each one
   strands a few IOSurfaces in WebKit's GPU process (TASK-104). Do not host a
   hidden tab just to take a picture of it. The Control+Tab switcher uses
   `WKWebView.takeSnapshot` on the pane already on screen for that reason.
6. Delegate callbacks from a web view may belong to a tab this window no
   longer shows. Resolve the tab with `tab(owning:)`.

# Where it lives

| What | Where |
|---|---|
| `ownsWebView`, `claimWebView`, `claimSingleWebView`, `claimSplitWebViews`, `showSnapshot`, `liveSnapshot`, `removeContentViews`, `handleWebViewOwnershipChanged`, `ensureOwnsWebView` | [BrowserWindowController.swift](../../Detour/Browser/Window/BrowserWindowController.swift) |
| `webViewContainer`, `ensureWebViewContainer()`, `WebViewContainerView` | [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift) |
| `Notification.Name.webViewOwnershipChanged` | top of `BrowserWindowController.swift` |

There is no unit test of the cross-window handoff itself; it is view
hierarchy behaviour and is checked at runtime with two windows on one space.
See [runtime verification](../playbooks/runtime-verification.md). One suite
does drive a hand-off between two real, never-shown windows by calling
`windowDidBecomeKey`: `ExtensionSidePanelTests`, to prove a tab's side panel
moves with the web view.

# Related

- [Single web view owner](../decisions/single-webview-owner.md) — why this design.
- [BrowserWindowController](./browser-window-controller.md) — `selectTab` and the claim path in context.
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — the two-pane claim.
- [GPU IOSurface limit](../platform/gpu-iosurface-limit.md) — why shows are counted.
- [AppKit gotchas](../platform/appkit-gotchas.md) — Auto Layout and the docked Web Inspector.
- [Side panel](../extensions/side-panel.md) — a tab's panel shows only in the owning window.
