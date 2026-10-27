---
type: Component
title: Suggestion pipeline
description: How the command palette's rows are produced - open tabs and history from the palette's profile, inline URL completion by frecency, network search suggestions - and how typed input is classified as a URL or a search.
resource: ../../Detour/Browser/CommandPalette/SuggestionProvider.swift
tags: [command-palette, history, search, frecency, performance]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T10:30:00Z }
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
  - id: task-209
    resource: backlog:TASK-209
    title: "Command palette: scope suggestions to the palette's profile"
  - id: history-bridge
    resource: ../../Detour/Browser/InternalPages/HistoryPageBridge.swift
    title: HistoryPageBridge.swift (scope(forProfile:))
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
memory), history (SQLite) and network search suggestions, and it names the
URL the field should inline-complete to. Open tabs and history both come from
the palette's **profile** only (TASK-209).[^task-209]
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

For a non-empty query `localSuggestions(for:historySpaceIDs:tabs:allowAutocomplete:currentTabID:)`
returns, in order, capped at `maxSuggestions` (12):

| # | Rows | Source | Limit |
|---|---|---|---|
| 1 | Top hit | `tabTopHit` (open tabs); else, for a host query, the best `bestHostCompletions` host; otherwise `bestURLCompletion` | 1, only when `allowAutocomplete` |
| 2 | `.searchInput` | the typed text | 1 |
| 3 | Other hosts | `bestHostCompletions` minus the top hit's host and any host whose root is already an open-tab row; host queries only | 2 (`maxOtherHosts`) |
| 4 | Open tabs | URL or title *contains* the query, case-insensitive (`matchingTabs`) | 3 |
| 5 | History | `searchHistory(query:spaceIDs:limit: 8)`, minus URLs already shown as tabs, as the top hit or as host rows | 8 |
| 6 | Search suggestions | added by the view (`PaletteRows.compose`) when they arrive | 4, or enough to reach six rows; at most 12 rows in all |
| 7 | Default-list filler | the empty-field list, minus URLs already listed (`PaletteRows.compose`) | up to six rows in all |

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

`bestHostCompletions(prefix:spaceIDs:limit:)` finds the profile's visits of the
last 90 days whose URL matches the prefix (the same four scheme patterns as
`bestURLCompletion`), sums each URL's frecency, groups the URLs by
`history_display_host(url)` and ranks the hosts by the sum. A site visited
across many pages beats one page visited a little more than each of them,
which ranking URL by URL got backwards. For each of the (at most three)
hosts kept it looks up the root (`https://host/`, `https://www.host/`, and
`http`) among the profile's own visits, labelled through `labelledSelect` like
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

For an empty query `defaultSuggestions` returns `recentHistory(spaceIDs:limit: 12)`,
with a row turned into `.openTab` when a tab already shows that URL. This
default list is shown with no row selected, unlike a typed query's list; see
the keyboard section of [command palette](./command-palette.md).

## Which open tabs are candidates

The provider never reads `TabStore`. The view hands it `[TabInfo]` built by
`CommandPaletteView.gatherTabInfos`: the normal tabs and the live pinned
entries' tabs of the spaces `PaletteTabScope.offeredSpaceIDs` allows.

| Palette's window | Spaces |
|---|---|
| Normal | the non-incognito spaces of the active space's profile, not only the active one |
| Private | its own space only |
| No active space, or one the store no longer has | none |
| Quick Detour window, Quick Detour launcher | none (`tabStore` is nil: switching to a tab would bring a browser window forward) |

