---
type: Concept
title: Tracking parameters
description: "The one rule that takes tracking parameters out of a link, shared by Copy URL, Share… and quarantine navigations (TrackingParameters.cleanLink): the built-in names and every utm_, how the query is rewritten, the downloaded AdGuard URL Tracking filter (TASK-329: download and cache, rule forms supported and skipped, matching, fallback), its exceptions beating the built-in names, its switch in Settings > Content Blocking (TASK-337: off, it is neither fetched nor used; the cache is kept), the runtime checks and the tests."
tags: [links, privacy, content-blocking, quarantine]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:41:01Z }
sources:
  - id: rule
    resource: ../../Detour/Browser/TrackingParameters.swift
    title: TrackingParameters.swift (the built-in names, isTracking, removing, cleanLink, copyableString, downloadedFilter)
  - id: filter
    resource: ../../Detour/Browser/TrackingParameterFilter.swift
    title: TrackingParameterFilter.swift (parsing and matching the $removeparam rules)
  - id: list
    resource: ../../Detour/Browser/ContentBlocker/TrackingParameterList.swift
    title: TrackingParameterList.swift (download, cache, refresh, fallback, the switch)
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift (drives the list from launch, Update Now, Clear Cache & Redownload and the switch)
  - id: quarantine-code
    resource: ../../Detour/Browser/QuickDetour/Quarantine.swift
    title: Quarantine.swift (trackingFreeURL)
  - id: task-194
    resource: backlog:TASK-194
    title: "Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose"
  - id: task-326
    resource: backlog:TASK-326
    title: "Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed"
  - id: task-329
    resource: backlog:TASK-329
    title: "Links: strip tracking parameters with the AdGuard URL Tracking filter in addition to the built-in list"
  - id: task-337
    resource: backlog:TASK-337
    title: "Content blocking: a setting for the AdGuard URL Tracking list, so Detour does not fetch it when it is off"
  - id: checks-329
    resource: ../../docs/harness/task329-tracking-filter-checks.py
    title: TASK-329 runtime checks (fixture list served locally, Shift-Cmd-C)
  - id: checks-329q
    resource: ../../docs/harness/task329-quarantine-checks.py
    title: TASK-329 AC #4 runtime checks (a routed link opened in Quarantine, the server's request log)
  - id: checks-337
    resource: ../../docs/harness/task337-tracking-list-setting-checks.py
    title: TASK-337 runtime checks (request log of a local list server, the switch pressed through Accessibility)
  - id: adguard-filter
    resource: https://github.com/AdguardTeam/AdguardFilters/tree/master/TrackParamFilter
    title: AdGuard URL Tracking filter sources (GPL-3.0)
  - id: adguard-kb
    resource: https://adguard.com/kb/general/ad-filtering/create-own-filters/
    title: AdGuard knowledge base, $removeparam and $domain modifiers
  - id: tsurlfilter
    resource: https://github.com/AdguardTeam/tsurlfilter/blob/master/packages/tsurlfilter/src/modifiers/remove-param-modifier.ts
    title: tsurlfilter remove-param-modifier.ts (a plain value becomes an anchored name= regex, no i flag)
  - id: copy-url
    resource: ./copy-url.md
    title: Copy URL
  - id: quarantine
    resource: ./quarantine.md
    title: Quarantine
---

Detour has one rule for taking tracking parameters (`utm_*`, `fbclid`,
`gclid`, …) out of a link, `TrackingParameters.cleanLink(for:)`: a built-in
list of names, plus the downloaded AdGuard URL Tracking filter's site rules
and exceptions while it is loaded and turned on. Every user of the rule gets
the same clean link, so a name added to the list, or a list rule, changes
all of them at once.

# Summary

