---
type: Feature
title: Quarantine
description: "A link opened in a throwaway Quick Detour window whose page has a non-persistent website data store of its own (TASK-194): how it is chosen (a Link Routes target, the Default for links from other apps, a route also for matching clicks, never a typed URL), the window (a Private-profile Quick Detour with its own store, its badge and tint, popups sharing the opener's store, Cmd+click a fresh one), Open in as a fresh load in any profile's space, history (none), archive (never), idle close (never), extensions (those allowed in Private), downloads (asked each time), the tracking-parameter rule, Safari's user agent, WebKit's fingerprinting protections, and the limits."
tags: [links, privacy, window, incognito, extensions, downloads]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T06:30:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-194
    resource: backlog:TASK-194
    title: "Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose"
  - id: rules
    resource: ../../Detour/Browser/QuickDetour/Quarantine.swift
    title: Quarantine.swift (QuarantineSession, QuarantineDownloadGate, the parameter rule, the user agent, the privacy SPI)
  - id: open-in
    resource: ../../Detour/Browser/QuickDetour/QuickDetourOpenIn.swift
    title: QuickDetourOpenIn.swift (quarantineOpenInMenu)
  - id: store
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift (openQuickDetourTab(quarantine:))
  - id: window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift (openQuarantine, the badge menu, Open in)
  - id: webkit
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController+WebKit.swift
    title: QuickDetourWindowController+WebKit.swift (the policy, downloads, popups)
  - id: resolver
    resource: ../../Detour/Browser/LinkRouting/LinkRouteResolver.swift
    title: LinkRouteResolver.swift (the Quarantine rule)
  - id: appdelegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (openLink, openInQuarantine)
  - id: harness
    resource: ../../docs/harness/task194-harness.patch
    title: TASK-194 runtime harness and its results
  - id: privacy
    resource: ../platform/webkit-privacy-protections.md
    title: WebKit privacy protections
---

# What it does

A link can be opened in **quarantine**: a [Quick Detour](./quick-detour.md)
window whose page has a website data store of its own, made for that window
and thrown away with it, so the destination neither sees nor sets any of
your cookies or site data, and nothing is recorded in history. The window
says so (an orange **Quarantine** badge where the profile pill is, and an
orange tint on its bar), and the page leaves it only on purpose: **Open in
<Space>** loads the current address fresh in a tab of the chosen space, on
that space's profile, and closes the window. Nothing the quarantined page
gathered comes along — that is the point.[^task-194]

The user's decisions of 2026-10-26: a fresh non-persistent store per window
(not the shared Private store); downloads asked about each time; a route set
to Quarantine also catches matching links clicked inside Detour, and links
from other apps are covered; typed URLs are never quarantined; extensions
allowed in Private run.

# How it is chosen

Quarantine is a [Link Routes](./link-routing.md) target, offered in the
Default's pop-up and in each route's Open in on the Links pane (after Quick
Detour, with a tooltip). The resolver (`resolveLinkRoute`):

