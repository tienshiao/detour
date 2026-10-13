---
type: Platform Quirk
title: WKWebView delegate call order
description: Which WKNavigationDelegate and WKUIDelegate methods WebKit calls, and in what order, for target=_blank links, window.open, custom-scheme links, failed and superseded loads, and custom-scheme internal pages — verified with a standalone spike.
tags: [webkit, navigation, delegates, peek, internal-pages]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-13T06:19:15Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: notes-spike
    resource: "Agent session notes, 2026-09-15 and 2026-09-19 (not in the repository)"
    title: WKWebView delegate spike — verified call order and custom-scheme facts
  - id: task-85
    resource: backlog:TASK-85
    title: "Peek: target=_blank links in a pinned tab or favourite open in a Peek"
  - id: task-86
    resource: backlog:TASK-86
    title: History page and the internal-page infrastructure
  - id: task-84
    resource: backlog:TASK-84
    title: Confirmation before opening external apps
  - id: task-121
    resource: backlog:TASK-121
    title: A standalone video URL shows the error page with "Plug-in handled load"
  - id: task-122
    resource: backlog:TASK-122
    title: A background tab whose load fails never shows the error page
  - id: task-167
    resource: backlog:TASK-167
    title: window.open() hands the page no window back, so an xterm.js terminal link opens an empty tab
  - id: task-168
    resource: backlog:TASK-168
    title: A sign-in popup cannot reach the page that opened it or close itself
  - id: spike-167
    resource: ../../docs/harness/task167-window-open-spike.swift
    title: Standalone spike — what createWebViewWith receives and what the page gets back
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: ui-delegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
    title: BrowserWindowController+WKUIDelegate.swift
  - id: peek-anchor
    resource: ../../Detour/Browser/Window/PeekAnchor.swift
    title: PeekAnchor.swift
  - id: internal-page
    resource: ../../Detour/Browser/InternalPages/InternalPage.swift
    title: InternalPage.swift (InternalPageNavigationPolicy)
---

Apple's documentation does not say which delegate method fires first when a
page opens a new window, or what a navigation action looks like when the app
itself started it. These were settled by experiment. Several Detour rules
(when a link opens a [Peek](../tabs/peek.md), how
[internal pages](../features/internal-pages.md) are protected, which failures
become an [error page](../features/error-pages.md)) depend on them.

# Behavior

## New windows

Verified 2026-09-15 on macOS 26's WebKit; it matches
`WebPageProxy::decidePolicyForNewWindowAction` and `FrameLoader::loadURL` in
WebKit's source.[^notes-spike]

| Page action | `decidePolicyFor` (navigation delegate) | `createWebViewWith` (UI delegate) |
|---|---|---|
| User-activated `<a target="_blank">` | Called first, on the **source** web view: `navigationType == .linkActivated`, `targetFrame == nil` | Called only if the policy returned `.allow` |
| Script `window.open(...)` | **Never called** | Called; the action's `navigationType` is `.other` |
| Custom-scheme link (tested with `zoommtg:`) | Called, with the main frame as target | Not involved |

Consequences:

- Returning `.cancel` for a nil-`targetFrame` action suppresses the new
  window entirely. That is the one place to redirect a `_blank` link.
- A rule written only in `decidePolicyFor` misses every script-opened window.
  Google Calendar opens an event's video-call link through `window.open`,
  not a `_blank` anchor, which is how this was found.[^task-85]

## What the page gets back

Measured 2026-10-10 on macOS 26 with a standalone binary, the delegate
returning nil, then a web view made from the supplied configuration.[^spike-167]

| Page action | `request.url` in `createWebViewWith` | Delegate returns nil | Delegate returns a web view |
|---|---|---|---|
| `window.open()` (no URL) | non-nil, the empty string | `window.open()` returns `null` | A window. The child shows `about:blank` with no policy call; the page's later `w.location.href = …` is a navigation of the child (`decidePolicyFor` on the child, type `.other`) |
| `window.open(url)` | the URL | `null` | A window. **WebKit loads the URL in the child itself**; `window.opener` is set and `opener.postMessage` arrives |
| `window.open(url, '_blank', 'noopener')` | the URL | `null` | Still `null` for the page, by design. The delegate is called all the same and WebKit loads the URL in the child, whose `window.opener` is null |
| `<a target="_blank">`, with or without `rel=noopener` | the URL | no window | WebKit loads the URL in the child |

