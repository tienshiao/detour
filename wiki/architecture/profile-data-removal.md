---
type: Concept
title: Profile data removal and storage scoping
description: "What deleting a profile removes and in what order, why the on-disk WebKit data needs a pending row and retries, and how WebKitStorageScope and UserDefaultsScope keep test and verification runs out of the production app's data."
tags: [architecture, profiles, storage, webkit, test-isolation]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:20Z }
sources:
  - id: removal
    resource: ../../Detour/Browser/ProfileDataRemoval.swift
    title: ProfileDataRemoval.swift
  - id: storage-scope
    resource: ../../Detour/Browser/WebKitStorageScope.swift
    title: WebKitStorageScope.swift
  - id: defaults-scope
    resource: ../../Detour/Browser/UserDefaultsScope.swift
    title: UserDefaultsScope.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (deleteProfile)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (deleteProfileRows, saveProfiles)
  - id: test-setup
    resource: ../../DetourTests/TestEnvironmentSetup.swift
    title: TestEnvironmentSetup.swift
  - id: task-31
    resource: backlog:TASK-31
    title: Deleting a profile must remove its per-profile rows
  - id: task-32
    resource: backlog:TASK-32
    title: Deleting a profile must remove its website data store and extension controller data on disk
  - id: task-33
    resource: backlog:TASK-33
    title: saveProfiles deletion of missing profiles must clean per-profile rows too
  - id: task-35
    resource: backlog:TASK-35
    title: Undo of Delete Space / Edit Space after its profile was deleted crashes
  - id: task-36
    resource: backlog:TASK-36
    title: Stop the test host writing WebKit data into the production app's WebKit directory
  - id: task-41
    resource: backlog:TASK-41
    title: Stop the test host writing the production app's UserDefaults and starting Sparkle
---

# Summary

Deleting a profile has to remove three things: the database rows keyed by the
profile, the profile's `WKWebsiteDataStore` on disk, and the storage of its
`WKWebExtensionController`. The rows go in one transaction. The on-disk data
cannot be removed while anything still uses it, so the delete records a
**pending removal** and a guarded remover retries, now and at the next
launch.

The same code has a second job. WebKit keeps this data under
`~/Library/WebKit/<bundle id>/`, keyed by bundle id, and the test host and
every `DETOUR_DATA_DIR` run share the production app's bundle id.
`WebKitStorageScope` gives each data directory its own identifiers, and
`UserDefaultsScope` does the equivalent for AppKit autosave names, so a test
run can neither pile data into the production directory nor delete from it.

# Rules

## The delete sequence

`TabStore.deleteProfile(id:)`, in order:

1. **Refuse** the Private profile, the last normal profile, and a profile any
   space uses.
2. **`saveNow()`.** A space moved off this profile less than a save interval
   ago still references it in the database, and the row delete would refuse.
3. **Delete the rows** (`AppDatabase.deleteProfile`). If it returns false,
   stop: nothing has been torn down. A profile gone from memory but with its
   row, its data and no pending removal would be unrecoverable.
4. **Clear the undo stack.** Undo closures hold spaces, which hold their
   profile strongly. Clearing the stack prevents an undo from rebuilding a space
   on the deleted profile and releases the `Profile` object (TASK-35).
5. **Tear down what uses the store**: live favorite backing tabs (they can
   outlive the space they were opened in), then
   `profile.unloadAllExtensions()` (background content, offscreen documents,
   keep-alive ports, native hosts, relayed WebSockets).
6. Set `profile.isDeleted = true` and drop it from `profiles`.
7. Start the removal on a **later main-actor turn** and return the `Task`.

`isDeleted` makes the profile's lazy `dataStore` and `extensionController`
non-persistent if something that still holds the object asks for them, so a
deleted profile never recreates persistent storage.

## Rows

`AppDatabase.deleteProfileRows` is the only place a profile row is deleted.
Per id, inside the caller's transaction: skip if a space references it;
delete `profileExtension`, `extensionInstalledEvent`, `favorite`,
`siteSetting` and `externalAppPermission` rows; delete the
`profile` row; optionally record the pending removal.

Two callers, with one important difference:

| Caller | Records a pending data removal? |
|---|---|
| `deleteProfile(id:)` — the user deleted this profile | Yes, in the same transaction. |
| `saveProfiles(_:)` — a stored profile is missing from the saved set | **No.** |

