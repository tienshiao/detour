---
type: Component
title: Tab and window bridge
description: How Detour's tabs and windows are presented to WebKit's extension runtime — the WKWebExtensionTab and Window conformances, the rule for when a tab is reported open, closed, moved or active, and what a window lists.
tags: [extensions, tabs, windows, webkit, lifecycle]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-28T05:00:00Z }
sources:
  - id: lifecycle
    resource: ../../Detour/Extensions/Runtime/ExtensionTabLifecycle.swift
    title: ExtensionTabLifecycle.swift
  - id: tab-conformance
    resource: ../../Detour/Extensions/Runtime/WKExtensionTabConformance.swift
    title: WKExtensionTabConformance.swift
  - id: window-conformance
    resource: ../../Detour/Extensions/Runtime/WKExtensionWindowConformance.swift
    title: WKExtensionWindowConformance.swift
  - id: active-tab
    resource: ../../Detour/Extensions/Runtime/ExtensionActiveTab.swift
    title: ExtensionActiveTab.swift
  - id: observer
    resource: ../../Detour/Extensions/Runtime/ExtensionTabObserver.swift
    title: ExtensionTabObserver.swift
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (notifyExistingTabs, window delegates)
  - id: task-50
    resource: backlog:TASK-50
    title: Favourites and Peeks register their backing tabs with the extension contexts
  - id: task-51
    resource: backlog:TASK-51
    title: Make a presented Peek the extension-visible active tab
  - id: task-52
    resource: backlog:TASK-52
    title: Register a tab with the contexts when its web view is created, not per creation path
  - id: task-57
    resource: backlog:TASK-57
    title: A parked Peek stays registered as an open extension tab after its host sleeps
  - id: task-59
    resource: backlog:TASK-59
    title: Moving a tab between the tab list, pinned section and favourites emits nothing
  - id: task-61
    resource: backlog:TASK-61
    title: Report a same-profile Move to Space as a tab move
  - id: task-20
    resource: backlog:TASK-20
    title: Un-skip the WKExtensionIntegrationTests runtime messaging tests
  - id: task-4
    resource: backlog:TASK-4
    title: "1Password: iframe autofill investigation"
  - id: task-81
    resource: backlog:TASK-81
    title: windows.getCurrent from a background worker reports "Window not found"
  - id: task-132-21
    resource: backlog:TASK-132.21
    title: A window with nothing selected reports no tabs to extensions
  - id: task-132-22
    resource: backlog:TASK-132.22
    title: Tell WebKit when a browser window opens or closes
  - id: task-132-2
    resource: backlog:TASK-132.2
    title: Resolve a WebKit tabId to its BrowserTab in polyfill handlers
  - id: lifecycle-tests
    resource: ../../DetourTests/ExtensionTabLifecycleTests.swift
    title: ExtensionTabLifecycleTests
  - id: task-193-3
    resource: backlog:TASK-193.3
    title: "Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)"
  - id: task-193-1
    resource: backlog:TASK-193.1
    title: "Quick Detour: the window, its single tab and the palette that opens it"
  - id: task-193-4
    resource: backlog:TASK-193.4
    title: "Quick Detour: a profile selector in the title bar"
  - id: quick-detour-tests
    resource: ../../DetourTests/QuickDetourExtensionTests.swift
    title: QuickDetourExtensionTests
  - id: task-214
    resource: backlog:TASK-214
    title: An extension allowed in Private can open a normal-profile window with windows.create
  - id: windows-create-tests
    resource: ../../DetourTests/ExtensionWindowsCreatePrivateTests.swift
    title: ExtensionWindowsCreatePrivateTests
  - id: task-223
    resource: backlog:TASK-223
    title: windows.create from a normal profile can open its window on another profile's space
  - id: task-224
    resource: backlog:TASK-224
    title: A normal-profile extension not allowed in Private can still open a Private window with windows.create({incognito true})
  - id: task-225
    resource: backlog:TASK-225
    title: windows.create opens a window for a javascript URL
  - id: webkit-windows-api
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIWindowsCocoa.mm
    title: WebKit WebExtensionContextAPIWindowsCocoa.mm (windowsCreate, read 2026-10-27)
