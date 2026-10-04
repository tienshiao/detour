---
type: Decision
title: History search matches titles only through the scope's own visits
description: Why a page title may match or label a history result only through visits made in the asking scope, how the title index makes that cheap, and the designs that were tried and dropped on the way.
tags: [history, privacy, profiles, search, sqlite]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T08:18:18Z }
sources:
  - id: history-db
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift
  - id: task-91
    resource: backlog:TASK-91
    title: Store the page title per visit and record in-page pushState navigations
  - id: task-93
    resource: backlog:TASK-93
    title: History search matches titles only through the profile's own visits
  - id: task-94
    resource: backlog:TASK-94
    title: Command palette history suggestions show and match another profile's page title
  - id: task-96
    resource: backlog:TASK-96
    title: Index every title a URL has had
  - id: task-138
    resource: backlog:TASK-138
    title: chrome.history.search returns history from every profile
  - id: title-index-tests
    resource: ../../DetourTests/HistoryTitleIndexTests.swift
    title: HistoryTitleIndexTests.swift
  - id: history-db-tests
    resource: ../../DetourTests/HistoryDatabaseTests.swift
    title: HistoryDatabaseTests.swift
  - id: session-notes
    resource: "Agent session notes, 2026-09-19 and 2026-09-20 (not in the repository)"
    title: History feature state notes
---

# Context

`historyURL` holds one row per URL, shared by every [profile](../architecture/profiles-and-spaces.md),
and its `title` is overwritten by the newest visit anywhere. `historySearch`,
the original FTS5 index, covers `(url, title)` of that table. Two leaks follow
once two profiles visit the same URL:

- **Display.** A suggestion or history row in the personal profile is labelled
  with the title the work profile last gave the page (`(3) Inbox - you@work`).
- **Match.** A query finds a URL through a word that only the other profile's
  title contains. Even when the row then shows its own title, the hit itself
  reveals the foreign text.

Per-visit titles (`historyVisit.title`, migration h4, TASK-91) fixed the
display on the History page but left search on the shared index. The schema
is described in [history database](../architecture/history-database.md); what
gets written when is in
[history recording and search](../features/history-recording-and-search.md).

# Decision

1. **A title may match or label a result only through a visit made in the
   asking scope.** The scope is the profile's spaces on the
   [History page](../features/history-page.md) and for the
   `chrome.history.search` extension API (the calling context's profile,
   TASK-138), and a single space in the
   [command palette](../features/suggestion-pipeline.md). Keeping the palette
   space-scoped rather than widening it to the profile was a product decision
   made in TASK-94.
2. **URL text is not protected.** A URL is the same text whoever visited it,
   so an FTS hit on the `url` column qualifies a row as soon as the scope has
   visited that URL at all.
3. **An index offers candidates; a matcher decides.** `historyTitle` (one
   refcounted row per distinct non-empty title a space gave a URL) and its FTS
   table `historyTitleSearch` produce candidate URLs. On the History page the
   pure Swift matcher `HistoryDatabase.titleMatches`, exposed to SQL as
   `history_title_matches`, is still the precise test. The palette trusts the
   index directly: a `historyTitle` row exists only while `n > 0`, that is,
   while an in-scope visit still carries that exact title.
4. **Index and matcher fold text with the same function.** `historyTitleSearch`
   indexes `history_fold(title)`, and the query terms for that table are folded
   by `HistoryDatabase.folded` too, so the gate cannot hide a row the matcher
   would accept.
5. **Every FTS term is quoted** (`ftsPrefixQuery` emits `"tok"*`). Unquoted,
   the words `AND`, `OR` and `NOT` are FTS5 operators: a query such as
   "not found" was a syntax error that every history lookup swallowed,
   returning nothing.[^task-94]

## Legacy visits

Visits recorded before h4 have `title IS NULL`; nothing ever stored what the
page was called at the time. The three surfaces treat them differently, on
purpose:

| Surface | Fallback for a title-less visit |
|---|---|
| History page (`visits`, `searchVisits`) | `COALESCE(v.title, h.title)`, unguarded. A profile-aware guard was considered and not filed: the case only affects pre-h4 visits and ages out with the 90-day expiry.[^task-94] |
| Palette (`scopedTitleExpression`, source C of `searchHistory`) | The shared title only when **no other space** has visited the URL; otherwise the empty string, and `SuggestionProvider.displayTitle` shows the URL instead. |
| Extension API (`extensionTitleExpression` in `searchURLs`) | The shared title only when **no space outside the profile** has visited the URL; otherwise none: the visit cannot match through a title, and the item's `title` is the URL.[^task-138] |

The History page cannot reuse the palette's guard: its scope is several space
IDs, so `o.spaceID <> v.spaceID` would read a sibling space of the same profile
as foreign. The extension API has the profile-aware form of it, written
against a `scope` CTE of the profile's space IDs (`o.spaceID NOT IN (SELECT
spaceID FROM scope)`). It was added there and not on the History page because
the reader is different: the History page shows a title to the person who made
the visit, the extension API hands it to third-party code. The same guard
would fit the History page; that was left as it is.

# Alternatives rejected

| Design | Where | Why it was dropped |
|---|---|---|
| Leave FTS on the URL-level title and only *display* the visit's own title | TASK-91, decision D | A row could show a title that does not contain the query, and the match could come from another profile's title. This was the state TASK-93 set out to fix. |
| A per-visit FTS table | TASK-91, decision D | Index bloat: a URL visited a thousand times under one title would be indexed a thousand times. `historyTitle` indexes distinct titles per `(urlID, spaceID)`, roughly the size of the existing FTS `title` column. |
| "The visit's title **equals** the matched URL-level title" | TASK-93 v1, implemented and reverted | Once another profile retitles a shared URL, this profile can no longer find its own "Inbox" by title. Worse than the leak. |
| Scan every in-scope visit's own title with the Swift function, unfiltered | TASK-93 v2 | Correct, but 380 ms per 50,000 visits in a Debug build against 8 ms before, all of it the per-row call into Swift.[^task-93] |
| The same scan behind a `LIKE`/`GLOB` prefilter | TASK-93 v3, shipped, then narrowed by TASK-96 | 18–40 ms per 50,000 ASCII titles, 220 ms when every title is non-ASCII.[^task-93] Accepted at the time because the bridge runs the query off the main thread and the page debounces input. The prefilter survives behind the candidate gate. |
| Shared FTS index as the palette's only candidate gate, own-title check on the candidates | TASK-94, shipped, then replaced by TASK-96 | A space's own title was findable only while the shared title still contained the word. Personal saw "Budget 2026", work retitled the URL "Dashboard", and "budget" found nothing in personal. Pinned by a test that TASK-96 inverted (`testAnOwnTitleAloneIsFoundThroughTheTitleIndex`). |
| Index the raw title with `unicode61` | TASK-96 first cut | The differential test found 13 divergences, all from Foundation folds that expand one character into two (`ß` to `ss`, the `ﬁ` ligature to `fi`), which `unicode61` cannot do. The History page lost "strasse" for "Straße".[^task-96] |
| Make the title index the precise test and drop the matcher | TASK-96 | Would change search semantics. Keeping the matcher makes the result set the same as before by construction. |
| GRDB `synchronize(withTable:)` for `historyTitleSearch` | TASK-96 | Its `AFTER UPDATE` trigger deletes and re-inserts the FTS entry on every column change, and `n` changes on every visit. A `historyTitle` row's title is immutable, so hand-written insert and delete triggers are the whole story. |
| `NOT EXISTS (another visit with this title)` in the delete trigger | TASK-96 | It walks every visit of the URL: quadratic for a page visited thousands of times. A refcount needs two unique-index seeks. |
| An index on `historyTitle(spaceID)` | TASK-96 | Every plan reaches the table by rowid from the FTS side; the index would be written and never read (checked with `EXPLAIN QUERY PLAN`). |

# Consequences

**What it buys**

- A title a page *used* to have is searchable again, in the scope that saw it.
- On the History page a row that matched on a title always displays a title
  that matched.
- No title from another profile can produce a result or hide one.
- Own-title, URL and miss searches on the History page went from 36–348 ms to
  about 10 ms per 50,000 visits; a palette lookup for a word only this space's
  title has went from finding nothing to 7.2 ms.[^task-96]

**What it costs**[^task-96]

- `recordVisit` is about 36% slower (roughly 0.5 ms per visit, on the async
  writer).
- Clearing 50,000 visits takes 357 ms instead of 167 ms: two unique-index
  statements per deleted visit. It runs off the main thread, but a
  `DatabaseQueue` serialises reads behind it.
- The database grew 38% (7.5 to 10.4 MB) at 14,900 title rows.
- Known bad shape: when every visit has a unique title, the one-letter palette
  query regresses (48.6 to 66.6 ms) and the database doubles.
- A common title word still leaves most visits as candidates on the History
  page (55 to 39 ms ASCII, 340 to 123 ms non-ASCII).

All figures are medians of five runs on a synthetic fixture (50,000 visits,
8,000 URLs, three spaces) in a Debug build. Re-measure with
`env TEST_RUNNER_HISTORY_BENCH=1 xcodebuild … -only-testing:DetourTests/HistoryBenchmarkTests`.

**Accepted and pinned by tests**

- *Match and label can come from different visits in the palette.* A palette
  row is a URL, not a visit: "inbox" can match this space's older visit while
  the row is labelled by its newer one. Both are the space's own.
- *Legacy visits keep the unfolded behaviour.* A title-less visit reaches the
  gate only through `historySearch`, which indexes the raw shared title, so
  "strasse" does not find a pre-h4 visit whose shared title is "Straße"
  (`testALegacyVisitKeepsTheUnfoldedBehaviourOfTheSharedIndex`).
- *Known hole in the palette's legacy guard.* The guard reads the present. If
  another space's title-less visits gave `historyURL.title` its value and are
  later deleted, nothing recomputes the shared title (`reconcileStagedURLs`
  only revisits it when a deleted visit carried a title of its own), and this
  space adopts it as a fallback. Confined to title-less visits inside the
  90-day window.

**Not covered, deliberately**

- `historyURL.faviconURL`, `visitCount` and the bm25 `rank` are still
  cross-space in the palette. The last two only order results; the favicon is
  displayed.

**Overturned**

- `chrome.history.search` was listed here as global by design: it read
  `historyURL` through `searchHistoryGlobal` and returned the shared title,
  count and last-visit time. That was a leak between profiles to any
  extension holding `history`, and TASK-138 removed the function. The API now
  follows rule 1 with the calling context's profile as its scope, and takes
  its counts and times from in-scope visits
  ([polyfill layer](../extensions/polyfill-layer.md)).[^task-138]

**Traps this design creates**

- Any connection that touches `historyVisit` needs `history_fold` registered.
  A raw `sqlite3` CLI insert of a *titled* visit fails with
  `no such function: history_fold`; seed with NULL titles or go through the
  app.[^task-96]
- A test that builds its own queue must call
  `HistoryDatabase.registerFunctions(on:)` before migrating past h5.
- Plain FTS5 `integrity-check` does not compare an external-content table with
  its content on SQLite 3.51; the `rank = 1` form does.[^task-96]
- The matcher, the query tokeniser and `history_fold` must keep going through
  `HistoryDatabase.folded`. `testTheGateNeverHidesWhatTheMatcherAcceptsExceptWhereRecorded`
  asserts an empty divergence list over a corpus chosen to produce one.

# Related

- [History recording and search](../features/history-recording-and-search.md) - the write side these rules depend on, and the query families that apply them.
- [History database](../architecture/history-database.md) - tables, triggers and migrations h1 to h5.
- [Suggestion pipeline](../features/suggestion-pipeline.md) - how the palette uses `searchHistory`, `recentHistory` and `bestURLCompletion`.
- [History page](../features/history-page.md) - the profile-scoped consumer of `visits` and `searchVisits`.
- [Two databases](./two-databases.md) - why history has no profile column to join on.

[^task-93]: History search matches titles only through the profile's own visits
[^task-94]: Command palette history suggestions show and match another profile's page title
[^task-96]: Index every title a URL has had
[^task-138]: chrome.history.search returns history from every profile
