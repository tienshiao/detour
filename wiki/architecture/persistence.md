---
type: Concept
title: Persistence
description: What Detour saves, where and when — the two databases, the debounced one-transaction session save, its write order and what it does when it cannot be written, session restore, interaction state, and the DETOUR_DATA_DIR switch.
tags: [architecture, storage, session, restore]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T09:36:35Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (scheduleSave, saveNow, makeSessionSnapshot, restoreSession)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift
  - id: history-database
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift
  - id: data-model-doc
    resource: ../../docs/data-model.md
    title: docs/data-model.md
  - id: tab-lifecycle-doc
    resource: ../../docs/tab-lifecycle.md
    title: docs/tab-lifecycle.md
  - id: storage-scope
    resource: ../../Detour/Browser/WebKitStorageScope.swift
    title: WebKitStorageScope.swift
  - id: task-33
    resource: backlog:TASK-33
    title: saveProfiles deletion of missing profiles must clean per-profile rows too
  - id: task-36
    resource: backlog:TASK-36
    title: Stop the test host writing WebKit data into the production app's WebKit directory
  - id: task-24
    resource: backlog:TASK-24
    title: Extension page tabs get a durable identity
  - id: task-117
    resource: backlog:TASK-117
    title: Closed-tab stack reads from the database only
  - id: task-149
    resource: backlog:TASK-149
    title: One session save is one transaction
  - id: atomicity-tests
    resource: ../../DetourTests/SessionSaveAtomicityTests.swift
    title: SessionSaveAtomicityTests.swift
  - id: save-benchmark
    resource: ../../DetourTests/SessionSaveBenchmarkTests.swift
    title: SessionSaveBenchmarkTests.swift (env-gated)
  - id: task-154
    resource: backlog:TASK-154
    title: A session save that fails is handled, not only logged
  - id: snapshot-repair
    resource: ../../Detour/Storage/SessionSnapshotRepair.swift
    title: SessionSnapshotRepair.swift (repairingInvalidRows)
  - id: failure-tests
    resource: ../../DetourTests/SessionSaveFailureTests.swift
    title: SessionSaveFailureTests.swift
  - id: repair-tests
    resource: ../../DetourTests/SessionSnapshotRepairTests.swift
    title: SessionSnapshotRepairTests.swift
---

# Summary

Detour keeps state in two SQLite files under
`~/Library/Application Support/<data dir>/`, both through GRDB:

| File | Singleton | Holds |
|---|---|---|
| `browser.db` | `AppDatabase.shared` | Profiles, spaces, tabs, pinned entries and folders, favorites, closed tabs, downloads, extension records and permissions, app state. See [session database](./session-database.md). |
| `history.db` | `HistoryDatabase.shared` | Visited URLs, visits, full-text indexes. See [history database](./history-database.md). |

Why two: [two databases](../decisions/two-databases.md).

The session (spaces and their tabs) is rewritten wholesale by a debounced
save. Everything else is written by its own call at the moment it changes.
Website data (cookies, local storage) is WebKit's, keyed by profile; see
[profiles and spaces](./profiles-and-spaces.md).

# Rules

## What is written when

| Data | Written by | When |
|---|---|---|
| Spaces, tabs, pinned entries, folders, favorites, all profiles | `TabStore.saveNow()` | 1 s after the last `scheduleSave()`; immediately on app termination, window close and at the start of `deleteProfile`. |
| One profile | `AppDatabase.saveProfile` | Immediately, in `addProfile` / `updateProfile`. |
| Closed-tab records | `pushClosedTab`, `deleteClosedTab…` | Immediately, inside `closeTab`, reopen, undo. Never loaded into memory (TASK-117). |
| Downloads | `DownloadManager` | Its own 1 s debounce; a save still pending at app termination is written by `flushPendingSave()`. See [downloads](../features/downloads.md). |
| Extension records, permissions, per-profile enablement | `AppDatabase` calls from the extension layer | Immediately. |
| History visits and title corrections | `HistoryDatabase.recordVisit`, `updateTitle` | Asynchronous writes, serialised in call order on GRDB's writer queue. |

`scheduleSave()` cancels the pending `DispatchWorkItem` and schedules a new
one on the main queue. It is called by every structural mutation, by a tab's
`url` or `favicon` changing, by `sleepStaleTabs`, by a window switching
space, and by Peek state changes.