So open tabs are suggested across the profile's spaces, as history is, but
never from another profile and never across the Private boundary in either
direction. Until TASK-209 a normal window was offered every non-incognito
space, so "Switch to Tab" could jump into another profile; until TASK-137 its
list also included the spaces of open Private windows.[^task-137]
`gatherTabInfos` is the only constructor of `TabInfo` outside the tests; a new
caller that hands tabs to the provider has to go through the same rule. The
Private rule and its fail-closed cases are on
[incognito](../architecture/incognito.md).

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
removes at the tail, so the list stays visually stable while typing. The
view does not show a pass's rows as they come: each pass updates its part
(`matchRows`, `searchSuggestionTexts`) and `PaletteRows.compose` rebuilds the
list from them plus default-list filler, so the list area is always six rows
and the passes change rows, not the box. A pass that lands after the user
arrowed to a row does not change that row. Details on
[Command palette](./command-palette.md#view-structure).

Only `loadDefaultSuggestions` (the empty-query list, hence `recentHistory`)
still reads the database synchronously on the main thread.

## History is profile-scoped

All four history lookups take the palette's scope, a list of
`historyVisit.spaceID`s: only URLs **the profile** has visited are suggested,
and a row is labelled with the profile's own latest titled visit, whichever of
its spaces made it, never with a title another profile gave the URL. That rule,
its legacy fallback and what was rejected on the way are on
[history own-title matching](../decisions/history-own-title-matching.md).

The scope is set on the palette by whoever shows it
(`CommandPaletteView.historySpaceIDs`) from
`PaletteTabScope.historySpaceIDs(profile:in:)`, which is the History page's
own definition, `HistoryPageBridge.scope(forProfile:)`: every space of the
profile plus its [Quick Detour](./quick-detour.md) scope. So the palette, the
[History page](./history-page.md) and `chrome.history.search` agree on what a
profile's history is.

| Entry point | Profile | History scope |
|---|---|---|
| Cmd+T, Cmd+L, the faux address bar, the sidebar's New Tab row, the empty state (all `BrowserWindowController.showCommandPalette`) | the active space's | that profile's spaces and Quick Detour scope |
| Quick Detour window's palette (the host in its bar) | the window's | the same, whichever window it was opened from |
| Quick Detour launcher | the one it was asked for | the same |
| Private window, Private Quick Detour, quarantine | the Private profile | none: nothing is recorded there, and no profile's history may be read |

The empty list is fail-closed: a palette nobody gave a scope, a deleted
profile and a missing one get no history. Every history-derived row goes
through the scope: the history rows, the history top hit and its inline
completion, the host rows, the empty-field list and the default-list filler
under a typed query (TASK-184).

**Decision (the user, 2026-10-26, TASK-209): the whole profile.** History
widened from the window's active space to the profile, like the History page
and including the profile's Quick Detour visits. This **supersedes** the
TASK-94 decision, recorded here for its reasoning: TASK-94 kept the palette
scoped to the active space while the History page was scoped to the profile,
so that a space's palette suggested what was done in that space. The cost was
that a page visited in a sibling space of the same profile, or in a Quick
Detour, could not be completed to, while its cookies were the same; and a
legacy (title-less) visit lost its title as soon as a sibling space had also
visited the URL. Rejected alternative in TASK-209: staying space-scoped
within the profile (only the open-tab rows and the Private boundary would
have changed).

`searchHistory` unions three indexed candidate sources (URL text; the scope's
own titles through the title index; the shared title for a legacy title-less
visit that no space outside the scope shares), takes `MIN(rank)` per URL, and
orders by `rank, -visitCount, id`. The three ranks are bm25 scores of two
different FTS tables and are not strictly comparable; they order suggestions
and nothing else.

`recentHistory` walks the scope's visits newest first, one cursor per space
over the (`spaceID`, `visitTime`) index, and stops at 12 distinct URLs
(`newestVisitPerURL`, the walk `chrome.history.search` lists with); the rows
are then labelled. Ties on the visit time go to the newer visit.

Each lookup names the scope through a `scope` CTE whose space IDs are the
statement's first binds, so the label expression binds nothing and the scope
can be named as often as needed.

`SuggestionProvider.displayTitle` falls back to the display URL when the title
is empty, which happens both for the guarded legacy case and when the visit a
URL's latest title came from was deleted.

## Inline completion and frecency

`bestURLCompletion(prefix:spaceIDs:)` matches the prefix against scheme-stripped
URLs by prepending the four scheme variants (`https://`, `http://`,
`https://www.`, `http://www.`) as `LIKE 'prefix%'` patterns. `%`, `_` and `\`
in the prefix are escaped. The patterns cannot use the index on `url`: `LIKE`
is case-insensitive and the index is `BINARY`. Since TASK-209 the URLs drive
the lookup (`historyURL CROSS JOIN historyVisit`, with `+` on the visit
terms), so only the matching URLs' visits are read; driving from the scope's
visits through the (`spaceID`, `visitTime`) index read every visit of the
profile on every keystroke (see Gotchas). Candidates are ranked by a
Firefox-style score summed over the profile's visits from the last 90 days,
whichever space made them:

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

- Every history-derived row (history rows, the history top hit and its inline
  completion, host rows, the empty-field list and the filler under a typed
  query) comes from the palette's profile, and every open-tab row from one of
  its spaces (TASK-209).
- A history row's title comes only from the profile's own visits, or from the
  shared title when no space outside the profile has visited the URL.
- A Private window's, a Private Quick Detour's and a quarantine's palette has
  no history scope at all.
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

- **Threading.** The reasoning in TASK-94 and TASK-97 says the palette's
  history queries run synchronously on the main thread per keystroke. In the
  code only `recentHistory` does (the empty-field list); `searchHistory` and
  both completions have run on `historyQueryQueue` since commit `81154a4`
  (the doc comment and the benchmark label were corrected in TASK-209). The
  latency budget still matters, because a `DatabaseQueue` is one connection
  and serialises every reader and writer behind the query.
- **`recentHistory` used to grow with total history.** It grouped every visit
  of the space per URL before taking the newest 12: 25–33 ms at 50,000 visits
  in a Debug build, on the main thread.[^task-97] Since TASK-209 it walks
  newest first and stops at 12 URLs: 9 ms for the benchmark's whole profile
  (80% of its visits), where the grouping statement would have read nearly
  twice the visits it read for one space.
- **The instant pass and `localSuggestions` share the tab rules.** Before
  TASK-182 the view's instant pass had its own copy of the tab top hit and
  tab matching, and a change to one copy made the list flicker between two
  answers. Both now call `SuggestionProvider.tabTopHit` and `matchingTabs`;
  keep it that way (`testTheInstantPassTopHitIsTheProvidersTabRule`).
- **Completion queries scan `historyURL`.** Inline completion runs once per
  keystroke on `historyQueryQueue`. A host query runs the host lookup *in
  place of* the URL lookup, not as well. The benchmark fixture's visits date
  from 1970; legs that depend on the 90-day window must move them first, or
  they measure an empty result.[^bench]
- **Cost of the profile scope (TASK-209).** Debug build, 55,000 visits over
  8,000 URLs, median of five; before = one space (45% of the visits, the
  statements of TASK-182/TASK-96), after = the profile (two spaces, 80%):

  | Lookup | Before (space) | After (profile) |
  |---|---|---|
  | `searchHistory` `a` (every URL) | 49 ms | 25 ms |
  | `searchHistory` URL token | 22 ms | 1.1 ms |
  | `searchHistory` title word | 30 ms | 8.5 ms |
  | `searchHistory` own-title token | 7.2 ms | 1.0 ms |
  | `recentHistory` (main thread) | 33 ms | 9 ms |
  | `bestURLCompletion` `s` (every URL) | 24 ms | 40 ms |
  | `bestHostCompletions` `s` | 38 ms | 61 ms |
  | `bestURLCompletion` `site13` | 15 ms | 3.2 ms |
  | `bestHostCompletions` `site13` | 16 ms | 4.6 ms |

  The search got faster because its `EXISTS` scope probes are written
  `+v.spaceID`: they read the candidate URL's own visits through
  `historyVisit_urlID`, where the planner had walked the space's visits
  through the (`spaceID`, `visitTime`) index. The completions are driven from
  `historyURL`; a first cut that kept them visit-driven with the wider scope
  measured 41 ms (`s`) and 24 ms (`site13`), linear in the visits in scope.
  Only a one-letter prefix that matches every URL is slower than before: it
  sums the frecency of every in-scope visit either way, and the profile has
  more of them. Re-measure with
  `env TEST_RUNNER_HISTORY_BENCH=1 xcodebuild … -only-testing:DetourTests/HistoryBenchmarkTests`.
- **`visitCount`, `rank` and `faviconURL` are cross-profile values.** The first
  two only order results. The favicon is displayed: one icon per URL, whoever
  fetched it last.
- **Tab matching is substring, history matching is token-prefix.** "box" finds
  an open tab titled "Inbox" but not a history row with that title.
- Measured per-query costs at 50,000 visits before TASK-209 (Debug, median of
  five, one space): about 47 ms for the one-letter query `a`, 22 ms for a URL
  token, 0.8 ms for a miss.[^task-96]

# Tests

- `SuggestionProviderTests` - order (top hit, verbatim, tabs, history),
  dedup against open tabs, the cap of 12, current tab excluded, autocomplete
  suppression, and the cross-profile label and match cases. TASK-209: two
  profiles over overlapping URLs (three spaces and a Quick Detour scope in
  one), every history row and the top hit's title from the palette's profile,
  a title word from a sibling space found, the empty-field list, and an empty
  scope offering only the verbatim row.
- `SuggestionProviderTests` host cases (TASK-182): a host prefix with only
  deep-URL tabs open, a tab at the root, the current tab's host, frecency
  summed per host, the root's own title, space scoping, host rows with
  autocomplete off, the cap of two, a query with a path, non-web tabs, and
  the instant pass agreeing with the provider.
- `AddressInputClassifierTests` - every row of the table above, including the
  false positives.
- `PaletteTabScopeTests` - the space rule in both directions (a normal window
  with a Private window open; a Private window with normal spaces and with
  another Private window), the profile rule (two profiles, each window offered
  its own) and the fail-closed cases. `PaletteHistoryScopeTests` - the history
  scope is the History page's (spaces plus Quick Detour scope), empty for the
  Private profile, a deleted one and none. `PaletteTabScopeWiringTests` -
  `gatherTabInfos` on a real store with both kinds of space and two profiles.
  `PaletteEntryPointScopeTests` - Cmd+T and Cmd+L in real windows on two
  profiles, and a Private window. The Quick Detour palettes:
  `QuickDetourLauncherTests`, `QuickDetourWindowTests`,
  `QuarantineWindowTests.testItsPaletteOffersNoHistoryAndNoTabs`.
- `HistoryDatabaseTests` - `searchHistory`, `recentHistory` and
  `bestURLCompletion` isolation and ordering
  (`testSearchHistoryNeverMatchesThroughAnotherProfilesTitle`,
  `testFTSKeywordTokensAreSearchableRatherThanASyntaxError`); TASK-209's
  "Palette profile scope" section: every space and the Quick Detour scope
  read, two profiles over one URL each labelled and matched by their own
  titles, the legacy fallback across sibling spaces, frecency summed over the
  profile only, the newest-first merge, an empty scope.
- `HistoryBenchmarkTests` - env-gated timings (`TEST_RUNNER_HISTORY_BENCH=1`),
  including the completion legs.
- Runtime, in a Debug build with the [TASK-181/182 harness](../../docs/harness/task181-182-harness.patch)
  (keys through the field editor's real key bindings): with three sleeping
  video tabs and a typed visit to another `you…` host, Cmd+T and `you`
  completed the field to `youtube.com` and listed the site root, the verbatim
  row, the other host and the three videos. Pixels were not captured.
- Runtime, TASK-209, with the [TASK-209 harness](../../docs/harness/task209-harness.patch):
  two profiles over overlapping URLs and titles seeded in an isolated data
  directory, a window per profile, and the rows each palette showed logged
  from its table. Light and dark, 18 palettes each (Cmd+T, Cmd+L, the faux
  bar, the launcher on both profiles, a Private window): no row from the other
  profile; a sibling space's and a Quick Detour's history now found; one
  Switch to Tab row for a URL open in both profiles; nothing but search
  suggestions in the Private window; a palette left open across a switch to
  the other profile's empty space followed it. The screen was locked, so the
  palettes were opened by direct calls, typed into through the field editor,
  and no pixels were captured.

# Related

- [Command palette](./command-palette.md) - the view that hosts these rows and submits them.
- [History own-title matching](../decisions/history-own-title-matching.md) - the scoping rule for titles.
- [History recording and search](./history-recording-and-search.md) - typed visits, and the other query families.
- [History database](../architecture/history-database.md) - the tables and indexes behind the three lookups.
- [Favicons](./favicons.md) - `FaviconLoader`, which loads the icons of history rows.
- [Incognito](../architecture/incognito.md) - the Private-window boundary the tab candidates respect.
- [History page](./history-page.md) - whose profile scope the palette shares since TASK-209.
- [Quick Detour](./quick-detour.md) - its palettes, and the scope its visits are filed under.

[^task-83]: Treat host:port and localhost input as a URL
[^task-137]: A normal window's open-tab suggestions include tabs from open Private windows
[^task-96]: Index every title a URL has had
[^task-97]: Recent history aggregates every visit in the space
[^task-182]: Complete a typed host prefix to the site (youtube.com), not to one deep URL
[^bench]: HistoryBenchmarkTests.swift (completion legs)
[^task-209]: Command palette: scope suggestions to the palette's profile