So a delegate that returns nil and loads the URL into a web view of its own
gives the page nothing to hold: a page that opens a blank window and
navigates it afterwards is left with an empty window, and a popup has no
opener to report to. xterm.js's link handler is the first shape
(`const w = window.open(); w.opener = null; w.location.href = uri`, and only
a console warning when `w` is null); a sign-in popup is the second.[^task-167][^task-168]

Other facts from the same runs:

- The supplied configuration shares the opener's `websiteDataStore` **and its
  `userContentController`** (the same object). Replacing
  `configuration.userContentController` with a fresh controller before
  creating the child is accepted: the child's user scripts and message
  handlers come from the new controller, and the opener link, `postMessage`
  and `window.close()` work as before.
- `window.close()` is reported to the **closing** web view's UI delegate as
  `webViewDidClose(_:)`, for a close called by the child, by the opener on its
  handle, and by a `noopener` child. The opener then reads `closed === true`
  on its handle. The child's UI delegate has to be set for any of that to be
  seen. Detour had implemented `webView(_:didClose:)`, which is not a
  `WKUIDelegate` method, so no page had ever closed a tab.[^task-168]

- **By the time a provisional failure is reported, `WKWebView.url` no longer
  names what failed.** A script-opened window whose first load failed left
  the tab's URL observer with `about:blank` as the last URL, and the error
  page was raised for that. The same was then measured in an ordinary tab: a
  page at P that sets `location.href` to a dead server gets the error page for
  **P**, and Reload retries P. (WebKit's source commits the page load state,
  reverting the URL, before it calls the failure delegate; the two runs agree
  with that but did not observe the order directly.) The failed URL is in the
  error's `NSURLErrorFailingURLErrorKey`.
  `BrowserTab.didFailProvisionalNavigation` takes it from there only when the
  tab has no URL of its own (nil or `about:blank`), which covers the opened
  window; the ordinary-tab case is open as TASK-170.[^task-167]
