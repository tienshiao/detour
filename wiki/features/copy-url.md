---
type: Feature
title: Copy URL
description: "Every copy of a page's or tab's address (Edit > Copy URL / Shift-Cmd-C in a browser or Quick Detour window, the faux address bar's and Quick Detour's Copy Link buttons, the dev toolbar's link button, the sidebar tab menu's Copy URL / Copy Link) puts the address on the clipboard without its tracking parameters, through TrackingParameters: the built-in list quarantine pages also use, plus the downloaded AdGuard URL Tracking filter's site-specific $removeparam rules and exceptions (TASK-329: rule forms supported and skipped, fallback, quarantine kept on the built-in list); Share… shares the clean link too; what is left alone (a page's own Copy Link, Opt-Cmd-click copies into Quick Detour) and why; the loaded URL, history and session keep the original (TASK-326)."
tags: [links, privacy, clipboard, sidebar, window]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T20:30:00Z }
sources:
  - id: task-326
    resource: backlog:TASK-326
    title: "Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed"
  - id: rule
    resource: ../../Detour/Browser/TrackingParameters.swift
    title: TrackingParameters.swift (the list, isTracking, removing, copyableString)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (copyCurrentURL, copyURL)
  - id: quick-detour
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift (copyCurrentURL)
  - id: sidebar
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (contextMenuCopyURL)
  - id: checks
    resource: ../../docs/harness/task326-copy-url-checks.py
    title: TASK-326 runtime checks through the automation endpoint
  - id: task-329
    resource: backlog:TASK-329
    title: "Links: strip tracking parameters with the AdGuard URL Tracking filter in addition to the built-in list"
  - id: filter
    resource: ../../Detour/Browser/TrackingParameterFilter.swift
    title: TrackingParameterFilter.swift (parsing and matching the $removeparam rules)
  - id: list
    resource: ../../Detour/Browser/ContentBlocker/TrackingParameterList.swift
    title: TrackingParameterList.swift (download, cache, refresh, fallback)
  - id: checks-329
    resource: ../../docs/harness/task329-tracking-filter-checks.py
    title: TASK-329 runtime checks (fixture list served locally, Shift-Cmd-C)
  - id: adguard-filter
    resource: https://github.com/AdguardTeam/AdguardFilters/tree/master/TrackParamFilter
    title: AdGuard URL Tracking filter sources (GPL-3.0)
  - id: adguard-kb
    resource: https://adguard.com/kb/general/ad-filtering/create-own-filters/
    title: AdGuard knowledge base, $removeparam and $domain modifiers
  - id: tsurlfilter
    resource: https://github.com/AdguardTeam/tsurlfilter/blob/master/packages/tsurlfilter/src/modifiers/remove-param-modifier.ts
    title: tsurlfilter remove-param-modifier.ts (a plain value becomes an anchored name= regex, no i flag)
---

Detour copies the clean link: whichever button or shortcut copies the
address of a page or tab, the clipboard gets that address without its
tracking parameters (`utm_*`, `fbclid`, `gclid`, …). Only the copied string
changes. The tab's URL, its history visits and its session record keep the
address as it was loaded.

# What it does

| Entry point | Code | Strips |
|---|---|---|
| Edit > Copy URL (Shift-Cmd-C), browser window | `BrowserWindowController.copyCurrentURL` → `copyURL(_:)` | yes |
| The faux address bar's link button (Copy Link) | `fauxAddressBar.onCopyURL` → `copyCurrentURL` | yes |
| A dev-mode page's toolbar link button (its own pane) | `copyURL(_:)` | yes |
| Edit > Copy URL (Shift-Cmd-C), Quick Detour window | `QuickDetourWindowController.copyCurrentURL` | yes |
| Quick Detour's title-bar Copy Link button | `titleBar.onCopyLink` → `copyCurrentURL` | yes |
| The sidebar tab menu's Copy URL / Copy Link (a tab, a split row, a pinned entry live or dormant, a pinned split) | `TabSidebarViewController.contextMenuCopyURL` | yes |
| A page's own context menu, Copy Link on a link | WebKit's item | no |
| The sidebar tab menu's Share… | `makeSharingPicker([TrackingParameters.removing(from: url)])` | yes (see below) |
| Opt-Cmd-click on a sidebar tab or favourite ("a Quick Detour copy") | `QuickDetour.sidebarCopyURL` | no: it picks the address a new Quick Detour *loads*, not a clipboard string |

The three code paths that write the clipboard call
`TrackingParameters.copyableString(for:)`. Each writes to a pasteboard
property (`urlPasteboard`, `.general` by default) that tests replace with a
private one.

