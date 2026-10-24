---
type: Component
title: Suggestion pipeline
description: How the command palette's rows are produced - open tabs, space-scoped history, inline URL completion by frecency, network search suggestions - and how typed input is classified as a URL or a search.
resource: ../../Detour/Browser/CommandPalette/SuggestionProvider.swift
tags: [command-palette, history, search, frecency, performance]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T08:30:00Z }
sources:
  - id: provider
    resource: ../../Detour/Browser/CommandPalette/SuggestionProvider.swift
    title: SuggestionProvider.swift
  - id: palette-view
    resource: ../../Detour/Browser/CommandPalette/CommandPaletteView.swift
    title: CommandPaletteView.swift (refreshLocalSuggestions)
  - id: classifier
    resource: ../../Detour/Browser/CommandPalette/AddressInputClassifier.swift
    title: AddressInputClassifier.swift
  - id: tab-scope
    resource: ../../Detour/Browser/CommandPalette/PaletteTabScope.swift
    title: PaletteTabScope.swift
  - id: search-service
    resource: ../../Detour/Browser/CommandPalette/SearchSuggestionsService.swift
    title: SearchSuggestionsService.swift
  - id: history-db
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift (recentHistory, searchHistory, bestURLCompletion)
  - id: task-83
    resource: backlog:TASK-83
    title: Treat host:port and localhost input as a URL
  - id: task-94
    resource: backlog:TASK-94
    title: Command palette history suggestions show and match another profile's page title
  - id: task-96
    resource: backlog:TASK-96
    title: Index every title a URL has had
  - id: task-97
    resource: backlog:TASK-97
    title: Recent history aggregates every visit in the space
  - id: task-137
    resource: backlog:TASK-137
    title: A normal window's open-tab suggestions include tabs from open Private windows
  - id: task-182
    resource: backlog:TASK-182
    title: Complete a typed host prefix to the site (youtube.com), not to one deep URL
  - id: bench
    resource: ../../DetourTests/HistoryBenchmarkTests.swift
    title: HistoryBenchmarkTests.swift (completion legs)
  - id: tab-scope-tests
    resource: ../../DetourTests/PaletteTabScopeTests.swift
    title: PaletteTabScopeTests.swift
  - id: provider-tests
    resource: ../../DetourTests/SuggestionProviderTests.swift
    title: SuggestionProviderTests.swift
  - id: classifier-tests
    resource: ../../DetourTests/AddressInputClassifierTests.swift
    title: AddressInputClassifierTests.swift
---

# Role

`SuggestionProvider` turns a query into the ordered `[SuggestionItem]` the
[command palette](./command-palette.md) shows. It merges open tabs (in
memory), history (SQLite, scoped to one **space**) and network search
suggestions, and it names the URL the field should inline-complete to.
`AddressInputClassifier` is the separate pure rule for "is this text a URL".

# How it works

## Row types and order

```swift
enum SuggestionItem {
    case searchInput(text:)        // the verbatim typed text: "Go to" or "Search"
    case historyResult(url:title:faviconURL:)
    case openTab(tabID:spaceID:url:title:favicon:)   // "Switch to Tab"
    case searchSuggestion(text:)   // from the search engine
}
```

For a non-empty query `localSuggestions(for:spaceID:tabs:allowAutocomplete:currentTabID:)`
returns, in order, capped at `maxSuggestions` (12):

| # | Rows | Source | Limit |
|---|---|---|---|
| 1 | Top hit | `tabTopHit` (open tabs); else, for a host query, the best `bestHostCompletions` host; otherwise `bestURLCompletion` | 1, only when `allowAutocomplete` |
| 2 | `.searchInput` | the typed text | 1 |
| 3 | Other hosts | `bestHostCompletions` minus the top hit's host and any host whose root is already an open-tab row; host queries only | 2 (`maxOtherHosts`) |
| 4 | Open tabs | URL or title *contains* the query, case-insensitive (`matchingTabs`) | 3 |
| 5 | History | `searchHistory(query:spaceID:limit: 8)`, minus URLs already shown as tabs, as the top hit or as host rows | 8 |
| 6 | Search suggestions | appended later by the view | 4, and only while the list has room under 12 |

The top hit also supplies `inlineCompletion`: for a host query the host
(`displayHost`), otherwise the scheme-stripped display URL (`displayURL`
drops `https://`, `http://`, a leading `www.` and one trailing slash).

