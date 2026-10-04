---
type: Component
title: Extension popup, menu and options page
description: The browser-side entry points to an extension — the pinned sidebar buttons, the Extensions menu, the action popup popover and the options page — and the rule that nothing but an explicit present may read an action's popupWebView.
tags: [extensions, ui, popup, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: popover
    resource: ../../Detour/Extensions/UI/ExtensionPopoverController.swift
    title: ExtensionPopoverController.swift
  - id: menu-decision
    resource: ../../Detour/Extensions/UI/ExtensionMenuPopupDecision.swift
    title: ExtensionMenuPopupDecision.swift
  - id: options-entry
    resource: ../../Detour/Extensions/UI/ExtensionOptionsPageEntry.swift
    title: ExtensionOptionsPageEntry.swift
  - id: options-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager+OptionsPage.swift
    title: ExtensionManager+OptionsPage.swift
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (Extensions menu)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (presentActionPopup, iconImage, pinned extensions)
  - id: task-55
    resource: backlog:TASK-55
    title: Building the Extensions menu loads every extension's popup page
  - id: task-56
    resource: backlog:TASK-56
    title: Implement menuHasKeyEquivalent so key presses stop rebuilding the menus
  - id: task-77
    resource: backlog:TASK-77
    title: Keys the extension popup page declines still play the unhandled-key beep
  - id: task-103
    resource: backlog:TASK-103
    title: Browser-side entry points to an extension's options page
  - id: task-51
    resource: backlog:TASK-51
    title: Make a presented Peek the extension-visible active tab
  - id: notes-updates
    resource: "Agent session notes, 2026-09-26 (not in the repository)"
    title: Options-page entry points — what the real 1Password manifest declares
  - id: menu-tests
    resource: ../../DetourTests/ExtensionMenuPopupDecisionTests.swift
    title: ExtensionMenuPopupDecisionTests
  - id: options-tests
    resource: ../../DetourTests/ExtensionOptionsPageEntryTests.swift
    title: ExtensionOptionsPageEntryTests
---

Detour has no toolbar. An extension's action is reached from a pinned button in
the sidebar's faux address bar, from the site-settings popover, or from the
Extensions menu; its popup is shown in an `NSPopover`; its options page opens
in a tab. The one rule that cost real trouble: **reading
`WKWebExtension.Action.popupWebView` loads the popup page.**

# How it works

## Entry points

| Entry | Code | Opens |
|---|---|---|
| Pinned extension button (faux address bar) | `FauxAddressBar.pinnedExtensionStack` → `tabSidebarDidRequestShowExtensionPopup` | The popup |
| Extension list in the site-settings popover | `SettingsPopoverViewController.onExtensionClick` / `onPinToggle` | The popup; pin or unpin |
| Extensions menu → *extension* → Show Popup | `AppDelegate.extensionMenuClicked` | The popup |
| Extensions menu → *extension* → Options… | `AppDelegate.extensionOptionsMenuClicked` | The options page |
| Settings → Extensions → Settings… | `ExtensionsSettingsViewController` | The options page |
| `browser.action.openPopup()` | `ExtensionManager.webExtensionController(_:presentActionPopup:…)` | The popup |
| `runtime.openOptionsPage()` | `…openOptionsPageFor…` | The options page |

Pinning is per [profile](../architecture/profiles-and-spaces.md)
(`profileExtension.isPinned`); `pinnedExtensions(for:)` is pinned ∩ enabled.
`ExtensionManager.iconImage` draws the action's icon and composites its badge
text. `extensionActionDidChangeNotification` and
`extensionPinStateDidChangeNotification` refresh the buttons.

## Showing a popup (`ExtensionPopoverController.show`)

1. Take the context from `ExtensionManager.context(for:)` and the tab from the
   key window's `extensionActiveTab` — the presented [Peek](../tabs/peek.md)
   when one is up, so the popup and any `activeTab` grant name the page the
   user is looking at.[^task-51]
2. `context.userGesturePerformed(in: tab)`. Without it `activeTab` grants
   nothing.
3. If the action `presentsPopup`, read `popupWebView`, **reload it** (Chrome
   recreates a popup on every open) and present it. Otherwise
   `context.performAction(for:)`, which fires `action.onClicked`.

Presenting (`presentPopupWebView`): the web view is registered in
`ExtensionPageHostRegistry`, the controller becomes its UI delegate (so
`window.close()` closes the popover), and after 50 ms the content is measured
with an injected `__detourMeasureBody`. The popover is sized to the content,
clamped to 100–800 wide and 100–600 tall (360 × 480 if measuring fails), and a
`ResizeObserver` posts later size changes to an `extensionPopupResize` message
handler.

The delegate path is only for extension-initiated opens. It anchors to the
pinned button if there is one, keeps the controller in
`ExtensionManager.activePopovers`, and calls WebKit's completion handler when
the popover closes. A user-opened popover is retained by an associated object
on the window controller instead.

## The Extensions menu must not load popups

`popupWebView` is created lazily: the read instantiates the web view and loads
the popup page. The menu once decided "is this item clickable?" by testing
that property for nil, so building the menu loaded every enabled extension's
popup. 1Password answers its popup loading against a locked vault by asking
the desktop app to unlock, so the user got an Apple Watch unlock prompt at
launch with no popup on screen. At the time `menuNeedsUpdate` also ran on
every key-equivalent dispatch, that is, on every Cmd+key press.[^task-55]

Two guards:

- `ExtensionMenuPopupDecision.hasPopup` takes the action through a protocol,
  `ExtensionActionPopupDeclaring`, that has only `presentsPopup`. Code that
  decides through it cannot reach the web view; the type is the guard. The
  manifest's `default_popup` is the fallback when no context is loaded.
- `AppDelegate.menuHasKeyEquivalent` answers key-equivalent queries for the
  Spaces and Extensions menus without a rebuild
  ([app shell](../architecture/app-shell.md)).[^task-56]

`popupWebView` is read in exactly two places: `show` (a user click) and
`presentActionPopup` (`action.openPopup()`).

## Options page

`ExtensionOptionsPageEntry.hasOptionsPage` is true for a non-empty
`options_page` or `options_ui.page`. Without one the Settings… button is
hidden and the menu item disabled.

Options and extension storage are per profile, so every entry point names the
profile whose context serves the page:

| Entry | Profile |
|---|---|
| `runtime.openOptionsPage()` | The calling controller's |
| Extensions menu | The key window's active space's; enabled only when that profile has the extension loaded |
| Settings → Extensions | `ExtensionOptionsPageEntry.resolveProfile`: the browser window right behind Settings, then the last-active space's profile, then any profile with an open space — the first in which the extension is loaded |

The Private profile qualifies only as the *first* candidate. Otherwise a
Private window left open in the background would capture a click made from a
normal window, and whatever the user changed would land in the in-memory
store.

`optionsPageTab(for:in:preferring:)` reuses a tab already showing the page —
same origin as the context's base URL and same path; query and fragment are
ignored — else calls `TabStore.addExtensionTab` with the context's
configuration. `openOptionsPage(for:in:)` then shows it in a window already on
that space, else switches a normal window to the space, else opens a new
window. For a Private profile it only ever uses its own window.

# Gotchas

- 1Password 8.12.37.1 declares neither `options_page` nor `options_ui`. Its
  Settings… button is hidden by design; its settings live in its own app
  page.[^notes-updates]
- `ExtensionManager.context(for:)` answers for the last-active space's
  profile. The popup path relies on that matching the window the user clicked
  in.
- A key the popup page declines falls off the end of the popover's responder
  chain and beeps. The popover window has no window controller, so the fix
  used for browser windows does not apply ([AppKit gotchas](../platform/appkit-gotchas.md)).[^task-77]
- An MV3 extension page's CSP blocks inline `fetch`; the test that proves the
  menu loads no popup uses an `<img>` beacon to a loopback server instead.[^task-55]
- In tests, releasing a profile whose extension configuration hosted a popup
  web view freed its process pool inside an IPC dispatch, and WebKit trapped.
  The symptom was `TEST FAILED` with zero failures in the *next* suite. The
  test closes the popup (`action.closePopup()`) and keeps torn-down profiles
  alive ([WebKit test host traps](../platform/webkit-test-host-traps.md)).[^task-55]
- Enablement of the menu's Options… item depends on the key window, so it
  cannot be driven in a process launched from a shell, which never becomes the
  key app ([in-process UI automation](../playbooks/in-process-ui-automation.md)).[^task-103]

# Tests

- [ExtensionMenuPopupDecisionTests](../../DetourTests/ExtensionMenuPopupDecisionTests.swift) — the decision with a spy action, and an integration test with a popup that beacons on load: the decision triggers no load, an explicit `popupWebView` read does.
- [ExtensionOptionsPageEntryTests](../../DetourTests/ExtensionOptionsPageEntryTests.swift) — `hasOptionsPage`, `resolveProfile`, tab reuse.
- `MenuKeyEquivalentMatcherTests` — the key-equivalent fast path against the real main menu.

# Related

- [ExtensionManager](./extension-manager.md) — the delegate methods behind `openPopup` and `openOptionsPage`.
- [Extension pages](./extension-pages.md) — an options tab is an extension page tab.
- [Settings](../features/settings.md) — the Extensions pane.
- [Updates](./updates.md) — which popups count as "open" for update deferral.

[^task-51]: Make a presented Peek the extension-visible active tab
[^task-55]: Building the Extensions menu loads every extension's popup page
[^task-56]: Implement menuHasKeyEquivalent so key presses stop rebuilding the menus
[^task-77]: Keys the extension popup page declines still play the unhandled-key beep
[^task-103]: Browser-side entry points to an extension's options page
[^notes-updates]: Options-page entry points — what the real 1Password manifest declares