---

WebKit's extension runtime keeps its own table of tabs and windows, built
entirely from what the host tells it. `BrowserTab` conforms to
`WKWebExtensionTab`, `BrowserWindowController` to `WKWebExtensionWindow`, and
`ExtensionTabLifecycle` is the single seam through which every "this tab
exists / is gone / moved / is active" announcement passes. The rules exist
because a tab WebKit was never told about still runs extension code.

# Role

A web view built from a profile's configuration always gets content scripts.
WebKit only knows that web view is a *tab* once some context has been told
`didOpenTab`. If nobody told it, every `runtime.sendMessage` from a content
script in that page fails inside WebKit with "Tab not found for message for
content script message".

That is not a quiet failure. A favourite's backing tab was once unregistered;
1Password's content script reports unhandled rejections with
`runtime.sendMessage`, the report itself rejected with "tab not found", and
the loop ran the page's WebContent process at about 120% CPU and 5 GB while
the page never finished loading.[^task-50] The fix was to make registration
structural rather than a call each creation path has to remember.

# How it works

## The rules

| Rule | Statement | Where |
|---|---|---|
| Placement | A tab is reported open the moment it becomes *enumerable*: when it enters `Space.tabs`, `Space.pinnedEntries` / `PinnedEntry.tab`, `Profile.favorites` / `Favorite.tab`, `BrowserTab.peekTab` or `TabStore.quickDetourTabs` while carrying a web view built from a profile's configuration. Each container has a one-line `didSet` calling `didPlace`. | `ExtensionTabLifecycle.didPlace` |
| New web view | `BrowserTab.wake()` re-announces an already-registered tab. WebKit maps a tab to a particular web view, so the new one must be reported or the contexts keep the released view. | `didCreateWebView(for:)` |
| Close | Only `BrowserTab.teardown()` reports a close: the one point every tab passes through and the last moment its web view exists. Idempotent. | `didClose` |
| Section move | Moving a live tab between the tab list, pinned section and favourites of one profile is a hand-off. It keeps its registration; only a pinned-flag flip is announced. | `didChangePinned` |
| Space move | "Move to Space" inside one profile is announced as a move, not a close and re-open, so extensions keep per-tab ports and frame maps. | `didMove` |
| Profile change | A move between profiles is a close plus a re-open under the new profile's contexts. | `didOpen` closes a previous registration |
| Parked peek | A Peek whose host slept is closed to the contexts. It is never woken as the same object, so leaving it registered would be a phantom tab with no web view. | `BrowserTab.parkPeek` |
| Active tab | A window's active tab is the presented Peek while one is up, otherwise the selected tab. | `extensionActiveTab` |

Why placement and not construction: `didOpenTab` fires `tabs.onCreated`, whose
parameters resolve `window(for:)` and that window's tab list. The tab must
already be listed when it is reported. A container's `didSet` runs after the
mutation, so it is; registering in `BrowserTab.init` would report a tab
nothing can place yet.[^task-52]

The profile to tell comes from the web view's own
`configuration.webExtensionController` (`Profile.profile(owning:)`), not from
the tab's space. Favourite and Peek tabs belong to a profile without living in
a space, and a tab whose configuration has no controller runs no extension
code and is deliberately never reported.

An ordinary sleeping tab stays registered; its wake re-reports it. A tab that
is already asleep when a context loads is not announced until it wakes.

## What the calls become

| Detour | WebKit call | Extension sees |
|---|---|---|
| `didOpen` | `didOpenTab` | `tabs.onCreated` |
| `didClose` | `didCloseTab(_:windowIsClosing: false)` | `tabs.onRemoved` |
| `didActivate(tab, previousActiveTab:)` | `didActivateTab` | `tabs.onActivated` |
| property observers on `$url`, `$title`, `$isLoading`; `didChangePinned` | `didChangeTabProperties` | `tabs.onUpdated` |
| `didMove(tab, fromIndex:, in: oldWindow)` | `didMoveTab` | `onMoved` when the old window is the current one; `onDetached` + `onAttached` when it differs; `onAttached` alone when it is nil |