**Decision (TASK-326 AC #6, made by Claude while the user was away, not
confirmed by the user):** every Detour command that copies "this page's" or
"this tab's" address strips, so the copied link is the same clean one
whichever button made it. A link copied from inside the page (WebKit's Copy
Link) is the page's content and stays as the page wrote it. Alternative:
strip only Shift-Cmd-C (the task's required scope); flipping it back is a
one-line change per entry point. The dev toolbar is the debatable one: a
developer testing how their own site handles `utm_*` on localhost gets the
clean address from its button too (the palette, Cmd+L, still shows the
full address).[^task-326]

Share… in the sidebar tab menu shares the clean link too (the user's call,
Nov 14 2026, after the first cut had left it alone): it is the other place a
page's address leaves Detour on the user's request, and a link sent from
Detour should be the same clean one whichever way it was sent. The picker is
built through `TabSidebarViewController.makeSharingPicker`, which a test
replaces to see the items.

# How it works

`TrackingParameters` holds the one list and the pure rule; quarantine
pages use the same one for their navigations
([Quarantine](quarantine.md#link-tracking-parameters)), so a name added to
the list changes both.

- **The list** (`TrackingParameters.names`): click IDs (`gclid`, `gclsrc`,
  `dclid`, `gbraid`, `wbraid`, `fbclid`, `msclkid`, `igshid`, `yclid`,
  `twclid`, `ttclid`, `li_fat_id`, `rb_clickid`), Google Analytics' linker
  `_ga`, mail tools' IDs (`mc_eid`, `mc_cid`, `_hsenc`, `_hsmi`, `mkt_tok`,
  `oly_anon_id`, `oly_enc_id`, `vero_id`, `s_cid`), plus any name starting
  with `utm_` (longer than the prefix). Names are compared without case and
  after percent-decoding (`utm%5Fsource` is `utm_source`). A name that only
  resembles one (`ref`, `source`, `utm`, `gclid_extra`, `ga`) is kept.
- **The rule** (`TrackingParameters.removing(from:)`): only http(s) URLs;
  the query is split on `&` in its percent-encoded form, so the parameters
  kept keep their order, repeats and exact bytes (`+`, `%2B`, `%5B%5D`). A
  URL with no tracking parameter is returned as it is, byte for byte. When
  something is removed, empty pieces (`a=1&&b`, a trailing `&`) go too, and
  a query left empty is dropped with its `?`. The fragment is kept, even
  when it looks like a query.

## The downloaded filter (TASK-329)

On top of the built-in names, Copy URL and Share… remove what AdGuard's URL
Tracking filter (filter 17) says to remove for the page's site:
`TrackingParameters.cleanLink(for:)` passes `downloadedFilter` to
`removing(from:using:)`. The built-in names stay the floor: before the first
download, offline, after an error response or a text that parses into no
rule, `downloadedFilter` is whatever was in use (nil at first) and nothing is
shown to the user.[^task-329]

- **The list** is the uBlock Origin build,
  `https://filters.adtidy.org/extension/ublock/filters/17.txt` (about 2,750
  rules, Nov 2026). It is GPL-3.0, so it is downloaded, never bundled; the
  tests use a trimmed, attributed excerpt
  (`DetourTests/TrackingParameterFilterFixture.swift`). AdGuard's own builds
  (`extension/chromium/…`) add global `utm_*`, `_ga` and `oly_enc_id` rules
  the built-in names already cover, and a few more exceptions; the uBO build
  keeps those rules' exceptions (`@@||eneba.com^$removeparam=utm_source`)
  without the rules.[^adguard-filter]
- **Download path**: `TrackingParameterList`, driven by
  `ContentBlockerManager` from launch, Update Now and Clear Cache &
  Redownload with the content blocker's bookkeeping (ETag, `lastFetch`,
  24 hours, the data directory's `ContentBlocker/adguard-url-tracking.txt`).
  It is not one of `filterLists`: it is never compiled into a WebKit rule
  list and has no Settings row or switch. Text is parsed off the main thread
  (`Task.detached`, about 40 ms for the whole list in a Debug build) and
  cached only once it parsed into rules, so a captive portal's page never
  replaces a good cache. Tickets keep an older text (the cache read at
  launch) from replacing a newer one, and refuse text read before a clear.
  The test host never downloads it (`AppDelegate.isRunningUnitTests`); a
  Debug build reads `DETOUR_TRACKING_FILTER_URL` for runtime checks.
  See [Content blocking](content-blocking.md#lists).
- **Matching** (`TrackingParameterFilter`, pure and `Sendable`; a fully
  qualified host's trailing dot is dropped before matching): a copied
  address is a page (a `document` request), so its own host is both what the
  URL pattern is matched against and what `domain=` is checked against, as
  AdGuard and uBlock Origin do for a top-level document.[^adguard-kb] Rules
  are indexed by host (`||host^` / `||host/…`), so a click matches the
  global names, the rules of the address's host and its parents, and a few
  hundred others: about 2 ms per address against the whole list in a Debug
  build.

| Rule form | Example | Handling |
|---|---|---|
| global name | `$removeparam=pjclid` | removed everywhere |
| host pattern | `\|\|supply.amazon.com^$removeparam=ref_` | the host and its subdomains |
| wildcard top level domain | `\|\|amazon.*/stores/$removeparam=lp_asin` | `.*` ending the host is a public suffix (approximation below); `\|\|amazon.*&linkCode=` is a plain `*` |
| open-ended host, substrings | `\|\|read.amazon.`, `&af_xp=$removeparam=c` | Adblock patterns: `\|\|`, `\|`, `^`, `*`, lower-cased address, port included |
| `domain=` | `domain=aboutamazon.com\|amazon.*\|~shop.example` | includes (any) and `~` excludes (none), subdomains included, `name.*` wildcards |
| remove all / all but | `/?affijet-click=$removeparam`, `\|\|go.mysku.ru^$removeparam=~r` | supported; refused without a pattern or included domain (it would strip every address) |
| request types | `$xhr`, `$image`, `$font`, `$3p` | skipped (`notForPages`): a page is none of them; `$document`, `$~xhr`, `$~3p` apply |
| regex | `$removeparam=/^at_custom/`, `/…/` patterns | skipped (`regex`: 42 rules); a regex **exception** keeps every parameter of its addresses from the list's rules instead (not from the built-in names) |
| unknown option | `$app=…`, `$match-case` | block rule skipped (`unsupported`); an exception kept without the option (`widenedExceptions`) |
| `@@` exceptions | `@@\|\|archive.*^$removeparam`, `@@\|\|eneba.com^$removeparam=utm_source` | bare: keeps every parameter; named: keeps that one, compared without case; `$important` on a block rule is ignored, so an exception still wins (the list has no `$important`) |

List names are compared exactly (raw or percent-decoded: `amp;utm_campaign`,
`%243p`) and only on a `name=` pair, as AdGuard's tsurlfilter does (its plain
`$removeparam` becomes an anchored `name=` regex with no `i` flag)[^tsurlfilter]; built-in names stay
case-insensitive and also match a bare `?name`. Patterns are matched against
the whole address including its `#fragment`, which a content blocker never
sees; a substring pattern could match text there (none in the list does). The whole list (2026-11-13) parsed into 2,665
rules (96 exceptions, 1 widened), skipping 42 regex, 46 for other request
types and 1 element-hiding line; each parse logs these counts
("Installed adguard-url-tracking from …") under the `content-blocker`
category.

Wildcard top level domains need a public suffix list Detour does not have.
`isPublicSuffixLike` accepts one label of letters (`com`, `de`, `xn--p1ai`)
or a common second-level label over a two-letter country code (`co.uk`,
`com.au`, `co.jp`), so `amazon.evil.com` is not `amazon.*`; a rarer real
suffix is missed (under-stripping, the safe side).

**Exceptions beat the built-in names (decision by Claude, TASK-329, while
the user was away, not confirmed):** once the list is loaded, a parameter an
exception keeps for the address is kept even if the built-in list names it,
when the exception is taken as written and limited to some addresses (a
pattern or an included domain). A widened exception (a regex, `~name`, an
unknown option such as `$app`) or one for every site cancels only the
list's own rules, so the built-in names stay the floor (the review's
finding: otherwise a widened exception would let `gclid` through).
The uBO build's exceptions exist for exactly those names (archived
addresses whose query is the original link's, `utm_source` sites need), and
a shared link that breaks is worse than one that keeps a tag. Without the
list the built-in names apply everywhere. Alternative: exceptions cancel
only list rules; one line in `TrackingParameters.removing`.

**Quarantine stays on the built-in list (TASK-329 AC #4, PROVISIONAL: chosen
by Claude while the user was away, not confirmed):** `Quarantine.trackingFreeURL`
and `openQuarantine` call `removing(from:)` without the filter. Stripping on
navigation can break the page (the list is tuned for content blockers that
also honour its exceptions per request type), while stripping on copy only
changes the copied text. Alternative: `cleanLink(for:)` in those two calls.

# Edge cases

- A non-web address (`detour://history`, `mailto:`, `file:`) is copied
  unchanged.
- A sleeping or dormant pinned tab's Copy URL strips its stored address the
  same way.
- The toast is unchanged ("URL copied" in a browser window, "Link copied" in
  Quick Detour); it does not say parameters were removed.

# Tests

| Suite | Covers |
|---|---|
| `TrackingParametersTests` | the list (AC #1's names, case, lookalikes kept), order and encoding of the rest, percent-encoded names and values, repeated keys, only-tracking queries and stray `&`, fragments, URLs left unchanged, non-web schemes |
| `CopyURLTests` | in a real browser window with a private pasteboard: `copyCurrentURL`, the Edit menu item's Shift-Cmd-C binding, the faux address bar button, the sidebar's Copy Link (unselected tab), Copy URL (selected tab) and a pinned tab's, each also checking the tab's URL keeps its parameters |
| `DevToolbarHostingTests` | the dev toolbar's link button |
| `QuickDetourWindowTests` | the title bar's Copy Link and `copyCurrentURL` on a loopback page, and the page keeping its address |
| `QuarantineTests`, `QuarantineWindowTests` | the quarantine navigation rule, which uses the same list |
| `TrackingParameterFilterTests` | the downloaded filter on the excerpt: counts by kind, global and per-site rules, wildcard TLDs in patterns and `domain=`, `~` domains, substrings, remove-all / all-but, request types, exceptions (bare, named, regex, widened, other types), case, repeats, list spellings, real-world links unchanged, quarantine on the built-in list; `testTheWholeDownloadedList` runs on a downloaded copy when `TEST_RUNNER_TRACKING_FILTER_FILE` names one |
| `TrackingParameterListTests` | the download path with a stub URLProtocol: first download, cache at launch, conditional refresh, offline, error response, a page that is no list, an unreadable cache, Clear Cache & Redownload, the Debug URL override, the test host downloading nothing |
| `CopyURLTests` (TASK-329 cases) | Copy URL, the sidebar's Copy URL and Share… with the filter installed, and without it |

At runtime (2026-11-14, `docs/harness/task326-copy-url-checks.py` through
the [automation endpoint](automation-endpoint.md)): a loopback page loaded
with `utm_source`, `utm_medium`, `fbclid`, `gclid` and `_ga`; Edit > Copy
URL by menu path, Shift-Cmd-C by key equivalent, the faux address bar's
button and the sidebar row's Copy URL all put the clean address on the
real clipboard (read with `pbpaste`); `list_tabs`, the history database
and the session database kept the tracked address.[^checks] A right click
on a sidebar row's label or icon does not open the tab menu through the
endpoint; one on the row's own background does.

At runtime for TASK-329 (2026-11-14, `docs/harness/task329-tracking-filter-checks.py`):
the excerpt plus rules for `127.0.0.1` served locally through
`DETOUR_TRACKING_FILTER_URL`; the list was fetched and cached, Shift-Cmd-C
and Edit > Copy URL copied the address without its host-pattern,
`domain=`, global-list and built-in parameters, an exception kept its
`utm_source`, the tabs kept their addresses; with the list's URL answering
404, nothing was cached, Shift-Cmd-C fell back to the built-in names and no
alert showed.[^checks-329] A pattern matches the address as written, port
included: `||127.0.0.1/keep/` does not match `127.0.0.1:64903/keep/`.

[^task-326]: TASK-326
[^checks]: docs/harness/task326-copy-url-checks.py
[^task-329]: TASK-329
[^checks-329]: docs/harness/task329-tracking-filter-checks.py
[^adguard-filter]: AdGuard URL Tracking filter sources (GPL-3.0)
[^adguard-kb]: AdGuard knowledge base, $removeparam and $domain modifiers
[^tsurlfilter]: tsurlfilter remove-param-modifier.ts (a plain value becomes an anchored name= regex, no i flag)

# Related

- [Quarantine](quarantine.md#link-tracking-parameters): the built-in list removed from a quarantine page's navigations (not the downloaded filter).
- [Content blocking](content-blocking.md#lists): the filter-list download path the tracking filter shares.
- [WebKit privacy protections](../platform/webkit-privacy-protections.md): WebKit's own click-ID filtering, which keeps `utm_*`.
- [Quick Detour](quick-detour.md): the title bar's Copy Link and the Opt-Cmd-click copy, which is a load, not a clipboard copy.
