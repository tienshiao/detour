---
type: Reference
title: Session database
description: The tables of browser.db, what each is for, the foreign keys that shape the save order, the migration history through v17, and the GRDB record types.
resource: ../../Detour/Storage/Database.swift
tags: [architecture, storage, schema, migrations]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T08:10:57Z }
sources:
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift
  - id: models
    resource: ../../Detour/Storage/Models
    title: Detour/Storage/Models (record types)
  - id: extension-models
    resource: ../../Detour/Extensions/Storage/Models
    title: Detour/Extensions/Storage/Models (extension record types)
  - id: data-model-doc
    resource: ../../docs/data-model.md
    title: docs/data-model.md (column-level reference)
  - id: task-31
    resource: backlog:TASK-31
    title: Deleting a profile must remove its per-profile rows
  - id: task-33
    resource: backlog:TASK-33
    title: saveProfiles deletion of missing profiles must clean per-profile rows too
  - id: task-46
    resource: backlog:TASK-46
    title: One enabled-state read per profile at startup
  - id: task-113
    resource: backlog:TASK-113
    title: Extension updates (source, update URL, pending permission approval)
  - id: task-149
    resource: backlog:TASK-149
    title: One session save is one transaction
---

`browser.db` is the session database: `AppDatabase.shared`, a struct around a
GRDB `DatabaseQueue`, opened at
`~/Library/Application Support/<data dir>/browser.db`. This page is the map;
[docs/data-model.md](../../docs/data-model.md) lists every column, and
[persistence](./persistence.md) covers when rows are written.

# Tables

| Table | Key | Purpose | Notes |
|---|---|---|---|
| `profile` | `id` | Settings per profile. | No `isIncognito` column: the Private profile is recognised by its fixed id. |
| `space` | `id` | Name, emoji, colour, order, `selectedTabID`, `profileID`. | FK to `profile` with no cascade, so a profile row cannot be deleted while a space references it. Incognito spaces are never written. |
| `tab` | `id` | One row per persisted live tab. | FK `spaceID` → `space`, cascade. `sortOrder` `>= 0` normal, `-1` pinned backing, `-2` favorite backing. |
| `pinnedTab` | `id` | A pinned entry: home URL, title, folder, order, split membership. | `tabID` → `tab`, set null: a dormant entry has no backing row. |
| `pinnedFolder` | `id` | Folder tree for pinned entries. | Self-reference `parentFolderID`, set null. |
| `favorite` | `id` | Favorites bar tiles, per **profile**. | `tabID` → `tab`, set null. |
| `closedTab` | `id` autoincrement | Closed and archived tab records. | No FK on `spaceID`; `deleteSpace` removes the rows itself. Index `closedTab_on_spaceID_id`. No row cap. |
| `download` | `id` | Download records. | |
| `contentBlockerWhitelist` | (`profileID`, `host`) | Per-site content blocker exceptions. | Cascades from `profile`. |
| `externalAppPermission` | (`profileID`, `origin`, `scheme`) | "Always allow" for external URL schemes. | Never written for the Private profile. |
| `extension` | `id` | Installed extensions: manifest, path, enabled, source, update URL. | |
| `extensionStorage` | (`extensionID`, `key`) | Dead: left from the pre-WKWebExtension runtime. Only tests call its accessors; `chrome.storage` is WebKit's. | Cascades from `extension`. |
| `profileExtension` | (`profileID`, `extensionID`) | Per-profile enabled and pinned flags. | A **missing row** means the profile's default: on, except in the Private profile. |
| `extensionPermission` | (`extensionID`, `permissionKey`, `permissionType`) | Saved permission decisions. | Status 0 is granted; any other value reads as denied. |
| `extensionInstalledEvent` | (`extensionID`, `profileID`) | Ledger for `runtime.onInstalled`. | No FK; deleted explicitly. |
| `pendingProfileDataRemoval` | `profileID` | Deleted profiles whose on-disk WebKit data is not removed yet. | No FK: the profile row is already gone. |
| `webKitStorageIdentifier` | `identifier` | WebKit storage identifiers an isolated data directory created. | The default data directory records nothing. |
| `appState` | `key` | Key-value app state. | Keys in use: `lastActiveSpaceID`, `extensionUpdateLastCheckAt`. |

