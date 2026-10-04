---
type: Concept
title: History recording and search
description: When a visit is recorded, how its title is stored and corrected, how in-page navigations become visits, and which query serves which consumer under which scope.
tags: [history, tabs, search, privacy, sqlite]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T08:18:18Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (History Recording, subscribeToTab, HistoryTitleUpdatePolicy, SameDocumentVisitPolicy)
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (lastRecorded… state)
  - id: history-db
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (launch expiry and sweep)
  - id: task-87
    resource: backlog:TASK-87
    title: Delete entries and clear history from the History page
  - id: task-88
    resource: backlog:TASK-88
    title: A visit recorded during an in-page navigation keeps the previous page's title
  - id: task-91
    resource: backlog:TASK-91
    title: Store the page title per visit and record in-page pushState navigations
  - id: task-93
    resource: backlog:TASK-93
    title: History search matches titles only through the profile's own visits
  - id: task-96
    resource: backlog:TASK-96
    title: Index every title a URL has had
  - id: title-update-tests
    resource: ../../DetourTests/HistoryTitleUpdateTests.swift
    title: HistoryTitleUpdateTests.swift
  - id: same-document-tests
    resource: ../../DetourTests/SameDocumentVisitTests.swift
    title: SameDocumentVisitTests.swift
  - id: history-db-tests
    resource: ../../DetourTests/HistoryDatabaseTests.swift
    title: HistoryDatabaseTests.swift
  - id: task-138
    resource: backlog:TASK-138
    title: chrome.history.search returns history from every profile
---

# Summary

`TabStore` records a visit when a tab finishes loading or settles after an
in-page navigation; `HistoryDatabase` stores it as one `historyVisit` row
under a shared `historyURL` row. Three things about that are not obvious from
the schema: the title is written twice and corrected late, a visit is tied to
a **space** (never a profile), and every reader has to choose between the
visit's own fields and the URL row's cross-profile aggregates. The schema
itself is on [history database](../architecture/history-database.md).

# Rules

## What records a visit

Two subscriptions in `TabStore.subscribeToTab`, both ending in
`recordHistoryVisit(tab:spaceID:)`:

| Trigger | Fires when | Why it exists |
|---|---|---|
| `tab.$isLoading` going false | a load ends, for a tab that has a `spaceID` | the ordinary case |
| `tab.$url`, debounced by `historySettleDebounce` (1 s) | the URL changed and held still | `history.pushState` and popstate traversals never toggle `isLoading`[^task-88], so a single-page app's page views were otherwise recorded only when an unrelated resource load happened to toggle it |

`recordHistoryVisit` then applies, in order:

1. The typed flag is consumed first (`consumeNextVisitIsTyped`), even if the
   visit is skipped below, so it cannot leak onto a later navigation.
2. Web view showing `browser-error://` - return. After a failed load `tab.url`
   still names the page the user asked for, so recording here would file a
   visit for a page that never loaded, titled by the
   [error page](./error-pages.md).
3. Incognito space - return.
4. Anything but `http`/`https` - return. This is what keeps `detour://`
   [internal pages](./internal-pages.md) and extension pages out.
5. **30 s dedup** per `"url|spaceID"` in the in-memory `recentHistoryWrites`,
   skipped for typed visits.

A tab with no `spaceID` (a favourite's or a Peek's tab that belongs to no
space) records nothing.

## The title is per visit

`recordVisit` writes the tab's title in two places: on the new `historyVisit`
row, which keeps it for good, and on `historyURL.title` as the "latest known
title" for consumers that want one row per URL. Before migration h4 only the
second existed, so the newest title relabelled every older visit of the URL,
in every profile.[^task-91] Visits from before h4 have `title IS NULL` and were
deliberately not backfilled.

## Late title correction

A single-page app finishes loading the new URL *before* it rewrites
`document.title`, so the title captured at recording time is often the
previous page's, or `BrowserTab`'s scheme-stripped URL placeholder.[^task-88]
A debounced `$title` subscription calls `updateHistoryTitle(for:)`, which
asks the pure `HistoryTitleUpdatePolicy.correction(...)`. Every guard is
required:

| Guard | What it rules out |
|---|---|
| tab has a space, not incognito, not loading | the recording exclusions; a title that may belong to either side of a navigation |
| title non-empty and equal to `webView.title` | stand-ins `BrowserTab.updateTitle` publishes: the pending-navigation placeholder, an internal page's name, a restoring session's persisted title; a sleeping tab has no web view and never passes |
| `tab.url == lastRecordedHistoryURL` | renaming the page the tab has since left, or a URL it never recorded |
| `lastRecordedVisitID != nil` | the insert is still in flight; the id's arrival retries |
| `webView.url == tab.url` | an error page's title renaming the real row |
| within `correctionWindow` (60 s) of the recording | an unread counter or marquee title rewriting history for as long as the tab stays open |
| `http`/`https` | everything the recorder excludes |

