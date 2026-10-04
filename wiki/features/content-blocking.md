---
type: Feature
title: Content blocking
description: "The built-in blocker: EasyList-family filter lists compiled to WKContentRuleLists, per-profile list toggles, the per-site switch implemented through a WebKit preferences SPI, and the blocked-resource counter."
tags: [content-blocker, webkit, profiles, spi, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
sources:
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift
  - id: rule-store
    resource: ../../Detour/Browser/ContentBlocker/ContentRuleStore.swift
    title: ContentRuleStore.swift (ContentBlockerStorage, ContentRuleStore)
  - id: parser
    resource: ../../Detour/Browser/ContentBlocker/EasyListParser.swift
    title: EasyListParser.swift
  - id: whitelist
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerWhitelist.swift
    title: ContentBlockerWhitelist.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (handleContentBlockerRulesChanged)
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

## Fetch, parse, compile

`ContentBlockerManager.shared.initialize()` runs at launch. For each list it
asks WebKit's store for an already compiled list; if there is one it only
checks whether a refresh is due (24 hours since `lastFetch`). Otherwise it
compiles from the cached text file, and fetches when there is no cache.

- **Fetch** is conditional (`If-None-Match` with the stored ETag,
  `If-Modified-Since`). A 304 only moves the timestamp.
- **Parse** (`EasyListParser`) emits `block`, `ignore-previous-rules` (for `@@`
  exceptions) and `css-display-none` (for `##` element hiding) rules. It skips
  what WebKit cannot express: extended CSS and snippet filters (`#?#`, `#$#`),
  element-hiding exceptions (`#@#`), and blocking rules with `popup`,
  `websocket`, `webrtc`, `csp`, `rewrite`, `redirect` or `ping` options. ABP
  regex literals are rewritten: `{n,m}` quantifiers are expanded into repeated
  atoms and `(a|b)` disjunctions into several rules, because WebKit's rule
  regex supports neither.
- **Compile** (`ContentRuleStore`) hands the JSON to
  `WKContentRuleListStore`. On a compile error it bisects the rules
  (`findBadRules`, depth capped at 20, serial) to find and strip the
  individually bad ones, then recompiles.

Every successful compile posts `.contentBlockerRulesDidChange`
(`reapplyRuleLists`); status changes post `.contentBlockerStatusDidChange` for
the Settings pane.

## Attaching lists to web views

`Space.makeWebViewConfiguration()` calls
`ContentBlockerManager.applyRuleLists(to:profile:)`, which adds each enabled
list's compiled `WKContentRuleList` when the master switch is on, and nothing
else. It adds no user script, so it is safe to call again after
`removeAllContentRuleLists()`.

On `.contentBlockerRulesDidChange`,
`BrowserWindowController.handleContentBlockerRulesChanged` removes and re-adds
the lists **only on the selected tab's panes, and only when this window owns
the web view**. Each tab has its own configuration, so other tabs keep the
lists they were created with until their web view is rebuilt (a wake) or they
are the selected tab when a later change is posted.

## The per-site switch

The whitelist is a persisted host set per profile (`contentBlockerWhitelist`
table, unique on `(profileID, host)`). Enforcement is per **navigation**, the
way Safari's per-site content-blocker switch works:

1. Both navigation delegates implement the *preferences* variant,
   `webView(_:decidePolicyFor:preferences:)`. Returning a
   `WKWebpagePreferences` is the only way to change blocking for a page, and
   WebKit calls only one of the two variants.
2. For an allowed **main-frame** navigation whose host is covered by the
   navigating tab's profile's whitelist, `ContentBlockerManager.configure`
   calls the private `-[WKWebpagePreferences _setContentBlockersEnabled:NO]`.
   That disables every rule list for the document and all of its subresource
   and subframe loads.
3. The profile is the **navigating tab's** (`tab(owning:)?.owningProfile`),
   not the window's active space: the window stays delegate of a tab's web
   view after a space switch.
4. A tab no window has claimed yet is its own web view's navigation delegate
   for exactly this decision, so a background-opened tab gets the switch too.

Because the switch acts at navigation time, toggling it reloads every pane
this window shows for that host (split members and the Peek), not just the
display tab.

Matching (`ContentBlockerWhitelist.covers`) is case-insensitive: a host is
covered by an exact entry or by an entry for a parent domain. Turning blocking
off stores the page's exact host, lowercased. Turning it back on removes
**every** entry covering the host, a parent-domain entry included; leaving the
parent would keep the site whitelisted and the switch would appear not to
take.

## The blocked counter

WebKit reports each load a rule list acted on through the private navigation
delegate callback
`_webView:contentRuleListWithIdentifier:performedAction:forURL:`, implemented
on `BrowserWindowController`. When the `_WKContentRuleListAction`'s
`blockedLoad` is true the owning tab calls `recordBlockedLoad(of:)`, which
counts a URL once per page: WebKit fires once per list that acted, and the
lists overlap. `BrowserTab.blockedCount` (`@Published`) resets in `load` and
on every committed navigation. A page with content blockers disabled produces
no callbacks at all.

# Why the per-site switch is not a rule list

The first implementation compiled a separate "whitelist" list of
`ignore-previous-rules` rules with `if-domain` triggers. It never worked.
WebKit evaluates each `WKContentRuleList` **independently** and merges their
Block results, so `ignore-previous-rules` only cancels rules in its *own*
list; the order the lists are added in is irrelevant (read from WebKit's
`ContentExtensionsBackend.cpp`).[^task-69] The old counter was wrong too: it
counted element `error` events from an injected script, which is every failed
image or script load, blocked or not. Together they produced "12 resources
blocked" on a page whose blocking was switched off.

`initialize()` still removes the retired `content-blocker-whitelist-<uuid>`
lists that earlier builds compiled; nothing else would ever delete them.

The same WebKit rule has a consequence inside the parser: an EasyList `@@`
exception only cancels blocks from the **same** list. An exception in
EasyPrivacy cannot un-block something EasyList blocks.

# Edge cases and gotchas

- **Two private selectors.** Both are guarded by `responds(to:)`. The
  preferences setter logs once and does nothing if WebKit drops it; the
  `blockedLoad` key is read through KVC, where an undefined key would raise an
  Objective-C exception on every blocked load.
  `testTheContentBlockerPreferencesSPIExists` fails if the setter disappears.
  Both were present on macOS 26.6.2.[^task-69]
- **Lists over 150,000 rules are split** into chunks compiled as `<id>`,
  `<id>-1`, `<id>-2`… (`compileSplit`). Read from the code, and not exercised
  at runtime: `applyRuleLists` and the Settings rule count look up only the
  base identifier, so only the first chunk would be attached and counted.
  Check this before relying on a list that large.
- **Storage is shared by bundle identifier.** WebKit's default rule list store
  and the standard defaults domain belong to the bundle id, so a test host or
  an isolated `DETOUR_DATA_DIR` run would compile into, and refresh, the
  production app's lists. `ContentBlockerStorage.forDataDirectory(named:)`
  gives any non-default data directory its own store, cache directory and
  defaults suite.[^task-36]
- **Bisection compiles probe lists into the real store.** Each probe uses the
  identifier `<id>-probe-<offset>-<count>` and is removed again when it
  compiles.
- **"No individual bad rules found"** means the full set fails while each
  half compiles (a combined state limit); the list is then not compiled at
  all.
- **A subframe navigation never changes blocking.** `configure` is called only
  for the main frame, and the host that decides is the page's.
- The fetch completion handler mutates `refreshingIdentifiers` on
  `URLSession`'s queue while the Settings pane reads it on main.

# Where state lives

| Data | Location |
|---|---|
| Raw list text | `<data directory>/ContentBlocker/<identifier>.txt` under Application Support |
| Compiled lists | WebKit's default `WKContentRuleListStore`, or `<data directory>/ContentRuleLists` for a non-default data directory |
| Fetch metadata | defaults keys `ContentBlocker.<id>.lastFetch`, `.etag`, `.ruleCount`, `.compiledRuleCount` |
| Whitelist | `contentBlockerWhitelist` in the [session database](../architecture/session-database.md); rows go with the profile |

# Differences from docs/content-blocking.md

- The document says every window re-applies rules to its web views on a rules
  change. The code re-applies to the selected, owned tab's panes only.
- The document describes a per-list refresh button. The pane has "Update All
  Now" (`forceRefreshAll`) and "Clear Cache & Redownload".

# Tests

- `ContentBlockerWhitelistTests` - `covers` cases, toggle persistence and
  per-profile scope, and two real-`WKWebView` tests: one `blockedLoad`
  callback with blocking on, none when the navigation's preferences disable
  content blockers; the counter's dedup and reset; an unclaimed tab is its web
  view's navigation delegate.
- `ContentBlockerTests` - storage isolation per data directory, parser cases,
  and compiling each cached real list through WebKit.
- The switch itself was confirmed by hand on a signed build: off then reload
  shows 0 blocked; on restores blocking; state survives popover reopen, tab
  switch and relaunch.[^task-69]

# Related

- [Settings](./settings.md) - the Content Blocking pane and the per-profile toggles.
- [BrowserTab](../architecture/browser-tab.md) - the tab's own navigation delegate for unclaimed web views.
- [Profile data removal](../architecture/profile-data-removal.md) - storage scoping per data directory, and what goes when a profile is deleted.
- [WebKit test-host traps](../platform/webkit-test-host-traps.md) - other state the test host shares with the production app.
- [WebKit source lookup](../platform/webkit-source-lookup.md) - how the rule-list evaluation was confirmed.

[^task-36]: Stop the test host writing WebKit data into the production app's WebKit directory
[^task-69]: The "Block content on this site" switch does not take effect