Related pages: [closed tabs and archive](../tabs/closed-tabs-and-archive.md),
[pinned tabs and folders](../tabs/pinned-tabs-and-folders.md),
[favorites](../tabs/favorites.md), [permissions](../extensions/permissions.md),
[runtime.onInstalled](../extensions/runtime-installed-event.md),
[profile data removal](./profile-data-removal.md).

## Foreign keys that shape the code

- `space.profileID → profile`, with no cascade. This is why `saveNow` writes the
  session before the profiles, and why `TabStore.deleteProfile` calls
  `saveNow()` first: a space moved off the profile less than a save interval
  ago still references it in the database.
- `tab`, `pinnedTab`, `pinnedFolder` cascade from `space`. The session step
  of a save deletes all spaces and re-inserts them, so every save clears and
  rebuilds those three tables. That is why the whole save is one transaction
  (`saveSessionSnapshot`, TASK-149): committed on its own, the session step
  leaves every space without pinned rows.
- `pinnedTab.tabID` and `favorite.tabID` reference `tab`. The backing tab row
  must be inserted first, so backing tabs travel in the session step and the
  pinned and favorite rows follow.
- `pinnedTab.folderID → pinnedFolder`. Within a space the order is: delete
  entries, delete folders, insert folders, insert entries.
- `pinnedFolder.parentFolderID → pinnedFolder`, checked immediately. Folder
  rows are inserted parent-first (`AppDatabase.parentFirst`), whatever order
  the store holds them in; see [persistence](./persistence.md).

Profile deletion does **not** rely on cascades. `deleteProfileRows` is the
one function that deletes a profile row, and it deletes `profileExtension`,
`extensionInstalledEvent`, `favorite`, `contentBlockerWhitelist` and
`externalAppPermission` rows explicitly, because cascades only run while
foreign keys are enforced and `extensionInstalledEvent` has no foreign key at
all (TASK-31, TASK-33). Rows keyed by extension alone are shared by all
profiles and are left alone.

# Migrations

Registered in `AppDatabase.migrator`. The numbering is post-consolidation:
`v1` creates the core schema in one step and is not the app's original first
migration.

| Version | Change |
|---|---|
| v1 | `profile`, `space`, `tab`, `appState`, `closedTab`, `download`, `pinnedFolder`, `pinnedTab`, `contentBlockerWhitelist`. |
| v2 | `extension`, `extensionStorage`, `profileExtension` (moved in from a separate `extensions.db`). |
| v3 | `extensionPermission`. |
| v4 | `favorite`. |
| v5 | `profileExtension.isPinned`. |
| v6 | `tab.splitGroupID`, `tab.splitFraction`. |
| v7 | `pinnedTab.splitGroupID`, `pinnedTab.splitFraction`. |
| v8 | `extensionID` on `tab`, `pinnedTab`, `favorite`, `closedTab`. Existing `webkit-extension://` rows are back-filled with a sentinel id (TASK-24). |
| v9 | `extensionInstalledEvent`, seeded for every existing extension × profile (TASK-22). |
| v10 | `extensionInstalledEvent.reinstallPending`; Private profile rows dropped (TASK-29). |
| v11 | `pendingProfileDataRemoval` (TASK-32). |
| v12 | `webKitStorageIdentifier` (TASK-36). |
| v13 | Data only: delete `nativeMessaging` denials saved before they were enforceable (TASK-44). |
| v14 | `externalAppPermission` (TASK-84). |
| v15 | Index `closedTab(spaceID, id)` (TASK-117). |
| v16 | `closedTab.closedAt`, back-filled from `archivedAt` (TASK-116). |
| v17 | `extension.source`, `updateURL`, `sourcePath`, `pendingPermissionApprovalJSON`; existing installs classified by reading their on-disk manifest (TASK-113). |

