---
type: Feature
title: chrome.history in the polyfill
description: How the polyfill's chrome.history.search reads only the calling profile's history, its argument rules, the 24-hour default range taken from Chrome, and the members that do nothing.
tags: [extensions, polyfill, history, profiles]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: task-138
    resource: backlog:TASK-138
    title: chrome.history.search returns history from every profile
  - id: task-153
    resource: backlog:TASK-153
    title: chrome.history.search with empty text scans every visit of the profile
  - id: task-251
    resource: backlog:TASK-251
    title: "Extensions: the history and management namespaces exist for extensions without the permission"
  - id: chrome-history-api
    resource: https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/history/history_api.cc
    title: "Chromium, history_api.cc (HistorySearchFunction)"
  - id: history-scope-tests
    resource: ../../DetourTests/ExtensionHistoryScopeTests.swift
    title: ExtensionHistoryScopeTests
---
Detour's `chrome.history` is a polyfill (WebKit vends none), installed only
when the manifest declares `history` in either permission list, and only
`search` does anything ([request gates](./polyfill-request-gates.md)). It
answers from the calling profile's history alone.

# history.search is profile-scoped

History belongs to a profile, and so does a handler. `history.search`
therefore reads only the visits of the spaces that use the handler's profile
— the scope `HistoryPageBridge.scope(forProfile:)` gives that profile's
[History page](../features/history-page.md), by the same function — through
`HistoryDatabase.searchURLs`. Before TASK-138 it read the shared `historyURL`
table unfiltered, and an extension in one profile got every other profile's
URLs, titles and visit counts; a test in a real context showed profile A's
worker receiving profile B's URL and the five-visit total of a page A had
visited twice.[^task-138]

| Rule | Detail |
|---|---|
| Scope | The spaces currently using the handler's profile. The last-active space plays no part |
| No scope | An empty list, never everyone's history: the Private profile (it records no visits), a deleted or released profile, a profile no space uses |
| `visitCount`, `typedCount`, `lastVisitTime` | Aggregated from the profile's own visits of the URL. `typedCount` was a constant 0 before |
| `title` | The title the profile's own visit recorded; the URL when it has none it may show ([history database](../architecture/history-database.md)) |
| `text` | Matched like the History page's search: alphanumeric tokens, prefix, OR'd, against the URL text and the profile's own titles. Empty lists everything in the range |
| `startTime` / `endTime` | Milliseconds, half-open `[startTime, endTime)`, select a URL by the profile's own visits |
| `startTime` left out | 24 hours before now, as in Chrome; see [the default range](#the-default-range-is-the-last-24-hours) |
| Order | Newest of the profile's qualifying visits first (before TASK-138, a search with text was ordered by FTS rank, then the shared visit count) |
| Arguments | `query` must be an object and `text` a string; `maxResults` a non-negative integer, the times numbers. Anything else is refused (`history.search: query.text must be a string`), where a lenient parse used to answer `search({})` with the whole history |

The query runs off the main thread and the reply is posted back to it. It
still holds history's one serial queue while it runs, so a
[command palette](../features/command-palette.md) read on the main thread
waits for it; what that costs is measured on
[history database](../architecture/history-database.md).

Not carried over from Chrome: `maxResults: 0` returns nothing (Chrome reads it
as no limit), and an omitted `endTime` is no upper bound (Chrome's is "now",
which differs only for a visit dated in the future).

# The default range is the last 24 hours

A query with no `startTime` (absent or `null`) covers the 24 hours before now.
Until TASK-153 it had no lower bound.

| Query | Range |
|---|---|
| `{ text: '' }`, `{ text: 'inbox' }` | from 24 hours ago, whatever `maxResults` and `endTime` say |
| `{ text: '', startTime: 0 }` | all of the profile's history: 0 or less is no lower bound |
| `{ text: '', startTime: t }` | from `t`, taken as given |
| `{ text: '', endTime: e }` with `e` more than a day ago | nothing: the default start is after the end |

Why Chrome's rule and not "no lower bound":

- It is what an extension written for Chrome expects. Chrome's schema says of
  `startTime` "If property is not specified, it will default to 24 hours", and
  `HistorySearchFunction` sets a one-day range and 100 results first, then
  overwrites each of start, end and count that the query names — so the default
  does not depend on the text or on the other two.[^chrome-history-api]
  `startTime: 0` is how an extension asks for everything.
- `search({ text: '' })` is what new-tab pages and history sidebars call on
  every open. Bounded to a day it read about 3,000 visits instead of 155,000
  on the benchmark history: 15 ms where the unbounded listing took 2.2 s
  before its query was rewritten.[^task-153]

The rule lives where the extension's arguments become a range,
`ExtensionPolyfillHandler.historySearchQuery(from:now:)`. The clock is a
parameter there, and `ExtensionPolyfillHandler.now` is the seam a test sets to
put a visit exactly on the edge (24 hours old is inside, a second older is
not). Because `startTime: 0` still reaches the unbounded query, that query has
to be cheap on its own; it is, for an empty text, since TASK-153.

# The other members

The other `chrome.history` members need no scoping because they read and
write nothing: `getVisits` answers `[]`, `addUrl`, `deleteUrl`, `deleteRange`
and `deleteAll` resolve without touching the database, and `onVisited` /
`onVisitRemoved` never fire. They make no native request at all, so they are
not permission-gated either. Whoever makes one of them real has to scope it
the same way.

# Tests

| Suite | Proves |
|---|---|
| [ExtensionHistoryScopeTests](../../DetourTests/ExtensionHistoryScopeTests.swift) | `chrome.history.search` through the production wiring (`Profile.extensionController`), one extension in two profiles: isolation, the permission gate, bad arguments and the default range from an extension page and a worker, promise and callback form |

# Related

- [Polyfill layer](./polyfill-layer.md) — the request path.
- [History database](../architecture/history-database.md) — `searchURLs`, the listing path and its measurements.
- [History page](../features/history-page.md) — the same per-profile scope, for people.
- [Incognito](../architecture/incognito.md) — why the Private profile has no scope.

[^task-138]: chrome.history.search returns history from every profile
[^chrome-history-api]: Chromium, history_api.cc (HistorySearchFunction)
[^task-153]: chrome.history.search with empty text scans every visit of the profile