| Origin | A route to Quarantine that matches | Default = Quarantine, no route matches |
|---|---|---|
| A link from another app | quarantined | quarantined |
| A routable click in a page (cross-host, Cmd+click, `_blank`, tab-style `window.open`; [the click rule](./link-routing.md#the-rule)) | **quarantined** (the user's decision) | stays: a Default of Quarantine would quarantine every link clicked to another site |
| A routable click in a **Private** window | stays (navigates as before): a quarantine's Open in reaches normal spaces, so a Private page's link would be one Cmd+O from a normal profile and its history — nothing leaves a Private window (code review; the first build quarantined it) | stays |
| A typed URL | skipped; the next route or the Default decides | stays |

"Routes keep sending trusted sites straight to their space": with the
Default on Quarantine, a route above it to a space still wins.

`linkPlacement` answers `.openInQuarantine` whatever windows are open, and
`AppDelegate.openLink` opens the window (`openInQuarantine`) instead of a
tab. The window is ordered in front of Detour's windows; Detour is not
activated by the placement (a link from another app is activated by the
sender's `NSWorkspace.open`).

# How it works

## A Private-profile Quick Detour on a store of its own

`QuickDetourWindowController.openQuarantine(url:privateProfile:sourceSpace:)`
makes a `QuarantineSession` (the store, `WKWebsiteDataStore.nonPersistent()`,
and the link as it arrived) and a Quick Detour on the **Private profile**
with it. `TabStore.openQuickDetourTab(quarantine:)` builds the page from the
Private profile's configuration — its extension controller, its content
rules — and puts the session's store in place of the profile's. Being a
Private-profile Quick Detour gives the rest:

| | A quarantine | Why |
|---|---|---|
| Store | `quarantine.dataStore`, non-persistent, never a profile's, never the Private store Private windows share | the user's decision |
| History | none (`recordHistoryVisit` skips a Private Quick Detour) | |
| Archive | never: no closed-tab record on any close | nothing of it should outlive it; a record would also keep its address |
| Idle auto-close | never (the rule's Private exception) | nothing would be archived, so the timer would only lose a page the user may be reading; a quarantine holds only memory |
| Extensions | the Private profile's contexts: those allowed in Private run (content scripts, the toolbar buttons, `sender.tab`); it is an incognito `popup` window to them; a normal profile's extensions never see it | the user's decision; the Private gate ([private profile extensions](../extensions/private-profile-extensions.md)) applies unchanged |
| Session restore | never | as every Quick Detour |
| The Private session (`hasLivePrivateSession`) | counts as a user: the Private site settings (content blocking's per-site switch) are shared with Private windows | a quarantine has no settings of its own; the switch affects blocking, not identity |
| Window look | the system appearance, an orange tint on the bar and the badge; not a Private window's dark | a look of its own |
| Launcher (Opt-Cmd-N) | a quarantine in front names no profile: the window behind it decides | a quarantine is not a profile to browse with |
| Routed Quick Detour profile | passed over, as a Private window is | |

The session lives as long as a page uses it: each tab holds it, and the
store's tear-down (`takeDownQuickDetourTab`) lets go; the last one gone, its
`deinit` removes the store's data explicitly and the store is released.
A web view's store is fixed when it is made, so the page can never move
into another store; that is also why Open in always reloads.

**Windows the page opens** (`target=_blank`, `window.open`) share the
opener's quarantine: WebKit hands `createWebViewWith` a copy of the opener's
configuration, store included, and the page keeps its `window.opener` (a
sign-in popup). **Cmd+click** (and Opt-Cmd) inside a quarantine opens
another quarantine with a store of its own: one store per window, the
decision.

## The badge and its menu

The profile pill becomes a **Quarantine** badge (`shield.lefthalf.filled`,
orange; `QuickDetourTitleBar.setQuarantine`). Pressed, it opens an
information menu (`makeQuarantineMenu`): what quarantine means, "Opened from
<the link's host>" and, once the page has gone elsewhere (a redirect), "Now
at <host>". The host in the middle of the bar is always where the page is.
It switches no profile: `switchProfile` refuses in a quarantine.

## Open in

`QuickDetour.quarantineOpenInMenu` (pure): every normal space of every live
profile, one section per profile in profile order, **every item reloads**.
The button names the space the link was clicked in (a routed click), else
the most recent normal window's space (a link from another app), while it
is listed; else the most recently used listed space; else the first. A
Private window's space is never a target.

`open(in:)` in a quarantine is always `reopen`: a new tab of the chosen space
on `tab.url` (already free of tracking parameters), placed by the Link
Routes placement, then the window closes. The load is a fresh GET on the
space's profile's store: no cookie, no storage, no referrer from the
quarantine. Lost, as decided for a quick look: the back/forward list, text
typed into a form (no warning: the page is one the user has not trusted
yet), scroll position, `window.opener`. Open in Private Window is not
offered (a reload into the shared Private store would gain nothing over
staying).

## Downloads: asked each time

A quarantine's download first goes to `QuarantineDownloadGate`. WebKit names
the file only when it asks where to save it, so the question is asked then,
as a sheet on the window: "Download “report.txt”?" / "From example.com, to
your Downloads folder. Quarantine keeps your cookies away from the site; it
does not check the file." **Download** hands the download to the
`DownloadManager` (listed, saved, and scoped to the window as a Private
window's are: cancelled with the window, after the close question); **Cancel**
(Escape) refuses a destination, which cancels it before a byte is written.
A window closing while the question is up answers it "no"; a download that
fails while it is up is never handed on. Open in closes the window, so with
an allowed download still running it asks first, as closing does
(`confirmClosingWithPrivateDownloads`). An extension
package (`.crx`) is a download like any other here, not offered for install.

## Link tracking parameters

`Quarantine.removingTrackingParameters` (pure) removes click IDs (`gclid`,
`gclsrc`, `dclid`, `gbraid`, `wbraid`, `fbclid`, `msclkid`, `igshid`,
`yclid`, `twclid`, `ttclid`, `li_fat_id`, `mc_eid`, `mc_cid`, `_hsenc`,
`_hsmi`, `mkt_tok`, `oly_anon_id`, `oly_enc_id`, `vero_id`, `s_cid`,
`rb_clickid`) and every `utm_` parameter, names compared without case and
after percent-decoding, other parameters kept in order with their spelling.
Applied to the link before the window loads it, and to every main-frame
navigation of the page (`trackingFreeURL`: a GET carrying any is cancelled
and loaded again without them; back/forward, reloads and form posts go
through; a server redirect landing back on the address just cleaned is let
through once, so a server that insists cannot loop the page). WebKit's own link decoration filtering, on in quarantine, removes
the click IDs on Apple's list before the policy even sees them; this rule
covers the rest (`utm_*`).

## Fingerprinting

On every navigation of a quarantine page Detour sets WebKit's
`BaselineProtections`, `FingerprintingProtections` and
`LinkDecorationFiltering` through the `_networkConnectionIntegrityPolicy`
SPI (guarded; see [WebKit privacy protections](../platform/webkit-privacy-protections.md)
for the measurements):[^privacy] canvas and audio readback are noised per
session and `screen` reports the window, not the display. The page's user
agent is Safari's own, the OS version frozen at `10_15_7` as Safari sends
it, with no Detour token (`Quarantine.userAgent`), and the page fetches no
favicon (the app's URL session is outside its store).

**Limits** (also on the platform page): the IP address, fonts, hardware
concurrency, languages and time zone are unchanged; quarantine stops a
visit being linked to your browsing through stored state and the common
fingerprint reads, it does not make you anonymous.

# Edge cases

| Case | Decision |
|---|---|
| The link redirects to another host | the page follows; the bar shows where it landed, the badge's menu where it came from |
| Two links quarantined at once | two windows, two stores |
| A page opened by the quarantined page | same quarantine, same store (its opener) |
| The quarantined page mid-form when Open in is chosen | reloaded fresh; the text is lost |
| No normal space at all | Open in is hidden |
| A Private window's link matching a Quarantine route | not quarantined: it stays in the Private window |
| Open in while a download the user allowed is running | asked first, as closing the window is (Continue Downloading keeps everything; a yes cancels it and opens) |
| A server redirecting the cleaned address back to one with tracking parameters | let through the second time (`lastTrackingFreeLoad`, cleared on commit) rather than looping; without WebKit's `_isRedirect` SPI the loop guard cannot tell a redirect |
| A download that fails while its question is up | a later yes hands nothing on (the gate remembers the failure) |
| The window closed while a download question is up | answered "no" |

# Tests

| Suite | Covers |
|---|---|
| `QuarantineTests` (27) | the parameter rule (lists, order and spelling kept, case, lookalikes, repeated and valueless, fragment, non-web URLs), which navigations are reloaded without them, Safari's user agent, the SPI applied and OR-ed (skipped without it), the Open in rule (every profile, all reloading, the source, most recent, Private and deleted left out, none); the store: a fresh store per quarantine, never the Private or a profile's, a popup sharing it, the Private profile's extension controller, the user agent on the web view, the session released with its last page, no history (real load), no archive, no favicon fetch |
| `QuarantineWindowTests` (15) | in real windows: the badge and the appearance, the pill switching nothing, never idle-closed, no archive; two quarantines sharing nothing and no Private window's or profile's cookie reaching one (a loopback server recording each request's `Cookie` header); a page's window sharing the quarantine; a clicked link losing its tracking parameters before the request; canvas noise and `screen` (skipped without the SPI); Open in listing every profile's spaces and **AC #3**: a quarantined page that got a `Set-Cookie` and wrote `localStorage`, moved by Open in, loads fresh in the space's store with no `Cookie` header and no storage, and the profile's cookie store has none; downloads asked, cancelled on no (nothing listed, no file) and saved on yes (scoped to the window); Open in asking before cancelling a running download; a redirect back to tracking parameters not looping |
| `LinkRouteResolverTests`, `LinkRoutingEligibilityTests`, `LinkPlacementTests`, `LinkRouteEditorTests` | the rules above, `.openInQuarantine`, the target offered |
| `ExternalLinkRoutingTests` (+4) | a route and the Default opening a quarantine with its own store and the front window's space in Open in; parameters stripped with the original kept; two links, two stores |
| `InPageLinkRoutingTests` (+3) | a routed click quarantined while the tab stays; never from a Private window; a typed URL never |
| `QuickDetourExtensionTests` (+2) | real contexts: an incognito popup to a Private-profile extension whose content script runs and reaches the worker with the quarantine's tab; a normal profile's extension seeing nothing |

The rule and store tests were written first, against stubs returning empty
values: 43 of the new or changed tests failed (the passing ones were
negative cases or properties a Private Quick Detour already had). The
window tests for in-page parameter stripping and the fingerprinting
protections came after the code; disabling the policy rewrite, and the SPI
call, each failed them. The code review's fixes (Open in asking about a
running download, the redirect loop) got tests after the fix, each failing
with its fix removed; the rule that a Private window's click is never
quarantined was changed test-first (4 failures, then green). The gate
ignoring a download that failed during its question has no test: a
`WKDownload` cannot be made or failed on demand in the test host.

# Runtime check

Debug build, isolated data directory, a loopback fixture server that sets a
cookie and logs every request's `Cookie` header, real posted clicks and keys,
light and dark, 2026-10-26/27 ([harness](../../docs/harness/task194-harness.patch),
which lists every step and result):[^harness]

- A link from a (named) mail app through a redirect matched a Quarantine
  route: a quarantine window, badge and tint, Safari's user agent, its store
  neither persistent nor the Private one; the server never saw the link's
  `utm_source` and `gclid`; the badge's menu said "Opened from 127.0.0.1",
  "Now at localhost".
- The quarantined site set and read its cookie and storage; a posted click on
  Open in closed the window and loaded the address in Home on Home's store:
  "cookie:no storage:no", no `Cookie` header, Home's cookie store empty.
- A routed click in a Home page opened a quarantine naming Home, the clicked
  tab staying put; a posted Cmd-click inside it opened another quarantine with
  a different store; a tracked link landed without its `utm_*`.
- A download link put up the question; Escape left nothing, Return saved the
  file as the quarantine's Private-scoped download.
- Canvas read back differently from a normal tab's and `screen` was the
  window (900 × 600 against 5120 × 1440).
- Settings > Links showed Quarantine in each route's Open in and the caption.

Not checked at runtime: a real app's link, an extension in a quarantine
(unit tests), the badge's menu drawn, several displays, VoiceOver.

# Related

- [Quick Detour](./quick-detour.md) — the window a quarantine is.
- [Link Routes](./link-routing.md) — the target and the click rule.
- [WebKit privacy protections](../platform/webkit-privacy-protections.md) — the SPI and what it measurably does.
- [Incognito](../architecture/incognito.md) — the Private profile and session a quarantine runs under.
- [Downloads](./downloads.md) — the Private download scope a quarantine's downloads use.

[^task-194]: Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose
[^privacy]: WebKit privacy protections
[^harness]: TASK-194 runtime harness and its results