Property changes are observed on the tab itself (Combine sinks installed by
`didOpen`, removed by `didClose`) rather than through `TabStore`, whose
per-tab subscriptions do not cover a Peek.

## What a window is

Two kinds of window are told to extensions, both `ExtensionListedWindow`s
(`extensionTabs`, `extensionActiveTab`, `extensionProfileID`):
`BrowserWindowController` and the [Quick Detour](../features/quick-detour.md)
window. `extensionListedWindows()` enumerates both in `NSApp.windows` order,
plus any open Quick Detour AppKit does not list yet; `openWindowsFor`,
`focusedWindowFor`, `notifyExistingTabs`, the window-focus forwarding and
`ExtensionTabLifecycle.windowListing` all go through it.

- `openWindowsFor` returns the listed windows whose profile is the
  controller's: a browser window's **active space's** profile, a Quick
  Detour's own. A window of another profile is invisible to this profile's
  contexts.
- A window lists `extensionWindowTabs`: the active space's pinned tabs, then
  its normal tabs, then the profile's live favourite backing tabs, each
  immediately followed by its Peek when that Peek has a web view. The same
  function backs `tabs(for:)`, the membership test in `window(for:)`, and
  `notifyExistingTabs`, so they cannot disagree.
- Tabs in a space no window is showing are registered but listed by no window.
- `BrowserTab.extensionWindow()` resolves in this order: the Quick Detour
  window whose page the tab is; the window whose
  `selectedTabID` is the tab; the window whose `extensionActiveTab` is the tab
  (a presented Peek belongs to the window presenting it); any window listing
  it; the window on the tab's space.
- `windowType` is `.normal` for a browser window and `.popup` for a Quick
  Detour (TASK-193.1), whose one tab is also its active tab; `isPrivate` is
  the window's incognito flag (a Quick Detour's: its profile's).

## Opening a window

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
contexts.[^task-223] `tabs.create` still adds to the profile's first space in
sidebar order (`space(for:)`), not its most recently used one.

## javascript: URLs

`windows.create` (the URL alone or among others), `tabs.create` and
`tabs.update` refuse a `javascript:` URL before anything opens or loads
(`ExtensionManager.isJavaScriptURL`, checked in `openNewWindowUsing`,
`openNewTabUsing` and `BrowserTab.loadURL`), with "Cannot load a javascript:
URL; use chrome.scripting.executeScript instead", as Chrome's MV3 refuses
them. The WebKit shipped with macOS 26.7 (build 25G229, Darwin 25.6) passes
all three through to Detour, although WebKit's `main` refuses the URL in
`windows.create` itself:[^webkit-windows-api] `windows.create` opened a
window, `tabs.create` a tab, and `tabs.update` loaded the URL into the tab,
which ran the script in its page, so an extension could script a page through
`tabs.update` instead of `scripting`.[^task-225] WebKit prefixes the
message with "Invalid call to <api>()." and capitalises its first letter,
which is why it does not start with the scheme.

## Active tab

`selectedTabID` is untouched by the Peek rule; it still names the focused pane
of a [split](../tabs/split-tabs.md), that is, the Peek's host. Only the
extension-visible active tab follows the overlay, so `tabs.query({active:
true})`, a toolbar popup and an `activeTab` grant target the page the user is
looking at ([Peek](../tabs/peek.md)).

Every path that can change it calls `announceExtensionActiveTabIfChanged`,
which goes through an `ExtensionActiveTabTracker` that dedupes by identity.
The previous tab is reported only when it is still registered with the same
profile. WebKit's `didActivateTab` runs `getOrCreateTab` on the previous tab,
so naming a closed one, or one from another profile, would resurrect it as a
phantom.[^task-51]

## When a context loads

