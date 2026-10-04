---
type: Component
title: History database
description: "history.db — one shared row per URL, one row per visit scoped to a space, two FTS5 indexes, the per-space title index and its triggers, and the rules that keep one profile's titles out of another's results."
resource: ../../Detour/Storage/HistoryDatabase.swift
tags: [architecture, storage, history, fts5, search]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T09:42:23Z }
sources:
  - id: history-database
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (recording, title correction, deletion follow-up)
  - id: data-model-doc
    resource: ../../docs/data-model.md
    title: docs/data-model.md
  - id: task-87
    resource: backlog:TASK-87
    title: Delete entries and clear history from the History page
  - id: task-91
    resource: backlog:TASK-91
    title: Store the page title per visit and record pushState navigations
  - id: task-93
    resource: backlog:TASK-93
    title: History search matches titles only through the profile's own visits
  - id: task-94
    resource: backlog:TASK-94
    title: Command palette title isolation and FTS token quoting
  - id: task-96
    resource: backlog:TASK-96
    title: Index every title a URL has had
  - id: task-138
    resource: backlog:TASK-138
    title: chrome.history.search returns history from every profile
  - id: task-152
    resource: backlog:TASK-152
    title: favicon.lookup answers from every profile's history, without a permission check
  - id: task-153
    resource: backlog:TASK-153
    title: chrome.history.search with empty text scans every visit of the profile
  - id: url-search-bench
    resource: ../../DetourTests/HistoryURLSearchBenchmarkTests.swift
    title: HistoryURLSearchBenchmarkTests.swift
  - id: url-search-tests
    resource: ../../DetourTests/HistoryURLSearchTests.swift
    title: HistoryURLSearchTests.swift
  - id: history-notes
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on the History feature
---

# Role

`HistoryDatabase` owns `history.db`: what was visited, when, in which space,
and under which title. It serves four readers — the
[command palette](../features/suggestion-pipeline.md), the
[History page](../features/history-page.md), URL completion, and the
`chrome.history` extension API — and it is written by `TabStore` when a load
finishes.

The database knows nothing about profiles. A profile's history is "the
visits of the spaces that use that profile", and callers pass those space
ids in.

# How it works

## Schema

| Table | Rows | Scope |
|---|---|---|
| `historyURL` | One per distinct URL: `title` (latest known), `faviconURL`, `visitCount`, `lastVisitTime`. | **Global**, shared by every space and profile. |
| `historyVisit` | One per visit: `urlID`, `spaceID`, `visitTime`, `isTyped`, `title` (nullable). | Per space. |
| `historyTitle` | One per distinct non-empty title a space has given a URL: `title`, `folded`, and `n` = visits currently carrying it. Unique on (`urlID`, `spaceID`, `title`). | Per space. |
| `historySearch` | FTS5 over `historyURL` (`url`, `title`), `unicode61`, kept in sync by GRDB's `synchronize(withTable:)`. | Global. |
| `historyTitleSearch` | FTS5, external content over `historyTitle.folded`, rowid = `historyTitle.id`. | Per space, through the join. |

