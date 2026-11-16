---
type: Feature
title: Error pages
description: "What a failed load looks like: the browser-error:// page, which failures earn one (only those before commit) and which are ignored, how the tab keeps the URL the user asked for, and how retry, restore and background tabs behave."
tags: [navigation, errors, webkit, tabs]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T12:00:00Z }
sources:
  - id: scheme-handler
    resource: ../../Detour/Browser/Window/ErrorSchemeHandler.swift
    title: ErrorSchemeHandler.swift (ErrorPage, ErrorSchemeHandler)
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (didFailProvisionalNavigation, showErrorPage, reload, the tab's own WKNavigationDelegate)
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
  - id: task-170
    resource: backlog:TASK-170
    title: When a page-started navigation fails, the error page names the page the tab was on, and Reload goes back to it
  - id: task-178
    resource: backlog:TASK-178
    title: A load that fails after the page committed replaces the working page with the full error page
  - id: task-372
    resource: backlog:TASK-372
    title: "Error page: a failed in-page navigation names the previous page's URL, so Reload goes back instead of retrying"
  - id: task-372-patch
    resource: ../../docs/harness/task372/provisional-url-fallback.patch
    title: The parked TASK-372 fix, its tests and the two wake probes
  - id: task-381
    resource: backlog:TASK-381
    title: "Extensions: a web page can make a tab load an extension's non-web-accessible page (window.open, then sleep/wake or Reload)"
  - id: navigation-failure-tests
    resource: ../../DetourTests/NavigationFailureURLTests.swift
    title: NavigationFailureURLTests.swift
  - id: committed-tests
    resource: ../../DetourTests/CommittedLoadFailureTests.swift
    title: CommittedLoadFailureTests.swift
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

When a navigation fails before anything committed, the tab's web view is sent to
`browser-error://error?failedURL=…&message=…`, a static page that shows
"Looks like you took a Detour.", the failed URL and the error's localised
description. The sidebar and the faux address bar show the URL that failed,
and Reload retries it. A failure after commit shows nothing: the document
that committed stays on screen.

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
| owned by a window | `BrowserWindowController` | `tab(owning:)?.didFailProvisionalNavigation(error:)` |
| a [Quick Detour](./quick-detour.md) window's page | `QuickDetourWindowController` | `page.didFailProvisionalNavigation(error:)` |
| never claimed, or its window closed | the `BrowserTab` itself | the same method |

`BrowserTab.didFailProvisionalNavigation(error:)`:

1. ignored error - return;
2. `restoringSession` is set - return (the restored session is kept);
3. the error's `NSURLErrorFailingURLErrorKey`, when it has one (not
   `about:blank`, the error scheme or an internal `detour://` URL), becomes
   `lastAttemptedURL`. Not an internal URL because Reload passes
   `lastAttemptedURL` to `loadRecordedURL`, which arms it: a failing internal
   URL the tab did not load itself is one a page chose;
4. `showErrorPage(for: lastAttemptedURL, error:)`.

**The URL that failed** (TASK-170).[^task-170] Step 3 is what makes the
error page, `tab.url` and Reload name the right URL:

| Navigation | Without step 3 | With it |
|---|---|---|
| Started by the page (a script's `location` change, a clicked link) | The page the tab was on: such a navigation reaches the tab only through the `webView.url` observer, and WebKit sets the web view's URL back to the committed page *before* it reports the failure, so the observer had already overwritten `lastAttemptedURL` | The target |
| Started by the tab (`load`) and redirected to a host that fails | What was asked for (the typed URL) | The redirect's target: the user's decision of 2026-10-28, as Chrome and Safari do; the error is about the host that is down, and Reload retries it directly |
| A window a page opened (no URL of its own, TASK-167) | Nothing to name | The target, as before |
| Started by the tab, not redirected | The URL asked for | The same URL |

Rejected: using the failing URL only when the tab has no URL of its own
(TASK-167's first version); it left the first two rows wrong.

**When the error names no URL** (TASK-372).[^task-372] Step 3 needs
`NSURLErrorFailingURLErrorKey`. Every network failure measured carries it
(script, link and `tabs.update` to a refused loopback port all name the
target), but WebKit's extension scheme handler refuses a main-frame
`webkit-extension://` load in a web view not built from that extension's
configuration with an `NSError` whose `userInfo` is nil (-1008; see
[extension pages](../extensions/extension-pages.md#where-an-extension-page-cannot-be)).
WebKit adds only `_WKRecoveryAttempterErrorKey`, so a page that navigates to
such a page, by script, link or `tabs.update`, gets an error page naming the
page it was on, and Reload goes back there. Measured 2026-11-16.

The fix is parked, not applied:
[docs/harness/task372/provisional-url-fallback.patch](../../docs/harness/task372/provisional-url-fallback.patch)
records `webView.url` at `didStartProvisionalNavigation` (already the target
there), clears it on commit and uses it when the error has no failing URL. Its
five tests fail without it and pass with it. It was held back because adopting a
refused extension URL made it the tab's URL, and **`wakeConfiguration` builds
a tab whose URL is an extension page from that extension's own
configuration**: after the tab slept and woke, Reload loaded the page WebKit
refused, a non-web-accessible one included (`options.html`, measured with the
patch's probe B).

Since TASK-381 an extension URL the tab's web view cannot serve never becomes
`url` ([extension pages](../extensions/extension-pages.md#only-a-servable-page-becomes-the-tabs-url)).
`showErrorPage` names it but leaves `url` alone.[^task-381] With the patch
applied on top (2026-11-16):

- the error page names the refused page;
- `url` stays on the page the tab was on;
- probes A and B end on the error page after sleep, wake and Reload;
- the patch's five tests then fail only on their `tab.url == refused URL`
  assertion, which has to become "unchanged".

Neither delegate implements `webView(_:didFail:withError:)`, the failure of
a navigation that already committed. See
[Failures after commit](#failures-after-commit).

`showErrorPage` sets `tab.url` to the failed URL (unless it is an extension
page the web view cannot show, TASK-381), clears the favicon, bumps
`faviconGeneration`, resets `previousFaviconSite`, and loads the error URL.

## Failures after commit

A committed navigation has a document on screen, so its failure is not a
request that produced no page, and the error page would replace something the
user is looking at. WebKit finishes the document with what arrived
(`didFinishDocumentLoad` follows the failure), `isLoading` goes false and the
tab's URL, title and favicon stay as they were.

Found on a YouTube Short (2026-10-12): the navigation committed in 0.4 s and
the video played, but the HTML response itself never finished. 62 s after
commit the main resource timed out (`NSURLErrorTimedOut`), WebKit reported
`didFailLoadForFrame` for the main frame, and the tab loaded the error page
over the playing video in the same millisecond.[^task-178] Why the response
stalled is not known.

Rejected:

- **An error page only when the committed document is empty.** A response
  that commits and dies before anything rendered leaves a blank page with no
  explanation. Telling that case apart needs an asynchronous look into the
  document after the failure, and the other browsers show the partial
  document too. Not built; nothing reported it.
- **Ignoring only timeouts after commit.** A dropped connection
  (`NSURLErrorNetworkConnectionLost`) over a rendered page is the same case.

## Which errors are ignored

Defined once, as an extension on `Error` in
`BrowserWindowController+Navigation.swift`:

| Predicate | Errors | Meaning |
|---|---|---|
| `isSupersededNavigationError` | `WebKitErrorDomain` 102 (frame load interrupted by a policy change, e.g. a download); `NSURLErrorCancelled` | the load was replaced; **another callback follows** |
| `isPlugInHandledLoadError` | `WebKitErrorDomain` 204 | a media document whose player took over the load; the page is committed and playing, and **no `didFinish` follows** |
| `isIgnoredNavigationError` | either | no error page |

The 204 arrives after commit, so since TASK-178 it could not raise an error
page anyway; the predicate still covers it for a caller that sees both kinds
of failure.

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
| otherwise | `issue(.reload)`: `webView.reload()`, in a fresh web process if this one is known not to be answering ([unresponsive web process](../platform/unresponsive-web-process.md)) |

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
  the provisional failure callback, a failing load in a never-shown tab sat
  silently and selecting the tab later did not surface it.
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
  row (`noteProcessTermination`; terminations more than 30 s apart start a
  new count); past the cap the pane stays blank until a
  manual reload. A process the tab replaced because it was not answering a
  load is not counted
  ([unresponsive web process](../platform/unresponsive-web-process.md)).
- **A `window.open` child refused an extension page.** Before TASK-381 it
  kept the extension URL: the child has no committed page, so the URL
  observer's provisional URL stayed `lastAttemptedURL` and `tab.url` through
  the failure. After `sleep(force:)` and `wake()` the tab was rebuilt from
  the extension's configuration and Reload loaded the page, `options.html`
  included (measured 2026-11-16 with probe A).[^task-372] Now the error page
  names the URL and `tab.url` stays nil. Reload retries the URL and is
  refused again, before and after a sleep and after a relaunch.[^task-381]
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
- `CommittedLoadFailureTests` - a server sends the start of a page under a
  `Content-Length` it never honours and then closes the connection; the tab
  stays on the page with its URL, title and favicon, both unowned and as a
  window's selected tab. Both fail without the fix.[^task-178]
- `NavigationFailureURLTests` - against a just-freed loopback port: a
  script's location change and a clicked link in a window's selected tab, a
  location change in an unowned tab, a typed URL redirecting to the dead
  host, a typed dead URL, and Reload after the failure; all but the last
  typed case fail without step 3.[^task-170] Since TASK-372 also
  `tabs.update` (`loadURL(_:for:)`) to the dead host, which passes on the
  same code. The parked patch adds the refused-extension-page cases.
- `BrowserTabWakeTests` - a failed wake keeps session, title and favicon;
  reload after it retries; a commit ends the protection; a failed *user* load
  still shows the error page.
- Runtime check for 204 (before TASK-178 removed the committed-failure
  handler): with the 204 ignored a `.mp4` tab's `webView.url` stayed on
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
[^task-178]: TASK-178, from the unified log of the affected process
[^task-372]: Error page: a failed in-page navigation names the previous page's URL, so Reload goes back instead of retrying
[^task-381]: Extensions: a web page can make a tab load an extension's non-web-accessible page (window.open, then sleep/wake or Reload)
[^task-170]: When a page-started navigation fails, the error page names the page the tab was on, and Reload goes back to it
