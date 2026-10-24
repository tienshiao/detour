---
type: Feature
title: Peek
description: The overlay that shows a linked page over the current tab; which links open in one, how it is anchored to its host tab, parked, restored and expanded, and how extensions see it.
tags: [tabs, peek, overlay, navigation, extensions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T17:30:00Z }
sources:
  - id: anchor
    resource: ../../Detour/Browser/Window/PeekAnchor.swift
    title: PeekAnchor.swift
  - id: overlay
    resource: ../../Detour/Browser/Shared/PeekOverlayView.swift
    title: PeekOverlayView.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (Peek Overlay section)
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (peekHostTab, presentPeek)
  - id: uidelegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
    title: BrowserWindowController+WKUIDelegate.swift (createWebViewWith)
  - id: browsertab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (Peek State, parkPeek)
  - id: active-tab
    resource: ../../Detour/Extensions/Runtime/ExtensionActiveTab.swift
    title: ExtensionActiveTab.swift
  - id: anchor-tests
    resource: ../../DetourTests/PeekAnchorTests.swift
    title: PeekAnchorTests.swift
  - id: task-42
    resource: backlog:TASK-42
    title: Cross-host link clicks in a favourite's tab should open a Peek, matching pinned tabs
  - id: task-48
    resource: backlog:TASK-48
    title: A cross-host link clicked in the unfocused pane of a pinned split bypasses the Peek intercept
  - id: task-51
    resource: backlog:TASK-51
    title: Make a presented Peek the extension-visible active tab while it is open
  - id: task-57
    resource: backlog:TASK-57
    title: A parked Peek stays registered as an open extension tab after its host sleeps
  - id: task-85
    resource: backlog:TASK-85
    title: target=_blank links in a pinned tab or favourite should open in a Peek instead of a new tab
  - id: task-185
    resource: backlog:TASK-185
    title: "Peek: add an Open in Split View button; splitting from a favourite or pinned tab opens the split in the normal section"
  - id: harness-185
    resource: ../../docs/harness/task185-harness.patch
    title: TASK-185 runtime harness and its results
---

# What it does

A Peek shows a page in a rounded panel over the current tab, dimming what is
behind it. It is for following a link without leaving, or losing, the page you
were on. Escape, Cmd+W, the close button or a click outside the panel dismiss
it; the expand button turns it into a normal tab, and the split button puts its
page beside the host in a [split](./split-tabs.md).

# When a link opens in a Peek

| Trigger | Where | Opens a Peek when |
|---|---|---|
| Shift+click | any tab on screen | always |
| A plain link click | a live [pinned tab](./pinned-tabs-and-folders.md) or [favourite](./favorites.md) | the target's host differs from the anchor's host |
| A `target="_blank"` link | pinned tab or favourite | the target has a host, **same host included** |
| Script `window.open` | pinned tab or favourite | tab-style (no popup features) and the target has a host |

"Anchored" tabs are the backing tabs of pinned entries and favourites. The
anchor is `PinnedEntry.pinnedURL` or `Favorite.url`, resolved by
`PeekAnchor.anchorURL(forTabID:pinnedEntries:favorites:)`; pinned entries are
checked first. Ordinary tabs and dormant tiles have no anchor.

What does **not** peek:

- Cmd+click (background tab) and Option+click (split) win over Shift and over
  the anchor rule. The order is Cmd, Shift, Option, then the anchor intercept
  ([tab lifecycle](./tab-lifecycle.md)).
- Any navigation that is not a link activation: redirects and script-driven
  location changes navigate an anchored tab in place.
- A popup-style `window.open` (size, position or the `popup` feature, as OAuth
  and payment windows ask for) keeps its own tab, which is a real child of
  the page: it has `window.opener` and can close itself. A window that peeks
  is not — the page's `window.open` returns null. The test is WebKit's
  `_wantsPopup` on `WKWindowFeatures` when available (macOS 14.2+), else
  explicit x/y/width/height.[^task-85]
- Hostless targets (`about:blank`, `blob:`, `window.open("")`).
- Anything while a Peek is already open: links inside a Peek navigate the Peek.
- A link fired by a background tab's web view.

Why `_blank` and `window.open` need two rules: WebKit asks the navigation
delegate about a `_blank` link first, with `navigationType == .linkActivated`
and a nil `targetFrame`, and calls `createWebViewWith` only if that is allowed.
A script `window.open` never reaches the navigation delegate at all.[^task-85]
See [WKWebView delegate order](../platform/wkwebview-delegate-order.md). Same-host
`_blank` links peek because in-place navigation is not what the page asked for,
and a new tab defeats the pinned-app model.

# How it works

## The Peek is a tab that is in no list

A Peek is a `BrowserTab` held in its host's `peekTab`. It is built from the
space's configuration, has no `spaceID`, is not in `space.tabs` and is not
subscribed by `TabStore`. Consequences:

- It records **no history**.
- `selectedTabID` still names the *host*. `displayTab` (`selectedTab?.peekTab
  ?? selectedTab`) is what the address bar and the back/forward/reload buttons
  act on while a Peek is up.
- Cmd+L shows the Peek's URL but opens a new tab rather than navigating in
  place.
- One Peek per host tab.

## Which tab is the host

`peekHostTab(firing:)` resolves the host from the **web view that fired the
link**, not from the selection, and accepts it only when it is the selected tab
or a pane of the selected tab's [split](./split-tabs.md)
(`PeekAnchor.interceptTab`). Resolving from the selection was a bug: in a
pinned split, a link activated in the unfocused pane by a middle click or a
scripted `anchor.click()` reaches the policy decision without AppKit having
moved first responder, and the pinned pane navigated off its home host.[^task-48]

`presentPeek(of:on:firing:)` then focuses that pane, falls back to selecting it
outright if focus did not move the selection, and only then calls
`showPeekOverlay`, which anchors on `selectedTab`. It runs one main-queue turn
later so the policy decision returns before the view hierarchy changes.

## Presenting

`presentPeekWebView` adds a `PeekOverlayView` covering the whole
`contentContainerView` and puts the Peek's web view above it with constraints
(12 pt top and bottom, 64 pt each side, 12 pt corner radius). The overlay is
modal:

- it spans both panes of a split, and pane focus cannot change while it is up;
- clicks outside the panel close it; scroll events on the dimmed area are
  swallowed so the page behind does not scroll;
- the Peek's web view becomes first responder.

**Escape is handled by the window controller, not the overlay.** The Peek's web
view holds first responder and is a *sibling* of the overlay, so the overlay
never sees key events. Keys the page declines bubble up the web view's
responder chain to `BrowserWindowController.keyDown` / `cancelOperation`. A
page that consumes Escape (closing its own modal, leaving fullscreen) still
wins.

## Hidden, parked, restored

The host carries three persisted fields: `peekURL`, `peekInteractionState` and
`peekFaviconURL`.

| State | `host.peekTab` | Peek web view | Host's peek fields |
|---|---|---|---|
| Presented | set | on screen | mirrored each time the Peek's URL changes |
| Hidden (host not selected, or this window lost the web view) | set | alive, off screen | as last mirrored |
| Parked (host asleep) | set, but its web view is gone | none | saved by `parkPeek` |
| Restored session | nil | none | read from the `tab` row |

- `hidePeekUI` takes the overlay off screen without destroying the Peek: tab
  switch, space switch, ownership loss, window close.
- `restorePeekOverlayIfNeeded` runs at the end of `selectTab`, on
  `windowDidBecomeKey`, and when a split pane gains focus. It **reuses a live
  Peek**; recreating from `peekURL` would discard the Peek's own navigation
  history. Otherwise it rebuilds from `peekURL` and `peekInteractionState`.
- `BrowserTab.parkPeek(force:)` runs when the host sleeps or is retargeted. It
  saves the state *before* sleeping the Peek; in the other order a later save
  would restore the Peek to its open-time URL.
- A parked Peek is never woken as the same object. `showPeekOverlay` always
  builds a new `BrowserTab` and tears the old one down. The host keeps the
  parked `peekTab` reference anyway, because the sidebar badge reads it through
  `displayPeekFavicon`.
- `observePeekTab` mirrors the live Peek's URL and favicon onto the host
  (`savePeekStateForPersistence`, `mirrorPeekFavicon`), so a mid-session save
  restores the Peek where the user navigated it, and every window's row or tile
  shows its favicon.

The peek columns are saved for normal tabs, pinned backing tabs and favourite
backing tabs alike.[^task-42]

`BrowserTab.hasPeek` is "selecting this tab brings a Peek back": a live Peek
(`peekTab` with a web view) or a `peekURL` to rebuild one from. It is the
same condition `restorePeekOverlayIfNeeded` acts on. The Control+Tab
switcher uses it to draw the Peek on the host's card
([tab switching](./tab-switching.md)).

## Closing and expanding

- `closePeekOverlay` clears the host's peek state, animates out and calls
  `teardown()` on the Peek (with a 0.3 s safety net in case the animation's
  completion never fires; `teardown` is idempotent).
- `expandPeekToNewTab` hands the **same web view** to a new normal tab
  (`addTab(in:webView:parentID:)`), animates its constraints out to the content
  area, then selects the tab. It closes the old Peek object for the extension
  contexts first: two open tabs sharing one web view would leave WebKit mapping
  the page to the dead one.
