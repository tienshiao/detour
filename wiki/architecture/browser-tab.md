---
type: Component
title: BrowserTab
description: "The tab model — an optional WKWebView with published state, sleep and wake, its own navigation delegate while no window owns it, and the flags that keep a restored session intact."
resource: ../../Detour/Browser/BrowserTab.swift
tags: [architecture, tabs, webkit, sleep]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-29T04:30:00Z }
sources:
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift
  - id: tab-record-factory
    resource: ../../Detour/Browser/TabRecord+BrowserTab.swift
    title: TabRecord+BrowserTab.swift
  - id: navigation-delegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: task-45
    resource: backlog:TASK-45
    title: A failed wake of a restored tab replaced its session with an error page
  - id: task-49
    resource: backlog:TASK-49
    title: Build TabRecords through one factory
  - id: task-91
    resource: backlog:TASK-91
    title: Per-visit titles and pushState visits
  - id: task-114
    resource: backlog:TASK-114
    title: A background tab whose load stalls shows its URL as the title
  - id: task-122
    resource: backlog:TASK-122
    title: A background tab whose load fails never shows the error page
  - id: task-124
    resource: backlog:TASK-124
    title: Stalled background loads and the sidebar progress bar
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process IOSurface leak and the show budget
  - id: task-176
    resource: backlog:TASK-176
    title: Reload on a tab whose web process is unresponsive does nothing; terminate the process and reload
  - id: task-227
    resource: backlog:TASK-227
    title: YouTube tabs come back from a relaunch titled with their URL
  - id: title-retention-tests
    resource: ../../DetourTests/TabTitleRetentionTests.swift
    title: TabTitleRetentionTests.swift
---

# Role

`BrowserTab` is one tab: an identity (`id`), an optional `WKWebView`, and the
state the UI and the store watch. It is an `NSObject` (for KVO) and is shared
by reference: every window showing a space sees the same `BrowserTab`
objects, which is why its web view can only be in one of them
([web view ownership](./webview-ownership.md)).

The same class backs normal tabs, pinned entries' backing tabs, favorites'
backing tabs and Peek tabs. What differs is where the tab is held, not its
type.

# How it works

## Three ways to exist

| Initialiser | Web view | Used for |
|---|---|---|
| `init(id:configuration:)` | Built now from the configuration | New tabs (`TabStore.addTab`). Also a window a page opened (`addTab(in:openedWith:)`), where the configuration is the one WebKit supplied and WebKit, not `load`, starts the navigation. |
| `init(id:webView:)` | Adopts an existing, already loading web view | An expanded Peek and extension pages (`addTab(in:webView:)`, `addExtensionTab`). Seeds `url`, `title`, `isLoading` from the web view. |
| `init(id:title:url:faviconURL:cachedInteractionState:spaceID:)` | None; `isSleeping = true` | Session restore of unselected tabs, and tabs created asleep. |

A convenience initialiser
(`init(id:title:archivedInteractionState:fallbackURL:faviconURL:configuration:)`)
builds a live tab and restores archived interaction state into it, or loads
the fallback URL. It is what session restore uses for the selected tab, and
what a reopened closed tab or a dormant tile going live is built with
(`TabStore.restoredTab`, `makeTab(loading:)`).

## Published state

`title`, `url`, `isLoading`, `isSleeping`, `isPlayingAudio`, `isMuted`,
`canGoBack`, `canGoForward`, `blockedCount`, `estimatedProgress`,
`isLoadProgressStalled`, `favicon`, `peekFavicon`.

They are fed by Combine publishers on the web view's KVO properties
(`setupObservers`), stored in `faviconCancellables` and dropped when the web
view is released. `isPlayingAudio` is the exception: it comes from classic KVO
on the private key `_isPlayingAudio`, delivered asynchronously on the main
queue.

Who subscribes: [TabStore](./tabstore.md) (notify observers, save, record
history), the owning window (address bar, navigation buttons, window title),
and `ExtensionTabLifecycle` (forwarding changes to extension contexts,
stored in `extensionPropertyObservers`).

## The web view and its container

`makeWebView(configuration:)` is the only place Detour builds a tab web view.
It enables developer extras and Picture in Picture (a private C function),
registers the `browser-error://` and `detour://` scheme handlers if the
configuration has none, installs the internal page bridge and the favicon
link bridge, and returns a `BrowserWebView` with `isInspectable = true`.
Extension pages are the exception: they adopt a plain `WKWebView` built from
the extension context's configuration.

