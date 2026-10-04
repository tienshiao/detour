---
type: Component
title: Internal pages (detour://)
description: "How Detour serves its own privileged pages into ordinary tabs: single-use arming, a scheme handler that serves only internal main documents, and a bridge in a private content world that re-verifies every sender."
resource: ../../Detour/Browser/InternalPages
tags: [internal-pages, security, webkit, bridge, navigation]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
sources:
  - id: internal-page
    resource: ../../Detour/Browser/InternalPages/InternalPage.swift
    title: InternalPage.swift (InternalPage, InternalPageNavigationPolicy)
  - id: scheme-handler
    resource: ../../Detour/Browser/InternalPages/InternalPageSchemeHandler.swift
    title: InternalPageSchemeHandler.swift
  - id: bridge
    resource: ../../Detour/Browser/InternalPages/InternalPageBridge.swift
    title: InternalPageBridge.swift
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (arming, loadInternalPage, loadRecordedURL)
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: task-86
    resource: backlog:TASK-86
    title: Profile-scoped History page in a tab (internal page + native bridge)
  - id: tests
    resource: ../../DetourTests/InternalPageTests.swift
    title: InternalPageTests.swift
  - id: integration-tests
    resource: ../../DetourTests/InternalPageIntegrationTests.swift
    title: InternalPageIntegrationTests.swift
  - id: delegate-spike
    resource: "Agent session notes, 2026-09-19: standalone WKWebView delegate spike (not in the repository)"
    title: WKWebView delegate and custom-scheme spike
---

# Role

An internal page is a page Detour itself serves into a normal tab, the way
Safari and Chrome show their history. `InternalPage` is the enum of them; it
has one case today, `.history` (`detour://history/`, the
[History page](./history-page.md)). Running in a tab gives the page web view
ownership, snapshots, sleep and wake, splits and session restore for free.
The price is that a privileged document now lives where web content lives, so
three independent layers keep web pages and extensions away from it:

1. `InternalPageNavigationPolicy` - only Detour can navigate a tab to it.
2. `InternalPageSchemeHandler` - only an internal document can load its
   resources, and that document runs no page-world script.
3. `InternalPageBridge` - the native bridge lives in a private content world
   and re-verifies every sender.

# How it works

## Layer 1: arming

A `WKNavigationAction` does not say who asked for it. An app-initiated
`load(_:)` has navigation type `.other` and reports the *current document* as
its source frame, exactly like a script navigation from that document.[^delegate-spike]
So trust is carried out of band: a tab is **armed** for one page.

| Entry point | Arms? | Callers |
|---|---|---|
| `BrowserTab.loadInternalPage(_:)` | yes | Cmd+Y (`TabStore.addTab(in:internalPage:)`), the palette when the user typed `detour://history` |
| `BrowserTab.loadRecordedURL(_:)` | yes, if the URL is internal | URLs Detour itself recorded from a committed navigation: reload retry, a favourite's home, rebuilding a closed tab or a dormant pinned entry. Keeps `?q=` state |
| `wake()` with a plain load of the tab's own URL | yes | a slept tab that was showing the page |
| `BrowserTab.load(_:)` | **never**; returns without loading an internal URL | everything untrusted: extensions' `tabs.create`/`tabs.update`, Cmd+click, links from other apps |

`InternalPageNavigationPolicy.decision(...)` is pure and shared by both
navigation delegates through `BrowserTab.authorizesNavigation(_:in:)`:

| Condition | Decision |
|---|---|
| not on the `detour` scheme | `.notInternal` |
| not the main frame of an existing frame (a nil target frame is a new window), or the host names no page | `.refused` |
| the page equals `armedInternalPage` | `.allowedByArming` - the caller spends the arming |
| type is `.backForward` or `.reload` **and** the URL is an entry of the web view's back/forward list | `.allowedAsRevisit` |
| otherwise | `.refused` |

Arming is **single-use**. Left armed while the page is showing, the tab would
wave through a redirect back to the internal scheme from the first history
entry the user clicked. An arming whose load never reaches the policy is
dropped by the URL observer once a web page commits.

The revisit rule requires the URL to *be* a session entry because a server
redirect keeps the type of the navigation it interrupts: going Back to a web
page that answers `302 detour://history/?q=…` would otherwise walk in. Script
cannot forge an entry (`pushState` is same-origin). Session restore needs no
arming: restoring `interactionState` arrives as `.backForward` with the list
already in place.[^delegate-spike]

Enforcement points, all of which must exist:

- `BrowserWindowController.decidePolicy` checks internal URLs **before**
  everything else, so a refused URL is not Cmd-clicked into a new tab, peeked,
  or offered to an external application.
- `BrowserTab`'s own `WKNavigationDelegate` (the delegate of a web view no
  window has claimed) applies the same check.
- `createWebViewWith` returns nil for an internal URL, because `window.open()`
  never consults `decidePolicyFor`.
- `ExtensionManager` and `WKExtensionTabConformance` refuse `detour://` URLs
  with an error instead of opening a tab whose only navigation would be
  cancelled.

## Layer 2: the scheme handler

`InternalPageSchemeHandler` is registered on every tab configuration in
`BrowserTab.makeWebView`, so it cannot assume who is asking: a web page in the
same web view can name these URLs in an `<iframe>`, `<img>` or `<script>`. It
serves a request only when `request.mainDocumentURL` is itself the same
internal page. A main-frame load reports itself as its main document;
anything embedded in a web page reports the web page.[^delegate-spike]

Every response carries:

```
Content-Security-Policy: default-src 'none'; style-src detour:; img-src detour: data:;
                         base-uri 'none'; form-action 'none'; frame-ancestors 'none'
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
Cache-Control: no-store
```

