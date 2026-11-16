---
type: Feature
title: Content blocking
description: "The built-in blocker: EasyList-family filter lists compiled to WKContentRuleLists, per-profile list toggles, how lists reach web views, the blocked-resource counter and where state lives; this hub links the pages on conversion, compilation, chunks, Clear Cache & Redownload and the per-site switch."
tags: [content-blocker, webkit, profiles, spi, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T17:25:00Z }
sources:
  - id: task-329
    resource: backlog:TASK-329
    title: "Links: strip tracking parameters with the AdGuard URL Tracking filter in addition to the built-in list"
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift
  - id: rule-store
    resource: ../../Detour/Browser/ContentBlocker/ContentRuleStore.swift
    title: ContentRuleStore.swift (ContentBlockerStorage, ContentRuleStore)
  - id: parser
    resource: ../../Detour/Browser/ContentBlocker/EasyListParser.swift
    title: EasyListParser.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (the blocked-load callback)
  - id: live-pages
    resource: ../../Detour/Browser/ContentBlocker/TabStore+ContentBlocking.swift
    title: TabStore+ContentBlocking.swift (contentBlockingPages, replaceContentRuleListsOnLivePages)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Space.makeWebViewConfiguration, makeUserContentController)
  - id: quick-detour
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController+WebKit.swift
    title: QuickDetourWindowController+WebKit.swift
  - id: quick-detour-window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift (contentBlockerRulesDidChange)
  - id: quick-detour-blocking-tests
    resource: ../../DetourTests/QuickDetourContentBlockingTests.swift
    title: QuickDetourContentBlockingTests.swift
  - id: doc
    resource: ../../docs/content-blocking.md
    title: docs/content-blocking.md
  - id: task-69
    resource: backlog:TASK-69
    title: The "Block content on this site" switch does not take effect
  - id: task-36
    resource: backlog:TASK-36
    title: Stop the test host writing WebKit data into the production app's WebKit directory
  - id: whitelist-tests
    resource: ../../DetourTests/ContentBlockerWhitelistTests.swift
    title: ContentBlockerWhitelistTests.swift
  - id: blocker-tests
    resource: ../../DetourTests/ContentBlockerTests.swift
    title: ContentBlockerTests.swift
  - id: task-351
    resource: backlog:TASK-351
    title: "Content blocking: a filter list's $removeparam line compiles into a block rule for the whole host"
  - id: task-359
    resource: backlog:TASK-359
    title: "Content blocking: an open Quick Detour window keeps the rule lists it was created with"
  - id: task-368
    resource: backlog:TASK-368
    title: "Content blocking: a rules change reaches only the selected tab's panes; background tabs keep their old lists"
  - id: live-page-tests
    resource: ../../DetourTests/LivePageContentBlockingTests.swift
    title: LivePageContentBlockingTests.swift
---

# What it does

Detour blocks ads, trackers, cookie notices and known-malicious URLs with
WebKit's `WKContentRuleList`. Four filter lists are fetched, converted from
AdBlock Plus syntax to WebKit rule JSON, compiled, and attached to each tab's
user content controller according to the tab's
[profile](../architecture/profiles-and-spaces.md). A per-site switch in the
sidebar's settings popover ("Block content on this site") turns blocking off
for one host in one profile, and the popover shows how many resources were
blocked on the current page.

# How it works

## Lists

| Identifier | Shown as | Profile toggle |
|---|---|---|
| `easylist` | EasyList (ads) | `isEasyListEnabled` |
| `easyprivacy` | EasyPrivacy (trackers) | `isEasyPrivacyEnabled` |
| `easylist-cookie` | Cookie notices | `isEasyListCookieEnabled` |
| `urlhaus-filter` | Malicious URLs | `isMalwareFilterEnabled` |

`Profile.isAdBlockingEnabled` is the master switch. The toggles live in
Settings > Profiles; list status and refresh live in Settings > Content
Blocking (see [settings](./settings.md)).

