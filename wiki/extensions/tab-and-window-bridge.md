---
type: Component
title: Tab and window bridge
description: How Detour's tabs and windows are presented to WebKit's extension runtime — the WKWebExtensionTab and Window conformances, the rule for when a tab is reported open, closed, moved or active, and what a window lists.
tags: [extensions, tabs, windows, webkit, lifecycle]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
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
| Placement | A tab is reported open the moment it becomes *enumerable*: when it enters `Space.tabs`, `Space.pinnedEntries` / `PinnedEntry.tab`, `Profile.favorites` / `Favorite.tab`, or `BrowserTab.peekTab` while carrying a web view built from a profile's configuration. Each container has a one-line `didSet` calling `didPlace`. | `ExtensionTabLifecycle.didPlace` |
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

- `openWindowsFor` returns the `BrowserWindowController`s whose **active
  space** belongs to the controller's profile. A window showing another
  profile's space is invisible to this profile's contexts.
- A window lists `extensionWindowTabs`: the active space's pinned tabs, then
  its normal tabs, then the profile's live favourite backing tabs, each
  immediately followed by its Peek when that Peek has a web view. The same
  function backs `tabs(for:)`, the membership test in `window(for:)`, and
  `notifyExistingTabs`, so they cannot disagree.
- Tabs in a space no window is showing are registered but listed by no window.
- `BrowserTab.extensionWindow()` resolves in this order: the window whose
  `selectedTabID` is the tab; the window whose `extensionActiveTab` is the tab
  (a presented Peek belongs to the window presenting it); any window listing
  it; the window on the tab's space.
- `windowType` is always `.normal`; `isPrivate` is the window's incognito flag.

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
  index.
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
- `didOpenWindow` is sent only while a context loads, and `didCloseWindow`
  never. A window created later is learned about when it becomes key, so
  `windows.onCreated` does not fire for one opened in the background and
  `windows.onRemoved` may never fire.[^task-132-22]
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
