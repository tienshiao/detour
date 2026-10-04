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
  +-- More than 150,000 rules: one rule list per chunk (see "Lists Over the Rule Cap")
  +-- Caches every compiled WKContentRuleList in memory
       |
       v
Apply (reapplyRuleLists)
  +-- Posts .contentBlockerRulesDidChange notification
  +-- Each window re-applies rules to its selected tab's panes
      (only the window that owns that web view)
```

## Lists Over the Rule Cap

WebKit is handed at most 150,000 rules as one rule list
(`ContentRuleStore.defaultMaxRulesPerList`). A filter list with more rules is
compiled as several rule lists, one per chunk of 150,000 rules in list order:
the first under the list's identifier, the rest as `<id>-1`, `<id>-2`, …
(`ContentRuleListChunks`). WebKit's store knows nothing about the grouping, so
`ContentRuleStore` handles a list's chunks as a set (TASK-145):

| When | What happens to the chunks |
|------|----------------------------|
| Compile | Every chunk is compiled. If at least one compiled, the list's chunk count is recorded and `compile` completes with all of the list's chunks; if none did, the list is left as it was |
| Attach | `cachedLists(forList:)` returns every compiled chunk; `ContentBlockerManager.ruleLists(for:in:)` collects them for the profile's enabled lists and `applyRuleLists` adds them all |
| List disabled, master switch off | The window removes all rule lists from the web view and re-applies; a disabled list contributes no chunk |
| Whitelisted site | `_setContentBlockersEnabled:NO` turns off every rule list for the navigation, so every chunk |
| Launch | `lookUpList` looks up as many chunks as the last compile recorded (`ContentBlocker.{id}.chunkCount` in defaults, written only when above 1) |
| List shrinks | The chunks the previous, longer compile left behind (`ContentRuleListChunks.staleIdentifiers`) are removed from WebKit's store, from memory and from defaults |
| Settings | `compiledRuleCount(forList:)` is the sum over the chunks; `isCompiled(list:)` is true when any chunk is compiled |
| Clear Cache & Redownload | `invalidateAll` removes every chunk and forgets the counts and chunk counts |

Before TASK-145 only the first chunk was attached, counted and looked up, and
later chunks were never removed.

No list is near the cap. Rules produced by the parser from the lists as fetched
on 2026-10-04 (the 2026-10-02 copies gave 74,973 / 56,146 / 25,002 / 9,571):

| List | Parsed rules | Compiled | Share of the cap |
|------|--------------|----------|------------------|
| `easylist` | 75,661 | 75,661 | 50.4% |
| `easyprivacy` | 56,158 | 56,158 | 37.4% |
| `easylist-cookie` | 25,010 | 25,008 (2 stripped as invalid) | 16.7% |
| `urlhaus-filter` | 9,605 | 9,605 | 6.4% |

Two limits of splitting, neither exercised by a real list yet:

- **Exceptions do not cross chunks.** WebKit evaluates each rule list on its
  own, so an `ignore-previous-rules` rule (an `@@` exception) only cancels
  blocks in its own chunk. Rules are chunked in list order, so an exception
  that lands in a later chunk than the block it was written for no longer
  applies.
- **A chunk that cannot be compiled** (even after stripping bad rules) leaves
  the list active with the chunks that did compile; the "Active" count in
  Settings is then lower than "In List". A chunk an earlier compile left under
  the same identifier stays in use.

## Applying Rules to WebViews

Rules are applied when creating a new `WKWebViewConfiguration` in `Space.makeWebViewConfiguration()`:

```swift
ContentBlockerManager.shared.applyRuleLists(to: config.userContentController, profile: profile)
```

This method adds each enabled filter list's compiled `WKContentRuleList`s (every
chunk of a list over the rule cap) when `profile.isAdBlockingEnabled`, and nothing
else — no user script, so it is safe to call again after
`removeAllContentRuleLists()` on every rules change.

On `.contentBlockerRulesDidChange`,
`BrowserWindowController.handleContentBlockerRulesChanged` does exactly that, but
only for the window's selected tab — both panes when it is a split — and only when
this window owns the web view. Every tab has its own configuration, so the other
tabs keep the lists their configuration was created with until their web view is
rebuilt (a sleeping tab waking) or they are the selected tab when a later change is
posted. The notification is posted after each successful compile, once the launch
lookups have all finished, and when a profile's blocking toggles change in Settings.

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

- Per-list display: parsed rule count ("In List"), compiled rule count ("Active", summed over the chunks of a split list), status, last fetch date
- Update All Now: re-fetches every list (`forceRefreshAll`; the fetch is conditional, so an unchanged list is not recompiled). There is no per-list refresh
- Clear Cache & Redownload: invalidates all compiled rules, deletes cached text and fetch metadata, re-fetches everything

`ProfilesSettingsViewController` provides per-profile toggles for each filter list and the master ad-blocking switch.

## Cache Locations

| Data | Location |
|------|----------|
| Raw filter text | `~/Library/Application Support/Detour/ContentBlocker/{identifier}.txt` |
| Compiled rules | WebKit's internal `WKContentRuleListStore` (managed by WebKit): one rule list per chunk, `{id}`, `{id}-1`, … |
| Fetch metadata | `UserDefaults`: `ContentBlocker.{id}.lastFetch`, `ContentBlocker.{id}.etag`, `ContentBlocker.{id}.ruleCount` |
| Compile metadata | `UserDefaults`: `ContentBlocker.{chunk id}.compiledRuleCount` per compiled chunk, `ContentBlocker.{id}.chunkCount` for a list of more than one chunk |

These are the locations for the default data directory. A non-default data
directory (`DETOUR_DATA_DIR`, as set for test runs and isolated launches) gets its
own of all three
(`ContentBlockerStorage`): `ContentBlocker/` and a `ContentRuleLists/` rule list
store inside that directory under Application Support, and its own defaults suite,
so it never compiles into or refreshes the production lists.
