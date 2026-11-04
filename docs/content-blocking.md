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
   - If yes, and it was compiled from the parser's current output
     (`ContentBlocker.<id>.rulesFormat` equals `EasyListParser.rulesFormatVersion`):
     check if a refresh is needed (24-hour interval)
   - If it exists but from an older format (or none recorded, any build before
     TASK-199): recompile from the cached text; the old list stays attached
     until the new one replaces it
   - If no: try loading from cached text file in `~/Library/Application Support/Detour/ContentBlocker/`
     (read and parsed on a background queue; see "Threading");
     after a successful compile, check if a refresh is needed. The check runs
     from the compile's completion, so a refresh never overlaps it
   - If no cache, or the cached text does not compile: fetch from upstream
     URL **without** the conditional headers, so an unchanged list cannot
     answer 304 and leave an old-format list attached

## Fetch & Compile Pipeline

```
Fetch (HTTP)
  +-- Conditional: If-None-Match (ETag) / If-Modified-Since
  +-- 304 Not Modified: update timestamp, done
  +-- 200 OK: cache raw text to disk (URLSession's queue); ETag, timestamp
  |   and rule count recorded on main
       |
       v
Parse (EasyListParser, on the manager's serial parse queue, one list at a time)
  +-- Converts AdBlock Plus filter syntax to WebKit content rule JSON
  +-- Orders the output: element hiding (generic, $generichide exceptions,
  |   domain-specific, $elemhide exceptions), block rules, network
  |   exceptions, $document allowlists, $important block rules
  |   (TASK-199; see "Exception Options")
  +-- Drops each $badfilter line and the rule it names
  +-- Tracks rule count and skipped rules
       |
       v
Compile (ContentRuleStore; one compile per list at a time, in call order)
  +-- Chunks and encodes the rules to JSON on its serial work queue
  +-- WKContentRuleListStore.compileContentRuleList(forIdentifier:encodedContentRuleList:)
  |   on main (WebKit requires it); a refused chunk's bad-rule search
  |   encodes its probes on the work queue too
  +-- More than 150,000 rules: one rule list per chunk (see "Lists Over the Rule Cap")
  +-- Caches every compiled WKContentRuleList in memory
       |
       v
Apply (reapplyRuleLists)
  +-- Posts .contentBlockerRulesDidChange notification
  +-- Each window re-applies rules to its selected tab's panes
      (only the window that owns that web view)
```

## Threading

Only the `WKContentRuleListStore` calls and the bookkeeping run on the main
queue (TASK-200). WebKit's store is main-thread only: `WK_SWIFT_UI_ACTOR`,
and every call asserts `RunLoop::isMain()` and completes on main. The public
compile also parses the JSON on the calling thread to validate CSS
selectors, then compiles to bytecode on its own work queue, so that parse is
the part of a compile left on main.

| Step | Queue |
|------|-------|
| Read and parse cached text; parse a download | serial parse queue (one list at a time, for peak memory) |
| Download, write the text to the cache | `URLSession`'s delegate queue |
| ETag, `lastFetch`, `ruleCount`, `rulesFormat`, `refreshingIdentifiers` | main |
| Chunking, JSON encoding, the bad-rule search's probes and the cleaned chunk | `ContentRuleStore`'s serial work queue |
| `WKContentRuleListStore` compile / look up / remove | main |
| Recording compiled lists and counts, attaching them | main |

Ordering: `ContentRuleStore.compile` runs a list's compiles one at a time in
call order, so a compile still searching for bad rules cannot record its list
over a later one. `ContentBlockerManager` gives each compile a ticket
(`FilterListCompileOrder`) on main when its text is chosen, and drops a
compile when a compile of newer text for the same list has already started,
so a cache compile read at launch never replaces a download that arrived
during it.

## Lists Over the Rule Cap

WebKit is handed at most 150,000 rules as one rule list
(`ContentRuleStore.defaultMaxRulesPerList`). A filter list with more rules is
compiled as several rule lists, each of at most 150,000 rules: the first under
the list's identifier, the rest as `<id>-1`, `<id>-2`, …
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
| Settings | `compiledRuleCount(forList:)` is the sum over the chunks, with an exception the chunks repeat counted once; `isCompiled(list:)` is true when any chunk is compiled |
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

### What a Chunk Holds

WebKit evaluates each rule list on its own, and an `ignore-previous-rules` rule
(an `@@` exception) only undoes rules **earlier in its own list**. Chunks that
were plain slices of the list would therefore lose every exception that landed
in a different chunk from the block rule it was written for. So a split list is
laid out by `ContentRuleListChunks.chunks(of:maxRulesPerList:isException:)`
(TASK-155):

- the rules that are not exceptions are sliced in list order;
- every slice is followed by **all of the list's exceptions**, in list order,
  so each chunk's exceptions come after, and undo, that chunk's block rules;
- a slice holds the cap less the number of exceptions it carries, so no chunk
  exceeds the cap.

With a cap of 4, `b0 b1 x0 b2 b3 b4 b5 b6` (`x0` an exception) becomes
`[b0 b1 b2 x0] [b3 b4 b5 x0] [b6 x0]`.

| Case | Rule |
|------|------|
| A list within the cap | One chunk, in list order, exactly as before. Nothing is moved |
| Rule count | Each chunk records how many of its rules count (`Chunk.countedRuleCount`): the repeated exceptions count in the first chunk only, so the list's count is the number of distinct rules compiled. A bad rule stripped by the fallback lowers the count only where it was counted |
| Exceptions near the cap | The chunks carry at most half the cap of exceptions (`maxCarriedExceptions`, 75,000), the first ones in list order, so every chunk keeps room for at least as many block rules and the number of chunks at most doubles. Exceptions beyond that are **left out** of a split list and logged as an error (`droppedExceptionCount`); "Active" is then lower than "In List" |
| A split list of only exceptions | One chunk of the carried exceptions. It undoes nothing, but the compile does not read as a failure |