`HistoryDatabase.updateTitle(visitID:url:title:)` then updates **that visit**
by id. `historyURL.title` follows only if the visit is still the newest visit
of the URL across all spaces, so an old tab settling late cannot override what
a newer visit called the page. Correcting by URL, the first design, renamed
every visit of the URL including other profiles'.[^task-91]

The URL travels with the title through the debounce (`.map { (title, tab.url) }`):
a `pushState` to another page and a Back within the same second would
otherwise write the second page's title onto the first URL.

## State a tab carries for this

All on `BrowserTab`, all set only by `TabStore.recordHistoryVisit`:

| Property | Meaning |
|---|---|
| `lastRecordedHistoryURL` | the URL this tab last got a row for, written or left standing by the dedup |
| `lastRecordedHistorySpaceID` | the space it was filed under; a tab moved to another space writes another profile's history and may not keep correcting the visit it left |
| `lastRecordedVisitID` | the `historyVisit.id` to correct; nil while the async insert is in flight |
| `lastRecordedHistoryAt` | start of the 60 s correction window; belongs to the *visit*, so a dedup-skipped pass does not restart it |
| `lastRecordedBackForwardItem` (weak) | the back/forward entry current at recording time |
| `historyRecordingGeneration` | says whether an id handed back asynchronously is still the one this tab holds |

The generation is bumped by every pass that changes which visit the tab
holds, and **not** by a dedup pass that continues the same visit: bumping
there discarded the tab's own in-flight id and lost the correction (checked by
mutation testing both ways).[^task-91]

## In-page navigations

`SameDocumentVisitPolicy.outcome(...)` tells `pushState` from `replaceState`
by **back/forward item identity**: `pushState` and a popstate traversal make
`backForwardList.currentItem` a different object, `replaceState` rewrites the
current item's URL in place.[^task-91] Query-string churn, including the
History page's own `?q=`, therefore never records.

| Condition | Outcome |
|---|---|
| URL equals `lastRecordedHistoryURL`, or no URL | `.skip` |
| no current item (a `loadHTMLString` document has none) | `.skip` |
| no recorded item to compare against | `.adoptBaseline` - take the current entry as baseline, record nothing |
| current item is the recorded item | `.skip` (a `replaceState`) |
| otherwise | `.record`, through `recordHistoryVisit`, so every rule above is shared |

Deliberately not gated on `isLoading`: an app whose subresource keeps loading
for a minute would lose every page view made meanwhile. Item identity already
excludes an uncommitted navigation. Accepted costs: a cross-document load that
takes more than 30 s after committing records a second visit, and the first
`pushState` in a tab with no baseline item is not recorded. Same-page
`#fragment` navigations record a visit, as in Chrome.[^task-91]

## What a delete has to undo in memory

`TabStore.historyDidDelete(_:spaceIDs:requestedAt:clearedScope:)` runs on main
after a [History page](./history-page.md) delete commits:

- Dedup markers are dropped only when **older than the request**
  (`requestedAt`), so a revisit right after a delete records, while a visit
  recorded during the delete keeps its state.
- A tab's `lastRecorded…` state is cleared only for URLs in
  `HistoryDeletionResult.removedURLs` (the `historyURL` row is gone). A merely
  *affected* URL still has a row worth correcting.
- A tab may keep the id of a deleted visit. That is harmless: `historyVisit.id`
  is `AUTOINCREMENT`, so the id is never reused and `updateTitle` matches
  nothing.

## Expiry and the launch sweep

Five seconds after launch `AppDelegate` calls
`HistoryDatabase.expireOldVisits()` (90 days) and
`TabStore.sweepHistoryOfDeletedSpaces()`. The sweep is why deleting a space
does **not** delete its visits: Undo Delete Space restores the space under the
same id and must find its history. The sweep treats spaces deleted this
session as existing, and the database refuses to sweep unless at least one
existing space owns a visit, so a session database that failed to restore
cannot make the whole history look orphaned.[^task-87]

`expireOldVisits` deletes rows without decrementing `historyURL.visitCount`,
so that column runs ahead of the visit rows. Delete reconciliation therefore
sets it to `max(visitCount - deletedHere, remaining rows)` instead of a plain
count, which would silently demote the URL for every other profile.

# Search: one database, two scopes

The history database has no notion of profiles. A profile's history is the
visits of the spaces that use it, and callers pass those space IDs in. Every
reader is scoped, to one space or to a profile's spaces; the unscoped query
`chrome.history.search` used to run was removed by TASK-138.

