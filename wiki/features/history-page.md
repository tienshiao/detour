---
type: Feature
title: History page
description: "The detour://history/ page: a profile-scoped list of visits in an ordinary tab, with search, a time-range filter, selection and delete, and a natively confirmed Clear History."
tags: [history, internal-pages, profiles, privacy, bridge]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
sources:
  - id: bridge
    resource: ../../Detour/Browser/InternalPages/HistoryPageBridge.swift
    title: HistoryPageBridge.swift
  - id: content
    resource: ../../Detour/Browser/InternalPages/HistoryPageContent.swift
    title: HistoryPageContent.swift (document, stylesheet, page script, favicon route)
  - id: time-range
    resource: ../../Detour/Browser/InternalPages/HistoryTimeRange.swift
    title: HistoryTimeRange.swift
  - id: history-db
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (showHistory)
  - id: task-86
    resource: backlog:TASK-86
    title: Profile-scoped History page in a tab
  - id: task-87
    resource: backlog:TASK-87
    title: Delete entries and clear history from the History page
  - id: task-92
    resource: backlog:TASK-92
    title: Time-range filter on the History page
  - id: task-95
    resource: backlog:TASK-95
    title: Revealing the selection bar shifts the list 40px under the pointer
  - id: integration-tests
    resource: ../../DetourTests/HistoryDeletionIntegrationTests.swift
    title: HistoryDeletionIntegrationTests.swift
  - id: internal-page-tests
    resource: ../../DetourTests/InternalPageIntegrationTests.swift
    title: InternalPageIntegrationTests.swift
  - id: time-range-tests
    resource: ../../DetourTests/HistoryTimeRangeTests.swift
    title: HistoryTimeRangeTests.swift
---

# What it does

Navigate > Show All History (Cmd+Y) opens `detour://history/` in a normal tab
of the window's active space. The page lists the visits of the tab's
**profile** (every space that currently uses it), newest first and grouped by
day, with a search field, a time-range control, row selection with delete, and
a Clear History menu. A second Cmd+Y selects the History tab the space already
has, a pinned one included (`BrowserWindowController.showHistory`).

Being a tab, it gets web view ownership, snapshots, sleep and wake, splits and
session restore without extra code. Being privileged, it sits behind the three
layers described on [internal pages](./internal-pages.md); this page covers
only what is specific to history.

# How it works

## Scope is derived, never sent

No bridge message names a profile or a space. `HistoryPageBridge.scope(for:)`
maps the sending tab to its `owningProfile` and returns the IDs of the spaces
whose `profileID` matches. It returns nil for an incognito or deleted profile,
and then `history.query` answers `{entries: [], incognito: true|false}` instead
of falling through to another profile. Visits of deleted spaces are not shown.

The same rule holds for writes: the SQL deletes only rows that are both named
and in scope (`id IN (…) AND +spaceID IN (…)`), so a forged visit id from
another profile deletes nothing
(`testACrossProfileForgedVisitIDDeletesNothing`).

## Bridge methods

| Method | Params | Reply |
|---|---|---|
| `history.query` | `search?`, `limit` (clamped to 1…200; the page asks for 100), `cursor? {time, id}`, `range?`, `window?` | `{entries: [{id, url, title, time}], incognito, window?, nextCursor?}` |
| `history.delete` | `ids` (1…500), `allVisitsOfURL?`, `window?` | `{cleared: true, deleted: n}` |
| `history.clear` | `range`: `hour` \| `today` \| `all` | `{cleared: bool, deleted: n}` |

Error strings: `forbidden` (sender check failed), `malformed`, `unavailable`
(no scope: incognito), `failed` (the write failed), `unknown method`.

There is no "open" method. Entries are plain `<a href>` links, rendered as
links only when the URL parses as `http(s)`, so click, Cmd-click and
middle-click ride the ordinary link policy and open in the tab's own space.

## Listing and paging

