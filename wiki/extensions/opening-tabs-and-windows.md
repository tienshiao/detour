---
type: Concept
title: Opening tabs and windows
description: Where a tab or window an extension opens with tabs.create or windows.create lands — the Private-or-normal rule for windows.create, the caller's profile's most recently used space, and the calls refused before anything opens.
tags: [extensions, tabs, windows, private, profiles]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:06:25Z }
sources:
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (openNewWindowUsing, openNewTabUsing, opensPrivateWindow, refusesPrivateWindow, newTabSpace)
  - id: tabstore-quick-detour
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift (mostRecentlyUsedSpace(ofProfile:))
  - id: polyfill-handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (targetSpace)
  - id: task-214
    resource: backlog:TASK-214
    title: An extension allowed in Private can open a normal-profile window with windows.create
  - id: task-223
    resource: backlog:TASK-223
    title: windows.create from a normal profile can open its window on another profile's space
  - id: task-224
    resource: backlog:TASK-224
    title: A normal-profile extension not allowed in Private can still open a Private window with windows.create({incognito true})
  - id: task-226
    resource: backlog:TASK-226
    title: tabs.create adds its tab to the profile's first space, not the one in use
  - id: windows-create-tests
    resource: ../../DetourTests/ExtensionWindowsCreatePrivateTests.swift
    title: ExtensionWindowsCreatePrivateTests
  - id: webkit-windows-api
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIWindowsCocoa.mm
    title: WebKit WebExtensionContextAPIWindowsCocoa.mm (windowsCreate, read 2026-10-27)
---
An extension opens a window with `windows.create` and a tab with
`tabs.create`; WebKit hands both to the controller delegate
(`ExtensionManager.openNewWindowUsing`, `openNewTabUsing`), and Detour decides
where they land. The rules keep a caller inside its own profile: a window or
tab on another profile's space would load with that profile's cookies and
history, and a normal window opened from a Private context would carry a
Private page's address out of it. How the new tab is then reported to
WebKit is the [tab and window bridge](./tab-and-window-bridge.md).

# Opening a window

`windows.create` reaches `openNewWindowUsing`, which opens a
`BrowserWindowController`. Whether it is Private is
`ExtensionManager.opensPrivateWindow(requested:callerIsIncognito:)`:

| Caller's profile | `incognito` | Window |
|---|---|---|
| Incognito (Private windows and quarantines share it) | anything, or left out | Private |
| Normal | `true` | Private if the extension is allowed in Private; otherwise refused |
| Normal | `false` or left out | normal, on the caller's profile's most recently used space; refused when the profile has no space |

