---
type: Decision
title: Closed tabs are read from the database only, with no row cap
description: Why the closed-tab stack has no in-memory mirror and no launch load, why nothing evicts records by count, and what was rejected on the way.
tags: [tabs, closed-tabs, persistence, decision, database]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: task-117
    resource: backlog:TASK-117
    title: Closed-tab stack reads from the database only, no launch load, no in-memory mirror
  - id: task-120
    resource: backlog:TASK-120
    title: Remove the closed-tab row cap entirely
  - id: task-116
    resource: backlog:TASK-116
    title: Reopen Closed Tab should distinguish archived tabs from closed ones
  - id: task-118
    resource: backlog:TASK-118
    title: Closed-tab records expire with history and are cleared by history deletion
  - id: task-119
    resource: backlog:TASK-119
    title: Archived Tabs page before the first space in the sidebar
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (Closed Tab Stack)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Reopen Closed Tab, Archived Tabs)
  - id: record
    resource: ../../Detour/Storage/Models/ClosedTabRecord.swift
    title: ClosedTabRecord.swift
  - id: notes
    resource: "Agent session notes, 2026-09-26 (not in the repository)"
    title: Closed tabs / archive work stream notes
---

# Context

`TabStore` used to hold `closedTabStack`, a copy of the whole `closedTab` table
in memory. It was loaded at launch, **including every `interactionState`
blob**, and every mutation wrote both copies, each with its own 100-row trim.
Measured on a real profile: 100 rows, about 850 KB, the largest blob
188 KB.[^task-117]

None of its users needed the mirror:

- menu validation for Reopen Closed Tab needs only `spaceID`, `url` and
  `extensionID` per record;
- the reopen scan needs the blob only for the one record it picks;
- the launch-time purge of uninstalled extensions' records duplicated what the
  reopen scan already does lazily;
- Delete Space, its undo and the close-undo cleanups can ask the database
  directly.

Separately, the 100-row cap was global: one large archive sweep could evict
every tab the user had just closed.[^task-116]

# Decision

1. **The `closedTab` table is the only store.** No launch load, no mirror.
   Listings, menu validation and the reopen scan read `ClosedTabSummary` rows
   (no blob) through an index on `(spaceID, id)` (migration v15). The full row
   is fetched only for the record being reopened.
2. **No row cap at all** (product decision, 2026-09-25). `pushClosedTab` and
   `insertClosedTabs` only insert. The user bounds the table with Clear Archive
   on the [Archived Tabs page](../tabs/closed-tabs-and-archive.md).

# Alternatives rejected

**Keep the full mirror.** It paid a launch-time read and a second code path on
every mutation for nothing a query could not answer.

**A lazily filled per-space metadata cache without blobs.** Named in TASK-117 as
the fallback if a query proved too hot for menu validation. It was not needed
and does not exist. If validation ever does become a problem, this is the shape
to add, not a mirror.

**A per-kind cap** (100 plain closes plus 100 archived records, so an archive
sweep could not evict closes). This shipped briefly as part of separating
archived from closed records, then was removed with the cap itself.[^task-116]

**Retention tied to history instead of a cap.** Designed in TASK-118 (records
older than the history window expire; deleting history deletes matching
records; older records keep URL and title but lose their blob). Not implemented.
When it is, it is the only *automatic* bound.[^task-118]

# Consequences

- Launch performs no closed-tab read; a reopen performs exactly one full-row
  read. Tests assert both through labelled read counters on `AppDatabase`
  (`testLaunchLoadsNoClosedTabRecordsAndReadsThemFromTheDatabase`,
  `testReopenReadsOnlyTheChosenRecordsFullRow`).
- Order is the row id. Reopen deletes the chosen record *by id*, because
  skipped records can sit above it.
- Delete Space snapshots the space's full rows and its undo re-inserts them with
  their **original ids**. `AUTOINCREMENT` never hands a freed id to a new row,
  so each record returns to its exact place in the reopen order. The mirror-era
  undo re-pushed them and reversed the order.[^task-117]
- Records of uninstalled extensions are no longer purged at launch. They are
  discarded when a scan reaches them (the reopen scan, the archive listing).
- With the database as the only truth, a close undo can ask whether its record
  still exists (`hasClosedTab(tabID:)`) and do nothing if it was already
  consumed. That fixed a duplicate tab after Cmd+Shift+T followed by
  Undo.[^task-119]
- **Rows and blobs accumulate until cleared.** Observed blob sizes: about 8.5 KB
  on average, 188 KB at most.[^task-120] Each record also keeps a back/forward
  list outside the history database, untouched by history deletion.
- There is no foreign key from `closedTab` to `space`: `saveSession` deletes and
  re-inserts every space row, so a cascade would wipe the table on each
  save.[^task-118] Space deletion removes the records explicitly instead.
- Closed-tab queries stay in `AppDatabase` and `TabStore`, not in view code, so
  a later consumer of the records does not have to pull logic out of a view
  controller.[^notes]

Do not reintroduce a count cap or an in-memory copy without revisiting this
page.

# Related

- [Closed tabs and the archive](../tabs/closed-tabs-and-archive.md): the feature built on this store.
- [Session database](../architecture/session-database.md): the table, the index and migrations v15 and v16.
- [Persistence](../architecture/persistence.md): what else is and is not loaded at launch.
- [Two databases](./two-databases.md): why these records are in the session database and not the history database.

[^task-116]: Reopen Closed Tab should distinguish archived tabs from closed ones
[^task-117]: Closed-tab stack reads from the database only, no launch load, no in-memory mirror
[^task-118]: Closed-tab records expire with history and are cleared by history deletion
[^task-119]: Archived Tabs page before the first space in the sidebar
[^task-120]: Remove the closed-tab row cap entirely
[^notes]: Closed tabs / archive work stream notes