`webView` has a `didSet` that registers the view with
`ExtensionPageHostRegistry` and `FaviconLinkBridge`. Property observers do
not run during `init`, so the two initialisers that take or build a web view
register explicitly. A third initialiser that sets `webView` must do the same.

`webViewContainer` (`WebViewContainerView`) wraps the web view. WebKit docks
the Web Inspector as a **sibling** of the web view, so windows host and move
the container, never the bare web view; that way the inspector travels with
the tab. The container uses autoresizing masks, not Auto Layout — constraints
break the docked inspector. `ensureWebViewContainer()` also repairs a
container that lost its web view.

## Sleep, wake, retarget, teardown

| Method | Web view | Interaction state | Extension contexts |
|---|---|---|---|
| `sleep(force:)` | Released | Archived to `cachedInteractionState` | Stays registered |
| `wake(supersededByLoad:)` | New one built | Restored, then cache cleared | Re-reported (`didCreateWebView`) |
| `retarget(to:)` | Released | **Discarded** | (caller's business) |
| `teardown()` | Released, media paused | Lost | `didClose` |

- `sleep()` does nothing while the tab plays audio unless `force` is true.
  It parks the tab's Peek first.
- `wake()` asks `spaceID`'s space for a configuration. For a
  `webkit-extension://` URL it uses the owning extension context's
  configuration instead, resolved by origin host
  (`wakeConfiguration(in:)`). It resets `showsSinceWake`.
- `retarget(to:)` exists for extension pages whose origin died under them:
  restoring the old interaction state would put the tab straight back on the
  dead URL, and the old web view cannot load the new origin at all. The tab
  is left asleep on the new URL and the display path rebuilds it. Title and
  favicon are kept on purpose. See
  [extension pages](../extensions/extension-pages.md).
- `teardown()` is the close point for every kind of tab. Paths that never
  produce a `TabStore` remove notification (deactivating a favorite, closing
  a Peek) still call it, which is why the extension close lives here.

`releaseWebView()` is shared by all three release paths. It forces
`isPlayingAudio = false`: the KVO observer is the flag's only writer and it
is asynchronous, so a forced release mid-playback would otherwise leave the
flag stuck on, and the tab would never auto-sleep again.

Policy for *when* tabs sleep is on
[sleeping and archiving](../tabs/sleeping-and-archiving.md).

## Interaction state

`WKWebView.interactionState` holds the back/forward list, scroll position
and form data. `currentInteractionStateData()` returns it archived with
`NSKeyedArchiver` (non-secure coding) from the live web view, or the cached
data for a sleeping tab. It feeds three places: the `tab` row
([persistence](./persistence.md)), the `closedTab` row, and sleep/wake.

`TabRecord.init(tab:spaceID:sortOrder:profile:…)` in
[TabRecord+BrowserTab.swift](../../Detour/Browser/TabRecord+BrowserTab.swift)
is the single mapping from a tab to its persisted row. Before TASK-49 there
were three hand-copied literals and one had drifted. `TabRecordFactoryTests`
uses a `Mirror` sweep to fail when a new column is not mapped.

## URL and title rules

`tab.url` is not simply `webView.url`. The URL observer keeps or ignores
emissions according to four pieces of private state:

| State | Meaning | Effect |
|---|---|---|
| `navigationPending` | `load(_:)` was called and nothing has committed | The title shows the scheme-stripped target URL. |
| `lastAttemptedURL` | The URL the tab is on or trying to reach: what `load(_:)` asked for, the observed web view URL, or the URL a provisional failure names (never an internal one; TASK-170) | Kept as `url` when WebKit reverts to nil after a cancel; the target of the error page and of Reload. |
| `awaitingFirstURL` | A fresh web view from `wake()` has not reported a URL yet | The web view's initial nil does not wipe the restored `url`. |
| `restoringSession` | `wake()` handed the web view cached interaction state and nothing has committed | A provisional failure shows no error page and keeps the persisted title. |

The last two were split out of `lastAttemptedURL` by TASK-45. Seeding
`lastAttemptedURL` in `wake()` had told the failure handler that the user
asked for the navigation, so a restored tab woken offline got an error page
over its restored session.

Consequences worth knowing:

- An error page (`browser-error://`) never becomes `tab.url`. `tab.url`
  stays on the URL the user asked for. Code that needs "what is actually
  displayed" must read `webView?.url`.
- A failed restore makes WebKit commit `about:blank`. That commit is ignored
  (`blankAfterFailedRestore`, and the guard in `didCommitNavigation()`),
  unless the tab's own `url` is `about:blank`, which is a genuine restore
  onto a blank page (TASK-114 follow-up).
- Restoring interaction state does not start a navigation by itself. The
  window's claim path calls `loadIfStalled()` as the kick; it is not
  `load(_:)`, so a kick that fails offline keeps the session.[^task-45]
- `updateTitle()` picks, in order: an internal page's name; the
  scheme-stripped pending URL; the document title; nothing while
  `restoringSession` (the persisted title stays); the scheme-stripped current
  URL; "New Tab" for a live tab with no URL.
- **A title outlives its page's empty moments (TASK-227).** `titledURL`
  records the URL the current title really belongs to: set with a document
  title, a non-empty persisted title (the sleeping init) or archived one
  (`restoreArchivedPage`), moved by `retarget(to:)`, cleared whenever a
  placeholder or an internal page's name is shown. A document title is tied
  to the web view's **`_committedURL`** (WKWebViewPrivate), not to
  `webView.url`: during a navigation the page started (a link, Back) the
  URL is already the destination while the title is still the old
  document's, and WebKit changes `_committedURL` and the title in one
  transaction, at commit and at a same-document change such as YouTube's
  `replaceState` that drops `&pp=`. Neither URL placeholder replaces the
  title while the URL it would show is `titledURL`; with the process gone,
  the tab's committed `url` counts too, because `lastAttemptedURL` still
  names the address a load redirected from. Without this, a web content process that
  died took the title with it (WebKit resets the page's URL and title on
  process exit, see [unresponsive web process](../platform/unresponsive-web-process.md)),
  the tab showed `youtube.com/watch?v=…`, the next save stored that, and a
  tab put to sleep kept it across every relaunch after. The same happened
  when a woken restored tab committed before its document reported a title,
  which a hidden web view can take minutes to do
  ([hidden web view load stalls](../platform/hidden-webview-load-stalls.md)).
  The cost: a page that empties its own title on the same URL keeps the old
  one.[^task-227]

`load(_:)` refuses `detour://` URLs; only `loadInternalPage(_:)` and
`loadRecordedURL(_:)` arm the tab for one. See
[internal pages](../features/internal-pages.md). Favicon generations are
described on [favicons](../features/favicons.md).

## Its own navigation delegate

A tab is the `WKNavigationDelegate` of its own web view until a window claims
it (`wireOwnedWebView`). A tab opened in the background — Cmd+click, an
extension's `tabs.create({active: false})` — loads before any window is its
delegate. The tab's delegate implements only what the window would forward:

| Callback | Why it is needed while unclaimed |
|---|---|
| `decidePolicyFor:preferences:` | Applies the internal page policy and the per-site content blocker switch. With no delegate WebKit uses default preferences (TASK-69). |
| `didCommit` | Without it a stalled background load kept its URL as its title until the load finished (TASK-114). |
| `didFailProvisionalNavigation` | Without it a failing background load never showed the error page (TASK-122). `didFail`, the failure of a navigation that already committed, is deliberately **not** implemented, here or in the window: the committed document stays on screen (TASK-178, see [error pages](../features/error-pages.md#failures-after-commit)). |
| `didStartProvisionalNavigation`, `_webViewWebProcessDidBecomeUnresponsive:`, `_webViewWebProcessDidBecomeResponsive:` | The events of the unresponsive-load rule (TASK-176); a background tab's blocked process is replaced the same way as an on-screen one. `webViewWebContentProcessDidTerminate` is deliberately **not** implemented here: doing so would switch off WebKit's own reload of a crashed background page when it is next shown. |

A window never clears itself as delegate when the user switches tabs; it
resolves callbacks through `tab(owning:)`. When a window closes it hands each
web view back to its tab (`handBackNavigationDelegates`), because the
delegate reference is weak and a dead window would leave the web view with no
delegate.

Which failures are ignored is decided once, in the tab
(`isIgnoredNavigationError`): superseded loads (WebKit error 102,
`NSURLErrorCancelled`) and media documents (WebKit error 204, which arrives
after commit and so reaches no tab since TASK-178). See
[error pages](../features/error-pages.md) and
[media and PiP](../platform/media-and-pip.md).

## Bookkeeping other subsystems read

- `showsSinceWake` / `noteShown()` — how many times a window has hosted this
  web view since it was built; drives the show-budget sleep rule
  ([GPU IOSurface limit](../platform/gpu-iosurface-limit.md)).
- `isLoadProgressStalled` / `sidebarProgress` — a hidden load whose progress
  has not moved for `loadStallInterval` (2 s). `isLoading` stays true
  ([hidden web view load stalls](../platform/hidden-webview-load-stalls.md)).
- `lastDeselectedAt` — when the tab last left a screen; nil means selected
  somewhere. Persisted.
- `switcherPreview`, `switcherPreviewAt` — the Control+Tab card; memory only
  ([tab switching](../tabs/tab-switching.md)).
- `lastRecordedHistoryURL`, `lastRecordedVisitID`, `lastRecordedHistoryAt`,
  `lastRecordedHistorySpaceID`, `lastRecordedBackForwardItem`,
  `historyRecordingGeneration` — written only by
  `TabStore.recordHistoryVisit`
  ([history recording](../features/history-recording-and-search.md)).
- `extensionRegisteredProfile` — the profile whose contexts were told this
  tab is open; nil means unregistered.
- `noteProcessTermination()` — counts web content process deaths less than
  30 s apart; the window auto-reloads the first two of a streak and leaves
  the pane blank from the third.
- `loadRecovery` (`UnresponsiveLoadRecovery`), `stopLoading()`,
  `scriptDialogDidBegin()` / `scriptDialogDidEnd()`,
  `isTerminatingUnresponsiveProcess` — a load or a Stop that a blocked web
  process never answers gets a new process. `reload()` and `load(_:)` go
  through `issue(_:)`; Stop must go through `BrowserTab.stopLoading()`, not
  the web view, and whoever shows a script dialog must bracket it, or the
  rule sees a hang where the page is waiting on the user
  ([unresponsive web process](../platform/unresponsive-web-process.md)).

# Gotchas

- `BrowserTab` reaches for `TabStore.shared` directly in `wake()`,
  `applyUserAgent()`, `owningProfile` and the user agent notification. A tab
  that belongs to a space of a private `TabStore` in a test resolves no space
  there and wakes with a bare `WKWebViewConfiguration()`.
- `owningProfile` falls back to `extensionRegisteredProfile` because favorite
  and Peek tabs can have no space of their own.
- `applySpoofedUserAgent(for:)` both sets the Chrome user agent for the
  Chrome Web Store hosts and **restores** the profile's for every other host.
  It must be called on the tab that is navigating, never on the selected tab.
- A `WKWebView` with no navigation delegate never sent the request for
  `load(_:)` in offscreen tests; a test that needs a real load must install a
  delegate.[^task-91]
- `http://127.0.0.1:1/` does not fail in WebKit: port 1 is on its restricted
  list and it silently commits `about:blank` with `didFinish`. Tests that
  need a refused connection use a just-freed loopback port.[^task-122]
- A web view's title arrives through KVO a run loop turn after the load
  callback; asserting it synchronously is flaky under load.[^task-45]

# Tests

`BrowserTabWakeTests`, `BrowserTabUnclaimedNavigationTests`,
`BackgroundTabTitleTests`, `LoadProgressStallTests`,
`NavigationErrorClassificationTests`, `TabRecordFactoryTests`,
`PeekStateTests`, `SleepShowBudgetTests`.

# Related

- [TabStore](./tabstore.md) — owner and subscriber.
- [Web view ownership](./webview-ownership.md) — who hosts the container.
- [BrowserWindowController](./browser-window-controller.md) — the delegate once claimed.
- [Tab lifecycle](../tabs/tab-lifecycle.md) — creation, navigation, closing.
- [Peek](../tabs/peek.md) — `peekTab` and parked Peeks.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — how a tab is reported to extensions.

[^task-45]: A failed wake of a restored tab replaced its session with an error page
[^task-227]: YouTube tabs come back from a relaunch titled with their URL
[^task-91]: Per-visit titles and pushState visits
[^task-122]: A background tab whose load fails never shows the error page
