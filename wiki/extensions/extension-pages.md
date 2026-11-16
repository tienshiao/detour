---
type: Concept
title: Extension pages in tabs
description: A tab showing a webkit-extension:// page is tied to one loaded context's origin, which dies on every context reload and every relaunch; how such tabs, pinned tiles, favourites and closed-tab records are rehomed, restored, refused or closed, and why a Quick Detour or quarantine window cannot show one.
tags: [extensions, tabs, persistence, pinned, favorites]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T18:40:00Z }
sources:
  - id: page-url
    resource: ../../Detour/Extensions/Runtime/ExtensionPageURL.swift
    title: ExtensionPageURL.swift
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (retargetExtensionPages, pendingExtensionOrigins, resolvePendingExtensionPages)
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (retarget, wake, wakeConfiguration)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (addExtensionTab, makeTab(loading:), restoredTab, rehomedTileURL)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (closePagesOfUnloadedExtension, install)
  - id: refusal
    resource: ../../Detour/Browser/DormantTileRefusal.swift
    title: DormantTileRefusal.swift
  - id: task-14
    resource: backlog:TASK-14
    title: Reload or close open extension pages when their context is reloaded
  - id: task-24
    resource: backlog:TASK-24
    title: Give extension-page tabs a durable identity so they survive a relaunch
  - id: task-28
    resource: backlog:TASK-28
    title: Undoing the close of an extension page tab restores a dead page
  - id: task-30
    resource: backlog:TASK-30
    title: Undo of Delete Tab must rehome extension page URLs
  - id: task-34
    resource: backlog:TASK-34
    title: Moving an extension-page favourite must give a loadable tab
  - id: task-37
    resource: backlog:TASK-37
    title: Activating a dormant pinned entry of a disabled or uninstalled extension gives a dead tab
  - id: task-38
    resource: backlog:TASK-38
    title: Move to Space loses extension pages
  - id: rehost-tests
    resource: ../../DetourTests/ExtensionPageRehostTests.swift
    title: ExtensionPageRehostTests
  - id: persistence-tests
    resource: ../../DetourTests/ExtensionPagePersistenceTests.swift
    title: ExtensionPagePersistenceTests
  - id: webkit-scheme-handler
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionURLSchemeHandlerCocoa.mm
    title: WebKit, WebExtensionURLSchemeHandlerCocoa.mm (main-frame loads need the configuration's requiredWebExtensionBaseURL)
  - id: task-381
    resource: backlog:TASK-381
    title: "Extensions: a web page can make a tab load an extension's non-web-accessible page (window.open, then sleep/wake or Reload)"
  - id: provenance-tests
    resource: ../../DetourTests/ExtensionPageProvenanceTests.swift
    title: ExtensionPageProvenanceTests
  - id: task-382
    resource: backlog:TASK-382
    title: "Extensions: a web page in a tab built from an extension's configuration can navigate to that extension's private pages"
  - id: webkit-navigation-state
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/NavigationState.mm
    title: WebKit, NavigationState.mm (isUnsupportedWebExtensionNavigation)
  - id: navigation-policy
    resource: ../../Detour/Extensions/Runtime/ExtensionPageNavigationPolicy.swift
    title: ExtensionPageNavigationPolicy.swift
  - id: navigation-policy-tests
    resource: ../../DetourTests/ExtensionPageNavigationPolicyTests.swift
    title: ExtensionPageNavigationPolicyTests
  - id: task-352
    resource: backlog:TASK-352
    title: "Extensions: reloading or updating an extension leaves its page in a Quick Detour window on the dead origin"
  - id: task-373
    resource: backlog:TASK-373
    title: "Tests: guard that a Quick Detour window still cannot show an extension page"
  - id: gate-tests
    resource: ../../DetourTests/QuickDetourExtensionPageGateTests.swift
    title: QuickDetourExtensionPageGateTests
---

An extension's own pages (options, a full-page UI, anything opened with
`tabs.create(chrome.runtime.getURL(…))`) can live in ordinary tabs, pinned
entries and favourites. Their URLs are `webkit-extension://<UUID>/path`, and
that UUID names one *loaded context*, not the extension. Every rule on this
page follows from the origin being short-lived.

# Summary

