---
type: Feature
title: Extension side panel
description: Detour's chrome.sidePanel — a polyfilled API whose state is kept natively per profile and extension, and a panel web view hosted beside the tab's content; tab panels and window panels, which window shows which panel, how a panel closes, and the keyboard focus rule.
tags: [extensions, side-panel, polyfill, window, hosting, focus]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T19:22:07Z }
sources:
  - id: state
    resource: ../../Detour/Extensions/Runtime/ExtensionSidePanelState.swift
    title: ExtensionSidePanelState.swift (the rules, sidePanelToDisplay, SidePanelLayout)
  - id: panel
    resource: ../../Detour/Extensions/Runtime/ExtensionSidePanel.swift
    title: ExtensionSidePanel.swift (panel, panel view, per-profile controller, reconcile)
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler+SidePanel.swift
    title: ExtensionPolyfillHandler+SidePanel.swift (sidePanel.* bridge messages)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (sidePanelJS)
  - id: layout-view
    resource: ../../Detour/Browser/Window/SidePanelLayoutView.swift
    title: SidePanelLayoutView.swift (layout view, divider, SidePanelWidthStore)
  - id: window-side
    resource: ../../Detour/Browser/Window/BrowserWindowController+SidePanel.swift
    title: BrowserWindowController+SidePanel.swift
  - id: popover
    resource: ../../Detour/Extensions/UI/ExtensionPopoverController.swift
    title: ExtensionPopoverController.swift (the toolbar action click)
  - id: docs-extensions
    resource: ../../docs/extensions.md
    title: docs/extensions.md, "Side panel"
  - id: task-132-8
    resource: backlog:TASK-132.8
    title: Host an extension's per-tab side panel beside the tab's content
  - id: task-132-1
    resource: backlog:TASK-132.1
    title: "Spike: can WebKit's native sidePanel be used"
  - id: state-tests
    resource: ../../DetourTests/ExtensionSidePanelStateTests.swift
    title: ExtensionSidePanelStateTests
  - id: polyfill-tests
    resource: ../../DetourTests/ExtensionSidePanelPolyfillTests.swift
    title: ExtensionSidePanelPolyfillTests
  - id: integration-tests
    resource: ../../DetourTests/ExtensionSidePanelTests.swift
    title: ExtensionSidePanelTests
  - id: runtime-check
    resource: "Runtime check, 2026-10-04 (isolated profile, harness in docs/harness/task132.8-harness.patch)"
    title: Runtime check of the side panel with API Explorer and the real Claude extension, signed out
---

`chrome.sidePanel` in Detour is entirely Detour's: released WebKit has no
side panel ([the decision](../decisions/polyfilled-side-panel.md)). The API is
a [polyfill](./polyfill-layer.md) module, its state lives natively, and the
panel is a web view Detour builds and puts at the trailing edge of the window's
content area. The long-form text is the "Side panel" section of
[docs/extensions.md](../../docs/extensions.md); this page is the map and the
rules.

# What it does

- An extension that declares the `sidePanel` permission gets `setOptions`,
  `getOptions`, `open`, `close`, `setPanelBehavior` and `getPanelBehavior`, in
  promise and callback form.
- An open panel shows beside the tab's content with a header (the extension's
  icon and name, a close button) and a divider the user can drag. The page
  area gets narrower; nothing else in it changes.
- A panel set for one tab shows only with that tab. The extension's default
  panel, opened for a window, shows beside every tab of that window that has
  no open panel of its own, except a tab the extension disabled the panel for
  (`setOptions({tabId, enabled: false})`): there it is hidden, not closed, as
  in Chrome.
- With `openPanelOnActionClick`, clicking the extension's toolbar action
  toggles the panel instead of firing `action.onClicked`.

# How it works

## The API and its gate

`sidePanelJS` defines `chrome.sidePanel` as an own property of `chrome` (and
of a distinct `browser`), which is read normally because WebKit vends nothing
under that name ([chrome runtime patching](./chrome-runtime-patching.md)).

