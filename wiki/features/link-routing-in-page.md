---
type: Feature
title: Typed URLs and links clicked in a page
description: "Which typed URLs and in-page link clicks Link Routes move, from where: the entry points (palette submit in new-tab mode, the Cmd+click branch, the policy after the download check, createWebViewWith for a page's window and for the link menu), the pure linkRoutingEligibility rule (new-tab opens route, the link menu's New Tab and New Window as a Cmd+click, plain clicks only to another host; never redirects, scripts, popups, Opt-Cmd/Option/Shift-clicks, Peeks, subframes, Open Link in Split View or in Quick Detour; host not site), the WebKit signals that tell a click from a script or a redirect, a route winning over the pinned/favourite Peek intercept, the user's decisions of 2026-11-15 (TASK-356 done), and the runtime checks."
tags: [links, navigation, webkit, peek]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T09:00:00Z }
stale_after: 2027-01-31T00:00:00Z
sources:
  - id: eligibility
    resource: ../../Detour/Browser/LinkRouting/LinkRoutingEligibility.swift
    title: LinkRoutingEligibility.swift (linkRoutingEligibility, inPageLinkClickBranch, isSameLinkRoutingHost, inPageLinkOutcome, routedLinkDecision, typedURLIsRoutable)
  - id: window-routing
    resource: ../../Detour/Browser/Window/BrowserWindowController+LinkRouting.swift
    title: BrowserWindowController+LinkRouting.swift (the WebKit signals, routedDecision, routedTypedDecision, openRoutedLink)
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (decidePolicy)
  - id: ui-delegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
    title: BrowserWindowController+WKUIDelegate.swift (createWebViewWith)
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (openTypedURL, focusAddressBar)
  - id: peek-anchor
    resource: ../../Detour/Browser/Window/PeekAnchor.swift
    title: PeekAnchor.swift (anchoredLinkAction)
  - id: appdelegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (openLink)
  - id: eligibility-tests
    resource: ../../DetourTests/LinkRoutingEligibilityTests.swift
    title: LinkRoutingEligibilityTests.swift
  - id: in-page-tests
    resource: ../../DetourTests/InPageLinkRoutingTests.swift
    title: InPageLinkRoutingTests.swift
  - id: task-191-4
    resource: backlog:TASK-191.4
    title: "TASK-191.4: route typed URLs and links clicked inside Detour"
  - id: harness-4
    resource: ../../docs/harness/task191-4-harness.patch
    title: TASK-191.4 runtime harness
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: task-194
    resource: backlog:TASK-194
    title: "Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose"
  - id: task-300
    resource: backlog:TASK-300
    title: "Link context menu: Open Link in Quick Detour"
  - id: task-307
    resource: backlog:TASK-307
    title: "Peek: ⌘O opens the Peek as a tab, a setting turns Peek off, and ⇧⌘T / ⌘Z reopen a closed Peek"
  - id: task-356
    resource: backlog:TASK-356
    title: "Link Routes: Open Link in New Tab and Open Link in New Window go through Link Routes"
  - id: harness-356
    resource: ../../docs/harness/task356-link-menu-checks.py
    title: TASK-356 runtime check through the automation endpoint
  - id: link-menu
    resource: ../../Detour/Browser/Window/BrowserWebView.swift
    title: BrowserWebView.swift (willOpenMenu, the contextMenuOpenIn… actions)
---

TASK-191.4.[^task-191-4] Inside Detour, a URL typed in a new tab and some
link clicks are routed: the window's WebKit delegates and the command
palette describe what happened; the pure `linkRoutingEligibility` and
`typedURLIsRoutable` (`LinkRoutingEligibility.swift`) decide **whether** it
is routed; `resolveLinkRoute` with `.clicked` or `.typed` decides
**where** ([resolver](./link-routing-resolver.md)); and
`AppDelegate.openLink(_:routedTo:)`, the 191.2 placement code moved out of
`openExternalURLs` so both paths call it, decides which window
([placement](./link-routing-placement.md)). Part of
[Link Routes](./link-routing.md).

A routed link is therefore placed exactly as a link from another app: the
window showing the space, brought forward, with the tab selected; else the
most recent normal window (normally the one clicked in) switches to the
space; Private into the most recent Private window, else a new one. A
decision of `.stay` (no route, Most Recent Space, a route to the current
space, anything out of a Private window, Quick Detour, a Default of
Quarantine) changes nothing: the code from before routes runs. A click a
Quarantine route matches opens a quarantine window instead (TASK-194).[^task-194]