`history.query` runs on a global queue and calls `visits` (no search) or
`searchVisits`. Both page by **keyset** over `(visitTime DESC, visitID DESC)`
through `HistoryCursor`, not OFFSET, so visits recorded while the user pages
cannot shift the window. The bridge asks for `limit + 1` rows to learn whether
a next page exists. In list mode a row is one visit; in search mode a row is a
URL, represented by its latest in-scope, in-range visit that itself matches
(see [history own-title matching](../decisions/history-own-title-matching.md)).

The page keeps a `generation` counter; a reply that does not carry the current
one belongs to a query the user has moved on from and is dropped. Search input
is debounced 150 ms. On window focus and on becoming visible the page runs
`refresh`, which re-reads the top of the list and re-renders only if the
newest entry changed. There is no live push.

## Time range: symbolic in, one window per listing

The page sends a symbolic `range`: `{preset: today|yesterday|week|month}` or
`{day: "YYYY-MM-DD"}`. `HistoryTimeRange` resolves it natively into half-open
bounds `[from, until)`:

- Day arithmetic goes through `Calendar.date(byAdding: .day, …)`, never a
  multiple of 86,400, so DST days do not start an hour off.
- Days resolve in a **Gregorian** calendar with the user's time zone. The date
  field speaks `YYYY-MM-DD`; resolving it in a Buddhist or Japanese system
  calendar would show a different day from the one the control names.
- A specific day is anchored at noon and walked back with `startOfDay`,
  because midnight does not exist on some DST days.
- Absent means all time; anything unrecognisable is `malformed`, never
  quietly widened to all of history. A valid day outside the 90-day retention
  window is not malformed: it answers an empty list.

The reply carries the resolved `window {from, until}`, and the page echoes
that window on every later page of the same listing and on URL-mode deletes.
Re-resolving "today" per request would move the window under a listing that
stays open across midnight. Letting the page name instants here is safe
because a window can only *narrow* a read or a delete fan-out, and the scope
is still native. `history.clear` is the opposite shape (an instant would widen
what is destroyed), so its cutoff stays native.

The range lives in the page URL next to the query (`?q=…&range=week` or
`&day=YYYY-MM-DD`), written with `history.replaceState`, so reload and session
restore return to the same view.

## Delete

| Mode | A row stands for | Message | Effect |
|---|---|---|---|
| List | one visit | `{ids}` | deletes that visit |
| Search | a URL | `{ids, allVisitsOfURL: true, window?}` | deletes every in-scope visit of that URL **inside the window the row was rendered under** |

What a row stands for is read from the row as it was rendered
(`dataset`), not from `state.query`, which may already have moved on to a
search whose rows have not landed. With a window, a second pass deletes the
named ids regardless, so the row the user clicked cannot survive its own
deletion. Selections larger than 500 are sent as several messages.

`HistoryDatabase.deleteVisits` stages per-URL counts in a temp table and then
repairs the shared `historyURL` rows in four set-based statements, whatever
the delete's size (`reconcileStagedURLs`): `lastVisitTime` from the newest
remaining visit in any space, `visitCount` as
`max(visitCount - deleted, remaining)`, the title only when a deleted visit
carried one, and the row itself removed when no visit remains anywhere. The
bridge then calls `TabStore.historyDidDelete`; see
[history recording and search](./history-recording-and-search.md).

A failed write is reported as `failed`, never as an empty success: the page
would otherwise take rows off screen that are still in the database.

## Clear History

`history.clear` is confirmed **natively**: an `NSAlert` sheet on the sending
tab's window naming the range and the profile, with a destructive button. The
page cannot see, fake or skip it. Details that matter:

- No window, or a window that already has a sheet: refused.
- The scope is re-derived *after* the user answers. The sheet blocks only its
  own window, and spaces or the tab's profile can change meanwhile.
- The cutoff is taken after the answer too: "the last hour" means the hour
  before the user said yes. `today` is the start of the local day.
- The page's `clearing` flag is the only thing that stops a second question
  being queued behind a sheet it cannot see.

## Selection