A fifth list rides along without being one of them: AdGuard's URL Tracking
filter (`adguard-url-tracking`, `TrackingParameterList`, TASK-329). It is
fetched at launch, by Update Now and by Clear Cache & Redownload with the
same ETag / `lastFetch` / 24-hour bookkeeping and cache folder, but it is
parsed into `$removeparam` rules for Copy URL, Share… and quarantine ([Tracking parameters](tracking-parameters.md#the-downloaded-filter-task-329))
instead of being compiled for WebKit; it has no profile switch but one
app-wide switch in Settings > Content Blocking (TASK-337: off, it is neither
fetched nor used, by any of the three paths; see
[Tracking parameters](tracking-parameters.md#turning-it-off-task-337)), the test host never
downloads it, and a Debug build takes its address from
`DETOUR_TRACKING_FILTER_URL`. `EasyListParser` leaves out a `$removeparam`
rule, and any other rule with an option it does not support, block or `@@`
(TASK-351; before, `$removeparam=name` compiled as a block rule for its
pattern). None of the four lists above had a `$removeparam` line on
2026-11-15; see
[unsupported options](./content-blocking-filter-conversion.md#options-the-parser-does-not-support-task-351).[^task-351]

## Fetch, parse, compile

`ContentBlockerManager.shared.initialize()` runs at launch. For each list it
asks WebKit's store for an already compiled list; if there is one **and** it
was compiled from the parser's current output, it only checks whether a
refresh is due (24 hours since `lastFetch`). Otherwise it compiles from the
cached text file, and fetches when there is no cache. A list compiled from an
older parser output is recompiled even though nothing was fetched: see
[recompiling after a parser change](./content-blocking-filter-conversion.md#recompiling-after-a-parser-change).

- **Fetch** is conditional (`If-None-Match` with the stored ETag,
  `If-Modified-Since`). A 304 only moves the timestamp. The fetch that stands
  in for a missing or uncompilable cache at launch is not
  (`fetchAndCompile(list:conditional: false)`): an unchanged list would
  answer 304 and leave nothing to compile, so a list found in an old format
  would stay attached as it was.
- **Parse** (`EasyListParser`) emits `block`, `ignore-previous-rules` (for `@@`
  exceptions) and `css-display-none` (for `##` element hiding) rules, ordered
  by section, not by file order, and skips what WebKit cannot express; see
  [filter-list conversion](./content-blocking-filter-conversion.md),
  [domain lists](./content-blocking-domain-lists.md) and
  [exceptions and element hiding](./content-blocking-exceptions.md).
- **Compile** (`ContentRuleStore`) encodes the rules to JSON and hands it
  to `WKContentRuleListStore`, stripping individually bad rules by bisection
  when the whole list fails; see
  [rule-list compilation](./content-blocking-rule-compilation.md) (and its
  queues and ordering rules). A list over the 150,000-rule cap is compiled as
  several rule lists ([chunks](./content-blocking-chunks.md)), and
  [Clear Cache & Redownload](./content-blocking-clear-cache.md) supersedes
  every compile under way.

Every successful compile posts `.contentBlockerRulesDidChange`
(`reapplyRuleLists`); status changes post `.contentBlockerStatusDidChange` for
the Settings pane.

## Attaching lists to web views

`Space.makeWebViewConfiguration()` calls
`ContentBlockerManager.applyRuleLists(to:profile:)` (through
`Space.makeUserContentController(for:)`), which adds the rule lists
of `ruleLists(for:in:)`: every compiled chunk of each enabled list when the
master switch is on (or, for a list cleared and not compiled again yet, the
chunks the clear removed, TASK-369), and nothing else. It adds no user script, so it is safe
to call again after `removeAllContentRuleLists()`.

A rules change reaches a web view that already exists through
`ContentBlockerManager.replaceRuleLists(on:profile:from:)`: every rule list
is removed and the profile's current ones are added, so a list switched off,
recompiled (a refresh) or cleared and compiled again (Clear Cache &
Redownload) leaves nothing behind. Who calls it on
`.contentBlockerRulesDidChange`:

| Observer | Pages it replaces the lists on |
|---|---|
| `TabStore.replaceContentRuleListsOnLivePages` (the shared store only, `TabStore+ContentBlocking.swift`) | every page of `contentBlockingPages`, once each: each space's tabs and pinned backing tabs with the space's profile, each profile's favourites' backing tabs with that profile, and the Peek of any of them with its host's profile. Selected or not, in whichever window shows it: a web view exists once, so there is no ownership to check. Left out: a sleeping tab (its next web view is built with the current lists), a page built from an extension context's configuration (`servedExtensionOriginHost`: it never got lists, and that controller is the extension's), a space without a usable profile, and Quick Detour pages (next row). |
| `QuickDetourWindowController.contentBlockerRulesDidChange` | its one page, a [Quick Detour](./quick-detour.md)'s or a [quarantine](./quarantine.md)'s, with the lists of the window's current profile (the Private profile for a quarantine). The window is the page's only host, so there is no ownership to check. |

Until TASK-368 a browser window replaced the lists only on its selected
tab's panes, and only when it owned their web view: a background tab, a
background split pair, a Peek or a pinned tab kept the lists it was created
with until its web view was rebuilt (a wake) or it was the selected tab when
a later change was posted. Tests switched a list off and recompiled one
with every kind of page open and only the selected tab followed. Since,
a background tab polling a loopback server asks for EasyPrivacy's
`/1pixel.php` from its first poll after the list is switched off in
Settings > Profiles and stops once it is back on, without being selected
(seen at runtime).[^task-368] The
pass moved to the store rather than going over every tab in each window:
two windows showing one space would each touch the same web views.

Until TASK-359 no Quick Detour window observed the notification, and an
open Quick Detour or quarantine page kept the lists it was created with: a
test showed a list switched off still blocking there, and a recompiled
list's old rule still blocking while its new one did not.[^task-359]

Clear Cache & Redownload itself posts no rules change. Until a cleared list
compiles again, every page, open or opened meanwhile, keeps blocking with
its old rules: the store keeps the removed chunks for attaching only
(`ContentRuleStore.attachableLists(forList:)`), so the first list to
compile again no longer strips the others from every page; see
[the pages between the clear and the recompile](./content-blocking-clear-cache.md#pages-between-the-clear-and-the-recompile)
(TASK-369).

## The per-site switch

A switch in the sidebar's settings popover turns blocking off for one host in
one profile. It is a host list in the [site settings](../architecture/site-settings.md)
table, enforced per main-frame navigation with the private
`-[WKWebpagePreferences _setContentBlockersEnabled:]`, and kept in memory
only in a Private window. A whitelist rule list was tried first and could
never work. See [the per-site switch](./content-blocking-per-site-switch.md).

## The blocked counter

WebKit reports each load a rule list acted on through the private navigation
delegate callback
`_webView:contentRuleListWithIdentifier:performedAction:forURL:`, implemented
on `BrowserWindowController` (and on Quick Detour's window controller for its
page). When the `_WKContentRuleListAction`'s
`blockedLoad` is true the owning tab calls `recordBlockedLoad(of:)`, which
counts a URL once per page: WebKit fires once per list that acted, and the
lists overlap. `BrowserTab.blockedCount` (`@Published`) resets in `load` and
on every committed navigation. A page with content blockers disabled produces
no callbacks at all. A list split into [chunks](./content-blocking-chunks.md)
changes nothing here: WebKit reports per rule list, and the tab counts a URL
once per page.

# Pages

- [Filter-list conversion](./content-blocking-filter-conversion.md) — `EasyListParser`: what it emits and skips, regex rewriting, rules with unsupported options such as `$removeparam` left out (TASK-351), and recompiling installed lists after a parser change (`rulesFormatVersion`).
- [Domain lists](./content-blocking-domain-lists.md) — one page condition per trigger: the most-specific-domain rule, `if-top-url` label-complement patterns, punycode, bad-rule counts per list (TASK-201).
- [Exceptions and element hiding](./content-blocking-exceptions.md) — what WebKit does with `ignore-previous-rules`, the parser's section order, each `@@` option, the file-order bug, options rejected, size and compile time (TASK-199, TASK-162).
- [Rule-list compilation](./content-blocking-rule-compilation.md) — `ContentRuleStore`'s compile and bad-rule bisection, which queue each step runs on, what WebKit requires on main, and the ordering rules (TASK-200, TASK-231.3).
- [Chunks](./content-blocking-chunks.md) — lists over the 150,000-rule cap: the list-level operations, what each chunk holds, how close the lists are, what splitting does not solve (TASK-145, TASK-155).
- [Clear Cache & Redownload](./content-blocking-clear-cache.md) — how work under way at the clear is refused at every stage, refresh tokens, and the runtime runs (TASK-202).
- [The per-site switch](./content-blocking-per-site-switch.md) — the site list, per-navigation enforcement through the preferences SPI, Private windows, matching, and why it is not a rule list (TASK-69, TASK-195).

# Edge cases and gotchas

- **Two private selectors.** Both are guarded by `responds(to:)`. The
  preferences setter logs once and does nothing if WebKit drops it; the
  `blockedLoad` key is read through KVC, where an undefined key would raise an
  Objective-C exception on every blocked load.
  `testTheContentBlockerPreferencesSPIExists` fails if the setter disappears.
  Both were present on macOS 26.6.2.[^task-69]
- **Storage is shared by bundle identifier.** WebKit's default rule list store
  and the standard defaults domain belong to the bundle id, so a test host or
  an isolated `DETOUR_DATA_DIR` run would compile into, and refresh, the
  production app's lists. `ContentBlockerStorage.forDataDirectory(named:)`
  gives any non-default data directory its own store, cache directory and
  defaults suite.[^task-36]
- **Port 9 (and WebKit's other restricted ports) never reach the content
  blocker.** A test page loading `http://127.0.0.1:9/x.js` reports no
  blocked load because WebKit refuses the port first; use an unused high
  port.
- **Checking a Quick Detour at runtime.** A plain path rule such as
  EasyPrivacy's `/1pixel.php` blocks on `127.0.0.1`, so a loopback page with
  that image works as a probe. The endpoint's page tools do not reach a
  Quick Detour's page, so read the fixture server's request log instead
  (blocked = never requested); Settings > Profiles' list switches have no
  identifiers but `hit_test` names them by label (TASK-359).[^task-359]
- **Local fixtures and generic hiding.** Generic hiding is off on
  `127.0.0.1` and `localhost` (EasyList's `$generichide` lines); use `lvh.me`.
  See [exceptions and element hiding](./content-blocking-exceptions.md#gotchas).

The gotchas of one part (a split list is several rule lists, bisection probe
lists, "No individual bad rules found", subframe navigations) are on that
part's page.

# Where state lives

| Data | Location |
|---|---|
| Raw list text | `<data directory>/ContentBlocker/<identifier>.txt` under Application Support (`adguard-url-tracking.txt` too, written only once it parsed into rules) |
| Compiled lists | WebKit's default `WKContentRuleListStore`, or `<data directory>/ContentRuleLists` for a non-default data directory. One rule list per chunk: `<id>`, `<id>-1`, … ([chunks](./content-blocking-chunks.md)) |
| Fetch metadata | defaults keys `ContentBlocker.<id>.lastFetch`, `.etag`, `.ruleCount`, `.rulesFormat` (parser output format of the last successful compile); `ContentBlocker.adguard-url-tracking.enabled` is the tracking list's switch (TASK-337) |
| Compile metadata | defaults keys `ContentBlocker.<chunk id>.compiledRuleCount` per compiled chunk, and `ContentBlocker.<id>.chunkCount` for a list of more than one chunk |
| Whitelist | `siteSetting` rows (`contentBlocking`) in the [session database](../architecture/session-database.md); rows go with the profile; none for the Private profile, whose switch stays in memory ([per-site switch](./content-blocking-per-site-switch.md)) |

# Tests

- `ContentBlockerTests` - storage isolation per data directory, parser cases,
  and compiling each cached real list through WebKit.
- `QuickDetourContentBlockingTests` - an open Quick Detour or quarantine
  page after a rules change, in a real window with its rule store swapped
  for a private one: a list switched off stops blocking (the Private
  profile's for a quarantine), and a list recompiled after `invalidateAll`
  blocks with its new rule and no longer with its old. The page `fetch`es
  one path per list from a loopback server, so loaded and blocked are both
  reported, and the window's blocked count must match. All three failed
  before the fix (TASK-359).
- `LivePageContentBlockingTests` - the browser window's pages after a
  rules change, with `TabStore.shared.contentRuleStore` swapped for a private
  store and the same two-path fetch: the selected tab, a background tab, its
  Peek, a background split pair and a pinned tab all stop blocking with a
  list switched off and block with a recompiled list's new rule only, none
  of them selected meanwhile; another profile's tab keeps its own lists; and
  which pages `contentBlockingPages` reaches (a favourite too; not a sleeping
  tab, a Quick Detour or an extension page). The first two failed for every
  page but the selected one before the fix (TASK-368).
- `ContentBlockerWhitelistTests` - the per-site switch, and two
  real-`WKWebView` tests: one `blockedLoad` callback with blocking on, none
  when the navigation's preferences disable content blockers; the counter's
  dedup and reset. Detail on [the per-site switch](./content-blocking-per-site-switch.md#tests).
- The parser's suites (`ContentBlockerExceptionTests`,
  `ContentBlockerDomainListTests`) are on
  [exceptions](./content-blocking-exceptions.md#tests) and
  [domain lists](./content-blocking-domain-lists.md#tests); the store's
  (`ContentRuleStoreThreadingTests`, `ContentRuleListChunkTests`) on
  [rule-list compilation](./content-blocking-rule-compilation.md#tests),
  [Clear Cache & Redownload](./content-blocking-clear-cache.md#tests) and
  [chunks](./content-blocking-chunks.md#tests).

# Related

- [Settings](./settings.md) - the Content Blocking pane and the per-profile toggles.
- [Tracking parameters](./tracking-parameters.md) - the AdGuard URL Tracking list that shares the download path.
- [BrowserTab](../architecture/browser-tab.md) - the tab's own navigation delegate for unclaimed web views.
- [Profile data removal](../architecture/profile-data-removal.md) - storage scoping per data directory, and what goes when a profile is deleted.
- [WebKit test-host traps](../platform/webkit-test-host-traps.md) - other state the test host shares with the production app.
- [WebKit source lookup](../platform/webkit-source-lookup.md) - how the rule-list evaluation was confirmed.

[^task-36]: Stop the test host writing WebKit data into the production app's WebKit directory
[^task-69]: The "Block content on this site" switch does not take effect
[^task-351]: Content blocking: a filter list's $removeparam line compiles into a block rule for the whole host
[^task-359]: Content blocking: an open Quick Detour window keeps the rule lists it was created with
[^task-368]: Content blocking: a rules change reaches only the selected tab's panes; background tabs keep their old lists