- **An extension page's `window.open` is supplied the extension context's
  configuration** (`_requiredWebExtensionBaseURL` set; CORS checks off for the
  extension's hosts). A child built from it for a web URL carried the
  extension's base URL and never loaded the page. Detour keeps the old path
  for such an opener: a tab of the space's own that the app loads, and null
  for the extension page.[^task-167]

## Telling a popup from a tab in `createWebViewWith`

| Call | `windowFeatures._wantsPopup` |
|---|---|
| `window.open(url)` | false |
| `window.open(url, '_blank')` | false |
| `window.open(url, '_blank', 'noopener,noreferrer')` | false |
| `window.open(url, '_blank', 'width=…,height=…')` | true |
| `window.open(url, '_blank', 'popup')` | true |

`_wantsPopup` is SPI on `WKWindowFeatures` (macOS 14.2+), read with
`value(forKey:)`. It implements the HTML "is popup" check.[^notes-spike]

`navigationAction.value(forKey: "_isUserInitiated")` was true for **every**
call, including `window.open` from `evaluateJavaScript` and from a timer
inside it. It cannot be used as a user-gesture check. The KVC key
`_userInitiated` does not work at all.[^notes-spike]

## Who asked for a navigation

`decidePolicyFor` cannot tell an app-initiated load from a script
navigation:

- An app `load()` has `navigationType == .other` and reports the **current
  document** as `sourceFrame`. The origin is empty only in a fresh web
  view.[^notes-spike]
- Restoring `interactionState` arrives as `.backForward`; `reload()` as
  `.reload`.[^notes-spike]
- `sourceFrame` is imported into Swift as non-optional, yet the external-apps
  code found it nil for navigations the app started. Reading a nil through
  the typed accessor is undefined behaviour, so that code reads it with
  `value(forKey: "sourceFrame")`.[^task-84] The spike result above and this
  one do not fully agree on when it is nil; treat it as "may be nil" and
  guard.
- A server redirect keeps the navigation type of the navigation it
  interrupts (recorded in the comments of `InternalPageNavigationPolicy`; the
  sources do not say how it was checked).

## Failure callbacks

| Situation | What WebKit reports |
|---|---|
| A load superseded by another (a page that navigates itself before its first load finishes) | `NSURLErrorCancelled` for the first, then the replacement's own `didFinish` or failure |
| A download-policy interruption | `WebKitErrorDomain` 102 (`WebKitErrorFrameLoadInterruptedByPolicyChange`); Detour treats it like a superseded load |
| A standalone media URL (media document) | Commit, then `didFail` with `WebKitErrorDomain` 204 and **no** `didFinish` — see [media and picture-in-picture](./media-and-pip.md)[^task-121] |
| A response that ends short after the navigation committed (a dropped connection, a timeout) | Commit, then `didFail` with the URL error (`NSURLErrorNetworkConnectionLost`, `NSURLErrorTimedOut`); WebKit finishes the document with what arrived and `isLoading` goes false. Detour's tab delegates do not implement `didFail`, so the page stays — see [error pages](../features/error-pages.md#failures-after-commit) |
| A URL on a restricted port (`http://127.0.0.1:1/`; ports 1, 7, 9 …) | No failure at all: WebKit commits `about:blank` and calls `didFinish`[^task-122] |
| A web view with no navigation delegate | Nothing is reported to anyone; a failed load leaves `about:blank` or the previous content |

## Custom-scheme pages

Verified 2026-09-19 while designing the `detour://` pages.[^notes-spike][^task-86]

- `WKURLSchemeTask.request.mainDocumentURL` is reliable. A main-frame load
  reports its own URL; a subresource embedded in a web page reports the web
  page's URL.
- A `WKUserScript` in a named `WKContentWorld` runs even when the response's
  CSP is `default-src 'none'`. Page-world inline script is blocked by the
  same CSP.
- A handler added with `addScriptMessageHandler(_:contentWorld:name:)` is
  invisible to the page world: `window.webkit` is undefined there.
- `frameInfo.securityOrigin` for a custom scheme is `scheme://host`.
- Adding a script message handler under a name that is already registered
  throws, and a `window.open` child shares its opener's
  `userContentController`, so installation must be guarded.[^task-86]

# Why it matters here

| Rule in Detour | Depends on | Code |
|---|---|---|
| In a pinned tab or favourite, every user-activated `_blank` link opens a Peek | nil `targetFrame` arrives in `decidePolicyFor` before any new web view exists | Peek branch of `decidePolicyFor` passes `opensNewWindow: navigationAction.targetFrame == nil` to `PeekAnchor.shouldPeek` |
| A tab-style `window.open` from an anchored tab also peeks; a popup-style one (OAuth, payment) keeps its own tab | `window.open` skips `decidePolicyFor`; `_wantsPopup` | `createWebViewWith` → `PeekAnchor.shouldPeekScriptedWindow(to:wantsPopup:)`, `wantsPopup(_:)` falls back to explicit x/y/width/height when the SPI is missing |
| A page's new window is a tab whose web view WebKit asked for | the page gets a window only when the delegate returns a web view made from the supplied configuration; WebKit then does the navigation | `createWebViewWith` → `TabStore.addTab(in:openedWith:parentID:)`, which swaps in a user content controller of the space's own |
| A window an extension page opens is not a child | the supplied configuration is the extension context's | `isExtensionContextConfiguration` in `BrowserWindowController+WKUIDelegate.swift` |
| `window.close()` closes the tab and returns to the tab that opened it | `webViewDidClose(_:)` on the closing web view's UI delegate | `webViewDidClose` in `BrowserWindowController+WKUIDelegate.swift` |
| `window.open` to an internal page is refused | `createWebViewWith` is the only hook for it | `InternalPage.isInternal(url)` check at the top of `createWebViewWith` |
| An internal page loads only when the tab was armed for it, or as a revisit of an entry already in the tab's back/forward list | An app `load()` is indistinguishable from a script navigation; session restore arrives as `.backForward`; redirects keep the navigation type | `InternalPageNavigationPolicy.decision` — trust is carried out of band by `BrowserTab.loadInternalPage(_:)`, and a `.backForward`/`.reload` must name a URL that is in `sessionEntryURLs` |
| The scheme handler serves only main documents on the internal scheme | `mainDocumentURL` | `InternalPageSchemeHandler` |
| The page bridge is unreachable from web content and extensions | content-world isolation survives a no-script CSP | `InternalPageBridge.contentWorld` |
| External-app prompt names the requesting origin | `sourceFrame` may be nil | `requestingOrigin(of:)` in `BrowserWindowController+ExternalApps.swift` |
| A superseded load or a media document does not become an error page | 102 / cancelled / 204 semantics | `Error.isSupersededNavigationError`, `isPlugInHandledLoadError`, `isIgnoredNavigationError` |
| A background tab still gets commit and failure callbacks | a web view with no delegate reports nothing | `extension BrowserTab: WKNavigationDelegate`; a closing window hands the delegate back with `handBackNavigationDelegates()` |

The last row has a trap of its own. A window stays the navigation delegate of
every web view it has ever hosted, and `navigationDelegate` is a weak
reference. When that window closes, the web views it used to host have no
delegate at all unless it is handed back to the tab.[^task-122]

# Workaround

There is nothing to work around; the rule is to put each decision in the
delegate method that actually sees the event, and to keep the decision itself
in a pure function with tests (`PeekAnchor`, `InternalPageNavigationPolicy`,
`ExternalAppLaunchPolicy`, the `Error` classification helpers).

For tests that need a load to fail for real, use a loopback port that was
free a moment ago (connection refused at once). Do not use port 1: it never
fails.[^task-122]

# How to re-verify

A standalone binary answers "which delegate method fires" in about a minute,
with no app build:[^notes-spike]

1. A `main.swift` with `NSApplication.shared`, an offscreen `WKWebView`, and
   delegates that print each call with `navigationType`, `targetFrame` and
   the features.
2. `loadHTMLString(_:baseURL:)` with the markup under test, then
   `evaluateJavaScript("el.click()")`. A click made this way counts as a user
   gesture, so popups are allowed.
3. Compile with `swiftc main.swift`. In a sandboxed shell add
   `-module-cache-path $TMPDIR/mc`; the default clang module cache is not
   writable there.
4. Run the binary outside the sandbox. Inside it the web process never
   launches and the run simply times out.

The same technique measured [hidden web view load stalls](./hidden-webview-load-stalls.md)
and the [GPU IOSurface limit](./gpu-iosurface-limit.md) control run
([docs/task-104/main.swift](../../docs/task-104/main.swift) is a complete
example of such a binary).

# Tests

- [PeekAnchorTests](../../DetourTests/PeekAnchorTests.swift) — the peek-vs-tab routing for `_blank` and scripted opens.
- [PageOpenedWindowTests](../../DetourTests/PageOpenedWindowTests.swift) — page-opened windows in a real window against loopback pages: the blank-then-navigate sequence, a single load, `noopener`, a failed first load, the opener link across origins, `window.close()`; and `ExtensionPageOpenedWindowTests` in the same file for the extension-page exception.
- [InternalPageTests](../../DetourTests/InternalPageTests.swift), [InternalPageIntegrationTests](../../DetourTests/InternalPageIntegrationTests.swift) — navigation policy, scheme handler, bridge isolation.
- [NavigationErrorClassificationTests](../../DetourTests/NavigationErrorClassificationTests.swift) — the ignored and not-ignored error sets.
- [BrowserTabUnclaimedNavigationTests](../../DetourTests/BrowserTabUnclaimedNavigationTests.swift) — real failures reaching an unclaimed tab.

The Google Calendar flow itself was never exercised end to end; only the
delegate order and the `_wantsPopup` values were.[^task-85]

# Related

- [Peek](../tabs/peek.md) — the feature the new-window rules serve.
- [Internal pages](../features/internal-pages.md) — arming, the scheme handler and the bridge.
- [External apps](../features/external-apps.md) — custom-scheme navigations and the confirmation sheet.
- [Error pages](../features/error-pages.md) — what happens after a failure is classified.
- [BrowserTab](../architecture/browser-tab.md) — the tab's own delegate versus the window's.
- [BrowserWindowController](../architecture/browser-window-controller.md) — where both delegates live.
- [WebKit source lookup](./webkit-source-lookup.md) — reading the WebKit functions named above.
- [AppKit gotchas](./appkit-gotchas.md) — the companion page for AppKit behaviour.

[^task-167]: window.open() hands the page no window back, so an xterm.js terminal link opens an empty tab
[^task-168]: A sign-in popup cannot reach the page that opened it or close itself
[^spike-167]: Standalone spike — what createWebViewWith receives and what the page gets back
[^notes-spike]: WKWebView delegate spike — verified call order and custom-scheme facts
[^task-85]: Peek: target=_blank links in a pinned tab or favourite open in a Peek
[^task-86]: History page and the internal-page infrastructure
[^task-84]: Confirmation before opening external apps
[^task-121]: A standalone video URL shows the error page with "Plug-in handled load"
[^task-122]: A background tab whose load fails never shows the error page