| Consumer | Function | Scope | A row is | Title shown |
|---|---|---|---|---|
| Palette, empty query | `recentHistory` | one space | a URL | the space's own latest titled visit (`scopedTitleExpression`) |
| Palette, typed | `searchHistory` | one space | a URL | same |
| Palette inline completion | `bestURLCompletion` | one space | a URL | same |
| History page list | `visits` | the profile's spaces | a visit | `COALESCE(v.title, h.title)` |
| History page search | `searchVisits` | the profile's spaces | a URL, stood for by its latest in-scope, in-range visit that itself matches | same |
| `chrome.history.search` | `searchURLs` | the calling extension context's profile's spaces | a URL, chosen like a History page search row, with its count and last-visit time aggregated from the profile's own visits | `v.title`; the shared title for a title-less visit only while no space outside the profile has visited the URL |

Shared semantics, kept identical on both the FTS side and in
`HistoryDatabase.titleMatches`:

- The query is cut into maximal alphanumeric runs; each token is
  **prefix-matched**; tokens are **OR'd**.
- Matching is case- and diacritic-insensitive (`HistoryDatabase.folded`).
- A token never matches mid-word: "box" does not find "Inbox".
- Every FTS term is quoted, because `AND`/`OR`/`NOT` are FTS5 operators.

Which titles may match and which may be displayed, and why, is the subject of
[history own-title matching](../decisions/history-own-title-matching.md).

**Never read `historyURL.visitCount` or `lastVisitTime` into a scoped view.**
They aggregate across all profiles; the History page and the extension API
derive every time and count from in-scope `historyVisit` rows
(`testVisitsNeverLeakAnotherProfilesVisitTime`,
`testAURLVisitedInBothProfilesReportsThisProfilesCountTimeAndTitle`).

# Where it lives

| Piece | File |
|---|---|
| Recorder, title correction, delete follow-up, sweep, both pure policies | [TabStore.swift](../../Detour/Browser/TabStore.swift) |
| Per-tab recording state, `load(_:typed:)` | [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift) |
| Writes, queries, deletes, migrations | [HistoryDatabase.swift](../../Detour/Storage/HistoryDatabase.swift) |
| Row types | [HistoryVisit.swift](../../Detour/Storage/Models/HistoryVisit.swift), [HistoryURL.swift](../../Detour/Storage/Models/HistoryURL.swift), [HistoryVisitEntry.swift](../../Detour/Storage/Models/HistoryVisitEntry.swift) |

# Gotchas

- `recordVisit` and `updateTitle` are fire-and-forget `asyncWrite`s on one
  serial writer queue. They commit in call order, and a later read on the same
  `DatabaseQueue` observes them because it queues behind them. Completions run
  on GRDB's writer queue, not the caller's.
- The id comes back through `RunLoop.main.perform(inModes: [.common])` plus
  `CFRunLoopWakeUp`, not `DispatchQueue.main`: the rest of the pipeline is
  scheduled on the run loop, and an idle run loop would otherwise service the
  block only at its next timer.
- `historyURL.title` can be empty: deleting the visit a URL's latest title
  came from blanks it when no remaining visit has one. Readers need a fallback
  (`SuggestionProvider.displayTitle`).
- A visit recorded at `didFinish` can capture the scheme-stripped placeholder
  when WebKit has not reported the title yet; the correction repairs it about
  a second later.[^task-88]

# Tests

- `HistoryTitleUpdateTests` - the policy matrix, plus real-`WKWebView` cases
  for the SPA sequence.
- `SameDocumentVisitTests` - the policy, and `pushState`/`replaceState`/slow
  loads against a loopback HTTP server. A `loadHTMLString` document has no
  back/forward item, so it cannot be used here.
- `HistoryDatabaseTests`, `HistoryTitleIndexTests` - queries, deletes,
  isolation, the title index.
- `HistoryURLSearchTests`, `ExtensionHistoryScopeTests` - the extension
  API's profile-scoped search, in the database and from real extension
  contexts in two profiles.
- Test-infrastructure finding: a `WKWebView` with **no navigation delegate**
  never sends the request for `load(_:)`; an offscreen test that needs a real
  load must install one.[^task-91]
- Both debounces are injected through `TabStore.init(historySettleDebounce:)`.

# Related

- [History database](../architecture/history-database.md) - schema, triggers, migrations.
- [History own-title matching](../decisions/history-own-title-matching.md) - the isolation rule and the designs rejected on the way.
- [History page](./history-page.md) - the profile-scoped reader and the only caller of the delete APIs.
- [Suggestion pipeline](./suggestion-pipeline.md) - the space-scoped reader.
- [Polyfill layer](../extensions/polyfill-layer.md) - `chrome.history.search`, the other profile-scoped reader.
- [Tab lifecycle](../tabs/tab-lifecycle.md) - where loads start and end.
- [Incognito](../architecture/incognito.md) - why nothing is recorded there.

[^task-87]: Delete entries and clear history from the History page
[^task-88]: A visit recorded during an in-page navigation keeps the previous page's title
[^task-91]: Store the page title per visit and record in-page pushState navigations