- A `webkit-extension://` page can load only in a web view built from the
  serving context's `webViewConfiguration`. Every web view on the profile's
  controller has WebKit's handler for the scheme, but the handler refuses a
  main-frame load unless the configuration's `_requiredWebExtensionBaseURL` is
  that extension's, which only the context's own configuration sets
  ([below](#where-an-extension-page-cannot-be)).
  `TabStore.addExtensionTab(in:url:configuration:)` takes that configuration
  for this reason.
- WebKit gives each loaded context a fresh base URL. The origin dies when the
  context is unloaded: on a background-recovery reload, an update, a
  disable → enable, and at every quit. (Its IndexedDB and `localStorage` move
  to the next origin; see [storage](./storage.md).)
- A page left on a dead origin is dead twice over. Its native `chrome.*`
  bindings went with the old context, and the
  [polyfill bridge](./polyfill-layer.md) rejects it because the origin
  resolves to no loaded context.
- So the durable identity of an extension page is **(extension id, path)**,
  not its URL.
- A tab's `url` names an extension page only if the tab's web view can show
  it, or the tab is asleep on one that such a web view showed. Everything
  that trusts an extension URL is built from `url`: wake, the save, closed-tab
  records, tiles and rehoming. So a page a web page chose never reaches the
  extension's configuration
  ([below](#only-a-servable-page-becomes-the-tabs-url)).
- A tab built from an extension's configuration never leaves that extension
  in its main frame: WebKit ignores the navigation. Web content can only be
  in its frames, and a frame that is not the extension's may not send the tab
  to the extension's pages
  ([below](#web-content-inside-an-extensions-tab)).

# Rules

## A context reload rehomes open pages

`Profile.retargetExtensionPages(from:to:)` moves every page on the old origin
onto the new one:

1. Find the pages (`extensionPageLocations`). A page can be in four places: a
   space's tabs, a pinned entry's tab, a favourite's backing tab, a Peek.
   The walk leaves out the [Quick Detour](../features/quick-detour.md) and
   quarantine pages (`TabStore.quickDetourTabs`) because they cannot show an
   extension page ([below](#where-an-extension-page-cannot-be)). Reaching one
   in the future would mean more than adding a case: the walk, the
   disable/uninstall close (`closePagesOfUnloadedExtension`), `wakeConfiguration`
   (which finds the context through the tab's space) and the window's re-host
   on `.spaceTabsNeedRehost` would all need a Quick Detour answer.[^task-352]
2. Rewrite each URL with `rewriteExtensionPageURL`, which carries path, query
   and fragment over in their percent-encoded form. An extension page's query
   often holds a URL of its own, and decoding then re-encoding would change it.
3. `BrowserTab.retarget(to:)`: release the web view, **discard** the cached
   interaction state (restoring it would put the tab back on the dead URL),
   leave the tab sleeping on the new URL.
4. Rewrite the stored `pinnedURL` / favourite `url` too, dormant or not: they
   are what a later activation loads.
5. Post `.spaceTabsNeedRehost` with the affected tab ids, on the *next*
   main-queue turn. Each window re-selects its displayed tab, and the normal
   display path (`claimWebView` → `wakeIfNeeded` → `wake`) rebuilds it.

The existing web view is not navigated, because it was built from the old
context's configuration and cannot load the new origin at all. Dropping it and
letting `wake` rebuild also makes the path correct for a tab whose web view
another window owns, or none
([WebView ownership](../architecture/webview-ownership.md)).

Title and favicon are deliberately kept. This is the same page coming back
from a new internal origin; clearing them would flash a raw
`webkit-extension://<uuid>/…` title and drop an icon that lives at an extension
URL and could not be fetched again.

The deferred notification is what makes each rehosted tab **announced once**.
The caller reloads the context and then announces the profile's live tabs to
it; a synchronous post would wake the displayed tab first, announcing it from
`wake()` and again from the sweep
([Tab and window bridge](./tab-and-window-bridge.md)).

## Only a servable page becomes the tab's URL

Added in TASK-381 (2026-11-16).[^task-381] `BrowserTab.servedExtensionOriginHost` is the origin host of
the context whose `webViewConfiguration` built the tab's current web view.
Only two places set it: `wake`, from the context that `wakeConfiguration`
picked, and `TabStore.addExtensionTab(in:url:context:)`, from the calling
context. It is nil for every other web view and while the tab sleeps.
`BrowserTab.mayAdopt` lets an extension URL become `url` only from that host,
which is exactly WebKit's main-frame gate
([below](#where-an-extension-page-cannot-be)). Every write of `url` on a tab
that has a web view goes through it:

- the URL observer;
- `load(_:)`;
- `showErrorPage`;
- `init(webView:)`;
- `restoreArchivedPage`.

The sleeping writes are trusted because what they carry came from `url`:
the sleeping init (restore, records, tiles) and `retarget`.

`currentPageURL` is the web view's URL when it may be adopted, else `url`.
`showsExtensionPage`, the rehoming walk, `existingOptionsPageTab`, and a
peek's saved and moved URL (`savePeekStateForPersistence`, `planMove`) read
it instead of `webView?.url ?? url`. The provisional URL of a refused load
lingers in `webView.url`: until the error page loads, and for good in a
window a page opened. A context reload would otherwise have retargeted that
URL onto the live origin.

**Why.** Before this, a refused URL stayed in `url`, and `wakeConfiguration`
trusts `url`. A web page's `window.open('webkit-extension://<id>/options.html')`
ended on an error page, but after a sleep and Reload the tab loaded
`options.html` in the extension's configuration. That page is not
web-accessible, and it ran with the extension's privileges. The same held
for:

- a page-chosen URL the app loads itself (`load(_:)`: Open Link in New Tab, a
  routed link);
- `tabs.create` with *another* extension's URL, built from the caller's
  configuration;
- a relaunch: the save stamps `extensionID` from `url`, so the restore
  rehomed the tab onto the new origin.

A page navigating *itself* was safe on main, because WebKit sets the web view
back to the committed page before the failure. TASK-372's fix, which names
the refused URL in that case, landed after this rule, so it does not widen
the hole.

**What the tab shows instead** (the user's decision, 2026-11-16, TASK-372):

- The error page names the refused URL, including when a page navigated
  itself (the error names no URL; the tab takes it from the navigation's
  start).
- `url` stays on the page the tab was on, and Reload loads that page. A
  `window.open` child has no such page: its `url` stays nil, it is saved and
  restored that way, and its Reload tries the refused URL again, which the
  unchanged configuration refuses again. See
  [error pages](../features/error-pages.md#who-decides).

**Rejected.**

- *A provenance flag checked at wake, persisted in a new column.* It would
  have to be carried through every record type: closed tabs, the undos,
  pinned entries, favourites, Move to Space. The `extensionID` column already
  plays that part once `url` is clean, because it is stamped from `url`.
- *Reading `_requiredWebExtensionBaseURL` from `webView.configuration`.* It
  is SPI. The tracked host is set only where Detour builds the web view, so
  it fails safe.

**Not covered.**

- The live route through a tab built from extension A's configuration was
  filed here as "the tab navigates to a web page, which then navigates it to
  A's pages". Measured in TASK-382, the tab cannot get to a web page; the
  route that is real goes through a web frame in A's page, and is closed
  ([below](#web-content-inside-an-extensions-tab)).
- Rows saved before the fix that already hold a refused URL cannot be told
  apart, so they are grandfathered.
- An extension page's own `window.open` of its own page still opens a space
  tab, which is refused (TASK-167's rule). The same goes for `tabs.update`
  from an extension to its own page in a web tab. Both used to start working
  after a sleep. Now they never do.

## Web content inside an extension's tab

Added in TASK-382 (2026-11-16): the gate is read from WebKit `main`, and the
results were measured in XCTest and in the running app (macOS 26.7).[^task-382]

**The main frame stays on the extension.** In a web view whose configuration
carries `_requiredWebExtensionBaseURL`, WebKit ignores every main-frame
navigation whose URL is not that extension's
(`isUnsupportedWebExtensionNavigation`).[^webkit-navigation-state] It does
this *after* the navigation delegate has answered `.allow`, and reports
nothing: no provisional load, no failure, no request.

Measured on a tab from `addExtensionTab` and on a plain `WKWebView` from
`context.webViewConfiguration`:

- a link in the options page to a loopback page;
- `location.href` from the options page;
- `webView.load` of the page, and `open_url` with `in_place` through the
  endpoint.

The server saw no request for the page. The only request was Detour's own
`/favicon.ico` guess for the in-place load. The tab stayed on `options.html`.
So no web page is ever the main frame of such a tab, and the tab's own
`window.open` children are space tabs
([`isExtensionContextConfiguration`](../platform/wkwebview-delegate-order.md)).

**Its frames can hold web content, and a frame can steer the top.** A
subframe navigation is exempt from that gate. When the extension's page
embeds a loopback frame, the frame's `top.location =
'webkit-extension://<ext>/other.html'` (`other.html` not web-accessible, no
user gesture) loaded `other.html` into the tab, with the extension's
privileges. WebKit's scheme handler serves it as a main frame in the
extension's own configuration. A script-clicked `target=_top` link in the
frame arrived instead with no target frame: it went the new-window way and
ended as a space tab on the -1008 error page.

**The rule** (`ExtensionPageNavigationPolicy`[^navigation-policy]). Both
navigation delegates apply it through `BrowserTab.authorizesNavigation`: the
window's for a web view it has claimed, the tab's own otherwise. A main-frame
navigation to a page of the extension that built the tab's web view
(`servedExtensionOriginHost`) goes ahead only in these cases:

- The requesting frame (`navigationAction.sourceFrame`) has that extension's
  origin. That covers its links, its scripts and Back from its page. It also
  covers an app load while the extension's page is on screen, such as
  `tabs.update` or Reload, because an app load reports the main frame as its
  source.
- The requesting frame is the main frame holding one of Detour's own
  documents: the initial `about:blank` (an empty origin) of the web view that
  `wake` or `addExtensionTab` loads, or the error page.
- No frame is named at all.

Anything else is cancelled, with a `navigation-policy` log line and no error
page: a web frame, an opaque frame (sandboxed or `data:`), another
extension's frame, and a main frame holding a web page, should WebKit's gate
ever go. `sourceFrame` is read by KVC (`WKNavigationAction.requestingFrame`),
because it is imported as non-optional yet can be nil for an app load. When
the window's delegate gets an extension-page navigation in a web view that
belongs to no tab, it applies the rule as if that web view served the page's
extension.

The rule refuses a web frame even when the target page is web-accessible.
This is Claude's choice, not yet confirmed by the user. A web page in a
space tab cannot top-navigate to one either, because WebKit refuses the main
frame (-1008, [below](#where-an-extension-page-cannot-be)), so the rule keeps
the two kinds of tab alike. The alternative is to let through targets that
the extension's `web_accessible_resources` match for the frame's origin.
That would serve, for example, a framed sign-in page that hands back to the
extension's callback page.

**Not touched.**

- Another extension's page in such a tab is still refused by WebKit, and the
  error page names it (TASK-372).
- A tab no context built is not this rule's business.
- Subframe loads are left to the scheme handler, which serves a subframe only
  web-accessible pages or pages framed by the extension itself.
- Back and forward started by a web frame (`top.history.back()`) were not
  measured. If WebKit names the main frame as the requester, they pass, but
  they can only reach pages the tab has already shown.
- A Cmd-click on a `target=_top` link to the extension's page, inside a web
  frame, now does nothing. Before, it opened a space tab, which WebKit then
  refused.

**Rejected.**

- *Moving the tab to a web configuration when it leaves the extension's
  origin.* The tab never leaves: WebKit drops the navigation. A replacement
  web view would also lose the back/forward list, because WebKit cannot swap
  a live web view's configuration.
- *Arming Detour's loads, as `InternalPageNavigationPolicy` does.* An app
  load already names the extension's page or one of Detour's documents as its
  source, because no web page is ever the main frame. Arming would have to
  thread through `addExtensionTab`, `wake`, `tabs.update` and Reload for no
  gain.

## Waking resolves the owning context

`BrowserTab.wakeConfiguration` picks the configuration by the URL's origin
host: the loaded context whose base URL has that host, else the space's
configuration. Before this rule any slept extension tab woke into the space
configuration and came back dead.[^task-14]

## Disable and uninstall close pages

There is no replacement origin, so the pages are closed, through `TabStore`
so selection, split groups and the sidebar stay consistent
(`closePagesOfUnloadedExtension`):

- a tab is closed; a pinned entry or favourite keeps its tile, dormant;
- the close is **not undoable** and writes no closed-tab record;
- a *disable* keeps the origin registered as pending, so the dormant tiles
  keep their identity and a re-enable moves them;
- an *uninstall* forgets the origins; the next restore drops those tiles;
- an install over an existing extension closes pages in any profile that got
  no replacement context.

## Persistence carries the extension id

Migration v8 added a nullable `extensionID` column to `tab`, `pinnedTab`,
`favorite` and `closedTab`. The URL column already holds the path.

At save, the id comes from `Profile.extensionID(forPageURL:)`: the loaded
context claiming the URL's host, else `pendingExtensionOrigins`. No tab
carries an identity property; a tab that navigates away simply stops matching.

At restore, `classifyPersistedExtensionPage` decides:

| Class | Meaning | Open tab | Pinned entry, favourite | Closed-tab record |
|---|---|---|---|---|
| `.notExtensionPage` | Ordinary URL | As always | As always | As always |
| `.restorable` | Installed and enabled in the profile | Restored sleeping, without interaction state | Kept | Kept |
| `.disabled` | Installed, not enabled there | Dropped | Kept dormant | Kept, skipped by Reopen |
| `.unavailable` | Not installed, or no id | Dropped | Dropped | Deleted when a Reopen scan reaches it |

A row saved before ids were recorded got the sentinel
`ExtensionPageURL.unknownExtensionID` from the migration's back-fill. It
classifies as `.disabled`, so an upgrade did not silently delete every
extension-page pin the user had. Nothing ever enables that id.

## Pending origins

Contexts load asynchronously, always after `TabStore.restoreSession`
([ExtensionManager](./extension-manager.md)). Restore therefore cannot rewrite
URLs. It leaves kept pages sleeping on the dead origin and records
`pendingExtensionOrigins[deadHost] = extensionID`.

`Profile.resolvePendingExtensionPages` runs right after contexts load (launch,
enable, install), before tabs are announced. It is `retargetExtensionPages`
with the pending origin as the old base, so it covers every container.

Until then:

- `BrowserTab.wake` on a pending origin builds the web view but loads nothing
  (`isAwaitingExtensionContext`). A load into the fallback configuration would
  only produce an error page.
- A save still writes the extension id, from the pending map, so quitting
  before contexts load loses nothing.

## Rebuilding from captured state

Reopen Closed Tab, the close undos, Delete Space and Delete Tab undos
([browser undo](../architecture/browser-undo.md)) all
rebuild from something captured earlier. They capture the extension id at
close time and go through `TabStore.restoredTab` / `rehomedTileURL`:

- an enabled extension's page comes back **sleeping** on the live origin (or
  on a pending one), without its interaction state;
- a disabled or uninstalled extension's page yields no tab. A single undo then
  does nothing, registers no redo, and leaves the record.

`TabStore.makeTab(loading:)` is the one constructor for a tile that has no web
view yet. It creates an extension page sleeping, so `wake` resolves the right
configuration.

## Dormant tiles are refused, never dropped

Activating or unpinning a dormant tile whose extension is off or gone returns
false and changes nothing. `TabStore.dormantTileRefusal` classifies the reason
(`DormantTileRefusal.extensionDisabled(name:)` / `.extensionUnavailable`) and
the window shows a toast at the user-driven call sites. Dropping a tile on a
click would delete it behind the user's back and could break pinned-split
invariants; the next restore drops uninstalled ones.[^task-37]

Favourite moves follow the same classification (`FavoriteDropTargets`): an
uninstalled extension's favourite cannot be dragged anywhere, and a disabled
one's dormant favourite may only become a pinned entry.[^task-34]

## Move to Space

Within one profile the tab object moves and keeps its web view. Across
profiles it is retargeted onto the destination profile's origin for that
extension, or refused with a toast when the extension is not enabled there.
Moves across the incognito boundary are refused.[^task-38]

## Where an extension page cannot be

Established in TASK-352 (2026-11-15): the gate read from WebKit `main`, the
results measured on macOS 26.7 (25G229).[^task-352]

**The gate (read from WebKit `main`).** `WebExtensionController::addPage` installs the extension URL
scheme handler on every page of the controller, so a space's, a Peek's or a
Quick Detour's web view has it. The handler
(`WebExtensionURLSchemeHandlerCocoa.mm`) refuses a main-frame load whose
configuration's `_requiredWebExtensionBaseURL` is not the extension's, with
`NSURLErrorResourceUnavailable` (-1008). That holds even for a
`web_accessible_resources` page. Only `WKWebExtensionContext.webViewConfiguration`
sets that base URL.[^webkit-scheme-handler]

**Quick Detour and quarantine pages never get a context's configuration.**
`openQuickDetourTab` is the only code that adds to `quickDetourTabs`, and it
builds the web view from one of three things:

- `Space.makeWebViewConfiguration(for:inSpace: false)`, the profile's configuration;
- the same configuration with the quarantine's store;
- WebKit's copy of a Quick Detour opener's configuration (`createWebViewWith` in a Quick Detour).

The `adopting:` parameter is used only by tests, and `wakeConfiguration` has no
space to find a context through. A browser window never hands its
`createWebViewWith` configuration to a Quick Detour: Opt-Cmd-click, Open Link
in Quick Detour and routed links all open a fresh window with a URL.

**Kept as a guard test.** `QuickDetourExtensionPageGateTests` (TASK-373)
asserts each cell below on a real Quick Detour window
(`QuickDetourWindowController`, a loaded test extension with `options.html`
and a web-accessible `war.html`, a loopback page). If a WebKit release relaxes
the gate, it fails.[^task-373] Each cell waits for either Detour's error page
or the extension's document, then asserts all of these:

- the error page names the refused URL;
- the document is not the extension's;
- `showsExtensionPage` is false;
- `tab.url` is as the table says.

A bare web view built from the tab's own configuration gets
`NSURLErrorResourceUnavailable` (-1008). The error page carries only the
message, so the test reads the code this way. A positive control loads both
pages in the context's own configuration, in a normal and in a Private
profile.

The document check is what catches a relaxed gate. `showsExtensionPage` and
`tab.url` cannot catch it: a Quick Detour tab has no
`servedExtensionOriginHost`, so `mayAdopt` refuses the URL whatever WebKit
does. This was measured by opening the Quick Detour on the context's
configuration (`openedWith:`). The fresh-load cells then failed on the
document, the error page and the -1008 check, while `tab.url` stayed nil.

| Entry | Example path | Result (2026-11-16, macOS 26.7) |
|---|---|---|
| Fresh window loads the extension URL, web-accessible or not | sidebar Opt-Cmd-click or Open in Quick Detour on an extension-page tab (`sidebarCopyURL` has no scheme filter), an archived record | error page, -1008; `tab.url` nil (TASK-381; it kept the extension URL on 2026-11-15) |
| `location.href =` from a web page, web-accessible or not | a script in the page (a content script's would be the same navigation; not run) | error page; `tab.url` stays the web page |
| A link clicked in a web page | — | error page; `tab.url` stays the web page |
| `tabs.update` (`loadURL(_:for:)`) on the Quick Detour's tab, web-accessible or not | an extension acting on the popup window's tab | error page; `tab.url` stays the web page |
| `window.open` of the web-accessible page | the child Quick Detour, on WebKit's copy of the opener's configuration | error page, -1008; `tab.url` nil |
| A quarantine loads the extension URL, web-accessible or not (`openQuarantine`) | — | error page, -1008; `tab.url` nil |
| A quarantine's web page, `location.href =` the web-accessible page | — | error page; `tab.url` stays the web page |

The space-tab cells are `ExtensionPageProvenanceTests`'.

Typed `webkit-extension://…` in the launcher or palette is a search
(`AddressInputClassifier` reads `webkit-extension:` as a host with an empty
port, which is no URL), and would be the fresh-load cell anyway. The rehoming walk and the
deferred-update count therefore lose nothing by leaving Quick Detour pages
out.

# Gotchas

- A Peek cannot show an extension page: its web view is built from the space
  configuration, which WebKit refuses for an extension main frame
  ([below](#where-an-extension-page-cannot-be)).
- Until TASK-381 a refused extension page could become a space tab's URL.
  A `window.open` child of a web page kept the extension URL it failed on, and
  Reload after a sleep loaded it, even a page that is not web-accessible
  (measured 2026-11-16, TASK-372). See
  [above](#only-a-servable-page-becomes-the-tabs-url).
- A tab made by `addExtensionTab` has a plain `WKWebView`, not one from
  `BrowserTab.makeWebView`, so it has no `browser-error` handler. A failed
  load there, such as another extension's page from `tabs.create`, shows a
  blank page, not the error page (measured 2026-11-16, TASK-381).
- If an extension is enabled but its `WKWebExtension` fails to load, its
  restored pages stay pending and display as an empty page, not an error page.
- The window registers its owned-pane script message handlers on the web
  view's `userContentController`. For an extension tab that controller is
  shared by every extension page of the profile.[^task-14]
- The relaunch behaviour is verified by round-tripping an in-memory database
  through `restoreSession` against real contexts with fresh base URLs, not by
  quitting and relaunching the app.[^task-24]

# Where it lives

- [ExtensionPageURL.swift](../../Detour/Extensions/Runtime/ExtensionPageURL.swift) — the pure functions and `PersistedExtensionPage`.
- [Profile.swift](../../Detour/Browser/Profile.swift) — locations, retarget, pending origins.
- [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift) — `retarget`, `wake`, `wakeConfiguration`.
- [TabStore.swift](../../Detour/Browser/TabStore.swift) — restore, rebuild helpers, refusals.
- [ExtensionPageNavigationPolicy.swift](../../Detour/Extensions/Runtime/ExtensionPageNavigationPolicy.swift) — the rule for web content in an extension's tab (TASK-382).
- Tests: [QuickDetourExtensionPageGateTests](../../DetourTests/QuickDetourExtensionPageGateTests.swift) (TASK-373: the gate in Quick Detour and quarantine windows, [above](#where-an-extension-page-cannot-be)); [ExtensionPageNavigationPolicyTests](../../DetourTests/ExtensionPageNavigationPolicyTests.swift) (TASK-382's rule, table cases); [ExtensionPageProvenanceTests](../../DetourTests/ExtensionPageProvenanceTests.swift) (TASK-382: a framed web page's `top.location` in a window and in the background, which load `other.html` without the rule; the extension's own link, Back, own frame and `tabs.update`; a pin of WebKit's gate. TASK-381: a `window.open` child, a page-chosen `load`, another extension's `tabs.create` and a relaunch, which all fail with `mayAdopt` always true; a page navigating itself, which already passed; positive controls). Runtime check through the endpoint: [docs/harness/task381-endpoint-checks.py](../../docs/harness/task381-endpoint-checks.py) (a page's `window.open` child, Reload, Cmd+Q and relaunch, with the options tab as the control; 9/9 on 2026-11-16), `ExtensionPageURLTests`, [ExtensionPageRehostTests](../../DetourTests/ExtensionPageRehostTests.swift), [ExtensionPagePersistenceTests](../../DetourTests/ExtensionPagePersistenceTests.swift), `ExtensionPageUndoTests`, `ExtensionPageFavoriteTests`, `MoveTabToSpaceTests`.

# Related

- [Storage](./storage.md) — what of an origin's storage WebKit moves to the next origin (IndexedDB, `localStorage`) and what it does not.
- [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md), [Favorites](../tabs/favorites.md) — dormant tiles.
- [Closed tabs and archive](../tabs/closed-tabs-and-archive.md) — the records that carry `extensionID`.
- [Sleeping and archiving](../tabs/sleeping-and-archiving.md) — what a sleeping tab is.
- [Popup and options UI](./popup-and-options-ui.md) — how an options tab is opened and reused.

[^task-14]: Reload or close open extension pages when their context is reloaded
[^task-24]: Give extension-page tabs a durable identity so they survive a relaunch
[^task-34]: Moving an extension-page favourite must give a loadable tab
[^task-37]: Activating a dormant pinned entry of a disabled or uninstalled extension gives a dead tab
[^task-38]: Move to Space loses extension pages
[^task-381]: Extensions: a web page can make a tab load an extension's non-web-accessible page (window.open, then sleep/wake or Reload)
[^task-382]: Extensions: a web page in a tab built from an extension's configuration can navigate to that extension's private pages
[^webkit-navigation-state]: WebKit, NavigationState.mm (isUnsupportedWebExtensionNavigation)
[^navigation-policy]: ExtensionPageNavigationPolicy.swift
[^task-373]: Tests: guard that a Quick Detour window still cannot show an extension page
[^task-352]: Extensions: reloading or updating an extension leaves its page in a Quick Detour window on the dead origin
[^webkit-scheme-handler]: WebKit, WebExtensionURLSchemeHandlerCocoa.mm (main-frame loads need the configuration's requiredWebExtensionBaseURL)