`ExtensionManager.notifyExistingTabs` tells the new context about the
profile's windows (`didOpenWindow`), every non-sleeping tab across **all** the
profile's spaces, the focused window, and the active tab. Announcing tabs of
spaces that are not on screen matters: without it `sender.tab` is null for
content-script messages from them.

Window focus is forwarded to every profile's controller from
`NSWindow.didBecomeKeyNotification` / `didResignKeyNotification`.

## Tab ids

WebKit mints tab ids itself from the tab objects it has been told about.
Detour has no table of them on `main`: nothing maps a WebKit tab id back to a
`BrowserTab`.[^task-132-2] `webView(for:)` returns the tab's web view only when
its configuration's controller is the asking context's.

# Invariants

- Every enumerable tab whose web view carries a live profile's controller is
  registered. A debug assertion (`assertExtensionRegistered`) checks it where
  a window claims a web view or presents a Peek.
- No creation path calls `didOpen` itself; no removal path calls `didClose`
  except through `teardown()`. A detach is not a teardown and stays silent.
- `didChangePinned` and `didMove` are called only after the tab is in its
  destination container, because handling them resolves the tab's window and
  index. For the attach to carry a position the receiving window must also
  have a tab selected: WebKit's `WebExtensionWindow::tabs()` is empty without
  an active tab, so `tab.index()` is not found and `tabs.onAttached` arrives
  with `newPosition: null` (seen in a real context, TASK-193.3). Quick
  Detour's Open in therefore selects the moved page first and announces the
  move inside `BrowserWindowController.holdingExtensionActivation`, which
  holds the window's `didActivate` until after it: `onDetached`,
  `onAttached` (with its position), then `onActivated`, as for a tab dragged
  between windows. The tab keeps its id; the Quick Detour window then closes
  listing no tab, so `didCloseWindow` fires only `windows.onRemoved`.[^task-193-3]
- A move resolves the old window and index *before* mutating anything.

# Gotchas

- "Tab not found" in the unified log's WebKit `Extensions` category means a
  web view was never reported open. Look for the creation path that bypasses
  the containers ([diagnosing extension problems](../playbooks/diagnosing-extension-problems.md)).
- A message sent to a sleeping worker can be silently lost.[^task-4]
- `chrome` exists only in the extension's content-script world. Evaluating
  `chrome.runtime.sendMessage` in the page world of an https page throws
  `Can't find variable: chrome`. Tests relay through `window.postMessage`.[^task-20]
- WebKit's `alarms.create` returns no promise.[^task-20]
- A window with nothing selected reports **no tabs at all**. WebKit's
  `WebExtensionWindow::tabs()` returns an empty list unless `activeTab(for:)`
  is non-nil and is in the list. By-id calls and events still work, since the
  flat tab table is fed by `didOpenTab`.[^task-132-21]
- WebKit lists only the windows it was told about: `windows.getAll` reads
  its own `m_windowOrderVector`, filled by `didOpenWindow`, by
  `didFocusWindow` and by `openWindowsFor` when a context loads — not by
  asking the delegate each time.[^task-193-1] For a browser window
  `didOpenWindow` is sent only while a context loads, and `didCloseWindow`
  never. A window created later is learned about when it becomes key, so
  `windows.onCreated` does not fire for one opened in the background and
  `windows.onRemoved` may never fire.[^task-132-22] A Quick Detour window
  tells its profile's loaded contexts itself, `didOpenWindow` before its tab
  is placed and `didCloseWindow` after the tab is closed: a lookup window may
  never be focused while an extension asks.[^task-193-1] Its profile pill
  (TASK-193.4) moves the same window object between profiles: the old tab
  closes, `didCloseWindow` goes to the old profile's contexts, the window's
  `extensionProfileID` changes, `didOpenWindow` goes to the new profile's,
  and only then does the new tab enter `quickDetourTabs` — so the window
  lists no tab at either announcement. `didCloseWindow` makes WebKit forget
  the window (`forgetWindow`), so reporting the same object open to that
  context again later gives it a new window id.[^task-193-4]