Until TASK-155 chunks were slices of the list in order and an exception in a
later chunk than its block rule did not apply. Since TASK-199 the parser puts
every network exception after every block rule of its list, so a list within
the cap applies an exception wherever it stood in the file too. TASK-162
confirmed in a web view that WebKit compiled in file order leaves the exempted
URL blocked, and found the case in the shipped EasyList (27 Oct 2026 copy):
ten `@@||thegay.com/...$domain=thegay.com` player exceptions above
`||thegay.com^$script,domain=thegay.com`, so the site's video player was
blocked until TASK-199. EasyPrivacy and EasyList Cookie had no exception a
later block rule overrode.

### Exception Options

WebKit's `ignore-previous-rules` undoes every earlier action of its rule list
(block or hide) for a load its trigger matches; there is no cosmetic-only
exception. The parser maps `@@` options by putting each rule where it reaches
only what it means to (TASK-199):

| Option | Compiled as |
|--------|-------------|
| `$generichide` | `ignore-previous-rules`, `url-filter` `.*`, `if-top-url` with the pattern (or `if-domain` from `domain=` when there is no pattern), right after the generic hiding rules: generic hiding is off on those pages, domain-specific hiding and every block rule still apply |
| `$elemhide` | The same, after the domain-specific hiding rules: all hiding off, blocking unchanged. Checked before `$generichide`, so a rule with both is an `$elemhide` |
| `$document` | The plain exception (resource type `document`) among the network exceptions, plus a page-wide one at the very end of the list: the page is allowlisted fully |
| `$genericblock`, `$specifichide` | Left out (none in the shipped lists): WebKit cannot undo only the generic block rules, or only domain-specific hiding |
| `$popup`, `$websocket`, `$webrtc`, `$ping`, `$csp` alone | Left out: no block rule of those types is compiled, and the option maps to no resource type, so the exception would undo every block rule for its URLs |
| `$redirect`, `$rewrite` (with or without `=`), `$csp=` | Left out: they lift rewriting rules, which the parser never compiles |
| anything else | A network exception, after all the block rules |

Block rules with `$important` go in a section of their own at the very end,
after the `$document` allowlists, so no exception undoes them. `$badfilter`
is not compiled: the line and the rule it repeats (the same line without
`$badfilter`) are both dropped and counted as skipped.

A compiled list from before TASK-199 is recompiled once at launch
(`rulesFormat`, see "Initialization Flow").

Limits that remain, none exercised by a real list yet:

- **The element-hiding section must fit in the first chunk.** The parser puts
  it first, and its page-wide `$generichide` / `$elemhide` exceptions are not
  carried (`chunks(ofCompiledRules:maxRulesPerList:)`): carried behind a
  chunk's block rules they would undo those too. A section longer than one
  chunk would leave hiding in chunk 0 that an exception in chunk 1 does not
  undo. EasyList's is about 24,000 rules; no shipped list reaches the cap.
- **`$important` is last only within the cap.** A split list appends the
  carried exceptions to every chunk, after its `$important` rules, so there a
  network exception can undo one.
- **A page-wide exception with both a pattern and `domain=`** keeps only the
  pattern (`if-top-url`; a WebKit trigger takes one page condition), so it
  covers more pages than the rule names. None of the shipped lists has one.
- **Exceptions still do not cross lists.** An exception in EasyPrivacy cannot
  un-block something EasyList blocks.
- **A chunk that cannot be compiled** (even after stripping bad rules) leaves
  the list active with the chunks that did compile; the "Active" count in
  Settings is then lower than "In List". A chunk an earlier compile left under
  the same identifier stays in use; after a parser change it is of the old
  format while the list records the new `rulesFormat`, and is not recompiled
  until the list text changes.

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

**Storage**: `contentBlocking = false` rows of the `siteSetting` table, through `SiteSettingsStore` (TASK-187; the `contentBlockerWhitelist` table until migration v18).

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

- Per-list display: parsed rule count ("In List"), compiled rule count ("Active", summed over the chunks of a split list with a repeated exception counted once), status, last fetch date
- Update All Now: re-fetches every list (`forceRefreshAll`; the fetch is conditional, so an unchanged list is not recompiled). There is no per-list refresh
- Clear Cache & Redownload: invalidates all compiled rules, deletes cached text and fetch metadata, re-fetches everything

`ProfilesSettingsViewController` provides per-profile toggles for each filter list and the master ad-blocking switch.

## Cache Locations

| Data | Location |
|------|----------|
| Raw filter text | `~/Library/Application Support/Detour/ContentBlocker/{identifier}.txt` |
| Compiled rules | WebKit's internal `WKContentRuleListStore` (managed by WebKit): one rule list per chunk, `{id}`, `{id}-1`, … |
| Fetch metadata | `UserDefaults`: `ContentBlocker.{id}.lastFetch`, `ContentBlocker.{id}.etag`, `ContentBlocker.{id}.ruleCount` |
| Compile metadata | `UserDefaults`: `ContentBlocker.{chunk id}.compiledRuleCount` per compiled chunk (the rules that chunk adds to the list's count), `ContentBlocker.{id}.chunkCount` for a list of more than one chunk |

These are the locations for the default data directory. A non-default data
directory (`DETOUR_DATA_DIR`, as set for test runs and isolated launches) gets its
own of all three
(`ContentBlockerStorage`): `ContentBlocker/` and a `ContentRuleLists/` rule list
store inside that directory under Application Support, and its own defaults suite,
so it never compiles into or refreshes the production lists.
