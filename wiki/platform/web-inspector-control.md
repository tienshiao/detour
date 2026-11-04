---
type: Platform Quirk
title: Driving the Web Inspector
description: How Detour opens, switches and closes the docked Web Inspector from the dev toolbar with no public API — the private _WKInspector calls and the frontend's own WI functions that work on macOS 26.7, what was rejected, the guards that hide a button when WebKit drops a call, and the inspector preferences WebKit writes to the app's shared defaults.
tags: [webkit, inspector, dev-mode, private-api]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T21:00:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: control
    resource: ../../Detour/Browser/DevMode/WebInspectorControl.swift
    title: WebInspectorControl.swift (WebInspectorTab, InspectorToggle, WebInspectorControl, WebInspectorToggler)
  - id: group
    resource: ../../Detour/Browser/DevMode/DevToolbarInspectorGroup.swift
    title: DevToolbarInspectorGroup.swift
  - id: tests
    resource: ../../DetourTests/WebInspectorControlTests.swift
    title: WebInspectorControlTests.swift
  - id: harness
    resource: ../../docs/harness/task186-4-harness.patch
    title: TASK-186.4 runtime harness
  - id: wk-inspector-h
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKInspector.h
    title: _WKInspector.h, _WKInspectorIBActions.h, _WKInspectorPrivateForTesting.h
  - id: ui-proxy
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Inspector/WebInspectorUIProxy.cpp
    title: WebInspectorUIProxy.cpp (show, close, showConsole, attach, toggleElementSelection)
  - id: ui-proxy-mac
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Inspector/mac/WebInspectorUIProxyMac.mm
    title: WebInspectorUIProxyMac.mm (platformCanAttach, platformHide)
  - id: main-js
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebInspectorUI/UserInterface/Base/Main.js
    title: WebInspectorUI Main.js (WI.showConsoleTab, WI.showNetworkTab, WI.tabBrowser)
  - id: task-186-4
    resource: backlog:TASK-186.4
    title: "Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network tabs"
---

# Behavior

WebKit has no public API to open the Web Inspector on a given tab, to ask
which tab it shows, or to close it. `WKWebView.isInspectable` only allows
it. Everything Detour does goes through two private layers:

1. **`-[WKWebView _inspector]`**, a `_WKInspector`.[^wk-inspector-h] Its
   calls map one to one onto `WebInspectorUIProxy`.[^ui-proxy]
2. **The frontend itself.** The inspector is a web page (WebInspectorUI) in
   its own `WKWebView` (a `WKInspectorWKWebView`), reachable through
   `-[_WKInspector inspectorWebView]` (declared in
   `_WKInspectorPrivateForTesting.h`, but compiled into the shipped
   framework). Detour evaluates JavaScript there against the frontend's `WI`
   namespace.[^main-js]

## What works (macOS 26.7, WebKit 21624.5.1.11.3)

Every selector below answers `instancesRespond(to:)` on this system and was
exercised at runtime.[^harness]

| Need | Call | Notes |
|---|---|---|
| Is it open? | `isVisible` (BOOL) | False until the frontend has loaded and opened, so right after `show` it still reads false |
| Open | `show` | Opens where WebKit last had it (see dock side below) |
| Open on Console | `showConsole` | `show` plus a backend message that WebKit queues until the frontend loads; no waiting needed |
| Close | `close` | Tears the frontend down (its web process too). `hide` was rejected, below |
| The frontend's web view | `inspectorWebView` | Nil while closed |
| Which tab is selected | JS: `WI.tabBrowser.selectedTabContentView.type` | `"console"`, `"network"`, `"elements"`, `"sources"`… (`WI.ConsoleTabContentView.Type` and friends) |
| Switch to Network | JS: `WI.showNetworkTab()` | Creates the tab if the user had closed it. There is no native call |
| Switch to Console | JS: `WI.showConsoleTab()` (or `showConsole`) | Also hides the split console drawer |
| Element picker | `toggleElementSelection`, `isElementSelectionActive` | On a closed inspector it only *connects* the frontend (hidden); picking an element opens it on Elements; turning the picker off before a pick closes the hidden frontend again |

The frontend is ready for JavaScript when `typeof WI !== 'undefined' &&
WI.tabBrowser` holds. Detour polls for that every 0.1 s (up to 10 s) after
`show`, together with `isVisible` and a non-nil `inspectorWebView`, before
it picks the Network tab; an inspector closed again while it loads ends the
wait.

Checked at runtime with the toolbar's buttons:[^harness] open, close and
switch for both tabs, a tab picked inside the inspector, two presses while
it loads, the saved right-hand side kept, a split pane, and a pane too narrow
to dock. The element picker turned on (on a closed inspector too) and off,
and its state read correctly; **picking an element was not verified**:
`NSApp.postEvent` mouse events, and `mouseMoved`/`mouseDown`/`mouseUp` sent
straight to the `WKWebView` with the app active, neither highlight nor pick.
WebKit's selection overlay appears to need real input.