Ticking a row swaps the search controls for the selection controls (count,
Delete, Cancel) **inside the same fixed-height row**, through one switch: the
`selecting` class on the header. An earlier layout revealed a 40 px bar under
the search row, which moved every row down under the pointer so a quick second
click landed on the wrong row.[^task-95]

While rows are ticked nothing replaces the list. `deferWhileSelecting` is
asked at every point a replacement could start or land; the owed action
(`reload` outranks `refresh`) runs once in `leaveSelection`. Load-more appends
still work. Focus returns to the control that had it, captured at `mousedown`
in the capture phase, because a real press blurs the field before `click`
fires.[^task-95]

Keys: Delete and Backspace delete the selection (`event.repeat` ignored),
Escape cancels, Shift-click extends from the last row toggled by hand, Cmd+A
selects every row when the list has focus and the field's text when the
search field has.

## Favicons

Rows load `favicon?pageUrl=…&size=32` from the page's own scheme, served by
`FaviconPNGLoader` (see [favicons](./favicons.md)). The page may name only a
*page* URL; which icon that resolves to is decided natively from the history
database, so the route cannot be pointed at an arbitrary host. Images are
`loading=lazy`; a 404 hides the image.

# Edge cases

- **Incognito**: an explanatory empty state, no range control, and
  `unavailable` for both destructive methods.
- **Hostile titles**: every entry string was written by a visited page. The
  script never assigns markup (`createElement` plus `textContent` only), and
  the document's CSP has no script source at all
  (`testAHostileTitleIsRenderedAsText`).
- **Form restore**: WebKit restores form values *after* the page script on
  reload and session restore, which left the range `<select>` out of step with
  the list. The controls carry `autocomplete=off` and are re-synced from state
  on `load` and `pageshow`.[^task-92]
- **Date field**: no `min`. The 90-day expiry runs only at launch, so older
  days can exist; `max` is refreshed to today on reveal and focus.
- **Never recorded**: the recorder skips non-`http(s)` URLs, so the page is
  not in its own list (`testTheHistoryPageIsNeverRecordedAsAVisit`).
- **Refresh during load-more**: `refresh` neither claims the loading flag nor
  starts a generation. Abandoning an in-flight load-more reply would stall
  paging for good, because the sentinel is already intersecting and its
  observer never fires again.

# Tests

| Suite | Covers |
|---|---|
| `HistoryDeletionIntegrationTests` | bridge methods through a real web view: scope, forged ids, malformed params, windows, the page UI (selection, focus, deferral, key repeat), dedup-cache follow-up, launch sweep |
| `InternalPageIntegrationTests` | loading, incognito, cross-profile isolation, hostile title, sleep/wake, restore |
| `HistoryTimeRangeTests` | parsing, bounds, DST, time zones, non-Gregorian system calendars, the wire window |
| `HistoryDatabaseTests` | `visits`, `searchVisits`, the delete APIs and reconciliation |

Test seams, never assigned in production: `HistoryPageBridge.database` and
`HistoryPageBridge.confirmClear`. The UI tests observe bridge traffic by
wrapping `postMessage` in the page's content world, with no production
hooks.[^task-95]

Runtime checks need real input events: a locked screen delivers none, and
WebKit throttles timers of hidden pages. A harness that pokes the page must
poll for the History document first; a fixed sleep after `showHistory` was not
enough.[^task-95] See
[in-process UI automation](../playbooks/in-process-ui-automation.md).

# Related

- [Internal pages](./internal-pages.md) - arming, the scheme handler, the content-world bridge.
- [History recording and search](./history-recording-and-search.md) - what the rows are and how they got their titles.
- [History own-title matching](../decisions/history-own-title-matching.md) - why search results stay inside the profile.
- [History database](../architecture/history-database.md) - schema and indexes, including `historyVisit_spaceID_visitTime` (h3) that the list relies on.
- [Profiles and spaces](../architecture/profiles-and-spaces.md) - what "the tab's profile" resolves to.

[^task-92]: Time-range filter on the History page
[^task-95]: Revealing the selection bar shifts the list 40px under the pointer