- **Open in Split View** (`openPeekInSplitView`, the third button) hands the
  same web view to the right pane of a split, so the Peek's back list and page
  state survive. The hand-off runs in the same order as expanding (close the
  old Peek for the extension contexts, clear the host's peek state, then the
  store mutation places the web view in a tab), glides the web view from the
  panel to the right pane's frame (`splitPaneRects`), and then `selectTab`s
  the pane and makes its web view first responder.[^task-185]
  - An ungrouped normal host becomes the left pane
    (`addTabInSplit(with:webView:in:)`).
  - A favourite or pinned host stays where it is: the split opens in the
    normal section with a copy of the host on the left
    (`addSplitInNormalSection(copying:rightPane:in:)`), see
    [split tabs](./split-tabs.md#opening-a-split-from-a-tab).
  - The button is shown only when `TabStore.splitOpening(from:in:)` answers
    for the host: never on a pane of a normal or pinned split (the overlay
    spans both panes, and a third pane is not a thing). It is decided when the
    overlay is built and asked again on the click, before anything is handed
    over, because the host can join a split from the sidebar while the Peek is
    up; then the button just hides.
  - The Peek is never a member: it hands its page over and is gone.
- Closing or removing the host tears the Peek down with it
  (`BrowserTab.teardown()` cascades).

## Extensions

- A live Peek is listed to extensions right after its host
  (`extensionWindowTabs`); a parked one is not.
- **A presented Peek is the window's extension-visible active tab.**
  `extensionActiveTab(selected:peekPresented:)` returns the Peek while the
  overlay is up and the Peek has a web view, else the selected tab. So
  `tabs.query({active: true})`, a toolbar popup and an `activeTab` grant target
  the page the user is looking at, not the host hidden behind it.[^task-51]
- Activation announcements all go through
  `announceExtensionActiveTabIfChanged()`, deduped by identity. `hidePeekUI`
  announces nothing, because every caller selects, deselects or closes right
  after.
- A parked Peek is **closed** for the contexts. Otherwise extensions would see a
  phantom open tab with no web view from the host's sleep until its next
  presentation. The close is gated on the Peek having really released its web
  view: a non-forced sleep spares an audible Peek, which is still a live page.[^task-57]
- An extension's `tabs.remove` on a Peek closes the overlay if presented, else
  tears it down and clears the parked state.

Details of registration are in
[tab and window bridge](../extensions/tab-and-window-bridge.md).

# Edge cases

- **Moving the host across profiles**: the Peek is parked by force, then its URL
  is retargeted or the Peek is dropped. A Peek the destination cannot show does
  not refuse the move; it is an overlay on the tab, not the tab.
- **Picture-in-picture**: switching away from a host whose Peek is playing
  starts PiP for the Peek and keeps its web view parented for the capture.
  Closing the host does not ([media and PiP](../platform/media-and-pip.md)).
- **Opening a Peek to a different URL than the parked one** clears the parked
  favicon and URL first, so the badge cannot show the previous Peek's icon.
- Reload, back and forward act on the Peek while the host has one.
- Option+click inside a Peek is left alone, so it still downloads there. The
  link menu inside a Peek has no Open Link in Split View either; the panel's
  own button is the way to split from a Peek.

# Tests

`PeekAnchorTests` (23: anchor lookup, host resolution including the unfocused
pane and the "inside a Peek" case, the three peek predicates), `PeekStateTests`
(save, clear, favicon precedence, `hasPeek`), `RecentTabSwitcherPeekTests`
(the switcher's entries and the Peek's picture), `FavoritePeekPersistenceTests` (round trip
through save and restore), `FavoriteTileBadgeTests`,
`ExtensionActiveTabTests` (a real window presenting and closing a Peek),
`ExtensionTabLifecycleTests` (park closes the registration),
`SplitOpeningTests` (the store half of Open in Split View: the web view kept,
the button's rule).

Checked at runtime only ([harness](../../docs/harness/task185-harness.patch)):
the button's visibility on each kind of host, the web view and its back list
surviving the hand-off, the right pane selected and first responder, and a
second window on the same space keeping its snapshot.

Not covered by a test: re-presenting a parked Peek registers the new Peek
exactly once (verified by reading `showPeekOverlay`), and the Google Calendar
`window.open` flow that motivated the scripted-window rule.[^task-57][^task-85]

# Related

- [Pinned tabs and folders](./pinned-tabs-and-folders.md) and [favourites](./favorites.md): the anchored tabs.
- [Tab lifecycle](./tab-lifecycle.md): the policy order the Peek branches sit in.
- [Split tab hosting](./split-tabs-hosting.md): pane focus and why the overlay spans both panes.
- [WKWebView delegate order](../platform/wkwebview-delegate-order.md): `_blank` versus `window.open`.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md): how a Peek is registered and enumerated.
- [Sidebar tab cell](../sidebar/tab-cell.md): the peek favicon badge on rows.

[^task-42]: Cross-host link clicks in a favourite's tab should open a Peek, matching pinned tabs
[^task-48]: A cross-host link clicked in the unfocused pane of a pinned split bypasses the Peek intercept
[^task-51]: Make a presented Peek the extension-visible active tab while it is open
[^task-57]: A parked Peek stays registered as an open extension tab after its host sleeps
[^task-85]: target=_blank links in a pinned tab or favourite should open in a Peek instead of a new tab
[^task-185]: Peek: add an Open in Split View button; splitting from a favourite or pinned tab opens the split in the normal section
