---
type: Feature
title: Content blocking per-site switch
description: "The \"Block content on this site\" switch: a per-profile host list in the site-settings table, enforced per main-frame navigation through the private WKWebpagePreferences _setContentBlockersEnabled: SPI (the navigating tab's profile, unclaimed tabs and Quick Detour included), kept in memory only in Private windows, host-or-parent matching, and why a whitelist rule list could never work (TASK-69)."
tags: [content-blocker, webkit, profiles, spi, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:06Z }
sources:
  - id: manager
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerManager.swift
    title: ContentBlockerManager.swift (configure, contentBlockersEnabled, setContentBlockersEnabled)
  - id: whitelist
    resource: ../../Detour/Browser/ContentBlocker/ContentBlockerWhitelist.swift
    title: ContentBlockerWhitelist.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (the unclaimed tab's own navigation delegate)
  - id: quick-detour
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController+WebKit.swift
    title: QuickDetourWindowController+WebKit.swift
  - id: whitelist-tests
    resource: ../../DetourTests/ContentBlockerWhitelistTests.swift
    title: ContentBlockerWhitelistTests.swift
  - id: task-69
    resource: backlog:TASK-69
    title: The "Block content on this site" switch does not take effect
  - id: task-187
    resource: backlog:TASK-187
    title: "Storage: a per-site settings table, with content blocking's site list migrated into it"
  - id: task-195
    resource: backlog:TASK-195
    title: "Content blocking: keep a Private window's per-site switch in memory only"
  - id: site-settings
    resource: ../architecture/site-settings.md
    title: Site settings
---

A switch in the sidebar's settings popover ("Block content on this site")
turns blocking off for one host in one profile. It is enforced per
navigation, the way Safari's per-site content-blocker switch works, through a
private `WKWebpagePreferences` setter; an earlier rule-list implementation
never worked. Part of [content blocking](./content-blocking.md).

# How it works

The whitelist is a persisted host set per profile: the
`contentBlocking = false` rows of the [site settings](../architecture/site-settings.md)
table (`siteSetting`), which replaced the `contentBlockerWhitelist` table in
migration v18 (TASK-187). `ContentBlockerWhitelist` keeps its API and reads
and writes `SiteSettingsStore.shared`. Enforcement is per **navigation**, the
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

The two delegates are `BrowserWindowController` and `BrowserTab` (for an
unclaimed tab). A [Quick Detour](./quick-detour.md) window is a third: its
own navigation delegate makes the same `configure` call for its page's
profile.

Because the switch acts at navigation time, toggling it reloads every pane
this window shows for that host (split members and the Peek), not just the
display tab.

## Private windows

In a **Private window** the switch is kept in memory only (TASK-195): the
store writes no row for the Private profile, and the override is dropped when
the last Private window closes (`SiteSettingsStore.discardPrivateSession`).
Nothing is compiled or cached from the site list (the decision is
`ContentBlockerManager.contentBlockersEnabled(forNavigationTo:profileID:whitelist:)`,
read at each navigation), so the next Private window blocks everywhere with
no further reset. The toggle and its reload work as in any other profile.
Migration v19 removed the Private rows earlier builds had written
([site settings](../architecture/site-settings.md)).

## Matching

Matching (`ContentBlockerWhitelist.covers`) is case-insensitive: a host is
covered by an exact entry or by an entry for a parent domain. Turning blocking
off stores the page's exact host, lowercased. Turning it back on removes
**every** entry covering the host, a parent-domain entry included; leaving the
parent would keep the site whitelisted and the switch would appear not to
take. Which way the toggle goes follows the store's most specific override,
so a `contentBlocking = true` row for a subdomain under a whitelisted parent
makes the switch turn blocking off rather than clear the parent.

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

The same WebKit rule shapes the filter lists' own exceptions; see
[exceptions and element hiding](./content-blocking-exceptions.md#what-webkit-does-with-an-exception).

# Edge cases

- **A private selector.** The preferences setter is guarded by
  `responds(to:)` and logs once and does nothing if WebKit drops it;
  `testTheContentBlockerPreferencesSPIExists` fails if the setter disappears.
  It was present on macOS 26.6.2.[^task-69] The blocked counter's private
  key is the other one (see [the blocked counter](./content-blocking.md#the-blocked-counter)).
- **A subframe navigation never changes blocking.** `configure` is called only
  for the main frame, and the host that decides is the page's.
- **A split list needs nothing special.** The setter turns off every rule
  list for the navigation, every [chunk](./content-blocking-chunks.md)
  included.

# Tests

- `ContentBlockerWhitelistTests` - `covers` cases, toggle persistence and
  per-profile scope, the Private switch (nothing on disk, back on clears it,
  closing the last Private space turns blocking back on while a normal
  profile's switch stays), and two real-`WKWebView` tests: one `blockedLoad`
  callback with blocking on, none when the navigation's preferences disable
  content blockers; the counter's dedup and reset; an unclaimed tab is its web
  view's navigation delegate.
- `ContentRuleListChunkTests` - a whitelisted navigation is not blocked by any
  chunk.
- The switch itself was confirmed by hand on a signed build: off then reload
  shows 0 blocked; on restores blocking; state survives popover reopen, tab
  switch and relaunch.[^task-69]

# Related

- [Site settings](../architecture/site-settings.md) - the `siteSetting` table, `SiteSettingsStore` and migrations v18 and v19.
- [BrowserTab](../architecture/browser-tab.md) - the tab's own navigation delegate for unclaimed web views.
- [Incognito](../architecture/incognito.md) - what a Private window keeps and drops.
- [WebKit privacy protections](../platform/webkit-privacy-protections.md) - the other per-navigation `WKWebpagePreferences` SPI Detour sets.
- [WebKit source lookup](../platform/webkit-source-lookup.md) - how the rule-list evaluation was confirmed.

[^task-69]: The "Block content on this site" switch does not take effect