Patterns worth copying from the existing migrations:

- **Spell out literals.** v10 writes the Private profile id as a string and
  v13 writes the enum raw values as numbers, with a comment naming the
  symbol. A migration that referenced `TabStore.incognitoProfileID` or an
  enum case would change meaning if the symbol were later renamed or
  renumbered.
- **Back-fill so "missing" keeps its meaning.** v8's sentinel id exists
  because a NULL `extensionID` on an extension page means "the extension was
  uninstalled", and restore drops such rows. Without the back-fill, upgrading
  would have deleted every extension-page pin and favorite.
- **Seed ledgers.** v9 seeds the installed-event ledger so upgrading does not
  deliver `install` to every extension at the next launch.
- **Fail safe when classifying.** v17 treats a keyed manifest as unpacked: the
  wrong call the other way would replace a developer's folder with the store
  build. See [CRX verification gate](../decisions/crx-verification-gate.md).

`migrator` is `static` and internal so a test can migrate a database part-way
and check what a later migration does to existing rows.

In DEBUG builds `eraseDatabaseOnSchemaChange` is on: a migration edited after
it ran wipes the debug database rather than failing.

# Record types

| Record | File |
|---|---|
| `ProfileRecord`, `SpaceRecord`, `TabRecord`, `PinnedTabRecord`, `PinnedFolderRecord`, `FavoriteRecord`, `DownloadRecord`, `ContentBlockerWhitelistRecord`, `ExternalAppPermissionRecord` | [Detour/Storage/Models](../../Detour/Storage/Models) |
| `ClosedTabRecord`, `ClosedTabSummary` | `ClosedTabRecord.swift` in the same directory. The summary is the same table without the `interactionState` blob. |
| `ExtensionRecord`, `ExtensionStorageRecord`, `ProfileExtensionRecord`, `ExtensionPermissionRecord`, `ExtensionInstalledEventRecord` | [Detour/Extensions/Storage/Models](../../Detour/Extensions/Storage/Models) |

`pendingProfileDataRemoval`, `webKitStorageIdentifier` and `appState` have no
record type and are accessed with raw SQL.

Records are plain `Codable` structs. The live model (`Profile`, `Space`,
`BrowserTab`, `PinnedEntry`, `Favorite`) is separate; conversion happens in
`TabStore.saveNow` / `restoreSession`, `Profile.toRecord()` /
`Profile.from(record:)`, and the `TabRecord` factory in
[TabRecord+BrowserTab.swift](../../Detour/Browser/TabRecord+BrowserTab.swift).

# Conventions of `AppDatabase`

- Every method goes through `performWrite` or `performRead`. Both catch,
  log to the `storage` log category, and return a default. **A failed write
  is silent to the caller** unless the method returns a value that says so
  (`deleteProfile` returns `Bool` for this reason).
- In DEBUG builds `performRead` counts reads per label
  (`AppDatabase.readCount(_:)`, `resetReadCounts()`). Tests use it to pin a
  query count, for example one enabled-state read per profile at startup
  however many extensions are installed (TASK-46), and zero closed-tab reads
  at launch (TASK-117).
- `AppDatabase(dbQueue:)` builds an instance over an in-memory queue for
  tests and runs the same migrator.

# Related

- [Persistence](./persistence.md) — save timing and restore.
- [History database](./history-database.md) — the other file.
- [Two databases](../decisions/two-databases.md) — why history is separate.
- [Extensions storage](../extensions/storage.md) — where `chrome.storage` really lives, and why `extensionStorage` is unused.
- [Updates](../extensions/updates.md) — the v17 columns in use.
