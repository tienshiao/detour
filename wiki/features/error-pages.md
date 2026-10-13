---
type: Feature
title: Error pages
description: "What a failed load looks like: the browser-error:// page, which failures earn one and which are ignored, how the tab keeps the URL the user asked for, and how retry, restore and background tabs behave."
tags: [navigation, errors, webkit, tabs]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-12T23:47:17Z }
sources:
  - id: scheme-handler
    resource: ../../Detour/Browser/Window/ErrorSchemeHandler.swift
    title: ErrorSchemeHandler.swift (ErrorPage, ErrorSchemeHandler)
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (didFailProvisionalNavigation, didFailNavigation, showErrorPage, reload, the tab's own WKNavigationDelegate)
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (failure forwarding, error classification)
  - id: task-45
    resource: backlog:TASK-45
    title: A failed wake of a restored ordinary tab replaces its restored session with an error page
  - id: task-121
    resource: backlog:TASK-121
    title: A tab showing a standalone video shows the error page with "Plug-in handled load"
  - id: task-122
    resource: backlog:TASK-122
    title: A background (unowned) tab whose load fails never shows the error page
  - id: classification-tests
    resource: ../../DetourTests/NavigationErrorClassificationTests.swift
    title: NavigationErrorClassificationTests.swift
  - id: unclaimed-tests
    resource: ../../DetourTests/BrowserTabUnclaimedNavigationTests.swift
    title: BrowserTabUnclaimedNavigationTests.swift
  - id: wake-tests
    resource: ../../DetourTests/BrowserTabWakeTests.swift
    title: BrowserTabWakeTests.swift
---

# What it does

When a navigation fails, the tab's web view is sent to
`browser-error://error?failedURL=…&message=…`, a static page that shows
"Looks like you took a Detour.", the failed URL and the error's localised
description. The sidebar and the faux address bar keep showing the URL the
user asked for, and Reload retries it.

# How it works

## The page

`ErrorPage.url(for:error:)` builds the URL; `ErrorPage.originalURL(from:)`
reads `failedURL` back. `ErrorSchemeHandler`, registered for the scheme on
every tab configuration in `BrowserTab.makeWebView`, renders inline HTML and
CSS with both values HTML-escaped. The document's `<title>` is the failed URL
without its `http(s)://` prefix, which is what the tab row then shows. The
page has no script and no bridge: unlike [internal pages](./internal-pages.md)
it is not privileged, and web content can navigate to it.

## Who decides

The decision is the **tab's**, whichever navigation delegate reported the
failure. Both delegates are pure forwarders:

| Web view state | Delegate | Calls |
|---|---|---|
| owned by a window | `BrowserWindowController` | `tab(owning:)?.didFailProvisionalNavigation(error:)` / `didFailNavigation(error:)` |
| never claimed, or its window closed | the `BrowserTab` itself | the same two methods |

`BrowserTab.didFailProvisionalNavigation(error:)`:

1. ignored error - return;
2. `restoringSession` is set - return (the restored session is kept);
3. otherwise `showErrorPage(for: lastAttemptedURL, error:)`.

`didFailNavigation(error:)` (a failure after commit) skips ignored errors and
shows the page for `webView.url ?? lastAttemptedURL`.

`showErrorPage` sets `tab.url` to the failed URL, clears the favicon, bumps
`faviconGeneration`, resets `previousHost`, and loads the error URL.

## Which errors are ignored

Defined once, as an extension on `Error` in
`BrowserWindowController+Navigation.swift`:

| Predicate | Errors | Meaning |
|---|---|---|
| `isSupersededNavigationError` | `WebKitErrorDomain` 102 (frame load interrupted by a policy change, e.g. a download); `NSURLErrorCancelled` | the load was replaced; **another callback follows** |
| `isPlugInHandledLoadError` | `WebKitErrorDomain` 204 | a media document whose player took over the load; the page is committed and playing, and **no `didFinish` follows** |
| `isIgnoredNavigationError` | either | no error page |

The two are separate on purpose. Code that waits for a navigation to *end*
must use `isSupersededNavigationError` alone: a 204 is the end of the
navigation, and treating it as "keep waiting" hangs. `OffscreenDocumentHost`
relies on that distinction.[^task-121]

The 204 case was found on a standalone `.mp4` URL: within four seconds of
loading, an owned tab switched to an error page reading "Plug-in handled
load". WebKit's `WebLocalFrameLoaderClient::committedLoad` cancels a
`MediaDocument`'s main-resource load with that error right after commit, and
its own `shouldFallBack` treats it like a cancellation.[^task-121] See
[media and PiP](../platform/media-and-pip.md).

## Keeping the error URL out of the tab's state

The error document must never become "the page this tab is showing":

- The `webView.url` observer returns early for the error scheme, so `tab.url`
  and `lastAttemptedURL` keep naming the page that failed.
- `didCommit` (both delegates) returns early for the error scheme, so
  `didCommitNavigation()` does not clear `navigationPending` or reset state
  for it.
- The history recorder returns when the web view shows the error scheme, and
  the title-correction policy requires `webView.url == tab.url`. Otherwise a
  failed load would record a visit for a page that never loaded, titled by the
  error page, or rename the real row. See
  [history recording and search](./history-recording-and-search.md).
- The favicon link bridge and the end-of-load favicon lookup both skip it.

## Retry

`BrowserTab.reload()`:

| State | Action |
|---|---|
| web view shows the error page, `lastAttemptedURL` known | `loadRecordedURL(lastAttemptedURL)` |
| web view shows the error page, nothing recorded | plain `load(_:)` of the `failedURL` from the error URL. Untrusted: any page can navigate to an error URL naming any `failedURL`, so it does not get to arm an internal page |
| web view shows nothing (no URL, or `about:blank` after a failed restore) | `loadRecordedURL(lastAttemptedURL ?? url)` |
| otherwise | `webView.reload()` |

Going **back or forward into** an error entry does not show the stale error
page: the window's `decidePolicy` cancels the `.backForward` navigation and
loads the original URL again.

# Edge cases

- **Restored sessions (TASK-45).** `wake()` hands a fresh web view the tab's
  cached interaction state and sets `restoringSession` until a navigation
  commits, a user load replaces the session, or the web view is released.
  While it is set a provisional failure keeps the session, the persisted title
  and the favicon: nothing was asked for, the load that failed is the restore
  itself. WebKit falls back to `about:blank` after such a failure, and that is
  kept out of `tab.url` and the retry target. `reload()` clears the flag, so a
  failing retry *does* show the error page. See
  [sleeping and archiving](../tabs/sleeping-and-archiving.md).
- **The stalled-load kick is not a user navigation.** `loadIfStalled()`
  re-issues the tab's URL without touching `lastAttemptedURL` or
  `navigationPending`, so a restore whose kick fails offline is kept rather
  than replaced by an error page.
- **Background tabs (TASK-122).** Before the tab's own delegate implemented
  the two failure callbacks, a failing load in a never-shown tab sat silently
  and selecting the tab later did not surface it.
- **Closed windows.** A window stays the navigation delegate of every web view
  it ever hosted; nothing clears it on a tab switch, and `tab(owning:)` relies
  on that. The reference is weak, so after the window closed those web views
  had no delegate at all. `windowWillClose` calls
  `handBackNavigationDelegates()`, which gives each such web view back to its
  tab.[^task-122]
- **Restricted ports never fail.** `http://127.0.0.1:1/` produces no failure
  callback: port 1 is on WebKit's restricted-port list and it silently commits
  `about:blank` with `didFinish`. Such a URL shows no error page at all, owned
  or not, and it is not a usable "connection refused" fixture.[^task-122]
- **Crashed web content process.** Not an error page:
  `webViewWebContentProcessDidTerminate` reloads the tab, at most twice in a
  row (`noteProcessTermination`); past the cap the pane stays blank until a
  manual reload. A process the tab replaced because it was not answering a
  load is not counted
  ([unresponsive web process](../platform/unresponsive-web-process.md)).
- **Back/forward re-attempt targets the selected tab.** The branch calls
  `selectedTab?.load(originalURL)` rather than resolving the tab from the web
  view that fired. Read from the code; the case of an unfocused split pane
  going back into an error entry was not checked.

# Tests

- `NavigationErrorClassificationTests` - the ignored set (102, 204,
  `NSURLErrorCancelled`), the non-ignored cases (cannot connect, WebKit 101,
  code 204 in another domain), and that 204 is not "superseded".
- `BrowserTabUnclaimedNavigationTests` - a real refused connection on a
  just-freed loopback port shows the error page in an unowned tab; a
  superseded load shows none; a failed restore keeps its session.
  Mutation-checked: each test fails without the code it covers.[^task-122]
- `BrowserTabWakeTests` - a failed wake keeps session, title and favicon;
  reload after it retries; a commit ends the protection; a failed *user* load
  still shows the error page.
- Runtime check for 204: with the fix a `.mp4` tab's `webView.url` stays on
  `https://` through load and reload; without it the URL became
  `browser-error://…Plug-in%20handled%20load` within 4 s.[^task-121]

# Related

- [Internal pages](./internal-pages.md) - the privileged scheme, and why an error page's `failedURL` is not trusted.
- [BrowserTab](../architecture/browser-tab.md) - `lastAttemptedURL`, `navigationPending`, `restoringSession` and the tab's own delegate.
- [Sleeping and archiving](../tabs/sleeping-and-archiving.md) - wake, and what a failed wake keeps.
- [Media and PiP](../platform/media-and-pip.md) - the media-document 204.
- [Offscreen documents](../extensions/offscreen-documents.md) - the other consumer of the superseded/plug-in distinction.
- [Web view ownership](../architecture/webview-ownership.md) - which delegate a web view has at any moment.

[^task-121]: A tab showing a standalone video shows the error page with "Plug-in handled load"
[^task-122]: A background (unowned) tab whose load fails never shows the error page