`saveProfiles` sweeps rows for profiles the store does not hold. That set is
not proof the user deleted anything: a launch that failed to load profiles
would pass a set missing live ones. Dropping rows is recoverable; removing a
`WKWebsiteDataStore` wipes cookies, logins and extension storage for good. So
the sweep never arms a removal (TASK-33, and the comment on `saveProfiles`).

## On-disk removal

`ProfileDataRemoval.remove(_:recordKey:)` is the only caller of the WebKit
removal calls. Per attempt:

1. Check removability (below). Remove the extension controller data, once.
2. Check removability again. Remove the website data store.
3. On success clear the pending row.

A failure retries after 0.25, 0.5, 1, 2, 4 and 8 seconds. When every attempt
fails the pending row stays, and `retryPendingRemovals()` picks it up at the
next launch.

**Removability is re-checked before every WebKit call.** Removal is refused
for the Private profile and for any profile that exists in memory or in the
`profile` table. A profile table that cannot be read is treated as a
transient failure and retried, never as permission to remove.

Outcomes: `.removed`, `.refusedLiveProfile` (row cleared; it can never become
removable), `.skippedUnrecordedStorage` (isolated data directory that never
created storage for this profile; row cleared), `.failed` (row stays).

The launch retry runs in `AppDelegate` immediately after the databases open
and **before** the content blocker, the extension manager, the first window
and `restoreSession` — anything that can create a profile's store or
controller. It is skipped in the XCTest host.

## What WebKit does

Measured on macOS 26 in the test host:[^task-32]

- `WKWebsiteDataStore.remove(forIdentifier:)` fails with "Data store is in
  use" while any store object for the identifier is alive, and with "in use
  (by network process)" for about 0.25 s after the last web view using it is
  released. A store that never hosted a web view is removable at once.
- The "by network process" message also appears while UI objects still hold
  the store, so it does not prove the UI side is clean.[^task-36]
- Identifier stores live in
  `~/Library/WebKit/<bundle id>/WebsiteDataStore/<uuid>/`. The directory
  appears as soon as `WKWebsiteDataStore(forIdentifier:)` is created.