| User | Code | Effect |
|---|---|---|
| [Copy URL](copy-url.md): every Copy URL / Copy Link of a page or tab (not the dev toolbar's) | `TrackingParameters.copyableString(for:)` → `cleanLink(for:)` | the clipboard string only; the tab, history and session keep the address as loaded |
| Share… in the sidebar tab menu | `makeSharingPicker([TrackingParameters.cleanLink(for: url)])` | the shared link |
| [Quarantine](quarantine.md#link-tracking-parameters): the link a quarantine window opens, and each main-frame GET of its page | `QuickDetourWindowController.openQuarantine`, `Quarantine.trackingFreeURL` → `cleanLink(for:)` | the address the page loads |

The rule began as `Quarantine.removingTrackingParameters` (TASK-194);
TASK-326 moved it out to `TrackingParameters` to share it with Copy URL and
added Google Analytics' linker `_ga` to the names.[^task-326] TASK-329 added
the downloaded filter, TASK-337 its switch.

WebKit's own link decoration filtering (on in quarantine) removed `gclid`,
`fbclid` and `mc_eid` on macOS 26.7 but kept `utm_*` (measured, TASK-194);
the built-in list is the floor whatever WebKit's does (see
[WebKit privacy protections](../platform/webkit-privacy-protections.md)).

# Rules

## The built-in names

`TrackingParameters.names`, checked by `isTracking`:

- click IDs: `gclid`, `gclsrc`, `dclid`, `gbraid`, `wbraid`, `fbclid`,
  `msclkid`, `igshid`, `yclid`, `twclid`, `ttclid`, `li_fat_id`, `rb_clickid`;
- Google Analytics' linker `_ga`;
- mail tools' IDs: `mc_eid`, `mc_cid`, `_hsenc`, `_hsmi`, `mkt_tok`,
  `oly_anon_id`, `oly_enc_id`, `vero_id`, `s_cid`;
- plus any name starting with `utm_` (longer than the prefix).

Names are compared without case and after percent-decoding (`utm%5Fsource`
is `utm_source`), and also match a bare `?name` with no value. A name that
only resembles one (`ref`, `source`, `utm`, `gclid_extra`, `ga`) is kept.

## Removing them

`TrackingParameters.removing(from:using:)` is pure:

- Only http(s) URLs; anything else (`detour://history`, `mailto:`, `file:`)
  comes back unchanged.
- The query is split on `&` in its percent-encoded form, so the parameters
  kept keep their order, repeats and exact bytes (`+`, `%2B`, `%5B%5D`).
- A URL with no tracking parameter is returned as it is, byte for byte.
- When something is removed, empty pieces (`a=1&&b`, a trailing `&`) go
  too, and a query left empty is dropped with its `?`.
- The fragment is kept, even when it looks like a query.

`cleanLink(for:)` is `removing(from: url, using: downloadedFilter)`;
`copyableString(for:)` is its `absoluteString`.

## The downloaded filter (TASK-329)

On top of the built-in names, every user of the rule removes what AdGuard's
URL Tracking filter (filter 17) says to remove for the page's site:
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
  list; its switch is in Settings > Content Blocking (below). Text is parsed off the main thread
  (`Task.detached`, about 40 ms for the whole list in a Debug build) and
  cached only once it parsed into rules, so a captive portal's page never
  replaces a good cache. Tickets keep an older text (the cache read at
  launch) from replacing a newer one, and refuse text read before a clear.
  The test host never downloads it (`AppDelegate.isRunningUnitTests`); a
  Debug build reads `DETOUR_TRACKING_FILTER_URL` for runtime checks.
  See [Content blocking](content-blocking.md#lists).
- **Matching** (`TrackingParameterFilter`, pure and `Sendable`; a fully
  qualified host's trailing dot is dropped before matching): a link is a
  page (a `document` request), so its own host is both what the
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
| `$badfilter` | `$removeparam=foo,badfilter` | drops the rule (or exception) it names, as EasyListParser does for the content blocker lists; both counted as `other` |
| exception for every address | `@@$removeparam=~bar` | refused unless it names a single parameter (it would switch the whole list off) |

List names are compared exactly (raw or percent-decoded: `amp;utm_campaign`,
`%243p`) and only on a `name=` pair, as AdGuard's tsurlfilter does (its plain
`$removeparam` becomes an anchored `name=` regex with no `i` flag)[^tsurlfilter]; built-in names stay
case-insensitive and also match a bare `?name`. Patterns are matched against
the address without its `#fragment`, as a request URL (what the list is
written for) never has one; a single-page app's hash route cannot trigger a
rule. A pattern matches the address as written, port included:
`||127.0.0.1/keep/` does not match `127.0.0.1:64903/keep/`.[^checks-329]
The whole list (2026-11-13) parsed into 2,665
rules (96 exceptions, 1 widened), skipping 42 regex, 46 for other request
types and 1 element-hiding line; each parse logs these counts
("Installed adguard-url-tracking from …") under the `content-blocker`
category.

Wildcard top level domains need a public suffix list Detour does not have.
`isPublicSuffixLike` accepts one label of at least two ASCII letters
(`com`, `de`) or a punycode one (`xn--p1ai`), or one of 21 common
second-level labels (`co`, `com`, `org`, `ac`, `ne`, `gob`, …) over a
two-letter country code (`co.uk`, `com.au`, `co.jp`), so `amazon.evil.com` is not `amazon.*`; a rarer real
suffix is missed (under-stripping, the safe side).

## Exceptions beat the built-in names

**Decision (TASK-329; first chosen by Claude, confirmed by the user on
2026-11-14 as built):**[^task-329] once the list is loaded, a parameter an
exception keeps for the address is kept even if the built-in list names it,
when the exception is taken as written and limited to some addresses (a
pattern or an included domain; `Rule.overridesBuiltInNames`). A widened
exception (a regex, `~name`, an unknown option such as `$app`) or one for
every site cancels only the list's own rules, so the built-in names stay the
floor (the review's finding: otherwise a widened exception would let
`gclid` through). The uBO build's exceptions exist for exactly those names
(archived addresses whose query is the original link's, `utm_source` sites
need), and a shared link that breaks is worse than one that keeps a tag.
Without the list the built-in names apply everywhere. Rejected alternative:
exceptions cancel only list rules (one line in `TrackingParameters.removing`).

## Quarantine navigations use the filter too

**Decision (TASK-329 AC #4, the user's, 2026-11-14):**
`Quarantine.trackingFreeURL` and `openQuarantine` call `cleanLink(for:)`, so
a quarantine page loads without the site parameters a copy of it would leave
out, and keeps those the list's exceptions keep (a built-in name included,
as above). With the list off or not downloaded they fall back to the
built-in names, as copies do. The first cut (a provisional choice while the
user was away) kept quarantine on the built-in names, because stripping on
navigation can break a page (the list is tuned for content blockers that
also honour its exceptions per request type) while stripping on copy only
changes the copied text; the user chose one rule for both.[^task-329] A page
that needs a stripped parameter and sends itself back to it is let through
the second time (`QuarantineTrackingRewrites`; see
[Quarantine](quarantine.md#link-tracking-parameters)).

## Turning it off (TASK-337)

Settings > Content Blocking > Tracking Parameters has a switch for the list, on by
default (`TrackingParameterList.isEnabled`, the defaults key
`ContentBlocker.adguard-url-tracking.enabled` in the data directory's content
blocker suite, beside the list's fetch bookkeeping; the pane is described in
[Settings panes](settings-panes.md#content-blocking)).[^task-337] The switch calls
`ContentBlockerManager.setTrackingParameterListEnabled`. The gate is in
`TrackingParameterList`, not the manager, so the tests reach it (the
manager's own gate is the test host's, `downloadsTrackingParameterList`):

| While off | What happens |
|---|---|
| Launch (`loadAtLaunch`) | nothing: no request, and the cached text is not even read, so Copy URL, Share… and quarantine use the built-in names alone |
| Update Now (`refresh`) | `.off`, no request |
| Clear Cache & Redownload | the cached text, ETag, `lastFetch` and rule count are deleted like the other lists', and nothing is downloaded |
| Turning it off (`setEnabled(false)`) | the rules in use are dropped at once (`install(nil)`) and every ticket taken so far is superseded, so a download already in flight is neither installed nor cached |
| Turning it on (`setEnabled(true)`, then `turnedOn()`) | the cached rules are installed, then the list is fetched: conditional on the cached text's ETag, in full when there is no cache. Offline, the cached rules stay in use |

**The cache is kept while off (the user's decision, 2026-11-14, keeping
what was built).**[^task-337] Turning the list on again then works
offline and costs a 304. Rejected alternative: delete the cached text when it is
turned off (a one-line change in `setEnabled`), so an off list leaves nothing
on disk. Clear Cache & Redownload while off deletes it, since that is what
the button says, but downloads nothing; turning the list on then downloads
it in full.

# Where it lives

| What | Where |
|---|---|
| Built-in names, the rule, `cleanLink`, `downloadedFilter` | [TrackingParameters.swift](../../Detour/Browser/TrackingParameters.swift) |
| Parsing and matching the list | [TrackingParameterFilter.swift](../../Detour/Browser/TrackingParameterFilter.swift) |
| Download, cache, refresh, switch | [TrackingParameterList.swift](../../Detour/Browser/ContentBlocker/TrackingParameterList.swift), driven by [ContentBlockerManager.swift](../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift) |
| Cached text | `<data directory>/ContentBlocker/adguard-url-tracking.txt` |
| Bookkeeping and switch | defaults `ContentBlocker.adguard-url-tracking.etag` / `.lastFetch` / `.ruleCount` / `.enabled` in the data directory's content blocker suite |

# Runtime checks

TASK-329 (2026-11-14, `docs/harness/task329-tracking-filter-checks.py`):
the excerpt plus rules for `127.0.0.1` served locally through
`DETOUR_TRACKING_FILTER_URL`; the list was fetched and cached, Shift-Cmd-C
and Edit > Copy URL copied the address without its host-pattern,
`domain=`, global-list and built-in parameters, an exception kept its
`utm_source`, the tabs kept their addresses; with the list's URL answering
404, nothing was cached, Shift-Cmd-C fell back to the built-in names and no
alert showed.[^checks-329]

Quarantine (2026-11-14, TASK-329 AC #4,
`docs/harness/task329-quarantine-checks.py`): a Link Route sent a link
clicked on a `localhost` page to Quarantine (a click to the same host is
never routed). With the list served, the local server's only request for
the link was `/probe.html?id=1`: the host rule's `ref_`, the global list
name `pjclid` and the built-in `utm_source` never reached it. With the
list's URL answering 404 it was `/probe.html?id=1&ref_=nav&pjclid=7`, the
built-in names alone.[^checks-329q]

TASK-337 (2026-11-14, `docs/harness/task337-tracking-list-setting-checks.py`:
a local server logging every request for the list through
`DETOUR_TRACKING_FILTER_URL`, the switch and buttons pressed through
Accessibility, one data directory over two launches).[^checks-337] On by
default, the list was requested once at launch and cached, and Shift-Cmd-C
left out its site parameters. Off, Shift-Cmd-C kept them (built-in names
only), and Update All Now, a relaunch and Clear Cache & Redownload made no
request for it (Clear Cache deleted its text). With the server answering
503, turning it on made one request and the cached rules were in use
again; turning it on after the clear made one full request and cached the
list again. Three requests in all, each from a step that should make one.

# Tests

| Suite | Covers |
|---|---|
| `TrackingParametersTests` | the list (TASK-326 AC #1's names, case, lookalikes kept), order and encoding of the rest, percent-encoded names and values, repeated keys, only-tracking queries and stray `&`, fragments, URLs left unchanged, non-web schemes |
| `TrackingParameterFilterTests` | the downloaded filter on the excerpt: counts by kind, global and per-site rules, wildcard TLDs in patterns and `domain=`, `~` domains, substrings, remove-all / all-but, request types, exceptions (bare, named, regex, widened, other types), case, repeats, list spellings, real-world links unchanged, quarantine navigations with and without the filter; `testTheWholeDownloadedList` runs on a downloaded copy when `TEST_RUNNER_TRACKING_FILTER_FILE` names one |
| `TrackingParameterListTests` | the download path with a stub URLProtocol: first download, cache at launch, conditional refresh, offline, error response, a page that is no list, an unreadable cache, Clear Cache & Redownload, the Debug URL override, the test host downloading nothing; the TASK-337 switch: on by default and stored in the list's defaults, off at launch (no request, cache not read, kept), refresh and Clear Cache while off (no request), turning off (rules dropped, cache kept, a response in flight dropped), turning on (cached rules offline plus a conditional fetch; a full one without a cache), the pane's status line |
| `SettingsSwitchRowTests` (TASK-337 case) | the pane's switch shows and writes the setting and is named by its label (a grouped-form row since TASK-338; `SettingsFormTests` checks its status line keeps its identifier and row) |
| `QuarantineTests`, `QuarantineWindowTests` | the quarantine navigation rule with the downloaded filter: with it loaded a per-site rule and an exception apply, a list-only parameter never reaches a loopback server from the opened link or a click; without it the built-in names alone |
| `CopyURLTests` (TASK-329 cases) | Copy URL, the sidebar's Copy URL and Share… with the filter installed, and without it (see [Copy URL](copy-url.md#tests)) |

[^task-326]: TASK-326
[^task-329]: TASK-329
[^task-337]: TASK-337
[^checks-329]: docs/harness/task329-tracking-filter-checks.py
[^checks-329q]: docs/harness/task329-quarantine-checks.py
[^checks-337]: docs/harness/task337-tracking-list-setting-checks.py
[^adguard-filter]: AdGuard URL Tracking filter sources (GPL-3.0)
[^adguard-kb]: AdGuard knowledge base, $removeparam and $domain modifiers
[^tsurlfilter]: tsurlfilter remove-param-modifier.ts (a plain value becomes an anchored name= regex, no i flag)

# Related

- [Copy URL](copy-url.md): the clipboard entry points that use the rule, and the one that does not (the dev toolbar).
- [Quarantine](quarantine.md#link-tracking-parameters): when a quarantine page's navigations are rewritten, what is left alone, and the rewrite budget.
- [Content blocking](content-blocking.md#lists): the filter-list download path the tracking filter shares.
- [Settings panes](settings-panes.md#content-blocking): the Tracking Parameters section of the Content Blocking pane.
- [WebKit privacy protections](../platform/webkit-privacy-protections.md): WebKit's own click-ID filtering, which keeps `utm_*`.