## Rejected

- **`_WKInspector attach` to force docking.** `WebInspectorUIProxy::attach`
  defaults its side to `Bottom`, so calling it from Objective-C docks at the
  bottom and overwrites the user's saved side. Detour calls `show` and lets
  WebKit open where it last was.[^ui-proxy]
- **`hide` instead of `close`.** Docked, `hide` is `platformDetach`: the
  frontend and its web process stay alive, hidden, for every tab ever
  inspected. `close` frees them; reopening costs one frontend load (about a
  second).[^ui-proxy-mac]
- **`showResources`** opens Sources, not Network; **`showMainResourceForFrame:`**
  opens the main resource in Sources. Neither reaches Network.
- **A pressed state on Console and Network.** The user can switch tabs
  inside the inspector, and nothing tells the app; tracking it would mean a
  poll or a script message handler injected into the frontend. The buttons
  are stateless and always read the tab when pressed. The picker does show
  its state: its own BOOL is cheap to read, so the button polls it every
  0.2 s from a press until it is off again.
- **Finding the frontend as the container's other `WKWebView`.** It works
  only while docked; `inspectorWebView` also finds an undocked one.

## Docking rules that matter

- **The dock side is WebKit's own.** `show` opens attached when
  `inspectorStartsAttached` is set (the default) *and* the page can host it;
  on the side in `inspectorAttachmentSide`. Undocking it once makes WebKit
  remember "starts detached".[^ui-proxy]
- **A page under 500 pt wide (or under ~334 pt tall) cannot dock**
  (`platformCanAttach`: width ≥ 500 and 0.75 × height ≥ 250). In a split
  pane narrower than that, the inspector opens in its own window.[^ui-proxy-mac]

# Why it matters here

The dev toolbar's Console, Network and element picker buttons
(TASK-186.4)[^task-186-4] need open, switch and close on one pane's web
view. All of it is SPI that a macOS update can rename or drop.

# Workaround

`WebInspectorControl` is the only place that touches the inspector for the
toolbar.[^control]

- **Guards.** Every selector is sent only after `responds(to:)`; BOOL
  getters are read through their `IMP` (not `perform`, which returns an
  object). Every script is a `try`-wrapped IIFE that returns a value, and a
  failed evaluation counts as "no answer". `_inspector` is checked before it
  is called: KVC on a missing key would raise an uncatchable
  `NSUndefinedKeyException`.
- **Capabilities hide buttons.** `WebInspectorControl.capabilities` is read
  once from the classes. Console needs `isVisible`, `close`,
  `inspectorWebView` and `showConsole`; Network the same with `show`; the
  picker `toggleElementSelection` and `isElementSelectionActive`; all need
  `_inspector`. A missing one leaves that button out of the group, and no
  capability at all leaves no group (no separator).[^group]
- **A frontend that does not answer** reads as "another tab", so the press
  switches rather than closes: never wrong, at worst one extra press. A
  frontend that never loads gives up after 10 s.
- **A canary test**, `testThisWebKitSupportsEveryButton`, fails when the
  system's WebKit stops answering one of the selectors.[^tests]

## Side effect: shared defaults

WebKit stores the inspector's preferences in the app's **standard user
defaults**, under `__WebInspectorPageGroupLevel1__.WebKit2Inspector…`
(`StartsAttached`, `AttachmentSide`, `AttachedHeight`, `AttachedWidth`…).
`DETOUR_DATA_DIR` does not isolate them: a harness run in an isolated
profile writes to the same `com.detourbrowser.mac` domain as the user's own
Detour. Before a run, record which `__WebInspector` keys exist
(`defaults read com.detourbrowser.mac | grep WebInspector`); afterwards
delete only the new ones and restore any whose value changed.

# Related

- [Dev mode](../features/dev-mode.md) — the toolbar the buttons sit in, and how it stays above a docked inspector.
- [WebKit source lookup](./webkit-source-lookup.md) — how the sources above were read.
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — why containers are frame-based for the docked inspector.

[^control]: WebInspectorControl.swift (WebInspectorTab, InspectorToggle, WebInspectorControl, WebInspectorToggler)
[^group]: DevToolbarInspectorGroup.swift
[^tests]: WebInspectorControlTests.swift
[^harness]: TASK-186.4 runtime harness
[^wk-inspector-h]: _WKInspector.h, _WKInspectorIBActions.h, _WKInspectorPrivateForTesting.h
[^ui-proxy]: WebInspectorUIProxy.cpp (show, close, showConsole, attach, toggleElementSelection)
[^ui-proxy-mac]: WebInspectorUIProxyMac.mm (platformCanAttach, platformHide)
[^main-js]: WebInspectorUI Main.js (WI.showConsoleTab, WI.showNetworkTab, WI.tabBrowser)
[^task-186-4]: Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network tabs
