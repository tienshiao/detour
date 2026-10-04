---
type: Decision
title: Two databases
description: Session state and browsing history live in separate SQLite files, browser.db and history.db.
tags: [decision, storage, history, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:20Z }
sources:
  - id: architecture-doc
    resource: ../../docs/architecture.md
    title: docs/architecture.md ("Key Design Decisions")
  - id: data-model-doc
    resource: ../../docs/data-model.md
    title: docs/data-model.md
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift
  - id: history-database
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (sweepHistoryOfDeletedSpaces)
  - id: task-87
    resource: backlog:TASK-87
    title: History delete and the launch sweep of deleted spaces
  - id: task-118
    resource: backlog:TASK-118
    title: Closed-tab records expire with history and are cleared by history deletion
---

# Context

Detour persists two different things: the **session** (profiles, spaces,
open tabs, pinned entries, favorites, closed tabs, extension records) and the
**browsing history** (URLs, visits, search indexes). Both use GRDB over
SQLite and both live in the same data directory.

# Decision

Keep them in separate files with separate singletons:

| File | Type | Page |
|---|---|---|
| `browser.db` | `AppDatabase` | [Session database](../architecture/session-database.md) |
| `history.db` | `HistoryDatabase` | [History database](../architecture/history-database.md) |

The reasons the design documents give:

- **Privacy.** History is never written for incognito spaces, and the
  separation is described as deliberate on those grounds.
- **Independent clearing.** History can be cleared without touching the
  session.

# Alternatives rejected

The sources name no alternative explicitly; the implied one is a single
database. No written comparison exists, so none is reconstructed here.

A related fact from the migration history: extension tables used to live in
a third file, `extensions.db`, and were moved **into** `browser.db` by
session migration `v2`. Why is not recorded. What the schema shows is that
`profileExtension` has foreign keys to both `profile` and `extension`, which
only one database can enforce.

# Consequences

Seen in the code today.

**No foreign keys between the files.** `historyVisit.spaceID` is a plain
text column. Nothing removes a deleted space's visits automatically, so:

- `TabStore.sweepHistoryOfDeletedSpaces()` runs a few seconds after launch
  and deletes visits whose space no longer exists. It is not done in
  `deleteSpace` because Undo Delete Space restores the space under the same
  id and its history must still be there.
- The sweep needs a guard that only exists because the files are separate:
  at least one existing space must own a visit. If the session database was
  reset, replaced or failed to restore, the store comes up with a fresh
  default space whose id matches no visit, and without the guard every visit
  would look orphaned and be deleted (TASK-87).

**History knows spaces, not profiles.** The history database cannot join to
`space` to find a profile's spaces. Callers pass the space ids in
(`HistoryPageBridge.scope(for:)` builds the list from `TabStore`).

**Clearing history does not clear closed tabs.** Closed-tab records are
session data in `browser.db`. Deleting history leaves them, URLs and titles
included. TASK-118 proposes tying their retention to history; the code on
`main` does not do it.

**Different write patterns stay out of each other's way.** The session is
rewritten wholesale and synchronously by `saveNow()`. History is written
with asynchronous writes and read synchronously on every command palette
keystroke. Each file has its own `DatabaseQueue`, which is a single
connection, so a long history delete blocks history reads but not a session
save.

**Different tooling per file.** `history.db` registers custom SQL functions
(`history_fold`, `history_title_matches`) that its triggers depend on; the
session database has none. The session migrator erases the database on
schema change in DEBUG builds; the history migrator does not.

**Both follow `DETOUR_DATA_DIR`,** so a test or verification run gets its own
pair. See [persistence](../architecture/persistence.md).

# Related

- [Persistence](../architecture/persistence.md) — what is written when.
- [Session database](../architecture/session-database.md) and [history database](../architecture/history-database.md) — the two schemas.
- [Incognito](../architecture/incognito.md) — what Private windows do not record.
- [Closed tabs and archive](../tabs/closed-tabs-and-archive.md) — the records that outlive a history clear.
- [History page](../features/history-page.md) — delete and clear.