## Host queries complete to the site

A query that could still be a bare host (`isHostQuery`: no whitespace and no
`/`, `?` or `#` yet, so `youtu` or `localhost:30`) completes to a **host**,
not to one page on it. `youtube.com/` and anything longer completes URL by
URL as before. Until TASK-182 the top hit was the first open tab whose
display URL started with the query, so with several video tabs open, `you`
completed to `youtube.com/watch?v=…` and nothing offered the site itself;
getting to the front page meant typing the whole domain.[^task-182]

| Source | Top hit |
|---|---|
| An open `http(s)` tab whose `displayHost` starts with the query (the first one in tab order; the current tab counts) | a tab already at that host's root (not the current tab) as Switch to Tab; otherwise the root URL as a navigating `.historyResult`, titled with the host, or with the root's own title and favicon when history has them |
| No such tab: `bestHostCompletions` | the best host's root |

`bestHostCompletions(prefix:spaceID:limit:)` finds the space's visits of the
last 90 days whose URL matches the prefix (the same four scheme patterns as
`bestURLCompletion`), sums each URL's frecency, groups the URLs by
`history_display_host(url)` and ranks the hosts by the sum. A site visited
across many pages beats one page visited a little more than each of them,
which ranking URL by URL got backwards. For each of the (at most three)
hosts kept it looks up the root (`https://host/`, `https://www.host/`, and
`http`) among the space's own visits, labelled through `labelledSelect` like
every other palette row; a root never visited is built from the scheme and
`www.` that the host's best page uses (`rootURL(host:like:)`).

With autocomplete off (after a Backspace, or trailing whitespace) there is no
top hit, but the matching hosts still appear as rows after the verbatim one.
Internal pages and `about:blank` tabs never complete a host
(`TabInfo.isWebPage`).

Chosen to match Firefox's origin completion rather than Chrome's
inline-the-best-URL. Two alternatives were set aside: completing to the
host only when the top URL hit is a deep page (still offers nothing for a
host whose pages are all deep), and adding a host row without changing the
completion (leaves the field completing to a video).

For an empty query `defaultSuggestions` returns `recentHistory(limit: 12)`,
with a row turned into `.openTab` when a tab already shows that URL. This
default list is shown with no row selected, unlike a typed query's list; see
the keyboard section of [command palette](./command-palette.md).

## Which open tabs are candidates

The provider never reads `TabStore`. The view hands it `[TabInfo]` built by
`CommandPaletteView.gatherTabInfos`: the normal tabs and the live pinned
entries' tabs of the spaces `PaletteTabScope.offeredSpaceIDs` allows.

| Palette's window | Spaces |
|---|---|
| Normal | every non-incognito space, not only the active one |
| Private | its own space only |

So open tabs are suggested across spaces (history is not, see below), but
never across the Private boundary in either direction. `gatherTabInfos` is the
only constructor of `TabInfo` outside the tests; a new caller that hands tabs
to the provider has to go through the same rule. Until TASK-137 a normal
window's list included the spaces of open Private windows.[^task-137] The
rule and its fail-closed cases are on [incognito](../architecture/incognito.md).

## Two passes per keystroke

`CommandPaletteView.refreshLocalSuggestions` does not call the provider on
the main thread:

1. **Instant pass, main thread, no SQLite.** Open tabs only: the tab-based top
   hit and its inline completion, the verbatim row, up to three tab matches,
   from the same `SuggestionProvider.tabTopHit` and `matchingTabs` the
   background pass uses. Typing never waits on the database.
2. **Background pass.** `provider.localSuggestions` runs on a serial
   `historyQueryQueue` and the authoritative list replaces the instant one on
   main. The result is dropped if `localSuggestionGeneration` advanced or the
   field's text changed since dispatch. The history-derived completion is
   applied only if no tab completion was applied and nothing has completed the
   field since.
3. **Network.** `scheduleSearchSuggestionFetch` debounces 150 ms, cancels the
   previous `Task`, and `appendSearchSuggestions` drops a response whose query
   no longer equals `suggestionsQuery`.

`updateSuggestions` reconfigures changed rows in place and only inserts or
removes at the tail, so the list stays visually stable while typing.

Only `loadDefaultSuggestions` (the empty-query list, hence `recentHistory`)
still reads the database synchronously on the main thread.

## History is space-scoped