The incognito row is the user's decision of 2026-10-27 (TASK-214). Before it,
an extension allowed in Private could open a normal window on a normal
profile's space, with its cookies and history, at any address, including the Private
or quarantined page it was running in. WebKit sets
`shouldBePrivate = incognito ?? false` before it calls the delegate, so an
explicit `incognito: false` cannot be told from a call that leaves the key
out.[^webkit-windows-api] Chrome's split-mode rule (follow the caller unless
it says `false`) cannot be built on that, and an exception for extensions also
enabled in a normal profile would have kept the leak for every plain
`windows.create({url})`. **Rejected**: wrapping `chrome.windows.create` in the
polyfill to pass an explicit `false` through (more code for a rare call; the
extension's normal-profile context can open normal windows itself) and
refusing the call (most calls would fail).[^task-214]

A Private window opened this way is a Private browser window on the shared
Private store, not a quarantine's own store. A normal context that asks for
`incognito: true` gets the window only if the user allowed the extension in
Private (`ExtensionManager.refusesPrivateWindow`, over
`isEnabled(extensionID:inProfile: TabStore.incognitoProfileID)`, so a missing
row refuses, as it keeps the extension out of Private); otherwise the call is
refused ("the extension is not allowed in Private") before any window opens,
which is Chrome's rule for an extension without incognito access. Before
TASK-224 an extension kept out of Private could still put a page of its
choosing in front of the user there.[^task-224] An allowed caller gets the
window but no window object back: WebKit reports a Private window only to a
context with access to Private data, so the promise resolves with
`undefined`.[^windows-create-tests] A caller whose profile
cannot be resolved is refused, and so is a `detour://` URL, before any window
opens (it used to be dropped, leaving an empty window reported as a success).

A normal window opens on one of the caller's own profile's spaces:
`TabStore.mostRecentlyUsedSpace(ofProfile:)`, the first of `spaceUseOrder`
on that profile, else its first space in sidebar order (the same rule as
Quick Detour's Open in default, `QuickDetour.mostRecentlyUsedSpace`). The key
window's space heads the use order, so a caller whose profile is in front gets
that space as before. When another profile is in front, the caller's most
recently used space is taken whether or not a window shows it: the user's
decision of 2026-10-28 for a profile with no open space was its last active
one, and no separate "a space some window shows" step was needed on top. A
profile with no space at all is refused ("the profile has no space") before a
window opens. Before this, the window took `AppDelegate.assignDefaultSpace`'s
space (the key normal window's, else the global last active, else the first),
so an extension of profile A could open a window, with its URL, on profile
B's space, with B's cookies and history and in B's extension
contexts.[^task-223]

# Opening a tab

`tabs.create` without a `windowId` (`openNewTabUsing`), and the polyfill's
`search.query` and `sessions.restore` (`ExtensionPolyfillHandler.targetSpace`),
add their tab to `ExtensionManager.newTabSpace(for:)`: for a normal profile,
the same `TabStore.mostRecentlyUsedSpace(ofProfile:)` as a normal window from
`windows.create`. An incognito profile's spaces are never in `spaceUseOrder`,
so there it is the global last active space
(`ExtensionManager.lastActiveSpaceID`, the space the last window to become key
showed then) when it is that profile's, else its first space; there is no test
of two Private windows. A profile with no space gets no tab anywhere:
`tabs.create` rejects ("the profile has no space"; it used to resolve with
nothing) and the polyfill calls answer "No space in this profile". Before
TASK-226, `tabs.create` took the profile's first space in sidebar order, which
no window may show, so the user never saw the tab, and the polyfill calls a
third rule (the global last active space if it was this profile's, else the
first).[^task-226] WebKit hands the delegate the window a `windowId` names
(`configuration.window`), which Detour does not read yet: the tab goes to the
same space either way. Like `windows.create`, `tabs.create` refuses a
`detour://` URL and a caller whose profile cannot be resolved before any tab
exists. In a window or a tab, an extension's own `webkit-extension:` URL
opens with the context's web view configuration (`TabStore.addExtensionTab`).

`windows.create`, `tabs.create` and `tabs.update` also refuse a `javascript:`
URL before anything opens or loads: [javascript: URLs](./javascript-urls.md).

# Gotchas

- `openNewWindowUsing` ignores `configuration.tabs` (moving existing tabs into
  the new window is a TODO in the code).

# Tests

- `ExtensionWindowsCreatePrivateTests` — `windows.create` from an incognito
  context (`incognito` left out, `false`, `true`; with a quarantine in
  front) and from a normal one, from the worker and an extension page, in the
  promise and callback forms; a `detour://` URL fails in every
  form and opens no window. A normal caller's `incognito: true` opens a
  Private window when the extension is allowed in Private and is refused
  (no row, or a row saying off) when it is not. A normal caller with another profile's window in
  front, with no window on its profile (its last active space, not its first),
  and with no space (refused, no window).
  `tabs.create` without a `windowId` lands in the caller's most recently used
  space (two spaces, the second used last, another profile in front), and is
  refused once the profile has no space, from both transports and forms.
- `ExtensionPolyfillProfileWiringTests` covers `search.query` choosing the
  sending profile's most recently used space.

# Related

- [Tab and window bridge](./tab-and-window-bridge.md) — how the opened window and tab are reported to WebKit.
- [ExtensionManager](./extension-manager.md) — the delegate callbacks.
- [Private profile extensions](./private-profile-extensions.md) — "allowed in Private", the row `windows.create({incognito: true})` reads.
- [Polyfill request gates](./polyfill-request-gates.md#the-profile-and-space-a-request-acts-in) — `search.query` and `sessions.restore`, which share the new-tab space rule.
- [Quick Detour Open in](../features/quick-detour-open-in.md) — the same most-recently-used-space rule.

[^task-214]: An extension allowed in Private can open a normal-profile window with windows.create
[^windows-create-tests]: ExtensionWindowsCreatePrivateTests
[^task-223]: windows.create from a normal profile can open its window on another profile's space
[^task-226]: tabs.create adds its tab to the profile's first space, not the one in use
[^task-224]: A normal-profile extension not allowed in Private can still open a Private window with windows.create({incognito true})
[^webkit-windows-api]: WebKit WebExtensionContextAPIWindowsCocoa.mm (windowsCreate, read 2026-10-27)