Indexes on `historyVisit`: `urlID`, `visitTime`, and (`spaceID`,
`visitTime`). The last one serves the History page paging through one
profile; without it SQLite walked the time index and discarded out-of-scope
rows, about 150 times slower for a profile owning a sliver of the history
(per the migration's comment).

Migrations: `h1` tables and `historySearch`; `h2` `isTyped`; `h3` the
(`spaceID`, `visitTime`) index; `h4` `historyVisit.title`, not back-filled;
`h5` `historyTitle`, `historyTitleSearch`, their triggers, back-filled from
titled visits.

## The one rule: shared row, private visits

`historyURL` is shared. Everything on it — `title`, `visitCount`,
`lastVisitTime`, `faviconURL` — aggregates across all profiles. A
profile-scoped view must therefore take its values from in-scope
`historyVisit` rows and never from the URL row. Concretely:

- **Titles are per visit** (TASK-91). The URL row's title is overwritten by
  the newest visit anywhere, so before `h4` one profile's "(3) Inbox —
  you@work" became the title another profile saw. A visit recorded before
  `h4` has a NULL title and falls back to the URL-level one.
- **A title from another profile may neither label a result nor produce
  one** (TASK-93, TASK-94). The reasoning and the rejected designs are on
  [history own-title matching](../decisions/history-own-title-matching.md).
- In the palette, `visitCount` and the FTS `rank` still cross profiles. They
  only order results. `faviconURL` is displayed and is shared; that is a
  known, accepted leak of one icon per URL.

No reader that answers a question from outside is unscoped. Until TASK-138
`chrome.history.search` read `historyURL` across all spaces
(`searchHistoryGlobal`, since removed), which handed an extension in one
profile the URLs, titles and visit counts of every other profile; it now
reads through `searchURLs`, scoped like the History page.

The favicon lookup was the same hole in a smaller shape (TASK-152). The row
for a URL exists, and has an icon, as soon as *any* profile visits the page,
so "is there an icon for this page?" was "has anyone visited it?" — and the
same-host fallback widened that to "has anyone visited this site?". An
extension asks through `faviconURL(for:visitedInSpaces:)`, which requires a
visit in the given spaces before it answers. Scope decides whether the lookup
answers, not which icon it answers with: the icon stays the URL's one shared
value. The one unscoped lookup left, `faviconURLInAnyProfile(for:)`, says so
in its name and serves only the History page, which asks for rows it already
listed from its own scope.[^task-152]

"Same host" is the URL's host and not a string prefix: the lookup matches
`https://host`, `https://host/…` and `https://host:port…` (and `http`) as
ranges over the URL text, which the unique index on `url` serves. The
`LIKE 'https://host%'` it replaced also took `host.evil.test` for the same
site and could not use the index.

## Custom SQL functions

Two functions are registered on the connection by `registerFunctions(on:)`,
and both queries **and migrations** call them:

| Function | Does |
|---|---|
| `history_fold(text)` | Case- and diacritic-insensitive, locale-independent folding (`String.folding`). `ß` → `ss`, the `ﬁ` ligature → `fi`. |
| `history_title_matches(title, query)` | The matcher: fold both sides, split into alphanumeric runs, true when some title token **starts with** some query token. Terms are OR'd. |

The shared instance registers them through `Configuration.prepareDatabase`;
`init(dbQueue:)` registers them on the injected queue before migrating,
because the `h5` back-fill calls `history_fold`.

Why the index stores folded text: FTS5's `unicode61` maps one code point to
at most one other, so it indexed `straße` where the matcher looked for
`strasse`. The index is a candidate gate in front of the matcher, so
anything the two fold differently is a result silently dropped. Indexing
`history_fold(title)` and folding the query terms with the same function
makes them agree by construction. The first cut without the folded column
produced 13 divergences in the differential test.[^task-96]

The matcher has three paths with one answer: a byte walk for ASCII titles
(no allocation), fold-then-byte-walk for titles that fold to ASCII, and
tokenising into strings for everything else. A single-entry cache keeps the
folded query tokens, because one keystroke can call the function tens of
thousands of times with the same query.

## The title index and its triggers

`historyTitle` is maintained entirely by SQL triggers on `historyVisit`
(`historyVisit_ai_title`, `_ad_title`, `_au_title_old`, `_au_title_new`):
insert increments or creates the row, delete decrements and removes it at
zero, a retitle moves the count from one row to another. Triggers, not Swift,
because visits are written and deleted by a dozen paths — recording, title
correction, the delete APIs, expiry, foreign key cascades, and tests' raw
SQL — and a trigger is the only place they all pass through.

`historyTitleSearch` is kept in step by two hand-written triggers on
`historyTitle` (`historyTitle_ai`, `historyTitle_ad`). GRDB's
`synchronize(withTable:)` was avoided: it adds an update trigger that
re-indexes on any column change, and `n` changes on every visit.

`historyTitle.id` is `AUTOINCREMENT` so an id is never reused; the FTS table
addresses rows by id and a reused id would resurrect a deleted title's index
entry.

## Reads

| Method | Caller | Scope | Notes |
|---|---|---|---|
| `recentHistory(spaceID:)` | Palette, empty query | One space | One row per URL, newest in-scope visit first. |
| `searchHistory(query:spaceID:)` | Palette | One space | Runs **synchronously on the main thread per keystroke**, so every candidate comes from an index: URL text, this space's own titles, and legacy title-less visits no other space has visited. |
| `bestURLCompletion(prefix:spaceID:)` | Palette inline completion | One space | Frecency: each visit adds a recency weight (100 within 4 days, 70 within 14, 50 within 31, 30 within 90), doubled for typed visits; visits older than 90 days are ignored. |
| `visits(spaceIDs:from:until:before:limit:)` | History page | A profile's spaces | Keyset paging on (`visitTime`, `id`), not OFFSET. Page size capped at 500. |
| `searchVisits(query:spaceIDs:…)` | History page search | A profile's spaces | One row per URL, represented by its newest in-range visit that matched. Candidate gate, then LIKE/GLOB prefilter, then the matcher. |
| `searchURLs(query:spaceIDs:from:until:limit:)` | `chrome.history.search` | A profile's spaces | One row per URL (`HistoryURLEntry`), newest in-scope visit first. Empty text lists everything in the window. Not for the main thread. |
| `faviconURL(for:visitedInSpaces:)` | Extension favicons (`detour-favicon://`) | A profile's spaces | Exact URL when the scope visited it, else the same-host page the scope visited most recently. Nil for a page or host only other profiles visited. |
| `faviconURLInAnyProfile(for:)` | The History page's `favicon` route | All spaces | Exact URL, then same host. Only for rows the caller already listed from its own scope. |

The palette labels each row with the space's own latest non-empty title
(`scopedTitleExpression`), and only falls back to the shared title when no
other space has visited the URL. The label subqueries run in an outer select
over the rows that survived `LIMIT`, never over every candidate.

## One select for both profile-scoped searches

`searchVisits` and `searchURLs` with text are built on the same inner select,
`scopedVisitsSelect`: the scope filter, the `[from, until)` window, the
candidate gate and the own-title matcher, with `ROW_NUMBER()` numbering each
URL's qualifying visits newest first. Both keep `rn = 1`, so a row in either
stands for the newest in-scope, in-range visit that itself qualified, and its
title is that visit's. What "this profile's visit matches this query" means
is therefore stated once.[^task-138]

They differ in two things:

| | `searchVisits` (History page) | `searchURLs` (`chrome.history.search`) |
|---|---|---|
| A row carries | the visit: id, time, title | the URL: id, title, and `visitCount`, `typedCount`, `lastVisitTime` aggregated over **all** of the scope's visits of it, not only those in the window |
| Title of a title-less (pre-`h4`) visit | `COALESCE(v.title, h.title)`, unguarded | the shared title only while no space **outside the scope** has visited the URL; otherwise none, and the caller shows the URL |

The aggregates come from a join on `historyVisit` in an outer select
(`urlEntriesSelect`) over the rows that survived `LIMIT`. The scope is also
given to the statement as a CTE (`scope`), because the guarded title
expression is repeated once per query token and so cannot bind the space list
itself. The join's scope test is written `+c.spaceID IN (…)`, for the reason
given under Deletion: the visits to aggregate are reached by URL, never by
walking the profile.

The extension's title rule is stricter than the History page's on purpose:
what it returns leaves the browser, to extension code. See
[history own-title matching](../decisions/history-own-title-matching.md).

## The empty-text listing is a walk, not a window

`chrome.history.search({ text: '' })` asks for the most recently visited URLs
and matches nothing. `scopedVisitsSelect` answers that too, with no tokens,
but only after numbering **every** in-scope visit in the range and evaluating
the title rule for each, to return 100 rows. Since TASK-153 `searchURLs` with
an empty text takes another route (`listedURLEntries`) that must give the
same rows:[^task-153]

1. **Walk** (`newestVisitPerURL`). One cursor per space of the scope, each
   reading `WHERE spaceID = ? [window] ORDER BY visitTime DESC, id DESC`
   straight off the (`spaceID`, `visitTime`) index, merged in Swift by
   (`visitTime`, `id`). The first visit of a URL the walk meets is that URL's
   newest in-scope, in-range visit, so it is kept and later ones are skipped;
   the walk stops at `limit` URLs.
2. **Describe.** The kept visit ids go, 500 at a time, through the same outer
   select as the text path: URL, the guarded title of that visit, and the
   aggregates over all of the scope's visits of the URL.

Both steps run inside one read, so they see the same history.

Why the merge is in Swift: SQLite cannot read an index in order across
`spaceID IN (…)`. It either sorts every in-scope visit before returning the
first, or walks the plain `visitTime` index through every other profile's
visits.

What must stay true, and what checks it:

| Rule | Check in `HistoryURLSearchTests` |
|---|---|
| Same rows, order, counts, times and titles as the windowed select with no tokens | `testTheListingAgreesWithTheWindowedSelect`: random histories with tied times, strangers on the same URLs, titled, empty-titled and title-less visits, compared for several scopes, ranges and limits. `windowedURLEntries` is not private so the test can call it |
| The work follows the rows returned, not the size of the scope | `testListingTheNewestURLsDoesNotWalkTheWholeScope` counts SQLite virtual-machine steps through a progress handler: a history ten times the size may take at most twice the steps. The windowed select took 9.7 times (917,030 against 94,280)[^task-153] |

The walk degrades to the whole scope only when the caller asks for it: a
`limit` larger than the number of URLs in the range, or a range in which a
few URLs have nearly all the visits.

The text path still windows over every qualifying visit. Its known bad shape
is a query that matches a much-visited URL whose visits have no title of
their own: `extensionTitleExpression`'s `NOT EXISTS` probe runs per
title-less candidate visit and walks all visits of the URL when no other
profile has visited it, which is quadratic. In the measurements below that
is 396 title-less visits of a 5,225-visit URL, and it is what the 2.2 s of
"text matching every URL" is attributed to: the same query takes 352 ms in
the 99,000-visit profile and 164 ms in the 45,000-visit one, neither of which
visited that URL. (Inferred from those controls; the URL was not removed to
isolate it.) Not fixed; the default range of `chrome.history.search` keeps
the common call away from it.

All FTS query tokens are double-quoted (`"tok"*`). FTS5 reserves `AND`, `OR`
and `NOT`; unquoted, typing "not found" was a syntax error and every lookup
returned nothing (TASK-94).

## Writes

- `recordVisit` is an asynchronous write. It upserts the URL row
  (`INSERT … ON CONFLICT DO UPDATE … RETURNING id`), inserts the visit with
  its title, and hands the visit id to `completion` **on GRDB's writer
  queue**. Callers hop to main themselves.
- `updateTitle(visitID:url:title:)` corrects one visit, identified by id; the
  `url` argument is a consistency check so stale state writes nothing rather
  than renaming a stranger's visit. The URL-level title follows only when
  this visit is still the newest visit of the URL across all spaces. It is
  queued behind the insert that produced the id, so it cannot overtake it.

When a visit is recorded, the 30 s dedup and the 60 s correction window live
in `TabStore`; see
[history recording and search](../features/history-recording-and-search.md).

## Deletion

Three entry points, all profile-scoped in SQL and all reporting a
`HistoryDeletionResult` (`deletedVisitCount`, `affectedURLs`, `removedURLs`):

| Method | Deletes |
|---|---|
| `deleteVisits(ids:spaceIDs:allVisitsOfURL:from:until:)` | Named visits; with `allVisitsOfURL`, every in-scope visit of those URLs within the window (search mode shows one row per URL). |
| `deleteVisits(spaceIDs:since:)` | Everything in scope at or after a cutoff; nil clears the scope. |
| `deleteVisits(notInSpaceIDs:)` | The launch sweep of spaces that no longer exist. |

Each stages per-URL counts in a temp table, deletes, then repairs the shared
`historyURL` rows in four set-based statements regardless of size:

- `lastVisitTime` becomes the newest remaining visit across **all** spaces.
- `visitCount` becomes `max(visitCount − deleted, remaining rows)`, not a
  plain count. `visitCount` runs ahead of the visit rows because expiry
  deletes rows without decrementing it; recomputing it would demote the URL
  for every other profile sharing the row.
- `title` is repaired only when a deleted visit carried a title of its own.
- A URL with no visit left anywhere loses its row and its FTS entry.

A failed delete is reported as `.failure`, never as an empty success: the
page would otherwise remove rows from the screen that are still stored.

The scope filter in deletes is written `+spaceID IN (…)`. The unary plus
stops SQLite using the (`spaceID`, `visitTime`) index for it. The app never
runs `ANALYZE`, and with default statistics the planner picked that index
for `id IN (<500 ids>) AND spaceID = ?` and walked every visit of the
profile to delete 500 rows (per the code comment, checked with
`EXPLAIN QUERY PLAN`).

The launch sweep has two guards because its scope is "everything else": an
empty list of existing spaces deletes nothing, and at least one existing
space must own a visit. The second covers a session database that was reset
or failed to restore, where a fresh default space would make all history
look orphaned.

Closed-tab records in the session database are not touched by history
deletion.

## Expiry

`expireOldVisits()` deletes visits older than 90 days and then URL rows left
with no visits. `AppDelegate` schedules it 5 seconds after launch so the
anti-join is off the launch path.

# Invariants

- A `historyTitle` row exists only while `n > 0`, that is, while some
  in-scope visit still carries that exact title.
- `historyTitleSearch` holds exactly the rowids of `historyTitle`.
- The LIKE/GLOB prefilter in `searchVisits` is a strict superset of the
  matcher: it may only save work, never exclude a row the matcher accepts.
- No profile-scoped read returns `historyURL.visitCount` or `lastVisitTime`
  as a value.

# Gotchas

- Seeding with the `sqlite3` command line: an insert of a visit **with a
  title** fails with "no such function: history_fold", because the trigger
  calls a function only the app registers. Seed NULL titles or go through
  the app.[^task-96]
- A test that drives `migrator` against a bare queue must call
  `registerFunctions(on:)` first, or `h5` fails.
- Plain FTS5 `integrity-check` does not compare an external-content table
  with its content on SQLite 3.51. The `rank = 1` form does; the tests use it
  together with a rowid-set comparison through `fts5vocab`.[^task-96]
- There is no `eraseDatabaseOnSchemaChange` here. Editing an unshipped
  history migration in place strands every database that already ran it; a
  scratch test database had to have its `h5` artefacts dropped by
  hand.[^history-notes]
- `DatabaseQueue` is one connection: a long write blocks every read behind
  it, including the palette's main-thread query. "Clear all" on 50,000
  visits took about 357 ms in a Debug build.[^task-96]
- A long **read** does the same. A query run off the main thread still holds
  the queue, and a palette read issued meanwhile waits for all of it: 2.4 s
  behind an extension's unbounded empty-text search before TASK-153; see
  [the measurements](#chromehistorysearch-on-a-large-history).[^task-153]
- The temp staging table outlives its transaction on that single connection,
  so each delete drops and recreates it.

# Measured cost

Debug build, 50,000 visits over 8,000 URLs and 3 spaces, median of
5:[^task-96]

| Operation | Before the title index | After |
|---|---|---|
| History page search, own title / URL / miss | 36–39 ms (322–348 ms when titles are non-ASCII) | about 10 ms |
| History page search, common title word | 55 ms (340 ms non-ASCII) | 39 ms (123 ms) |
| Palette, word only in this space's own title | found nothing | 7 ms, finds it |
| 1,000 `recordVisit` calls | 1,423 ms | 1,932 ms |
| Database size, 14,900 title rows | 7.5 MB | 10.4 MB |

Known bad shape: if every visit has a unique title, the single-letter
palette query gets slower (49 → 67 ms) and the database roughly doubles.

The benchmark is `HistoryBenchmarkTests`, gated behind
`TEST_RUNNER_HISTORY_BENCH=1` in `xcodebuild`'s environment. See
[build and test](../playbooks/build-and-test.md).

## chrome.history.search on a large history

`HistoryURLSearchBenchmarkTests`, gated behind
`TEST_RUNNER_HISTORY_SEARCH_BENCH=1`. Debug build, median of 5, measured on
2026-10-04 (once before the change, twice after, the two agreeing within 10%)
on a machine under heavy load (load average above 40), so the numbers are
orders of magnitude. 300,000 visits of 40,000 URLs over 90 days in
a file database; three profiles over five spaces; the profile measured has two
spaces and 155,327 visits; one URL has 2% of all visits; the oldest fifth of
the visits has no title of its own.[^task-153]

`searchURLs`, the profile's two spaces, `limit` 100 unless stated:

| Query | Before TASK-153 | After |
|---|---|---|
| Empty text, all history | 2,157 ms | 12.7 ms |
| Empty text, all history, the profile owning 15% of the visits | 126 ms | 4.9 ms |
| Empty text, last 24 hours | 15.1 ms | 12.5 ms |
| Empty text, all history, `limit` 1,000 | 2,165 ms | 59 ms |
| Empty text, all history, `limit` 10,000 | 2,440 ms | 367 ms |
| Empty text, all history, no limit (26,333 rows) | 2,648 ms | 776 ms |
| Text, a URL token, all history | 48 ms | 49 ms |
| Text, a common title word, all history | 171 ms | 170 ms |
| Text, a common title word, last 24 hours | 15 ms | 16 ms |
| Text matching every URL, all history | 2,281 ms | 2,251 ms |
| Text matching every URL, last 24 hours | 34 ms | 34 ms |
| Text matching every URL, all history, the 99,000-visit profile | not measured | 352 ms |
| Text matching every URL, all history, the 45,000-visit profile | not measured | 164 ms |

The budget TASK-153 holds the listing to: an empty-text search for Chrome's
default 100 results takes at most 50 ms on this history in a Debug build,
whatever the range. Past that the cost follows the rows asked for, about
30–60 µs each.

A palette read made on the main thread while an extension's search holds the
queue (the read's whole duration, wait included):

| Read | Alone | Behind empty text, all history, 100 | Behind empty text, all history, no limit | Behind text matching every URL, all history |
|---|---|---|---|---|
| `recentHistory` before | 142 ms | 2,416 ms | 2,849 ms | 2,477 ms |
| `recentHistory` after | 151 ms | 164 ms | 919 ms | 2,399 ms |
| `searchHistory("a")` before | 216 ms | 2,433 ms | | |
| `searchHistory("a")` after | 219 ms | 226 ms | | |

So a default-size listing now delays a palette read by its own 13 ms. The two
waits that remain are an extension asking for the whole history in one call,
and a text search over all history that hits the bad shape above; nothing
bounds those short of giving the main thread a connection of its own. The
"alone" column is also worth a look: on a history this size the palette's own
reads take longer than the wait this task removed.

# Tests

`HistoryDatabaseTests`, `HistoryURLSearchTests` (`searchURLs`: isolation
between two profiles, own counts, times and titles, the legacy-title guard),
`HistoryTitleIndexTests` (migrate-versus-fresh, every
delete path, the differential gate test), `HistoryDeletionIntegrationTests`,
`HistoryTitleUpdateTests`, `SameDocumentVisitTests`, `HistoryTimeRangeTests`,
`HistoryBenchmarkTests`.

For the empty-text listing, `HistoryURLSearchTests` also holds the differential
test against the windowed select and the step-count test described above;
`HistoryURLSearchBenchmarkTests` is the gated timing run.

# Related

- [History recording and search](../features/history-recording-and-search.md) — when a visit is recorded and corrected.
- [History page](../features/history-page.md) — the profile-scoped reader.
- [Suggestion pipeline](../features/suggestion-pipeline.md) — the space-scoped reader.
- [History own-title matching](../decisions/history-own-title-matching.md) — the isolation decision.
- [Two databases](../decisions/two-databases.md) — why this is a separate file.
- [Persistence](./persistence.md) — the session side.

[^task-96]: Index every title a URL has had
[^task-138]: chrome.history.search returns history from every profile
[^task-152]: favicon.lookup answers from every profile's history, without a permission check
[^task-153]: chrome.history.search with empty text scans every visit of the profile
[^history-notes]: Session notes on the History feature
