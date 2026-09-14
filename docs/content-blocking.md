# Content Blocking

Detour includes a built-in content blocker that filters ads, trackers, cookie notices, and malicious URLs using WebKit's `WKContentRuleList` API.

## Architecture

```
ContentBlockerManager.shared
  +-- EasyListParser           Parses EasyList/AdBlock Plus filter syntax -> WebKit JSON rules
  +-- ContentRuleStore         Compiles and caches WKContentRuleLists
  +-- ContentBlockerWhitelist  Per-profile host exceptions (the per-site switch)
```

All files are in `Browser/ContentBlocker/`.

## Filter Lists

Four filter lists are supported, fetched from upstream sources:

| Identifier | Source | Purpose | Profile Toggle |
|------------|--------|---------|----------------|
| `easylist` | easylist.to | Ad blocking | `isEasyListEnabled` |
| `easyprivacy` | easylist.to | Tracker blocking | `isEasyPrivacyEnabled` |
| `easylist-cookie` | fanboy.co.nz | Cookie consent notices | `isEasyListCookieEnabled` |
| `urlhaus-filter` | malware-filter.gitlab.io | Malicious URLs | `isMalwareFilterEnabled` |

Each list can be independently toggled per profile. The master `isAdBlockingEnabled` toggle disables all lists at once.

## Initialization Flow

On app launch, `ContentBlockerManager.shared.initialize()`:

1. Load whitelist entries from the database and remove the retired
   `content-blocker-whitelist-<profileUUID>` rule lists earlier builds compiled
2. For each filter list:
   - Check if a compiled `WKContentRuleList` already exists in WebKit's store
   - If yes: check if a refresh is needed (24-hour interval)
   - If no: try loading from cached text file in `~/Library/Application Support/Detour/ContentBlocker/`
   - If no cache: fetch from upstream URL

## Fetch & Compile Pipeline

```
Fetch (HTTP)
  +-- Conditional: If-None-Match (ETag) / If-Modified-Since
  +-- 304 Not Modified: update timestamp, done
  +-- 200 OK: cache raw text to disk
       |
       v
Parse (EasyListParser)
  +-- Converts AdBlock Plus filter syntax to WebKit content rule JSON
  +-- Tracks rule count and skipped rules
       |
       v
Compile (ContentRuleStore)
  +-- WKContentRuleListStore.compileContentRuleList(forIdentifier:encodedContentRuleList:)
  +-- Caches compiled WKContentRuleList in memory
       |
       v
Apply (reapplyRuleLists)
  +-- Posts .contentBlockerRulesDidChange notification
  +-- All windows re-apply rules to their WebViews
```

## Applying Rules to WebViews

Rules are applied when creating a new `WKWebViewConfiguration` in `Space.makeWebViewConfiguration()`:

```swift
ContentBlockerManager.shared.applyRuleLists(to: config.userContentController, profile: profile)
```

This method adds each enabled filter list's compiled `WKContentRuleList` when
`profile.isAdBlockingEnabled`, and nothing else — no user script, so it is safe to
call again after `removeAllContentRuleLists()` on every rules change.

## Per-Profile Whitelist

The whitelist allows users to disable content blocking for specific domains on a per-profile basis.

**Storage**: `contentBlockerWhitelist` table with composite key `(profileID, host)`.

**Mechanism** (TASK-69): a per-navigation switch, the way Safari's per-site
content-blocker toggle works. In `decidePolicyFor(navigationAction, preferences:)`,
for a main-frame navigation whose host is covered by the tab's profile's whitelist,
`ContentBlockerManager.configure` calls the private
`-[WKWebpagePreferences _setContentBlockersEnabled:NO]`, which disables every rule
list for that document and all of its subresource and subframe loads. A tab no
window has claimed yet is its own web view's navigation delegate for exactly this
decision, so background-opened tabs get the switch too.

A rule list cannot do this: WebKit evaluates each `WKContentRuleList` independently
and merges their Block results, so an `ignore-previous-rules` rule only cancels
rules in its *own* list — a separate "whitelist" list is a no-op regardless of the
order the lists are added in.

**Matching** (`ContentBlockerWhitelist.covers`): a host is covered by an exact entry
or by an entry for a parent domain (`news.example.com` is covered by
`example.com`); case-insensitive. Turning blocking *off* stores the page's exact
host, lowercased. Turning it back *on* removes every entry covering the host —
including a parent-domain entry, so flipping the switch on `mail.example.com` also
drops an `example.com` entry and re-blocks its other subdomains; that is
deliberate, since leaving the parent entry would keep the switch from taking.

```
whitelist.toggleHost("example.com", profileID: id)
  -> Save to / delete from DB (synchronous)
  -> Reload every on-screen pane (split members, peek) whose host is covered
```

## Blocked Resource Counting

WebKit reports every load a rule list acted on through the private navigation
delegate callback `_webView:contentRuleListWithIdentifier:performedAction:forURL:`
(implemented on `BrowserWindowController`); when the `_WKContentRuleListAction`'s
`blockedLoad` is true the owning tab records the URL. WebKit fires once per list
that acted, and the filter lists overlap, so `BrowserTab.recordBlockedLoad(of:)`
counts each URL once per page. The count is exposed via `BrowserTab.blockedCount`
(`@Published`) and resets to 0 in `load(_:)` and on every committed navigation.

The previous implementation counted element `error` events from an injected user
script — every failed image or script load, blocked or not — which is why the
popover reported "12 blocked" on pages whose blocking was switched off (TASK-69).
A page with content blockers disabled produces no callbacks at all.

## Settings UI

`ContentBlockerSettingsViewController` provides:

- Per-list display: parsed rule count, compiled rule count, last fetch date
- Refresh button: re-fetches and recompiles a single list
- Clear cache & redownload: invalidates all compiled rules, deletes cached text, re-fetches everything

`ProfilesSettingsViewController` provides per-profile toggles for each filter list and the master ad-blocking switch.

## Cache Locations

| Data | Location |
|------|----------|
| Raw filter text | `~/Library/Application Support/Detour/ContentBlocker/{identifier}.txt` |
| Compiled rules | WebKit's internal `WKContentRuleListStore` (managed by WebKit) |
| Fetch metadata | `UserDefaults`: `ContentBlocker.{id}.lastFetch`, `ContentBlocker.{id}.etag`, `ContentBlocker.{id}.ruleCount` |