All three history lookups take one `spaceID`: only URLs **this space** has
visited are suggested, and a row is labelled with this space's own latest
titled visit, never with a title another profile gave the URL. That rule, its
legacy fallback and what was rejected on the way are on
[history own-title matching](../decisions/history-own-title-matching.md).
Keeping the palette scoped to the space, while the
[History page](./history-page.md) is scoped to the profile, was a product
decision recorded in TASK-94.

`searchHistory` unions three indexed candidate sources (URL text; this space's
own titles through the title index; the shared title for a legacy title-less
visit that no other space shares), takes `MIN(rank)` per URL, and orders by
`rank, -visitCount, id`. The three ranks are bm25 scores of two different FTS
tables and are not strictly comparable; they order suggestions and nothing
else.

`SuggestionProvider.displayTitle` falls back to the display URL when the title
is empty, which happens both for the guarded legacy case and when the visit a
URL's latest title came from was deleted.

## Inline completion and frecency

`bestURLCompletion(prefix:spaceID:)` matches the prefix against scheme-stripped
URLs by prepending the four scheme variants (`https://`, `http://`,
`https://www.`, `http://www.`) as `LIKE 'prefix%'` patterns. `%`, `_` and `\`
in the prefix are escaped. The code comment says this lets SQLite use the
index on `url`; it does not. `LIKE` is case-insensitive and the index is
`BINARY`, so `EXPLAIN QUERY PLAN` shows a scan of `historyURL` (checked for
TASK-182; see the benchmark numbers under Gotchas). Candidates are
ranked by a Firefox-style score summed over the space's visits from the last
90 days:

| Visit age | Weight |
|---|---|
| under 4 days | 100 |
| under 14 days | 70 |
| under 31 days | 50 |
| under 90 days | 30 |

doubled for a **typed** visit, with the newest visit as the tiebreak. A site
the user deliberately goes to daily beats one clicked into many times weeks
ago. The provider re-checks that the scheme-stripped result really starts with
the query before using it as a top hit.

## URL or search

`AddressInputClassifier.directURL(from:)` returns the URL the text denotes, or
nil for a search. One function serves both submission and the row's "Go to"
(globe) versus "Search" (magnifier) icon, so the row always matches what
Return does.

| Input | Result |
|---|---|
| contains whitespace | search |
| explicit `http://` / `https://` | taken as written |
| `detour://` naming an existing internal page | that URL (opening it is still `loadInternalPage`'s decision) |
| `localhost`, `*.localhost`, IPv4 literal, bracketed IPv6 literal | `http://` |
| dotted host, no port (`example.com`) | `https://` |
| any host with an explicit port | `http://`, except `:443` which keeps `https://` |
| dotless non-numeric name with a valid port (`myhost:8080`) | `http://` |
| dotless word without a port (`swift`) | search |
| all-digit label with a "port" (`10:30`, `16:9`) | search |
| colon not followed by a port in 1…65535 (`note:todo`, `foo:99999`) | search |

Only the host part decides: everything before the first `/`, `?` or `#`, minus
any `user@`. So `foo/bar.html` is a search, where an earlier rule ("contains a
dot and no spaces") made it `https://foo/bar.html`.[^task-83]

## Network suggestions

`SearchSuggestionsService` fetches from the profile's engine with
`URLSession.shared`, parsing the OpenSearch array form
(`["query", ["s1", …]]`) or Yahoo's `gossip` object, up to five strings. The
provider drops a suggestion equal to the query, since the verbatim row covers
it. Errors yield an empty list silently.

# Invariants

- A history row's title comes only from the asking space's own visits, or from
  the shared title when no other space has visited the URL.
- The current tab is never switched to by the top hit. Its host can still be
  completed to (the row then navigates to the root).
- No row, top hit or inline completion comes from a tab of an incognito space
  unless the palette belongs to that space's own Private window.
- A URL appears once: tab matches, the top hit and host rows are excluded
  from the history rows, and a host whose root is an open-tab row is not
  offered again as a host row.
- Stale results never land: both asynchronous passes are guarded
  (generation plus text for history, query equality for network).

# Gotchas

- **Stale comments about threading.** The doc comment on
  `HistoryDatabase.searchHistory`, the benchmark's "main thread, per
  keystroke" label, and the reasoning in TASK-94 and TASK-97 all say the
  palette's history queries run synchronously on the main thread per
  keystroke. In the code only `recentHistory` does; `searchHistory` and
  `bestURLCompletion` have run on `historyQueryQueue` since commit `81154a4`.
  The latency budget still matters, because a `DatabaseQueue` is one
  connection and serialises every reader and writer behind the query.
- **`recentHistory` cost grows with total history.** It groups every visit of
  the space per URL before taking the newest 12: 25–28 ms at 50,000 visits in
  a Debug build, on the main thread.[^task-97] TASK-97 proposes walking visits
  newest-first and stopping early.
- **The instant pass and `localSuggestions` share the tab rules.** Before
  TASK-182 the view's instant pass had its own copy of the tab top hit and
  tab matching, and a change to one copy made the list flicker between two
  answers. Both now call `SuggestionProvider.tabTopHit` and `matchingTabs`;
  keep it that way (`testTheInstantPassTopHitIsTheProvidersTabRule`).
- **Completion queries scan.** Inline completion runs once per keystroke on
  `historyQueryQueue`. At 55,000 visits (Debug, median of five, visits moved
  into the last 90 days): `bestURLCompletion` 23 ms and
  `bestHostCompletions` 36 ms for the one-letter `s` that matches every URL,
  and about 15 ms each for `site13`. A host query runs the host lookup *in
  place of* the URL lookup, not as well.[^bench] The benchmark fixture's
  visits date from 1970; legs that depend on the 90-day window must move
  them first, or they measure an empty result.
- **`visitCount`, `rank` and `faviconURL` are cross-space values.** The first
  two only order results. The favicon is displayed: one icon per URL, whoever
  fetched it last.
- **Tab matching is substring, history matching is token-prefix.** "box" finds
  an open tab titled "Inbox" but not a history row with that title.
- Measured per-query costs at 50,000 visits (Debug, median of five): about
  47 ms for the one-letter query `a`, 22 ms for a URL token, 0.8 ms for a
  miss.[^task-96]

# Tests

- `SuggestionProviderTests` - order (top hit, verbatim, tabs, history),
  dedup against open tabs, the cap of 12, current tab excluded, autocomplete
  suppression, and the cross-profile label and match cases.
- `SuggestionProviderTests` host cases (TASK-182): a host prefix with only
  deep-URL tabs open, a tab at the root, the current tab's host, frecency
  summed per host, the root's own title, space scoping, host rows with
  autocomplete off, the cap of two, a query with a path, non-web tabs, and
  the instant pass agreeing with the provider.
- `AddressInputClassifierTests` - every row of the table above, including the
  false positives.
- `PaletteTabScopeTests` - the space rule in both directions (a normal window
  with a Private window open; a Private window with normal spaces and with
  another Private window) and its fail-closed cases.
  `PaletteTabScopeWiringTests` - `gatherTabInfos` on a real store with both
  kinds of space.
- `HistoryDatabaseTests` - `searchHistory`, `recentHistory` and
  `bestURLCompletion` isolation and ordering
  (`testSearchHistoryNeverMatchesThroughAnotherProfilesTitle`,
  `testFTSKeywordTokensAreSearchableRatherThanASyntaxError`).
- `HistoryBenchmarkTests` - env-gated timings (`TEST_RUNNER_HISTORY_BENCH=1`),
  including the completion legs.
- Runtime, in a Debug build with the [TASK-181/182 harness](../../docs/harness/task181-182-harness.patch)
  (keys through the field editor's real key bindings): with three sleeping
  video tabs and a typed visit to another `you…` host, Cmd+T and `you`
  completed the field to `youtube.com` and listed the site root, the verbatim
  row, the other host and the three videos. Pixels were not captured.

# Related

- [Command palette](./command-palette.md) - the view that hosts these rows and submits them.
- [History own-title matching](../decisions/history-own-title-matching.md) - the scoping rule for titles.
- [History recording and search](./history-recording-and-search.md) - typed visits, and the other query families.
- [History database](../architecture/history-database.md) - the tables and indexes behind the three lookups.
- [Favicons](./favicons.md) - `FaviconLoader`, which loads the icons of history rows.
- [Incognito](../architecture/incognito.md) - the Private-window boundary the tab candidates respect.

[^task-83]: Treat host:port and localhost input as a URL
[^task-137]: A normal window's open-tab suggestions include tabs from open Private windows
[^task-96]: Index every title a URL has had
[^task-97]: Recent history aggregates every visit in the space
[^task-182]: Complete a typed host prefix to the site (youtube.com), not to one deep URL
[^bench]: HistoryBenchmarkTests.swift (completion legs)