## `saveNow()` write order

`saveNow()` turns the store into one value, `AppDatabase.SessionSnapshot`
(`TabStore.makeSessionSnapshot()`, which only reads), repairs the rows in it
that could never be saved ([below](#when-a-save-cannot-be-written)), and hands
it to `AppDatabase.saveSessionSnapshot`, which writes it in **one transaction**
(TASK-149). Four steps inside it, in an order the foreign keys dictate:

1. **Session**: `DELETE` every `space` row — which cascades to `tab`,
   `pinnedTab` and `pinnedFolder`, and sets `favorite.tabID` to NULL — then
   insert each persistent space and its tab rows, then upsert
   `lastActiveSpaceID`.
2. **Profiles**: after the session, so a profile no space references any
   more can be dropped without a foreign key violation.
3. **Pinned folders and entries**, per space: folders before entries,
   because entries reference folders, and each folder after its parent
   (`parentFirst`), because `pinnedFolder.parentFolderID` is an immediate
   foreign key onto the same table. The store's folder array is not
   parent-first: a folder dragged into one created after it stays ahead of
   it, Undo Delete Folder appends the restored parent behind its children,
   and a relaunch loads rows by per-level `sortOrder`. Written in array order
   the child row is refused. Before the save was one transaction that lost
   the space's pinned rows; in one transaction it would fail the whole save,
   every time.[^task-149]
4. **Favorites**, per profile: after the session, because `favorite.tabID`
   references a `tab` row.

Each step is a private static function of `AppDatabase` that takes the open
transaction. `saveSession`, `saveProfiles`, `savePinnedFoldersAndTabs` and
`saveFavorites` remain as single-step writes over the same functions, each
its own transaction; only tests call them.

Tab rows come in three kinds, told apart by `sortOrder`:

| `sortOrder` | Row is |
|---|---|
| `>= 0` | A normal tab at that position. |
| `-1` | The backing tab of a live pinned entry. |
| `-2` | The backing tab of a live favorite, stored under the first persistent space of the favorite's profile. |

All three are built by one factory, `TabRecord.init(tab:spaceID:sortOrder:profile:…)`.

Incognito spaces are filtered out before step 1. The built-in Private
**profile** row is saved (it carries settings); its spaces and tabs never are.

Things to know about this design:

- The save is **all or nothing**. Step 1's cascade removes the pinned rows
  that step 3 puts back, so the steps have to commit together: after a save
  that failed or was cut short (a crash, a kill, a failed statement) the
  database holds the complete previous save. `SessionSaveAtomicityTests`
  makes a save fail at each step with a SQLite trigger and compares every
  session table with its contents before the save. Until TASK-149 the four
  steps were 2 + spaces + profiles separate transactions, and an
  interruption after the first left spaces without pinned entries and
  folders.
- The other side of that: **a failure in any statement fails the whole
  one-transaction save**. `saveSessionSnapshot` throws, and `saveNow()`
  decides what happens next; see
  [When a save cannot be written](#when-a-save-cannot-be-written). Nothing
  retries on a timer: the next `scheduleSave()` or `saveNow()` is the retry.
- One transaction costs no more than many. Measured once, Debug build, a
  file database, 20 spaces, 2,000 tabs with 4 KB of interaction state each,
  300 pinned entries, 60 folders, 200 favourites: a save went from 262 ms
  in 26 commits to 232 ms in 1 (medians of nine).[^task-149] Most of a
  save is building and inserting the tab rows, not committing. Rerun with
  `TEST_RUNNER_SESSION_SAVE_BENCH=1` and `SessionSaveBenchmarkTests`
  ([build and test](../playbooks/build-and-test.md)).
- `saveProfiles` treats its argument as the complete set of profiles and
  drops stored profiles that are missing from it (unless a space still
  references one). A store that saves before it has loaded the profiles would
  therefore drop real profile rows. `restoreSession` loads profiles first,
  even when there is no session to restore, for exactly this reason
  (TASK-32, TASK-33). The sweep deletes rows only; it never schedules removal
  of the on-disk website data. See
  [profile data removal](./profile-data-removal.md).

## When a save cannot be written

Since the save is one transaction, one row the database refuses would fail
every debounced save and the save at quit for as long as the store holds that
row, and the user would lose every session change since the last good save.
`saveNow()` therefore handles a failure instead of only logging it
(TASK-154).[^task-154] It returns a `TabStore.SessionSaveOutcome` and keeps it
in `lastSaveOutcome`.

| Layer | Applies to | What is written | Outcome |
|---|---|---|---|
| 1. Repair | Pinned rows that could never be valid | Everything, with those rows moved to the root | `.saved` |
| 2. Unit by unit | A row the database refuses (`SQLITE_CONSTRAINT`: foreign key, uniqueness, NOT NULL, a raising trigger) | Every unit except the one holding the row | `.savedExcept([failures])` |
| 3. Nothing | Any other error (full disk, I/O error, locked or damaged file) | Nothing; the last good save stays | `.failed(reason:)` |

**Repair.** `SessionSnapshot.repairingInvalidRows()` is a pure function of
the snapshot. `pinnedFolder.parentFolderID` and `pinnedTab.folderID` are
foreign keys onto `pinnedFolder`, so these rows are refused by the insert, and
each is moved to the root of its space, after what is already there:

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

**Unit by unit.** `AppDatabase.saveSessionSnapshotIsolatingFailures` writes
the same snapshot again, still in **one transaction**, with each unit in its
own savepoint:

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
error.

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

**What the next launch loads after a partial save.** Every statement ran with
foreign keys enforced, so the database is valid by the schema:
`restoreSession()` loads the failed space as last saved and the rest as new.
`space.selectedTabID` and `lastActiveSpaceID` are not foreign keys and may
name a tab or space that is not there (the selected tab moved out of a space
that failed; the active space is new and could not be saved); the launch code
already tolerates both, as for any stale selection.

**Not handled.** Layer 3 writes nothing and tells nobody: it is an error-level
log line and `lastSaveOutcome`. There is no user-facing message for a failed
save.

**Cost.** While a row keeps being refused, each save runs the one-step save
up to that row and then the unit-by-unit save: roughly twice the work of a
save. Not measured.

Rejected, with the reason:

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

`SessionSaveFailureTests` refuses one row with a SQLite trigger (`RAISE`
with a `WHEN` on the row's id) and checks the other units, the failed unit's
previous rows and what a relaunched store holds; `SessionSnapshotRepairTests`
covers the repair as a pure function. `SessionSaveAtomicityTests` now injects
a failure that is *not* a constraint failure (a trigger calling a SQL function
that fails with `SQLITE_FULL`), the case that must leave the previous save
whole.

## Session restore

`TabStore.restoreSession()` runs once at launch, after the first window
exists (see the [launch sequence](./overview.md)).

1. Load every profile, then `ensureIncognitoProfile()`.
2. `loadSession()` returns nil when the `space` table is empty or on a read
   error; restore stops there and `ensureDefaultSpace()` makes a "Home" space.
3. For each space, in `sortOrder`:
   - Normal tabs (`sortOrder >= 0`, not a pinned backing tab). The space's
     **selected** tab is built live, with its interaction state restored into
     a new web view. Every other tab is built **sleeping** and wakes when
     first shown.
   - `sanitizeSplitGroups` repairs split groups that are no longer a valid
     adjacent pair.
   - Pinned folders, then pinned entries. An entry whose `tabID` names a
     saved backing row comes back live; otherwise dormant.
     `sanitizePinnedSplitGroups` follows.
4. Favorites, per profile — **after** the spaces loop. A favorite's backing
   tab needs a host space of its profile, which only exists once the spaces
   are restored. Doing this earlier left the backing tab unrecreated, and its
   orphaned row was dropped by the next save.
5. A space whose selected tab was dropped in step 3 gets a new selection.
6. Return the last active space id and its selected tab id to `AppDelegate`.

Closed-tab records are not loaded.

`lastDeselectedAt` is restored from the row, or set to "now" when the row has
none, so a tab with no stamp starts its idle clock at launch instead of being
slept or archived immediately. The selected tab gets nil (it is on screen).

### Extension pages on restore

A saved `webkit-extension://` URL names an origin that died with the previous
launch, because WebKit mints a new origin for each context load. The
`extensionID` column saved beside the URL is the durable identity (TASK-24).
Restore classifies each such page once:

| Extension is | Open tab on its page | Pinned entry / favorite on its page |
|---|---|---|
| Not installed (or no saved id) | Dropped | Dropped |
| Installed, disabled in the profile | Dropped | Kept, dormant |
| Enabled | Restored sleeping, **without** interaction state | Kept |

Kept pages register a pending origin on the profile; the pages are moved to
the live origin once the extension's context has loaded. See
[extension pages](../extensions/extension-pages.md).

## Interaction state

`WKWebView.interactionState` (back/forward list, scroll position, form data)
is archived with `NSKeyedArchiver` and stored as a blob in three columns:
`tab.interactionState`, `tab.peekInteractionState` and
`closedTab.interactionState`. In memory a sleeping tab holds the same bytes
as `cachedInteractionState`. Restoring is assigning the unarchived object
back to a new web view's `interactionState`; the failure modes are on
[BrowserTab](./browser-tab.md).

The blob can be large. The closed-tab listing and menu validation read
`ClosedTabSummary` rows, which leave the blob out; only the one row being
reopened is read in full.

## `DETOUR_DATA_DIR`

`detourDataDirectory()` uses the environment variable `DETOUR_DATA_DIR` as
the directory **name** under Application Support, defaulting to `Detour`.
The test scheme sets it to `DetourTests` (in `project.yml`), and runtime
verification runs use their own names.

Scoped by the data directory:

- both databases, the unpacked extension files (`Extensions/`), staged
  extension updates;
- WebKit website data and extension controller storage, through derived
  identifiers (`WebKitStorageScope`);
- the content blocker's compiled rule lists, filter cache and defaults suite
  (`ContentBlockerStorage`);
- the window frame and sidebar split autosave names (`UserDefaultsScope`);
- whether Sparkle starts at all (only in the default directory).

**Not** scoped, because they are keyed by bundle id, which every run
shares:[^task-36]

- `URLSession.shared`'s cookie storage and URL cache;
- WebKit's default data store, used by any web view built from a bare
  `WKWebViewConfiguration()`;
- keychain items, native messaging host manifests.

Two launches with the same `DETOUR_DATA_DIR` share everything, including the
session. A stale build launched on a verification directory can rewrite its
session; see [runtime verification](../playbooks/runtime-verification.md).

## Debug builds

The session migrator sets `eraseDatabaseOnSchemaChange = true` under
`#if DEBUG`: editing a migration that has already run erases the debug
`browser.db` instead of failing. The history migrator does not; changing an
unshipped history migration in place strands any database that already ran
it. See [history database](./history-database.md).

# Where it lives

| What | Where |
|---|---|
| `scheduleSave`, `saveNow`, `SessionSaveOutcome`, `makeSessionSnapshot`, `restoreSession` | [TabStore.swift](../../Detour/Browser/TabStore.swift) |
| `SessionSnapshot`, `saveSessionSnapshot`, `saveSessionSnapshotIsolatingFailures`, the single-step saves, `loadSession` | [Database.swift](../../Detour/Storage/Database.swift) |
| `repairingInvalidRows`, `SessionSnapshotRepair` | [SessionSnapshotRepair.swift](../../Detour/Storage/SessionSnapshotRepair.swift) |
| The tab row factory | [TabRecord+BrowserTab.swift](../../Detour/Browser/TabRecord+BrowserTab.swift) |
| Tests | `SessionSaveAtomicityTests`, `SessionSaveFailureTests`, `SessionSnapshotRepairTests`, `AppDatabaseTests`, `TabStoreTests`, `TabRecordFactoryTests`, `ExtensionPagePersistenceTests`, `FavoritePeekPersistenceTests`, `ProfileDataRemovalTests`; `SessionSaveBenchmarkTests` (env-gated) |

# Related

- [Session database](./session-database.md) — the tables.
- [History database](./history-database.md) — the other file.
- [TabStore](./tabstore.md) — what calls `scheduleSave`.
- [Tab lifecycle](../tabs/tab-lifecycle.md) — the events that change the session.
- [Profile data removal](./profile-data-removal.md) — `WebKitStorageScope` and test-host isolation.
- [Build and test](../playbooks/build-and-test.md) — passing `DETOUR_DATA_DIR` to a test run.

[^task-36]: Stop the test host writing WebKit data into the production app's WebKit directory
[^task-149]: One session save is one transaction
[^task-154]: A session save that fails is handled, not only logged