**WebKit does not know the `sidePanel` permission**: it is absent from
`WKWebExtension.requestedPermissions`.[^task-132-1] So the manifest is the
gate, twice: the module defines nothing unless the manifest's `permissions`
list has `sidePanel`, and `handleSidePanelRequest` refuses every `sidePanel.*`
bridge message from an extension without it (`hasPermission`, which reads the
required `permissions` only, not `optional_permissions`). A namespace that is
already there is left alone and reported as `native`. The state is in
`__detourPolyfillDiag.apis.sidePanel`: `absent`, `polyfill`, `native`,
`define-failed`.

Two things the module does that are easy to miss:

- **Calls are serialised.** Each call first resolves its tab id, which is
  asynchronous, so the calls of one JavaScript context are chained and reach
  Detour one at a time in call order. The Claude extension calls
  `setOptions(…)` and `open(…)` back to back with neither awaited; without the
  chain `open` could arrive first. A failed call does not stop the ones behind
  it.
- **A bad argument rejects** (or sets `runtime.lastError`) where Chrome throws.

It also wraps two functions in every top-level extension page of an extension
with the permission: `window.close` (see "Closing" below) and
`tabs.getCurrent`, where WebKit answers `null` in a page that is not a tab and
Chrome answers `undefined`. The wrapper turns that `null` into `undefined`,
keeps WebKit's function on `_detourNative`, and roots the `tabs` wrapper.

## State

`ExtensionSidePanelState` is a pure value type holding, for one extension in
one profile: the default options, each tab's own options,
`openPanelOnActionClick`, and the open panels oldest first. It has no web
views and no windows, so every rule in it is unit-tested.
`ExtensionSidePanelController` owns one state per extension and the panel
objects behind it. There is one controller per profile, `Profile.sidePanels`,
so nothing in it can reach another profile's tabs or panels.

- The default panel's path is the manifest's `side_panel.default_path` until
  `setOptions` without a `tabId` names another.
- `setOptions` changes only the fields given. A field a tab did not set comes
  from the default; `enabled` defaults to true.
- A path must resolve to a page in the extension's own package
  (`panelURL`).
- All of it is in memory. `Profile.unloadExtension` calls
  `extensionDidUnload`, which closes the extension's panels and forgets its
  options and behaviour.

## Two kinds of panel

| | Tab panel | Window panel |
|---|---|---|
| Scope | `.tab(tab id)` | `.window(window)` |
| Opened by | `open({tabId})` for a tab that has options of its own (`setOptions` with a `tabId`) | `open({windowId})`, or `open({tabId})` for a tab without options of its own |
| Page | The tab's options, falling back to the default | The default options |
| Shows | Only with its tab | Beside every tab of its window that has no open tab panel and that the panel is not disabled for (`sidePanelToDisplay`'s `isDisabledForTab`; only the focused pane's options count) |
| Goes away with | Its tab | Its window |

Having options of its own is what makes a tab's panel a tab panel; the
decision is `ExtensionSidePanelState.open`. Opening an open panel creates
nothing and reloads nothing; it only makes that panel the most recent one, and
loads another page if the options now name one.

One panel per place: when an extension opens a panel in a scope where another
extension of the same profile has one, the older panel is closed
(`ExtensionSidePanelCloseReason.replaced`).

## Naming tabs and windows

A `tabId` goes through the tab id bridge: the polyfill resolves it with
`__detourResolveTab` and sends Detour the tab's handle, which is refused
unless this profile lists the tab (the bridge is described on the
[Claude extension epic](./claude-extension-epic.md) page).

A `windowId` cannot be bridged. WebKit mints window ids and offers no lookup,
and Detour has no window bridge. **A window is therefore named by its active
tab**:

1. The polyfill calls WebKit's own `windows.get(windowId, {populate: true})`,
   which validates the id and resolves `WINDOW_ID_CURRENT`, and refuses
   `open({tabId, windowId})` when that window does not list the tab.
2. It sends the handle of the window's active tab (else its first tab) as
   `windowTabHandle`.