- `focusedWindowFor` answers only with the key window, and only if it shows
  the profile. `windows.getCurrent` from a worker was seen failing with
  "Window not found" at every worker start (1Password's sign-in-with setup
  does not check for it). The nil answer at launch and in every profile but
  the key window's is the likely cause; it has not been confirmed.[^task-81]
- `openNewWindowUsing` ignores `configuration.tabs` (moving existing tabs into
  the new window is a TODO in the code).

The planned changes to the window model are in the
[Claude extension epic](./claude-extension-epic.md); this page describes `main`.

# Tests

- [ExtensionTabLifecycleTests](../../DetourTests/ExtensionTabLifecycleTests.swift) — a recording notifier swapped in for `ExtensionTabLifecycle.notifier`; asserts the tab was already listed when reported, once, for normal, pinned, favourite, peek and wake; the move rules.
- `ExtensionActiveTabTests` — the pure rule, the tracker, and a real window presenting and closing a Peek.
- `MoveTabToSpaceTests`, `WKExtensionIntegrationTests`.
- `QuickDetourExtensionTests` — the Quick Detour window in real contexts: a
  `popup` window from an extension page and from the worker, isolation from
  another profile (also for a context that loads after the window opened),
  a content script's `sender.tab`, the toolbar button, the close.
- `ExtensionWindowsCreatePrivateTests` — `windows.create` from an incognito
  context (`incognito` left out, `false`, `true`; with a quarantine in
  front) and from a normal one, from the worker and an extension page, in the
  promise and callback forms; a `detour://` URL fails in every
  form and opens no window. A normal caller's `incognito: true` opens a
  Private window when the extension is allowed in Private and is refused
  (no row, or a row saying off) when it is not. A normal caller with another profile's window in
  front, with no window on its profile (its last active space, not its first),
  and with no space (refused, no window). A `javascript:` URL refused by
  `windows.create`, `tabs.create` and `tabs.update` (the page left alone) in
  every form, in one test to keep the suite's retained profiles down.
- In tests a web view must be registered as a tab (`registerProbeTab` in `ExtensionTestSupport`) before content-script messaging works; that was the real cause of six tests once skipped as "sandbox limits".[^task-20]

# Related

- [ExtensionManager](./extension-manager.md) — the delegate callbacks that open tabs and windows.
- [Favorites](../tabs/favorites.md), [Peek](../tabs/peek.md), [pinned tabs](../tabs/pinned-tabs-and-folders.md) — the containers outside `space.tabs`.
- [Sleeping and archiving](../tabs/sleeping-and-archiving.md) — when a web view is released and rebuilt.
- [WebView ownership](../architecture/webview-ownership.md) — a tab's web view may be owned by another window, or none.
- [Extension pages](./extension-pages.md) — the announce-once ordering on a context reload.

[^task-50]: Favourites and Peeks register their backing tabs with the extension contexts
[^task-51]: Make a presented Peek the extension-visible active tab
[^task-52]: Register a tab with the contexts when its web view is created, not per creation path
[^task-20]: Un-skip the WKExtensionIntegrationTests runtime messaging tests
[^task-4]: 1Password: iframe autofill investigation
[^task-81]: windows.getCurrent from a background worker reports "Window not found"
[^task-132-21]: A window with nothing selected reports no tabs to extensions
[^task-132-22]: Tell WebKit when a browser window opens or closes
[^task-132-2]: Resolve a WebKit tabId to its BrowserTab in polyfill handlers
[^task-193-1]: Quick Detour: the window, its single tab and the palette that opens it
[^task-193-3]: Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)
[^task-193-4]: Quick Detour: a profile selector in the title bar
[^task-214]: An extension allowed in Private can open a normal-profile window with windows.create
[^windows-create-tests]: ExtensionWindowsCreatePrivateTests
[^task-223]: windows.create from a normal profile can open its window on another profile's space
[^task-225]: windows.create opens a window for a javascript URL
[^task-224]: A normal-profile extension not allowed in Private can still open a Private window with windows.create({incognito true})
[^webkit-windows-api]: WebKit WebExtensionContextAPIWindowsCocoa.mm (windowsCreate, read 2026-10-27)
