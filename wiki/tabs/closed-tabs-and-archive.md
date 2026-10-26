---
type: Feature
title: Closed tabs and the Archived Tabs page
description: What a closed-tab record holds, how Reopen Closed Tab, the close undos and the Archived Tabs page each consume it, how archived records differ from plain closes, and closed Quick Detours filed under their profile's scope (TASK-193.5).
tags: [tabs, closed-tabs, archive, undo, sidebar]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-26T19:00:00Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (closeTab, reopenClosedTab, archiveEntries, restoreClosedTab)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (closed tab stack, migrations v15 and v16)
  - id: record
    resource: ../../Detour/Storage/Models/ClosedTabRecord.swift
    title: ClosedTabRecord.swift
  - id: layout
    resource: ../../Detour/Browser/Sidebar/ArchiveListLayout.swift
    title: ArchiveListLayout.swift
  - id: page-view
    resource: ../../Detour/Browser/Sidebar/ArchivePageView.swift
    title: ArchivePageView.swift
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (archive page reload)
  - id: restore-tests
    resource: ../../DetourTests/ArchivedTabRestoreTests.swift
    title: ArchivedTabRestoreTests.swift
  - id: task-115
    resource: backlog:TASK-115
    title: Sidebar Archive items record the tab as archived
  - id: task-116
    resource: backlog:TASK-116
    title: Reopen Closed Tab should distinguish archived tabs from closed ones
  - id: task-117
    resource: backlog:TASK-117
    title: Closed-tab stack reads from the database only
  - id: task-118
    resource: backlog:TASK-118
    title: Closed-tab records expire with history and are cleared by history deletion
  - id: task-119
    resource: backlog:TASK-119
    title: Archived Tabs page before the first space in the sidebar
  - id: task-120
    resource: backlog:TASK-120
    title: Remove the closed-tab row cap entirely
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: notes
    resource: "Agent session notes, 2026-09-26 (not in the repository)"
    title: Closed tabs / archive work stream notes
---

# What it does

Closing a normal tab in a non-incognito space writes one row to the `closedTab`
table of the [session database](../architecture/session-database.md). That row
is the tab's only life after closing. Three things can bring it back, and each
*consumes* the row:

| Way back | Scope | Which records |
|---|---|---|
| Reopen Closed Tab (Cmd+Shift+T) | the window's active space | plain closes only, newest first |
| Undo (Cmd+Z) of the close | the tab that undo action closed | its own record, while it still exists |
| Archived Tabs page | every non-incognito space, and closed Quick Detours | plain closes and archived records alike |

The Archived Tabs page is the leftmost page of the sidebar's
[page strip](../sidebar/space-paging.md), before the first space: swipe right
past the first space, or Navigate > Show Archived Tabs. Incognito windows have
no such page.

# How it works

## The record

