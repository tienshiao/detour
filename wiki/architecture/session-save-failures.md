---
type: Concept
title: Session save failures
description: What TabStore.saveNow() does when the one-transaction session save cannot be written — the repair of pinned rows that could never be valid, the unit-by-unit retry that keeps a refused unit's last good rows, keeping the last good save on any other error, what a relaunch loads after a partial save, and the alternatives rejected (TASK-154).
tags: [architecture, storage, session]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:05:16Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (saveNow, writeSessionSnapshot, SessionSaveOutcome, lastSaveOutcome)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (saveSessionSnapshot, saveSessionSnapshotIsolatingFailures, SessionSaveFailure, isConstraintFailure)
  - id: snapshot-repair
    resource: ../../Detour/Storage/SessionSnapshotRepair.swift
    title: SessionSnapshotRepair.swift (repairingInvalidRows)
  - id: arc-import-apply
    resource: ../../Detour/Browser/TabStore+ArcImport.swift
    title: TabStore+ArcImport.swift (applyArcImport, which reads the save's outcome)
  - id: arc-import-text
    resource: ../../Detour/Import/Arc/ArcImportText.swift
    title: ArcImportText.swift (the result line for a save that wrote nothing)
  - id: task-154
    resource: backlog:TASK-154
    title: A session save that fails is handled, not only logged
  - id: task-149
    resource: backlog:TASK-149
    title: One session save is one transaction
  - id: failure-tests
    resource: ../../DetourTests/SessionSaveFailureTests.swift
    title: SessionSaveFailureTests.swift
  - id: repair-tests
    resource: ../../DetourTests/SessionSnapshotRepairTests.swift
    title: SessionSnapshotRepairTests.swift
  - id: atomicity-tests
    resource: ../../DetourTests/SessionSaveAtomicityTests.swift
    title: SessionSaveAtomicityTests.swift
---

The session save is one transaction (TASK-149, see
[persistence](./persistence.md#savenow-write-order)), so one row the database
refuses would fail every debounced save and the save at quit for as long as
the store holds that row, and the user would lose every session change since
the last good save. `TabStore.saveNow()` therefore handles a failure instead
of only logging it (TASK-154).[^task-154] It returns a
`TabStore.SessionSaveOutcome` and keeps it in `lastSaveOutcome`. Nothing
retries on a timer: the next `scheduleSave()` or `saveNow()` is the retry.

# Rules

## Three layers

| Layer | Applies to | What is written | Outcome |
|---|---|---|---|
| 1. Repair | Pinned rows that could never be valid | Everything, with those rows moved to the root | `.saved` |
| 2. Unit by unit | A row the database refuses (`SQLITE_CONSTRAINT`: foreign key, uniqueness, NOT NULL, a raising trigger) | Every unit except the one holding the row | `.savedExcept([failures])` |
| 3. Nothing | Any other error (full disk, I/O error, locked or damaged file) | Nothing; the last good save stays | `.failed(reason:)` |

`AppDatabase.isConstraintFailure` tells layer 2 from layer 3: a
`DatabaseError` whose result code is `SQLITE_CONSTRAINT`. Such a failure
belongs to the row and comes back on every save of it; anything else is not
about one row, and writing the parts separately would fail the same way.
`saveSessionSnapshot` and `saveSessionSnapshotIsolatingFailures` throw rather
than log, so `saveNow()` (in `writeSessionSnapshot`) makes the decision.

## Repair

`SessionSnapshot.repairingInvalidRows()` is a pure function of the snapshot,
run on every save before the write. `pinnedFolder.parentFolderID` and
`pinnedTab.folderID` are foreign keys onto `pinnedFolder`, so these rows are
refused by the insert, and each is moved to the root of its space, after what
is already there:

- a folder whose parent is not among its space's folders (a parent in another
  space counts as missing);
- of each parent cycle, the folder that comes first in the store's order,
  which opens the cycle; the others keep their parent. A folder that only
  hangs below a cycle is not touched;
- an entry whose folder is not among its space's folders.

Only the saved rows change: the store keeps what it holds and loads the
repaired tree at the next launch. Each repair is an error-level log line,
written when the set of repairs changes rather than once a save. No store
mutation is known to produce these rows (`movePinnedFolder` refuses a cycle);
the repair is a defence, like `sanitizePinnedSplitGroups` at load.
`AppDatabase.parentFirst` relies on it: it cannot order a folder with a
missing parent or one on a cycle, and leaves those for the insert to refuse.

## Unit by unit

`AppDatabase.saveSessionSnapshotIsolatingFailures` writes the same snapshot
again, still in **one transaction**, with each unit
(`SessionSaveFailure.Unit`) in its own savepoint:

| Unit | Rows |
|---|---|
| Each space | The `space` row, its `tab` rows, its `pinnedFolder` and `pinnedTab` rows. One unit because deleting the space row to rewrite it cascades to the other three. |
| Profiles | The `profile` rows and the sweep of profiles the store no longer has. |
| Each profile's favourites | Its `favorite` rows. |

A unit that fails with a constraint failure is rolled back to its savepoint,
so it holds **what the last good save wrote for it**; a space that was
never saved is absent. One exception: a favourites unit that fails after the
space hosting its live favourites was written keeps its rows, but with
`tabID` NULL — rewriting the space deleted the backing tab rows and the
cascade cleared the reference — so those favourites are dormant until a later
save writes the unit. Every other unit is written. Spaces the store no longer
has are deleted first, as in the one-step save. Each failed unit is an
error-level log line (category `storage`) naming the unit and the database's
error. Any error that is not a constraint failure, inside this pass too,
rolls the whole save back and is layer 3.

Two rules keep the units independent:

- A row that changed unit (a tab moved to another space) may still be held,
  under the same primary key, by a unit this pass has not written. Before a
  unit inserts its rows, those stale copies are deleted from every unit not
  written in this pass. A copy in a unit that *was* written is a real
  duplicate and fails the insert.
- A live favourite's backing tab row belongs to the space that hosts it. When
  that space was not written and the row is not among the ones it kept, the
  favourite is saved dormant instead of failing its profile's favourites on
  `favorite.tabID`.

## What the next launch loads after a partial save

Every statement ran with foreign keys enforced, so the database is valid by
the schema: `restoreSession()` loads the failed space as last saved and the
rest as new. `space.selectedTabID` and `lastActiveSpaceID` are not foreign
keys and may name a tab or space that is not there (the selected tab moved
out of a space that failed; the active space is new and could not be saved);
the launch code already tolerates both, as for any stale selection.

## Who hears about it

A debounced save or the save at quit tells nobody: a failure is an
error-level log line and `lastSaveOutcome`, with no user-facing message.

The one caller that reads the outcome is the
[Arc import](../features/arc-import.md): `applyArcImport` calls `saveNow()`
once and returns its outcome. On `.failed` the import's result view adds
"Detour couldn’t save this yet (…); it tries again with the next change."
and no import links are recorded; on `.savedExcept` the links of the spaces
whose unit failed are left out, so they wait for an import after the next
good save (read from the code, 2026-11-16).

## Cost

While a row keeps being refused, each save runs the one-step save up to that
row and then the unit-by-unit save: roughly twice the work of a save. Not
measured.

# Alternatives rejected

- *Each step in its own transaction* (the shape before TASK-149). The session
  step deletes every space row and the cascade takes the pinned rows with it;
  committed alone and followed by a failing pinned step, it drops rows the
  last good save held, and it reopens the crash window. Spaces and tabs are
  also one step there, so one refused tab row would lose every space's tab
  changes.
- *Skipping only the refused row.* It commits a degraded copy over a good one
  (a refused space row would delete that space and everything in it), and a
  failure that hits many rows would commit a near-empty session.
- *Isolating every kind of error.* With a full disk every unit fails; only a
  constraint failure is a property of a row.

# Tests

`SessionSaveFailureTests` refuses one row with a SQLite trigger (`RAISE`
with a `WHEN` on the row's id) and checks the other units, the failed unit's
previous rows and what a relaunched store holds; `SessionSnapshotRepairTests`
covers the repair as a pure function. `SessionSaveAtomicityTests` now injects
a failure that is *not* a constraint failure (a trigger calling a SQL function
that fails with `SQLITE_FULL`), the case that must leave the previous save
whole.

# Where it lives

| What | Where |
|---|---|
| `saveNow`, `writeSessionSnapshot`, `SessionSaveOutcome`, `lastSaveOutcome` | [TabStore.swift](../../Detour/Browser/TabStore.swift) |
| `saveSessionSnapshot`, `saveSessionSnapshotIsolatingFailures`, `SessionSaveFailure`, `isConstraintFailure`, `parentFirst` | [Database.swift](../../Detour/Storage/Database.swift) |
| `repairingInvalidRows`, `SessionSnapshotRepair` | [SessionSnapshotRepair.swift](../../Detour/Storage/SessionSnapshotRepair.swift) |

# Related

- [Persistence](./persistence.md) — the save this handles, its write order and session restore.
- [Session database](./session-database.md) — the foreign keys and cascades that make the units.
- [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md) — the folder tree the repair defends.
- [Arc import](../features/arc-import.md) — the one caller that reports the outcome.

[^task-154]: A session save that fails is handled, not only logged