3. Natively the window is the one showing that tab's live web view, else the
   one WebKit is told the tab is in
   (`ExtensionSidePanelController.window(showing:)`).

A window WebKit lists no tabs for sends only `hasWindow`. That is not a
corner case: a window with nothing selected reports no tabs
([tab and window bridge](./tab-and-window-bridge.md)). The call then means the
window the calling page is in (a tab's, a popup's, a panel's) when it shows
this profile, else the key window when it shows this profile, else the first
window that does.

## The panel's web view

`ExtensionSidePanel` builds a plain `WKWebView` from
`context.webViewConfiguration`, the way an
[offscreen document](./offscreen-documents.md) is built, so the page gets the
extension's `chrome.*`, the polyfill and the profile's data store. It is
registered with `ExtensionPageHostRegistry`, so it is never taken for the
extension's background page, and it is inspectable.

The web view lives from `open` to `close`, on screen or not. A panel hidden
with its tab is only taken out of the window. A runtime check set a JavaScript
marker in the Claude panel's page, switched to another tab and back, and found
the same web view and the marker intact.[^runtime-check]

Other behaviour of the panel object:

- A load failure before the requested page has committed closes the panel;
  after that it is the page's own navigation and is ignored.
- A lost web content process reloads the requested page.
- A link or `window.open` from the panel opens a new tab in the window showing
  the panel and selects it; a panel has no windows of its own.

## Hosting in the window

The content split item's view is a `SidePanelLayoutView`
(`BrowserWindowController.contentAreaView`). It holds `contentContainerView`
and, while a panel shows, the panel's `ExtensionSidePanelView` at the trailing
edge with a `SidePanelDividerView` over the boundary.

- **Frames only**, for the reason [split tabs](../tabs/split-tabs-hosting.md)
  are frame-based: Auto Layout around a web view breaks the docked Web
  Inspector. The layout view overrides `resizeSubviews` and frames its
  children from `SidePanelLayout.frames`, a pure function.
- It reuses the split's approach and none of its model. The tab content area
  is simply narrower, so everything that lives in it (the page or the two
  split panes, Peek, the find bar, the link status bar, the empty state)
  lays out against its bounds as before.
- The panel is at least 280 pt wide and leaves the page 240 pt while it can;
  in an area too narrow for both, the panel keeps its minimum first. The
  default width is 380 pt.
- The divider is a hairline with a 7 pt strip to grab, lying over the panel's
  leading edge. The width is saved when a drag ends, not during it.
- `SidePanelWidthStore` keeps one width for every panel and window, under a
  defaults key scoped to the data directory. The wanted width survives a
  window too narrow for it and comes back when the window grows.

## Which panel a window shows

One function decides for every window at once:
`ExtensionSidePanelController.reconcile()`. For each window it asks the pure
`sidePanelToDisplay`:

1. the open tab panel of a tab whose **live web view** the window shows, in
   the order of `sidePanelDisplayedTabs`: the presented Peek, the selected tab
   (the focused pane of a split), then the other pane;
2. otherwise the window's own panel;
3. between two candidates in the same place, the most recently opened.

`sidePanelDisplayedTabs` is empty unless the window owns the selected tab's
web view. So a window drawing a snapshot shows no tab panel, and when
[ownership](../architecture/webview-ownership.md) moves to another window the
panel moves with the web view, without reloading. Only panels of the profile
of the window's active space are candidates.

`reconcile` runs after anything that can change the answer: a panel opening
or closing, `setOptions`, `announceExtensionActiveTabIfChanged` (selection, a
Peek going up or down, a split pane taking focus), the end of `claimWebView`,
a window losing ownership, `deselectAllTabs`, a tab's teardown, a window
closing, an extension unloading. It is idempotent and cheap with nothing open.
It detaches before it attaches, so a panel moving between windows is not taken
back out by the window it left, and a re-entrant call is folded into another
pass (four at most).

## Closing

| Path | Trigger |
|---|---|
| `sidePanel.close` | The tab's own panel when open, else the window panel of the tab's window. Closing a closed panel is not an error |
| The header's close button | `closeFromUserInterface` |
| `window.close()` in the panel's page | `webViewDidClose`, and `sidePanel.closeSelf` |
| Options | `setOptions` that disables the panel or leaves it no path |
| Its tab closes | `BrowserTab.teardown` → `tabDidClose`. `closeOrphans` also closes the panel of a tab that is now placed in another profile, or that is in no list at all (a Peek parked with its sleeping host) |
| Its window closes | Window panels only; a tab panel the window was showing just leaves it |
| The extension unloads | Disable, uninstall, update, reload through `Profile.unloadExtension` |
| The first load fails | `loadFailed` |
| Replaced | Another extension opened a panel in the same scope |

An unlisted tab is given a second look before its panel closes. `TabStore`
moves a tab between lists by taking it out, notifying, and only then putting
it in, and a window answering that notification reconciles in between. So
`closeOrphans` defers the decision one turn of the main queue
(`closeIfStillUnlisted`) and closes the panel only if the tab is still in no
list. A tab moved to another space of the same profile keeps its panel
(tested); the code comment names making a tab a favourite as the same case.

`window.close()` needs two routes. WebKit passes `close()` on to the host only
for a window with a single history entry, so the polyfill's wrapper also sends
`sidePanel.closeSelf` before calling WebKit's function. The handler honours
that message only from the main frame of a web view that is a panel; from any
other page it answers `false` and does nothing.

Closing releases the web view. What the extension sees is the page going away:
its ports disconnect and
[`runtime.getContexts`](./runtime-get-contexts.md) no longer lists it. The
reason is logged in the `ext-sidepanel` category.

## Keyboard focus

- A panel Detour opens on a click (`openPanelOnActionClick`) takes the keys.
- A panel the extension opens takes them only if the user clicked that
  extension's toolbar action or pressed one of its
  [command shortcuts](./command-shortcuts.md) in the last 5 seconds
  (`noteUserGesture`, `userGestureLifetime`). One gesture lets one `open` take
  focus. Any other `open` leaves focus where it was.
- A panel that comes back with its tab never takes focus.
- **The panel's page cannot take the keys by itself.** When a page focuses an
  element (an `autofocus` field, a `focus()` call), WebKit's web process asks
  the web view to make itself first responder, so any `open` would steal the
  keys from the tab as soon as the panel page loaded. The panel web view is
  therefore created with `_setShouldSuppressFirstResponderChanges:` (WebKit
  SPI, guarded with `responds(to:)` and logged once if missing). That also
  suppresses the request a mouse press makes, so `ExtensionSidePanelWebView`
  takes first responder itself on mouse down. At runtime: a click in the
  panel's field made the panel first responder and typed keys landed in the
  field; a `focus()` call from the panel page while the tab had the keys left
  them with the tab.[^runtime-check]
- A panel that leaves the window, or closes, while it holds the keys hands
  them to the page (`restoreWebContentFocus`).

`open()` itself needs no user gesture, unlike Chrome: Detour cannot see one
from a worker. The gesture only decides focus.

## The toolbar action

`ExtensionPopoverController.show` is the user's click, in the window it is
handed. It notes the gesture, and then:

- with `openPanelOnActionClick`, calls `handleActionClick`: if the window is
  showing a panel of this extension it is closed, otherwise the panel for the
  active tab is opened with focus. `action.onClicked` does not fire and no
  popup is shown, as in Chrome;
- without it, the click goes the usual way (popup, or `action.onClicked`), and
  an extension that opens its panel from the listener gets focus through the
  gesture.

# Invariants

- **A panel is not a `BrowserTab`.** It has no sidebar row, is never
  `selectedTabID`, and WebKit is told nothing about it. It therefore cannot
  appear in `tabs.query`, the Control+Tab switcher or the closed-tab records;
  `tabs.getCurrent()` in its page is `undefined`; Cmd+W closes the tab.
- The API exists, and the bridge answers, only with the manifest's `sidePanel`
  permission.
- A tab panel shows only in the window that owns its tab's live web view.
- A panel's web view is created by `open` and released by a close path, never
  by being hidden.
- The layout view and the panel view are frame-based.
- A panel belongs to one profile's controller and is shown only by a window
  whose active space is on that profile.

# Edge cases

- No `sidePanel.onOpened` / `onClosed`, no `getLayout` / `Side`.
- `getOptions` answers the options in force (the tab's own fields over the
  default's) and includes `tabId` only for a tab with options of its own.
  Chrome answers the stored entry.
- A window panel is keyed by the window, not the space. From the code: it
  stays beside the tabs of another space of the same profile, and is hidden,
  not closed, while the window shows a space of another profile. No test
  covers this.
- `chrome.runtime.reload()` does not pass through `Profile.unloadExtension`
  ([updates](./updates.md)), so the panels and options of an extension that
  reloads itself are not reset by the unload path. What happens to an open
  panel then has not been checked.
- Private windows need nothing special: a panel can only be opened for a
  context loaded in that profile
  ([Private profile extensions](./private-profile-extensions.md)).
- An open panel, on screen or hidden, counts as activity that defers an
  [update](./updates.md).
- **The Claude extension's Cmd+E does not close its panel while signed out.**
  That is the extension, not Detour. Its worker's shortcut handler found the
  panel through `runtime.getContexts` and sent
  `{type: "close_side_panel", tabId}`, and the panel page received the
  message; but the listener that calls `window.close()` belongs to the
  extension's signed-in components, which the "Log in" screen does not mount.
  With a listener of the same body injected into the panel page, Cmd+E closed
  the panel (logged as "its page called window.close()") and the next Cmd+E
  opened a fresh page.[^runtime-check] The toggle cannot be checked end to end
  without signing in; the stand-in is in the
  [side panel runtime check](../playbooks/side-panel-runtime-check.md).
- The docked Web Inspector with a panel open is covered on
  [split tabs hosting](../tabs/split-tabs-hosting.md): it docked in a page 500
  pt wide or more and not in the panel's own page.

# Tests

| Suite | Proves |
|---|---|
| [ExtensionSidePanelStateTests](../../DetourTests/ExtensionSidePanelStateTests.swift) | The pure rules: option fallback, which scope `open` picks, the close rules, `sidePanelToDisplay`, `SidePanelLayout` |
| [ExtensionSidePanelPolyfillTests](../../DetourTests/ExtensionSidePanelPolyfillTests.swift) | The JavaScript against a recording bridge: the permission gate, what each call sends, window naming, call order, callback form, the `getCurrent` and `window.close` wrappers |
| [ExtensionSidePanelTests](../../DetourTests/ExtensionSidePanelTests.swift) | A real extension in production profiles and real, never-shown windows, from the worker and from a page: hosting, "not a tab", tab switching, split, divider, two windows, every closing path, a tab moved to another space keeping its panel, isolation by extension and by profile, Private, focus, the toolbar action |

`ExtensionSidePanelTestSupport.swift` holds the shared world
([testing extensions](./testing-extensions.md)). Not covered by a unit test,
and checked in the running app instead: the docked Web Inspector, the real
click and key paths, and the appearance.

# Related

- [chrome.sidePanel is polyfilled](../decisions/polyfilled-side-panel.md) — why not WebKit's sidebar.
- [runtime.getContexts](./runtime-get-contexts.md) — how an extension finds its open panel.
- [Command shortcuts](./command-shortcuts.md) — the other gesture that lets a panel take focus.
- [Offscreen documents](./offscreen-documents.md) — the other web view built from the context's configuration.
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — the frame-based hosting this sits beside.
- [Web view ownership](../architecture/webview-ownership.md) — why a tab panel follows the live web view.
- [Claude extension epic](./claude-extension-epic.md) — the extension this was built for.

[^task-132-1]: Spike: can WebKit's native sidePanel be used
[^runtime-check]: Runtime check of the side panel with API Explorer and the real Claude extension, signed out