- Extension controller storage lives in
  `~/Library/WebKit/<bundle id>/WebExtensions/<UUID>/` and is **not** removed
  by `remove(forIdentifier:)`. There is no identifier-level API. The remover
  builds a throwaway controller for the identifier (with a non-persistent
  default store, so the profile's store is not recreated), removes its data
  records, then deletes the directory by path. That path is WebKit's layout,
  not API.

The practical consequence: everything holding the store must be released
before the removal runs. `removeDataOfDeletedProfile` takes the discarded
`Profile` weakly only to log when something still retains it. Retainers
found the hard way:[^task-36]

- undo closures on `TabStore.undoManager` (now cleared on delete);
- a favicon callback installed on restored dormant favorites that captured
  its profile strongly while the profile held the favorite. Every restored
  profile with a dormant favorite leaked its store until it was fixed.

## WebKitStorageScope

`Profile.dataStore` and `extensionController` do not use the profile id
directly. They ask `WebKitStorageScope.current`:

| Data directory | WebKit identifier |
|---|---|
| `Detour` (default, or `DETOUR_DATA_DIR` unset) | The profile id. Production data keeps its existing stores. |
| Anything else | A version 5 (name-based, SHA-1) UUID over a fixed namespace and `"<data dir>/<profile id>"`. |

The derived identifier is stable per data directory across launches, and it
can never equal a production profile id, which is a random version 4 UUID.
The namespace constant must never change; doing so would orphan every store
an isolated directory already created.

An isolated directory **records** each identifier in its own `browser.db`
(`webKitStorageIdentifier`) before WebKit creates storage for it
(`identifierForCreatingStorage`), so a crash in between still leaves a record
to clean up from. The default directory records nothing.

`refusalToRemove(identifier:)` allows a removal only when all hold:

1. this is not the default data directory;
2. the identifier is recorded in this directory's database;
3. it is version 5 and re-derives from the recorded profile id and this
   directory's name;
4. it equals no profile id in the **production** database, which must be
   readable.

The production database is never opened in place. It may be in use by the
running app, which uses a rollback journal with immediate busy errors; a
shared lock from another process could make one of its writes fail. The file
is copied byte for byte while no `-journal` exists and its size and
modification time are stable, and the copy is opened read-only. Unreadable
means nothing is removed; a missing database means no production profiles.

The bundle id was kept deliberately. Sparkle, keychain items, native
messaging host manifests and the 1Password browser trust are all keyed by
it. Using non-persistent stores under XCTest was rejected because the
persistence tests need real stores and it would not cover isolated app
runs.[^task-36]

## UserDefaultsScope and Sparkle

`UserDefaults.standard` in the test host is the production domain.

- `UserDefaultsScope.autosaveName(_:)` suffixes the window frame and sidebar
  split view autosave names with the data directory name outside the default
  directory. Production keeps reading the plain keys.
- Sparkle's updater starts only when the process is not the XCTest host and
  runs in the default data directory (`AppDelegate.startsUpdater`). See
  [app shell](./app-shell.md).
- The content blocker's rule list store, filter cache and defaults suite are
  scoped the same way (`ContentBlockerStorage`); see
  [content blocking](../features/content-blocking.md).

Still shared by every run with this bundle id: `URLSession.shared`'s cookie
storage and cache, and WebKit's default data store, which any web view built
from a bare `WKWebViewConfiguration()` writes to. Neither grows without
bound.[^task-36]

## In the test bundle

`TestEnvironmentSetup` is the test bundle's principal class.

- At bundle start it resets the shared store, drops leftover pending removal
  rows (the launch retry does not run in the test host), and calls
  `removeRecordedStorage` for everything this data directory recorded except
  the live profiles.
- At bundle end it unloads extensions, clears the undo stack, swaps the
  remaining profiles' store and controller for non-persistent ones, and
  removes all recorded storage. Storage still in use stays recorded and goes
  at the next run's start.
- It snapshots the production autosave and Sparkle (`SU*`) defaults keys and
  restores only the keys **this process** changed. It tells its own writes
  from the production app's through `UserDefaults.didChangeNotification`,
  which a process receives only for its own writes.

Before this work the test suites had left about 5,000 website data store
directories and 3,400 extension controller directories in the production
WebKit directory. Afterwards a full run recorded and removed 157 identifiers
and left the production counts unchanged.[^task-36]

See [WebKit test host traps](../platform/webkit-test-host-traps.md) for
related behaviour.

# Where it lives

| What | Where |
|---|---|
| `deleteProfile`, `retryPendingProfileDataRemovals` | [TabStore.swift](../../Detour/Browser/TabStore.swift) |
| `ProfileDataRemoval`, `Remover`, `Outcome` | [ProfileDataRemoval.swift](../../Detour/Browser/ProfileDataRemoval.swift) |
| `WebKitStorageScope` | [WebKitStorageScope.swift](../../Detour/Browser/WebKitStorageScope.swift) |
| `UserDefaultsScope` | [UserDefaultsScope.swift](../../Detour/Browser/UserDefaultsScope.swift) |
| `deleteProfileRows`, pending removal and identifier tables | [Database.swift](../../Detour/Storage/Database.swift) |
| Tests | `ProfileDataRemovalTests` (fake remover, plus one real WebKit integration test), `ProfileDeletionUndoTests`, `AppDatabaseTests`, `UserDefaultsScopeTests`, `ProductionDefaultsIsolationTests` |

`Remover` is a pair of closures so tests inject failures and successes
without touching real stores.

TASK-32's notes describe an earlier gate (`Remover.forCurrentDataDirectory`,
outcome `.skippedIsolatedDataDirectory`) that refused all removal outside the
default directory. TASK-36 replaced it with the recorded-identifier scheme
above; those symbols no longer exist.

# Related

- [Profiles and spaces](./profiles-and-spaces.md) — the profile model and the undo guards.
- [Persistence](./persistence.md) — `DETOUR_DATA_DIR` and what it scopes.
- [Session database](./session-database.md) — the tables involved.
- [Incognito](./incognito.md) — the profile that is never removed.
- [Build and test](../playbooks/build-and-test.md) — running tests in their own data directory.
- [Runtime verification](../playbooks/runtime-verification.md) — isolated app runs.

[^task-32]: Deleting a profile must remove its website data store and extension controller data on disk
[^task-36]: Stop the test host writing WebKit data into the production app's WebKit directory