`ClosedTabRecord` holds `tabID` (the closed tab's UUID), `spaceID`, `url`,
`title`, `faviconURL`, `interactionState` (the back/forward list, a blob),
`sortOrder` (the index the tab was closed at), `archivedAt`, `closedAt` and
`extensionID`.

- `id` is `AUTOINCREMENT`. Newest-first order is `id DESC`, never a timestamp.
- **`archivedAt` is the archive marker.** Set by the
  [archive sweep](./sleeping-and-archiving.md) and by the sidebar's "Archive
  Tab" / "Archive Tabs Below"; nil for a plain close. Its value doubles as the
  flag; there is no separate reason column.
- `closedAt` is on every row since migration v16 (backfilled from `archivedAt`).
  For an archive the two stamps are equal. Both members of a split closed
  together share one `closedAt`. Rows older than v16 without `archivedAt` have
  nil and are listed last, by id.
- `ClosedTabSummary` is the same row **without the blob**. Menu validation, the
  reopen scan and listings read summaries; the full row is fetched only for the
  one record being reopened.

Not recorded: incognito closes, a close with `undoable: false`, and closing a
pinned entry's or favourite's tab (those go dormant instead).

## Closed Quick Detours

Since TASK-193.5 a closed [Quick Detour](../features/quick-detour.md#the-archive)
is a row of the same table, with `spaceID` = its profile's Quick Detour
scope (`QuickDetour.historySpaceID(forProfileID:)`, the id its history
visits use) instead of a space's. No migration: every query keyed by a
space (Reopen Closed Tab, a space's deletion and its undo) never meets that
id, so they stay correct unchanged. `archivedAt` set means the idle timer
closed it ("auto-closed"); nil, closed by hand or at quit. Private ones are
never recorded. The listing knows the scopes of the live normal profiles
(`ArchiveEntry.kind = .quickDetour(profileID:autoClosed:)`), a restore
reopens a Quick Detour window instead of a tab
(`QuickDetourWindowController.restore`), Clear covers the scopes when no
space filter is set, and deleting a profile deletes its rows.

## The database is the only store

There is no in-memory copy and nothing is loaded at launch. Reads go through
the `closedTab_on_spaceID_id` index (v15). See
[the decision](../decisions/closed-tabs-database-only.md), which also covers the
absence of any row cap.

## Reopen Closed Tab

`TabStore.reopenClosedTab(in:)` scans the space's summaries with
`includeArchived: false`. Skipping archived rows means Cmd+Shift+T always
brings back a tab the user closed, never one the timer took hours ago.[^task-116]
For each summary, an extension page is classified by its saved `extensionID`:

- extension uninstalled: the record is deleted during the scan;
- extension disabled: skipped but kept, so it can be reopened after an enable;
- ordinary page or enabled extension: chosen.

The shared tail `reopenClosedTabRecord` fetches the full row, deletes it by row
id (skipped records may sit above it, so "pop the newest" would be wrong),
rebuilds the tab with `restoredTab`, and inserts it at `min(sortOrder, count)`
snapped out of any split group. The tab comes back **unsplit** and with a
**new UUID**.

`AppDatabase.popClosedTab(spaceID:)` still exists and ignores `archivedAt`, but
nothing in the app calls it; only `AppDatabaseTests` does.

## Close undo

`closeTab` and `closeSplitGroup` register an undo that rebuilds the tab from
state captured in the closure, then deletes the record by `tabID`. Before
rebuilding it checks `AppDatabase.hasClosedTab(tabID:)`:

- the record is gone (restored from the archive page, reopened, deleted or
  cleared): the undo does nothing. Otherwise it would produce a duplicate of a
  restored tab, or bring back a tab the user threw away;[^task-119]
- incognito closes push no record and always undo;
- in "Close Both Splits", a member whose record is gone stays closed and the
  other comes back alone, as a plain tab.

A manual archive is undone under the name "Archive Tab", and its redo re-closes
with the same `archivedAt`, so a redone archive stays an archive.[^task-115]

## The Archived Tabs page

- **Listing**: `TabStore.archiveEntries()` reads every summary once, drops
  records of spaces that no longer exist, classifies extension pages with one
  shared availability lookup, silently deletes records of uninstalled
  extensions, and marks a disabled extension's page `isRestorable = false`
  (listed, dimmed, not restorable).
- **Layout** is the pure `archiveRows(entries:query:spaceFilter:now:calendar:)`:
  dated entries by `closedAt` descending with ties by id descending, then one
  undated group; headers by *calendar-day* distance (Today, Yesterday, N days,
  N weeks, N months, N years); a header appears only when an entry survives the
  filter. Search splits on whitespace and requires every term, ignoring case
  and diacritics, in the title or the URL *without its scheme* (so "https" does
  not match every row).
- **Restore** (click, Return, or the context menu) calls
  `restoreClosedTab(recordID:)`: the tab goes back into the record's **own**
  space at its original index, the window switches to that space, selects the
  tab and leaves the archive page. Archived records are restorable here, unlike
  through Cmd+Shift+T. A record that cannot come back makes the window beep.
- **Delete** (Delete/Backspace, context menu) and **Clear Archive…** (the page's
  Filter menu, or Navigate > Clear Archived Tabs…, after a confirmation sheet)
  remove records permanently. Clear covers all spaces (and the closed Quick
  Detours) or the filtered space, and is not undoable.
- **Quick Detour rows** (TASK-193.5) say so on their second line: "Quick
  Detour · example.com", or "Quick Detour · auto-closed · …"
  (`archiveEntrySubtitle`); they have no space badge, a space filter hides
  them, and restoring one opens a Quick Detour window on its profile.
- **Live updates**: every `closedTab` mutation in `TabStore` fires
  `tabStoreDidUpdateClosedTabRecords()`, which carries no detail. The sidebar
  marks the page stale and reloads it at most once per run-loop turn, and only
  while it can be seen (showing, or the strip in motion); otherwise lazily when
  it next shows. It also reloads when it was last loaded on an earlier day,
  because the relative-date headers have moved.

The page has no address bar. Its search pill takes the bar's row and copies its
styling; the bar itself rides off with the first space's page.[^notes]

# Edge cases

- Deleting a space deletes its records; Undo Delete Space re-inserts them
  **with their original ids** (`insertClosedTabs`), which puts each back at its
  exact place in the reopen order. The earlier undo re-pushed them and reversed
  the order.[^task-117]
- An archived record of an uninstalled extension's page is no longer purged by
  the reopen scan (it never sees archived rows); the archive listing purges it
  instead.[^task-116]
- Manual archives recorded before `archivedAt` was threaded through the sidebar
  items have it nil and behave as plain closes.
- **Deleting history does not touch closed-tab records.** A record keeps the
  tab's URL, title and whole back/forward list outside the
  [history database](../architecture/history-database.md), and never expires.
  Retention tied to history is designed in TASK-118 (hook:
  `TabStore.historyDidDelete`, matching on the record's current URL only,
  because the blob is an opaque WebKit archive) but is not in the code.[^task-118]

# Tests

`QuickDetourArchiveTests` and `QuickDetourArchiveWindowTests` (closed Quick
Detours: TASK-193.5), `ArchivedTabRestoreTests` (listing, restore position and space, extension
rules, delete, clear, the notification, the undo-after-consume cases),
`ArchiveListLayoutTests` (buckets, sort, search, filter), `TabStoreTests`
("Archive vs close records", reopen ordering), `AppDatabaseTests` (index, v16
backfill, `testClosedTabRecordsAreNeverEvictedByCount`), `SidebarPageStripTests`.

The read-count tests are worth knowing about: `AppDatabase` labels its
closed-tab reads (`closedTabSummariesReadLabel` and friends) so a test can
assert that launch performs zero closed-tab reads and a reopen performs exactly
one full-row read.[^task-117]

Runtime check recorded for the page (isolated profile, in-process harness):
four records across two spaces under Today / Yesterday / 3 days / 1 week
headers, a search narrowing to one row, a click restoring into the other space
and switching the window there, and swipes in both directions. Not exercised at
runtime: the Clear Archive sheet, the Filter menu, a disabled-extension
row.[^task-119]

# Related

- [Closed tabs are read from the database only](../decisions/closed-tabs-database-only.md): why there is no mirror and no cap.
- [Sleeping and archiving](./sleeping-and-archiving.md): the sweep that produces archived records.
- [Tab lifecycle](./tab-lifecycle.md): the close path that writes the record.
- [Space paging](../sidebar/space-paging.md): the page strip the archive page sits in.
- [Session database](../architecture/session-database.md): the `closedTab` table and its migrations.
- [Extension pages](../extensions/extension-pages.md): the classification used for records of extension pages.

[^task-115]: Sidebar Archive items record the tab as archived
[^task-116]: Reopen Closed Tab should distinguish archived tabs from closed ones
[^task-117]: Closed-tab stack reads from the database only
[^task-118]: Closed-tab records expire with history and are cleared by history deletion
[^task-119]: Archived Tabs page before the first space in the sidebar
[^notes]: Closed tabs / archive work stream notes