# Entry points

| Where | What is asked | Routed |
|---|---|---|
| Command palette submit (`paletteLoadURL`, then `openTypedURL`) | `typedURLIsRoutable(url, isSearch:, navigatesInPlace:)` | A URL (per `AddressInputClassifier`, which also covers a history row) submitted in new-tab mode (Cmd+T). A search never. Cmd+L or a click on the address bar never, while it navigates a selected tab in place; the palette is in new-tab mode while a Peek is open, and with no tab selected an in-place submit opens a new tab and routes as one. |
| `decidePolicy`, Opt-Cmd branch (TASK-193.5) | not asked: the branch opens a Quick Detour; the rule says `quickDetourClick` | never |
| `decidePolicy`, Cmd+click branch | the rule, before the background tab | Cmd+click (Cmd+Shift too; Cmd+Option only with the Quick Detour click off in Settings, or to a non-web URL) |
| `decidePolicy`, after the download check, before the anchor intercept | the rule for every link activation that gets that far | A `target=_blank` link (nil `targetFrame`, before WebKit would call `createWebViewWith`), and a plain click to another host |
| `createWebViewWith`, a page's own request (not the link menu's) | the rule, before the anchor intercept | A tab-style `window.open` |
| `createWebViewWith`, a link menu action (`contextMenuLinkAction`, TASK-356) | the rule with `.linkMenuAction(action)`, before the action's own code; no anchor intercept | Open Link in New Tab and Open Link in New Window. Open Link in Split View and Open Link in Quick Detour never. |

A routed click is cancelled (the page's tab stays on its page; a routed
`window.open` or link menu action returns nil, so the page gets no window)
and opened one main-queue turn later (`openRoutedLink`), so the policy decision returns
before windows switch spaces or come forward. A typed URL is opened at once,
keeping its typed flag for history.

# The rule

`linkRoutingEligibility(InPageLinkRequest) -> .routable(kind) | .notRouted(reason)`.
The request carries the entry (`.navigationAction(isLinkActivation:targetsMainFrame:opensNewWindow:isRedirect:)`,
`.pageWindowRequest(isLinkActivation:wantsPopup:)`, `.linkMenuAction(LinkMenuAction)`), the
modifiers, the user-gesture signal, whether it is in a Peek, the page URL
(`webView.url`), the target and the Opt-Cmd setting
(`quickDetourClickEnabled`). Checked in this order:

| Case | Result | Why |
|---|---|---|
| Target not http/https (`mailto:`, `detour://`, `data:`, `about:`, `blob:`, `file:`, app schemes) | not routed (`notWebURL`) | Routes match web pages only; non-web schemes and downloads are decided by the policy before it asks anyway. |
| Fired by a Peek's page, or while a Peek is presented | `inPeek` | A Peek is a look at a link; its links navigate the Peek (decided 2026-10-25). The overlay is modal, so while it is up a click can only be in it. |
| The link menu's Open Link in New Tab / in New Window | **routed** (`linkMenuNewTab` / `linkMenuNewWindow`) | As a Cmd+click: whatever the host (the same host included), the modifiers held or WebKit's gesture signal for the replayed request (the menu item is the user's). The user's decision of 2026-11-15, built in TASK-356 (see [decisions](#decisions-2026-11-15)).[^task-356] A Peek's page and non-web links are refused above. |
| The link menu's Open Link in Split View / in Quick Detour | `linkMenuAction` | The user picked where it opens: next to this tab, or outside any space (TASK-300's item does what Opt-Cmd-click does).[^task-300] |
| A `_blank` link reaching `createWebViewWith` | `decidedByNavigationPolicy` | WebKit asked the policy first; it was routed (cancelled) or not there. |
| Popup-style `window.open` (`_wantsPopup`, else explicit x/y/width/height) | `popupWindow` | It must keep its opener (sign-in and payment windows, TASK-168). |
| Tab-style `window.open` without a gesture | `noUserGesture` | WebKit blocks those anyway (`javaScriptCanOpenWindowsAutomatically` is off). |
| Tab-style `window.open` | **routed** (`scriptedWindow`) | A new-tab open. |
| A server redirect (`_isRedirect`) | `redirect` | Never routed: the user clicked the link, not the redirect target. Checked first because WebKit asks the policy again for the redirect with the click's link activation and gesture. |
| Not a link activation (`.other`, `.formSubmitted`, `.backForward`, `.reload`, `.formResubmitted`) | `notLinkActivation` | Script navigations (`location.href = …`, also inside a click handler), client redirects (`location.replace` on load, meta refresh), forms, history, app loads. |
| A link activation without a user gesture | `noUserGesture` | A page's own `a.click()` from a timer or a load script. |
| Opt-Cmd (Shift or not), to a web URL, with Settings' switch on (`quickDetourClickEnabled`) | `quickDetourClick` | TASK-193.5: a Quick Detour, which the user chose.[^task-193-5] |
| Cmd | **routed** (`commandClick`) | A new-tab open, whatever the host or frame. |
| Shift | `shiftClickPeek` | Shift-click Peeks; Shift before Option, as the branches. |
| Option | `optionClickSplit` | Option-click splits. |
| `target=_blank` (nil `targetFrame`), any frame | **routed** (`blankTarget`) | A new-tab open, same host included. |
| Target a subframe | `subframe` | An iframe navigating is not the page leaving. A `target=_top` link in an iframe targets the main frame and counts as a plain click. |
| Same host as the page | `sameHost` | Decided 2026-10-25: moving within a site stays in the tab. |
| Plain click to another host | **routed** (`crossHostClick`) | The tab stays on its page; the link opens in the routed destination. |

The modifier order is the navigation policy's (`inPageLinkClickBranch`):
Opt-Cmd, then Cmd, then Shift, then Option.

**Host, not site.** `isSameLinkRoutingHost` compares hosts without case,
trailing dot or a leading `www.` (dropped only when a dot remains, so
`www.com` is not `com`); ports are ignored (host, not origin). There is no
public-suffix list in the codebase, so it cannot compare registrable domains:
`mail.example.com` is another host than `example.com`, and a click between
them is routed (a route that matches it decides; with none, nothing moves).
A page without a host (`about:blank`, a `data:` page) has no host to stay on,
so a click from it to a web URL is cross-host. The History page's rows are
plain links on `detour://history`, so a click on one is a cross-host click
like any other.

**Typed.** `typedURLIsRoutable` is `!isSearch && !navigatesInPlace && http(s)`.
`isSearch` is the palette's own classification (a submission
`AddressInputClassifier` does not read as a URL, or a search suggestion row),
so a search URL whose host a route names (`google.com`) is still a search.
`navigatesInPlace` is the palette's mode with a tab selected
(`navigateInPlace && selectedTab != nil` in `openTypedURL`).

# Signals from WebKit

Measured 2026-10-25 on macOS 26.7 with a standalone `WKWebView` against a
loopback fixture server (two hosts: `127.0.0.1` and `localhost`), logging
every `decidePolicyFor` and `createWebViewWith`:[^task-191-4]

| Action | `navigationType` | `targetFrame` | `_isUserInitiated` | `_isRedirect` | `_hasOpener` |
|---|---|---|---|---|---|
| Real Cmd+click (posted mouse event) | link | main | true | false | false |
| `a.click()` from `evaluateJavaScript` | link | main | true | false | false |
| A page's own timer `a.click()` (no gesture) | link | main | **false** | false | false |
| Timer `location.href = …` | other | main | false | false | false |
| A click handler's `location.href = …` | other | main | **true** | false | false |
| A click handler's `setTimeout(() => a.click(), 0)` | link | main | true | false | false |
| Same-host link, then a 302 to another host | link, then **link again** for the redirect target | main | true, true | false, **true** | false |
| Same-host link to a page that `location.replace`s on load | link, then other | main | true, false | false | false |
| `<a target=_blank>` | link (policy), then link (`createWebViewWith`) | nil | true | false | false |
| `window.open(url)` from a click | other (`createWebViewWith` only) | nil | true | false | true |
| `window.open(url, 'p', 'popup,…')` | other (`createWebViewWith` only), `_wantsPopup` true | nil | true | false | true |
| `dispatchEvent(new MouseEvent('click', {metaKey: true}))` | link, modifier flags **0** | main | true | false | false |

So: `navigationType == .linkActivated` separates link clicks from script
navigations and client redirects; `_isUserInitiated` separates a user's click
from a page's own `a.click()`; `_isRedirect` is the only thing that separates
a server redirect (which keeps the click's type and gesture) from the click.
Both are SPI on `WKNavigationAction`, read by key behind a `responds(to:)`
guard (`BrowserWindowController+LinkRouting.swift`); without them every
action counts as a gesture and nothing as a redirect. Anything the app runs
with `evaluateJavaScript` carries a gesture, which is why the earlier
spike saw `_isUserInitiated` true for every call (see
[WKWebView delegate order](../platform/wkwebview-delegate-order.md)), and why
the unit tests can drive real clicks that way. A synthetic click carries no
modifiers into the navigation action, so a page cannot fake a Cmd+click.

A click handler's own `a.click()` (directly or a `setTimeout(…, 0)` later)
inherits the user's gesture and is routed like the click: WebKit reports it
exactly as a real click.

# The Peek intercept and other branches

- **A route elsewhere wins over the pinned/favourite anchor intercept**
  (decided 2026-10-25). `inPageLinkOutcome(routed:anchorPeeks:)`: a routed
  decision → open it there; `nil` or `.stay` → the intercept as before. On
  an anchored tab a routed cross-host click or `_blank` link or tab-style
  `window.open` therefore goes to its space instead of a Peek. Unrouted, the
  intercept peeks; with Peek turned off in Settings (TASK-307), a cross-host
  click on an anchored tab opens a new tab from it instead, and a `_blank`
  link or `window.open` opens as from an ordinary tab
  (`PeekAnchor.anchoredLinkAction`, `scriptedWindowPeeks`).[^task-307]
- Policy order around it: internal URL, Opt-Cmd (Quick Detour, TASK-193.5),
  **Cmd+click (route, else background tab)**, Shift (Peek), Option (split),
  back/forward into an error page, non-web scheme, download, **route, then
  the anchor intercept**, allow ([tab lifecycle](../tabs/tab-lifecycle.md)).
- A redirect is never routed, but the anchor intercept still sees it: WebKit
  reports a server redirect as a link activation, so on a pinned tab or
  favourite a same-host link that redirects to another host **opens the
  redirect target in a Peek** (seen at runtime, [below](#runtime-check)).
  That is how the intercept behaved before this task; [Peek](../tabs/peek.md)
  said otherwise and was corrected.

# Decisions (2026-11-15)

Cases the task's decisions did not name were decided while implementing
(TASK-191.4 notes, 2026-10-25) and put to the user, who decided them on
2026-11-15.[^task-191-4]

**Changed** (the user's decision, 2026-11-15; done in TASK-356):[^task-356]

- **Open Link in New Tab and Open Link in New Window are routed like a
  Cmd+click.** TASK-191.4 had left the link menu unrouted on the reasoning
  that the user chose where the link opens; the user's reason for the change
  is consistency with other browsers' link rules: Arc's Air Traffic Control
  and Firefox's Multi-Account Containers apply their rules whatever opened
  the link. A routed one is placed as a routed Cmd+click is (where the route
  says, selected, its window in front), so a routed **New Window** opens a
  window of its own only where placement would for any routed link: with no
  window on the space, the most recent normal window switches to it
  ([placement](./link-routing-placement.md)). Unrouted (no route, a route to
  the current space, Most Recent Space, a Private window), each opens as
  before: a background tab from the page's tab, or `createNewWindowWithURL`,
  Private from a Private window. That last part was a fix found in the
  task's review: a Private window's Open Link in New Window had opened the
  link in a **normal** window on the last normal space and its profile
  (`incognito` defaulted to false; confirmed by a failing test).
  The TASK-191.4 estimate of "one line in `createWebViewWith`" was short:
  production never built a `.linkMenuAction` request, so the menu's
  `contextMenuLinkAction` now asks the rule there, and the entry carries the
  action so the rule tells the four items apart.
- **Open Link in Split View and Open Link in Quick Detour stay unrouted**
  (`linkMenuAction`). The menu items are built in `BrowserWebView.willOpenMenu`
  (a browser window only; a Quick Detour window keeps WebKit's own) and each
  replays WebKit's Open Link in New Window item, which reaches
  `createWebViewWith` (seen at runtime: each routed item logged one `Link
  routed` line, of the menu's kind, and no other).[^link-menu]

**Confirmed as built** (the user's decision, 2026-11-15):

- **Cmd+L (or a click on the address bar) while a Peek is open routes.**
  `focusAddressBar` and the faux address bar open the palette in new-tab mode
  then (it shows the Peek's URL but opens a new tab), and the rule keys on the
  palette's mode, not on the key that opened it.
- **A routed Cmd+click opens selected, in front**, as a link from another
  app does, not as a background tab in the other space: a tab that appeared
  silently in a space not on screen would look like a click that did nothing.
- **Cmd+click and `_blank` in an iframe route**: they open a new tab whichever
  frame the link is in; "subframe navigations" are an iframe navigating
  itself.
- **A click from an internal page to a web host is cross-host** (above).
- **`window.open()` then `w.location = …`** (xterm.js's pattern) is not
  routed: the open has no web URL and the later navigation is the child's,
  type `.other`.

# Runtime check

Harness `docs/harness/task191-4-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1914`, 2026-10-25, screen unlocked.[^harness-4]
A loopback fixture page of links reached as `127.0.0.1` (the page),
`localhost` (routed to Work) and `[::1]` (no route); window B on Work, window
A on Personal with a pinned tab; real mouse and key events posted with
`NSApp.postEvent`. Every routing question and placement was logged:

| Case | Logged | Result |
|---|---|---|
| Plain same-host click | `notRouted(sameHost)` | navigated in place |
| Plain click to `localhost` | `routable(crossHostClick)` → Work → `openInWindow(B)` | B in front with the tab selected; A's tab stayed on its page |
| Cmd+click to `localhost` / same host | `commandClick` → Work / decision none | Work window / background tab in A, as before |
| `_blank` (routed path) / unrouted | `blankTarget` → Work / none | Work window / a tab in A (its `createWebViewWith` logs `decidedByNavigationPolicy`) |
| `window.open` tab-style / popup | `scriptedWindow` → Work / `popupWindow` | Work window / a tab in A whose opener received its `postMessage` |
| Option-click, Shift-click | not asked: their branches run first | a split; a Peek |
| In a Peek: `_blank`, cross-host click to a Private-routed URL | `inPeek` | a tab in A as before; the Peek navigated |
| Server redirect to `localhost` | `sameHost`, then `redirect` (`_isRedirect`, still a link activation with a gesture) | the tab followed the redirect |
| Client redirect, `onclick` `location.href`, page timer `a.click()` | `notLinkActivation`, `notLinkActivation` (gesture true), `noUserGesture` | in place |
| `onclick` → `a.click()` | `crossHostClick`, gesture true | routed to Work, like the click |
| Cross host with no route (`[::1]`) | routable, decision none | in place |
| Pinned tab: to `localhost` / to `[::1]` / same-host link redirecting to `localhost` | Work / none / `redirect` | Work window, no Peek / Peek / **Peek of the redirect target** |
| Cmd+T `localhost:8714/b?kind=typed` | `TYPED routable` → Work → `openInWindow(B)` | in B |
| Cmd+L, a search (route `contains "routeme"`) | `navigatesInPlace`, `isSearch`: not routable | in place; a search tab in A |
| Private route from A, twice | `privateWindow` → `openInNewPrivateWindow`, then `openInPrivateWindow(P)` | a new Private window, then a tab in it |
| From the Private window: click and typed URL to `localhost` | routable, decision none (normal routes ignored) | in place; a tab in P |

Captures by window number in the session scratchpad (`task191-4/out`).
Input trap: a plain click posted to a window of an **inactive** app is
swallowed while a Cmd-click goes through (macOS's click-without-activating),
so a first run made while the user was in another app routed only the
Cmd-clicks; the harness now activates Detour and makes the window key before
each input. Even then the first plain click after a window became key
occasionally produced no navigation action at all and was re-posted.

**The link menu (TASK-356)**, 2026-11-16, `docs/harness/task356-link-menu-checks.py`
through the automation endpoint, `DETOUR_DATA_DIR=DetourVerify-356`:[^harness-356]
a world with Personal (a page of links on `127.0.0.1`) and Work, one route
(`localhost` → Work), a window on each, side by side. Each case right-clicks a
link (`click button=right`), reads the menu (`list_menu`) and chooses the item
by title (`choose_menu_item`), with the links window made key first:

| Item, link | Result |
|---|---|
| New Tab, `localhost` | `routable(linkMenuNewTab)` → Work: the tab in Work, selected in the Work window, which is key; no tab in Personal; the links window kept its space and page |
| New Window, `localhost` | `routable(linkMenuNewWindow)` → Work: the same, and no new window |
| Split View, `localhost` | not routed: a split with the links page in Personal, nothing in Work |
| Quick Detour, `localhost` | not routed: a Quick Detour window (not a quarantine), nothing in Work |
| New Tab, `127.0.0.1` (no route) | a background tab in Personal |
| New Window, `127.0.0.1` (no route) | a new browser window with the link |

Only the two routed cases logged `Link routed`. Not run: a Private window
and a Peek's link menu (the in-app tests cover both).

**Not verified at runtime:** a favourite's tab (the pinned tab stands in for
the anchor intercept; both go through `PeekAnchor.anchorURL`), a split pane
clicking (the eligibility does not look at panes), a link in an iframe
(subframe, `target=_top`), the History page's links, and real sites.

# Tests

- `LinkRoutingEligibilityTests` (TASK-191.4): every case of the rule above,
  `www.`, ports, subdomains, hostless pages, the modifier order, redirects
  with each entry, Peek, the precedence over the anchor intercept, `.stay`
  as no route, the typed rule, and both layers with the resolver: Private
  both ways, Quarantine, the Default, a route to the current space.
- `InPageLinkRoutingTests`: real windows against a loopback server reached
  as `127.0.0.1` and `localhost`, clicks made with `evaluateJavaScript`,
  which carries a gesture: a cross-host click opens in the Work window and
  the tab stays, with no Work window the clicking window switches, `_blank`
  and tab-style `window.open` routed (the page gets null), a Private route
  opens a Private window; same-host, a server redirect, a click handler's
  `location.href`, a page timer's `a.click()`, a popup (opener kept), a
  click in a Peek and a click in a Private window not routed; on a pinned
  tab the route wins over the Peek and with no route it peeks; typed: Cmd+T
  routed, in place not, a search not, no route and a route to the current
  space open here, a Private window ignores normal routes, a Private route
  opens a Private window.
- The link menu (TASK-356): `LinkRoutingEligibilityTests` answers each of the
  four actions, with modifiers, without a gesture, the same host, a hostless
  or internal page, in a Peek, to non-web links, and with the resolver (a
  space, the current space, Private both ways, Quarantine, the Default; Split
  View and Quick Detour never ask it). `InPageLinkRoutingTests` set the
  pending `contextMenuLinkAction` and call the page's `window.open`, which
  reaches the menu's branch in `createWebViewWith` as WebKit's replayed item
  does (the item itself is the runtime check): New Tab and New Window open in
  the Work window, selected, in front (with no Work window, the clicking one
  switches), unrouted they open as before, Split View and Quick Detour are not
  routed, nor New Tab in a Peek or a Private window.
- Cmd+click is not in the unit tests: a script's event carries no modifiers
  into the navigation action, so it is checked at runtime only.

# Related

- [Link Routes](./link-routing.md): the hub.
- [Tab lifecycle](../tabs/tab-lifecycle.md): the full link policy order.
- [Peek](../tabs/peek.md): the anchor intercept a route wins over.
- [Command palette](./command-palette.md): new-tab and in-place modes.
- [WKWebView delegate order](../platform/wkwebview-delegate-order.md): more on the delegate calls and their SPI.
- [Quick Detour](./quick-detour-entry-points.md#opt-cmd-click-on-a-link): Opt-Cmd-click, which is never routed.

[^task-191-4]: TASK-191.4: route typed URLs and links clicked inside Detour
[^harness-4]: TASK-191.4 runtime harness
[^task-193-5]: Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive
[^task-194]: Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose
[^task-300]: Link context menu: Open Link in Quick Detour
[^task-307]: Peek: ⌘O opens the Peek as a tab, a setting turns Peek off, and ⇧⌘T / ⌘Z reopen a closed Peek
[^task-356]: Link Routes: Open Link in New Tab and Open Link in New Window go through Link Routes
[^harness-356]: TASK-356 runtime check through the automation endpoint
[^link-menu]: BrowserWebView.swift (willOpenMenu, the contextMenuOpenIn… actions)