There is **no script source**. Nothing injected into the document's markup
can execute, and there is no inline `<style>` or `style` attribute either: the
page script toggles classes and the `hidden` property.

Resources are Swift string literals (`HistoryPageContent.html`, `.css`,
`.script`); the project bundles no web resources. A nil resource is a 404.

## Layer 3: the bridge

The page's logic is a `WKUserScript` in a private content world
(`WKContentWorld.world(name: "DetourInternalPage")`), main frame only, at
document start. A user script in a named content world runs even under
`default-src 'none'`; page CSP does not govern it.[^delegate-spike] The script
wrapper returns immediately unless `location.protocol` and `location.host`
name its page, reading `location` through the world's own bindings, which page
script cannot patch.

The handler `webkit.messageHandlers.detourInternal` is a
`WKScriptMessageHandlerWithReply` added to that world only. Page-world script
and extension content-script worlds cannot see it at all: `window.webkit` is
undefined there.[^delegate-spike] That is exposure control, not the guarantee.
A `WKUserContentController` can be shared between web views (a `window.open`
child gets its opener's), so each message is re-verified:

- `message.world` is the bridge's world;
- `InternalPageBridge.authorizedPage(...)`: main frame, security origin
  protocol and host name an internal page (for a custom scheme the origin is
  `scheme://host`[^delegate-spike]), and both the frame URL and `webView.url`
  name that same page;
- `TabStore.tab(hosting:)` finds a `BrowserTab` for the web view (a space's
  tabs, pinned entries, the profile's favourites, or a Peek over any of them).

Anything else gets the error string `forbidden`.

**The API carries no scope identifiers.** What a page may read or delete is
derived natively from the tab that sent the message, never from the message.

# Invariants

- `BrowserTab.load(_:)` never loads an internal URL. Adding a caller that has a
  trusted reason must use `loadInternalPage` or `loadRecordedURL`; never widen
  `load`.
- `tab.url` can only be internal because an armed load committed it. `wake()`
  and the rebuild-from-URL initialiser rely on this when they re-arm.
- `InternalPageBridge.install(on:)` is idempotent. Registering a handler name
  twice in one world raises, and a configuration reaches `makeWebView` more
  than once (an extension's shared configuration on every wake).
- `TabStore.tab(hosting:in:)` is the single definition of "a space's tabs" for
  web view lookups. The navigation policy and the bridge's sender check must
  never disagree about it.
- Nothing goes to the network for a `detour://` URL. `load(_:arming:)` skips
  its optimistic `favicon.ico` download for an armed page, and the tab shows
  `InternalPage.symbolName` (an SF Symbol) instead.
- An internal page is never recorded as a visit: the history recorder accepts
  only `http`/`https`.

# Gotchas

- **The page's title and icon come from the enum**, not the document:
  `BrowserTab.updateTitle` names the page before it loads and while it sleeps,
  and `displayHost` returns the page's title rather than the URL host
  ("history").
- **`replaceState` churn**: every `?q=` rewrite reports a new URL to the tab's
  observers. `applyInternalPageIcon` guards against re-bumping the favicon
  generation for each one.
- **Calling a finished or stopped `WKURLSchemeTask` raises** an Objective-C
  exception. The handler tracks active tasks in a main-thread set and answers
  asynchronous providers through it (the favicon route answers from a
  background queue).
- **Typed `detour://nowhere` is a search.** `AddressInputClassifier` treats
  only a URL naming an existing page as a URL.
- **Error-page retry is not trusted.** The `failedURL` in a `browser-error://`
  query string can be named by any web page, so `reload()` passes it to plain
  `load`, which refuses the internal scheme; only `lastAttemptedURL` goes
  through `loadRecordedURL`.
- A web page can still send the tab *back* to the internal page with
  `history.back()`. It gains nothing: the document is cross-origin to it and
  runs no page-world script.

# Adding a page

1. Add a case to `InternalPage`; give it `title`, `symbolName`, a resource
   provider (`resource(for:completion:)`) and a `scriptSource`.
2. Add its branch to the `switch page` in `InternalPageBridge` and write its
   method handler in the style of `HistoryPageBridge`: scope from the tab,
   every parameter validated, unknown shapes answered `malformed`.
3. Keep the document script-free and style-attribute-free; build DOM with
   `createElement` and `textContent`.
4. Confirm destructive actions natively, on the tab's window.
5. Extend `InternalPageTests` (policy, handler, sender check) and add
   real-web-view negative cases like those in `InternalPageIntegrationTests`.

# Tests

- `InternalPageTests` - pure: URL parsing, the policy matrix (arming, subframe
  and new window refused, revisit of a session entry, redirect during
  back/forward refused, only an arming allow is spent), scheme handler
  gating, CSP has no script source, sender authorisation, idempotent install,
  the user script inert off its page.
- `InternalPageIntegrationTests` - real `WKWebView`: an armed tab loads the
  page; a web page cannot navigate to or embed it; the page world cannot see
  the bridge; the bridge refuses the right world on a web page; `load` refuses
  the scheme on an unarmed tab; sleep/wake and restore.

# Related

- [History page](./history-page.md) - the one internal page, and its bridge methods.
- [Error pages](./error-pages.md) - the older `browser-error://` scheme, which has no bridge and is not privileged.
- [WKWebView delegate order](../platform/wkwebview-delegate-order.md) - the delegate and custom-scheme facts this design rests on.
- [BrowserTab](../architecture/browser-tab.md) - web view creation, wake, and the tab's own navigation delegate.
- [Command palette](./command-palette.md) - the typed-URL route into `loadInternalPage`.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) - the extension tab API that refuses `detour://`.

[^delegate-spike]: WKWebView delegate and custom-scheme spike
