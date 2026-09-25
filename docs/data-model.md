# Data Model & Database Schema

Detour uses two separate SQLite databases via [GRDB](https://github.com/groue/GRDB.swift):

- **Session database** (`browser.db`) -- profiles, spaces, tabs, pinned items, favorites, closed tabs, downloads, extensions, permissions, and app state
- **History database** (`history.db`) -- visited URLs, per-visit records, and full-text search over URLs and titles

Both live in `~/Library/Application Support/Detour/`. Setting the `DETOUR_DATA_DIR` environment variable replaces the `Detour` directory name (`detourDataDirectory()` in `Storage/Database.swift`), which the test scheme and verification harnesses use to keep their data isolated.

> **DEBUG builds** set `eraseDatabaseOnSchemaChange = true` on the session migrator: a migration edited after it ran erases the debug database instead of failing.

---

## Session Database

**Singleton**: `AppDatabase.shared` (`Storage/Database.swift`)

### Tables

#### `profile`

Browser settings and website data identity. Spaces reference profiles; multiple spaces can share one. The built-in Private profile (`TabStore.incognitoProfileID`, `00000000-0000-0000-0000-000000000001`) is saved too; its `WKWebsiteDataStore` is non-persistent.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID |
| `name` | TEXT | NOT NULL | Display name |
| `userAgentMode` | INTEGER | NOT NULL, default 0 | 0=Detour, 1=Safari, 2=Custom |
| `customUserAgent` | TEXT | | Custom UA string (when mode=2) |
| `archiveThreshold` | DOUBLE | NOT NULL, default 43200 | Seconds before auto-archive (0=never) |
| `sleepThreshold` | DOUBLE | NOT NULL, default 3600 | Seconds before auto-sleep (0=never) |
| `searchEngine` | INTEGER | NOT NULL, default 0 | 0=Google, 1=DDG, 2=Bing, 3=Yahoo, 4=Ecosia, 5=Kagi |
| `searchSuggestionsEnabled` | BOOLEAN | NOT NULL, default true | Show search suggestions in palette |
| `isPerTabIsolation` | BOOLEAN | NOT NULL, default false | Each tab gets a non-persistent data store |
| `isAdBlockingEnabled` | BOOLEAN | NOT NULL, default true | Master content blocking toggle |
| `isEasyListEnabled` | BOOLEAN | NOT NULL, default true | EasyList ad filter |
| `isEasyPrivacyEnabled` | BOOLEAN | NOT NULL, default true | EasyPrivacy tracker filter |
| `isEasyListCookieEnabled` | BOOLEAN | NOT NULL, default true | Cookie notice filter |
| `isMalwareFilterEnabled` | BOOLEAN | NOT NULL, default true | Malicious URL filter |

#### `space`

Workspace that groups tabs. Each space belongs to a profile.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID |
| `name` | TEXT | NOT NULL | Display name |
| `emoji` | TEXT | NOT NULL | Space icon emoji |
| `colorHex` | TEXT | NOT NULL | Hex color code (e.g. "007AFF") |
| `sortOrder` | INTEGER | NOT NULL | Position in space list |
| `selectedTabID` | TEXT | | UUID of the space's selected tab |
| `profileID` | TEXT | NOT NULL, FK -> profile | Associated profile |

Incognito spaces are never saved.

#### `tab`

Every persisted live tab: the space's normal tabs **and** the backing tabs of live pinned entries and favorites. `sortOrder` tells them apart:

| `sortOrder` | Meaning |
|-------------|---------|
| `>= 0` | Normal tab, position in the space's tab list |
| `-1` | Backing tab of a live pinned entry (referenced by `pinnedTab.tabID`) |
| `-2` | Backing tab of a live favorite (referenced by `favorite.tabID`), stored under the first persistent space of the favorite's profile |

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID |
| `spaceID` | TEXT | NOT NULL, FK -> space (CASCADE) | Parent space |
| `url` | TEXT | | Current URL (nil for blank tabs) |
| `title` | TEXT | NOT NULL, default "New Tab" | Page title |
| `faviconURL` | TEXT | | URL of the tab's favicon |
| `interactionState` | BLOB | | Archived `WKWebView.interactionState` (back/forward list) for session restore |
| `sortOrder` | INTEGER | NOT NULL | See above |
| `lastDeselectedAt` | DOUBLE | | When the tab was last deselected (drives sleep and auto-archive) |
| `parentID` | TEXT | | UUID of the tab that opened this one |
| `peekURL` | TEXT | | URL shown in the tab's Peek overlay |
| `peekInteractionState` | BLOB | | Peek's archived interaction state |
| `peekFaviconURL` | TEXT | | Peek's favicon URL |
| `splitGroupID` | TEXT | | Split group shared with the adjacent partner tab (normal tabs only; see [split-tabs-design.md](split-tabs-design.md)) |
| `splitFraction` | DOUBLE | | Left pane's width fraction |
| `extensionID` | TEXT | | Extension that owns the URL when it is a `webkit-extension://` page (TASK-24); NULL otherwise |

#### `pinnedTab`

A pinned entry. The entry itself only stores its "home" (pinned URL and title); when the entry is live, its current page lives in a backing `tab` row.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID |
| `spaceID` | TEXT | NOT NULL, FK -> space (CASCADE) | Parent space |
| `pinnedURL` | TEXT | NOT NULL | The pin's home URL |
| `pinnedTitle` | TEXT | NOT NULL | Display name for the pin |
| `faviconURL` | TEXT | | Cached favicon for dormant display |
| `sortOrder` | INTEGER | NOT NULL | Position among siblings |
| `folderID` | TEXT | FK -> pinnedFolder (SET NULL) | Parent folder (nil = top level) |
| `tabID` | TEXT | FK -> tab (SET NULL) | Backing tab when live; nil = dormant |
| `splitGroupID` | TEXT | | Pinned split membership. While pinned, the group lives **only** here; the backing tab's `splitGroupID` stays nil |
| `splitFraction` | DOUBLE | | Left pane's width fraction |
| `extensionID` | TEXT | | As on `tab`, for `pinnedURL` |

#### `pinnedFolder`

Folders for organizing pinned entries. Self-referential for nesting.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID |
| `spaceID` | TEXT | NOT NULL, FK -> space (CASCADE) | Parent space |
| `parentFolderID` | TEXT | FK -> pinnedFolder (SET NULL) | Parent folder for nesting |
| `name` | TEXT | NOT NULL | Folder display name |
| `isCollapsed` | BOOLEAN | NOT NULL, default false | UI collapse state |
| `sortOrder` | INTEGER | NOT NULL | Position among siblings |

#### `favorite`

Favorites-bar tiles. Per **profile**, not per space: every space of the profile shows the same favorites.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID |
| `profileID` | TEXT | NOT NULL, FK -> profile (CASCADE) | Owning profile |
| `url` | TEXT | NOT NULL | The favorite's home URL |
| `title` | TEXT | NOT NULL | Display title |
| `faviconURL` | TEXT | | Cached favicon |
| `sortOrder` | INTEGER | NOT NULL | Position in the bar |
| `tabID` | TEXT | FK -> tab (SET NULL) | Backing tab when live; nil = dormant |
| `extensionID` | TEXT | | As on `tab`, for `url` |

#### `closedTab`

Stack of closed tabs for Reopen Closed Tab (Cmd+Shift+T). Records are per space; incognito tabs are never recorded. The newest record has the highest `id`.

Capped at **100 rows across all spaces** (`AppDatabase.closedTabCap`, lowest `id` deleted first). The table is the only store — nothing is loaded at launch and there is no in-memory mirror (TASK-117). Menu validation and the Reopen Closed Tab scan read blob-free `ClosedTabSummary` rows through the `closedTab_on_spaceID_id` index on `(spaceID, id)`; only the reopened row's `interactionState` is read. Undoing Delete Space re-inserts the space's rows with their original ids, keeping the reopen order. See TASK-116/118 for planned changes (`closedAt`, retention tied to history).

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PRIMARY KEY (auto-increment) | Stack ordering key |
| `tabID` | TEXT | NOT NULL | Original tab UUID |
| `spaceID` | TEXT | NOT NULL | Space the tab belonged to (no FK; `deleteSpace` removes the rows explicitly) |
| `url` | TEXT | | Last URL |
| `title` | TEXT | NOT NULL | Last title |
| `faviconURL` | TEXT | | Last favicon URL |
| `interactionState` | BLOB | | Archived interaction state (back/forward list) |
| `sortOrder` | INTEGER | NOT NULL | Original position in the tab list (reopen inserts there) |
| `archivedAt` | DOUBLE | | Set when the tab was archived — by the auto-archive timer or the sidebar's "Archive Tab" / "Archive Tabs Below" (TASK-115). NULL for Cmd+W / Close Tab. There is no close timestamp for other records (TASK-116 adds `closedAt`) |
| `extensionID` | TEXT | | As on `tab` |

#### `download`

File download records with progress tracking.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID |
| `filename` | TEXT | NOT NULL | Downloaded file name |
| `sourceURL` | TEXT | | Original download URL |
| `destinationURL` | TEXT | NOT NULL | Local file path |
| `totalBytes` | INTEGER | NOT NULL, default -1 | Total size (-1 = unknown) |
| `bytesWritten` | INTEGER | NOT NULL, default 0 | Bytes downloaded so far |
| `state` | TEXT | NOT NULL | "downloading", "completed", "failed", or "cancelled" |
| `createdAt` | DATETIME | NOT NULL | When download started |
| `completedAt` | DATETIME | | When download finished |

#### `contentBlockerWhitelist`

Per-profile domain exceptions for content blocking.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `profileID` | TEXT | NOT NULL, FK -> profile (CASCADE) | Profile this exception belongs to |
| `host` | TEXT | NOT NULL | Domain to whitelist (e.g. "example.com") |

Unique key: `(profileID, host)`

#### `externalAppPermission`

"Always allow `<origin>` to open `<scheme>` links" decisions (TASK-84). Never written for the Private profile.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `profileID` | TEXT | NOT NULL, FK -> profile (CASCADE) | Profile the decision belongs to |
| `origin` | TEXT | NOT NULL | Requesting page origin |
| `scheme` | TEXT | NOT NULL | External URL scheme (e.g. `zoommtg`) |

Unique key: `(profileID, origin, scheme)`

#### `extension`

Installed Web Extensions (moved here from a separate `extensions.db`).

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | Extension id |
| `name` | TEXT | NOT NULL | Display name |
| `version` | TEXT | NOT NULL | Installed version |
| `manifestJSON` | BLOB | NOT NULL | Raw manifest |
| `basePath` | TEXT | NOT NULL | Unpacked extension directory |
| `isEnabled` | BOOLEAN | NOT NULL, default true | Global enable switch |
| `installedAt` | DOUBLE | NOT NULL | Install timestamp |

#### `extensionStorage`

Key-value storage for polyfilled extension storage.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `extensionID` | TEXT | NOT NULL, FK -> extension (CASCADE) | Owning extension |
| `key` | TEXT | NOT NULL | Storage key |
| `value` | BLOB | NOT NULL | Stored value |

Primary key: `(extensionID, key)`

#### `profileExtension`

Per-profile extension state. A **missing row** means the profile's default: off for the built-in Private profile (TASK-74), on everywhere else (`extensionEnabledByDefault(inProfile:)`).

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `profileID` | TEXT | NOT NULL, FK -> profile (CASCADE) | Profile |
| `extensionID` | TEXT | NOT NULL, FK -> extension (CASCADE) | Extension |
| `isEnabled` | BOOLEAN | NOT NULL, default true | Enabled in this profile |
| `isPinned` | BOOLEAN | NOT NULL, default false | Button shown in the faux address bar in this profile |

Primary key: `(profileID, extensionID)`

#### `extensionPermission`

Saved permission decisions per extension.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `extensionID` | TEXT | NOT NULL, FK -> extension (CASCADE) | Extension |
| `permissionKey` | TEXT | NOT NULL | Permission name or match pattern |
| `permissionType` | INTEGER | NOT NULL | `ExtensionPermissionType` raw value (0 = API permission) |
| `status` | INTEGER | NOT NULL | `ExtensionPermissionStatus` raw value (0 = granted; anything else reads as denied, fail closed) |
| `grantedAt` | DOUBLE | NOT NULL | Decision timestamp |

Primary key: `(extensionID, permissionKey, permissionType)`

#### `extensionInstalledEvent`

`runtime.onInstalled` ledger (TASK-22): which version's install/update event each profile has been delivered. The Private profile never gets one.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `extensionID` | TEXT | NOT NULL | Extension |
| `profileID` | TEXT | NOT NULL | Profile |
| `deliveredVersion` | TEXT | NOT NULL | Version last delivered |
| `deliveredAt` | DOUBLE | NOT NULL | Delivery timestamp |
| `reinstallPending` | BOOLEAN | NOT NULL, default false | A reinstall owes an `update` even at the same version (TASK-29) |

Primary key: `(extensionID, profileID)`

#### `pendingProfileDataRemoval`

Deleted profiles whose on-disk WebKit data (website data store, extension controller storage) has not been removed yet (TASK-32). Retried at launch. No FK: the profile row is already gone.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `profileID` | TEXT | PRIMARY KEY | Deleted profile's UUID |
| `requestedAt` | DOUBLE | NOT NULL | When deletion was requested |

#### `webKitStorageIdentifier`

WebKit storage identifiers created by an isolated data directory (`DETOUR_DATA_DIR` other than `Detour`), so it can remove exactly what it created from the WebKit directory it shares with the production app (TASK-36). The default data directory records nothing.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `identifier` | TEXT | PRIMARY KEY | WebKit storage identifier |
| `profileID` | TEXT | NOT NULL | Profile it was created for |
| `createdAt` | DOUBLE | NOT NULL | Creation timestamp |

#### `appState`

Key-value store for app-level state.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `key` | TEXT | PRIMARY KEY | State key |
| `value` | TEXT | | State value |

Currently stores: `lastActiveSpaceID` -- the UUID of the most recently active space, used for session restoration.

### Migration History

The migrations were consolidated at one point: `v1` creates today's core schema in one step, and the numbering below is **not** the pre-consolidation history.

| Version | Changes |
|---------|---------|
| v1 | Core tables: `profile`, `space`, `tab`, `appState`, `closedTab`, `download`, `pinnedFolder`, `pinnedTab`, `contentBlockerWhitelist` |
| v2 | Extension tables moved in from `extensions.db`: `extension`, `extensionStorage`, `profileExtension` |
| v3 | `extensionPermission` |
| v4 | `favorite` |
| v5 | `isPinned` on `profileExtension` |
| v6 | `splitGroupID`, `splitFraction` on `tab` |
| v7 | `splitGroupID`, `splitFraction` on `pinnedTab` |
| v8 | `extensionID` on `tab`, `pinnedTab`, `favorite`, `closedTab`; existing `webkit-extension://` rows back-filled with a sentinel id (TASK-24) |
| v9 | `extensionInstalledEvent`, seeded for every existing extension x profile (TASK-22) |
| v10 | `reinstallPending` on `extensionInstalledEvent`; Private profile rows dropped (TASK-29) |
| v11 | `pendingProfileDataRemoval` (TASK-32) |
| v12 | `webKitStorageIdentifier` (TASK-36) |
| v13 | Data-only: drop pre-TASK-25 `nativeMessaging` denials (TASK-44) |
| v14 | `externalAppPermission` (TASK-84) |
| v15 | index `closedTab(spaceID, id)` (TASK-117) |

### Persistence Strategy

`TabStore.saveNow()` writes the session in several steps:

1. **Session** (`saveSession`, one transaction): delete all `space` rows (cascading to `tab`, `pinnedTab`, `pinnedFolder`), re-insert every persistent space with its normal tabs, pinned backing tabs (`sortOrder = -1`) and favorite backing tabs (`sortOrder = -2`), then upsert `lastActiveSpaceID`.
2. **Profiles** (`saveProfiles`), after the session so profiles no longer referenced by any space can be deleted without FK violations.
3. **Pinned items** per space (`savePinnedFoldersAndTabs`, one transaction): folders before entries, since entries reference folders.
4. **Favorites** per profile (`saveFavorites`).

Saves are **debounced**: mutations call `scheduleSave()`, which waits 1 second before writing, so rapid changes coalesce. `saveNow()` also runs on app termination.

Closed tabs, downloads, extension state and permissions are written immediately by their own calls rather than by `saveNow()`.

### Record Types

Each table has a GRDB record struct:

| Record | File |
|--------|------|
| `ProfileRecord` | `Storage/Models/ProfileRecord.swift` |
| `SpaceRecord` | `Storage/Models/SpaceRecord.swift` |
| `TabRecord` | `Storage/Models/TabRecord.swift` |
| `PinnedTabRecord` | `Storage/Models/PinnedTabRecord.swift` |
| `PinnedFolderRecord` | `Storage/Models/PinnedFolderRecord.swift` |
| `FavoriteRecord` | `Storage/Models/FavoriteRecord.swift` |
| `ClosedTabRecord` | `Storage/Models/ClosedTabRecord.swift` |
| `DownloadRecord` | `Storage/Models/DownloadRecord.swift` |
| `ContentBlockerWhitelistRecord` | `Storage/Models/ContentBlockerWhitelistRecord.swift` |
| `ExternalAppPermissionRecord` | `Storage/Models/ExternalAppPermissionRecord.swift` |
| `ExtensionRecord` | `Extensions/Storage/Models/ExtensionRecord.swift` |
| `ExtensionStorageRecord` | `Extensions/Storage/Models/ExtensionStorageRecord.swift` |
| `ProfileExtensionRecord` | `Extensions/Storage/Models/ProfileExtensionRecord.swift` |
| `ExtensionPermissionRecord` | `Extensions/Storage/Models/ExtensionPermissionRecord.swift` |
| `ExtensionInstalledEventRecord` | `Extensions/Storage/Models/ExtensionInstalledEventRecord.swift` |

`pendingProfileDataRemoval`, `webKitStorageIdentifier` and `appState` are accessed with raw SQL.

---

## History Database

**Singleton**: `HistoryDatabase.shared` (`Storage/HistoryDatabase.swift`)

Deliberately separate from the session database for privacy (incognito spaces never write to it) and to allow independent history clearing. Every connection registers two custom SQL functions (`registerFunctions(on:)`), which queries **and** migrations depend on:

- `history_fold(text)`: the case/diacritic/width folding all history search applies (e.g. `ß` -> `ss`)
- `history_title_matches(title, query)`: the SQL face of `titleMatches(_:query:)`

### Tables

#### `historyURL`

Unique URLs with aggregate visit stats. Shared by every space and profile.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PRIMARY KEY (auto-increment) | Row ID |
| `url` | TEXT | NOT NULL, UNIQUE | Full URL |
| `title` | TEXT | NOT NULL | Latest known title (from any profile) |
| `faviconURL` | TEXT | | Latest favicon URL |
| `visitCount` | INTEGER | NOT NULL | Total visit count |
| `lastVisitTime` | DOUBLE | NOT NULL | Unix timestamp of last visit |

Index: `historyURL_lastVisitTime` on `lastVisitTime`

#### `historyVisit`

Individual visits, scoped to a space.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PRIMARY KEY (auto-increment) | Row ID |
| `urlID` | INTEGER | NOT NULL, FK -> historyURL (CASCADE) | URL reference |
| `spaceID` | TEXT | NOT NULL | Space where the visit occurred |
| `visitTime` | DOUBLE | NOT NULL | Unix timestamp |
| `isTyped` | BOOLEAN | NOT NULL, default false | Deliberate navigation (user submitted the URL) |
| `title` | TEXT | | Title the visit was recorded with (TASK-91). NULL for older visits, which fall back to `historyURL.title` |

Indexes: `historyVisit_urlID`, `historyVisit_visitTime`, `historyVisit_spaceID_visitTime` (History page paging per profile)

#### `historyTitle`

Every distinct non-empty title a space has given a URL (TASK-96), with a count of the visits carrying it. Maintained entirely by SQL triggers on `historyVisit` (`historyVisit_ai_title`, `_ad_title`, `_au_title_old`, `_au_title_new`), so every write path (recording, retitles, all delete APIs, expiry, FK cascades) keeps it in sync.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PRIMARY KEY (AUTOINCREMENT) | Never reused (the FTS index addresses rows by id) |
| `urlID` | INTEGER | NOT NULL, FK -> historyURL (CASCADE) | URL reference |
| `spaceID` | TEXT | NOT NULL | Space |
| `title` | TEXT | NOT NULL | Raw title (immutable; a retitle is a different row) |
| `folded` | TEXT | NOT NULL | `history_fold(title)`, what the FTS index covers |
| `n` | INTEGER | NOT NULL | Visits currently carrying this title; the row is deleted at 0 |

Unique key: `(urlID, spaceID, title)`

#### `historySearch` (FTS5 virtual table)

Full-text index synchronized with `historyURL` (GRDB `synchronize(withTable:)`), tokenizer `unicode61`. Columns: `url`, `title`.

#### `historyTitleSearch` (FTS5 virtual table)

External-content FTS index over `historyTitle.folded` (content rowid = `historyTitle.id`), tokenizer `unicode61`. Kept in sync by the hand-written `historyTitle_ai` / `historyTitle_ad` triggers.

### Migration History

| Version | Changes |
|---------|---------|
| h1 | `historyURL`, `historyVisit`, `historySearch` |
| h2 | `isTyped` on `historyVisit` |
| h3 | `historyVisit_spaceID_visitTime` index |
| h4 | `title` on `historyVisit` (not back-filled) (TASK-91) |
| h5 | `historyTitle`, `historyTitleSearch` and their triggers; back-filled from titled visits (TASK-96) |

### Key Behaviors

**Recording visits**: Upserts the `historyURL` row with `INSERT ... ON CONFLICT DO UPDATE ... RETURNING id`, then inserts the visit with its own title. Later title changes (SPA navigations, late `<title>`) correct the recorded visit through `updateTitle` (TASK-88).

**Deduplication**: TabStore keeps an in-memory cache (`recentHistoryWrites`, `"url|spaceID" -> timestamp`). A non-typed visit to the same URL in the same space within 30 seconds is skipped.

**Search**:
- *Command palette* (`searchHistory`, space-scoped): FTS5 prefix `MATCH` on `historySearch`, ordered by FTS rank then visit count, and showing the space's own title where it has one (TASK-94).
- *History page* (`searchVisits`, profile-scoped via a set of space IDs): candidates come from `historySearch` (URL) and `historyTitleSearch` (the space's own titles), gated by `history_title_matches` against each visit's own title (TASK-93/96). So a title a page *used* to have is searchable, and no other profile's title can produce or hide a result.

**Deletion**: The History page deletes by visit ids (optionally all visits of a URL within a time range) or everything since a cutoff for a profile's spaces. `deleteVisits(notInSpaceIDs:)` sweeps visits of deleted spaces. URLs left with no visits are removed. Closed-tab records in the session database are **not** touched (TASK-118).

**Expiration**: About 5 s after launch (off the critical path), visits older than 90 days are deleted (`expireOldVisits`), along with URLs left without visits.

---

## In-Memory Model Classes

The database records are plain structs. The live in-memory model uses richer classes:

| Class | Purpose | Key State |
|-------|---------|-----------|
| `Space` (`Browser/TabStore.swift`) | Workspace container | `tabs: [BrowserTab]`, `pinnedEntries: [PinnedEntry]`, `pinnedFolders: [PinnedFolder]`, `selectedTabID`, `profile: Profile?` |
| `BrowserTab` | Tab with optional WebView | `@Published` title, url, loading, favicon, audio; sleep/wake lifecycle; `splitGroupID`/`splitFraction`; Peek state |
| `PinnedEntry` | Pinned item | `pinnedURL`, `pinnedTitle`, `folderID`, `sortOrder`, `splitGroupID`; `tab: BrowserTab?` (nil = dormant) |
| `PinnedFolder` | Folder in the pin hierarchy | `parentFolderID`, `isCollapsed`, `sortOrder` |
| `Favorite` | Favorites-bar tile (per profile) | `url`, `title`, `sortOrder`; `tab: BrowserTab?` (nil = dormant) |
| `Profile` | Settings + website data | `favorites: [Favorite]`, `isIncognito`, `lazy var dataStore: WKWebsiteDataStore` (persistent per profile, or non-persistent) |

Closed-tab records are not held in memory; `TabStore.closedTabRecords(in:)` queries the `closedTab` table (see above).

### Record <-> Model Conversion

- **Save**: `TabStore.saveNow()` converts in-memory models to records (see *Persistence Strategy*).
- **Restore**: `TabStore.restoreSession()` loads records and builds the model objects. Pinned entries and favorites whose `tabID` names a saved backing tab come back live; others come back dormant.
- **Profile**: `Profile.toRecord()` and `Profile.from(record:)`.

The selected tab in each space gets a live `WKWebView` on restore, rebuilt from its `interactionState`. All other tabs are restored sleeping (no WebView) and wake on selection.

Extension pages (TASK-24) are special-cased on restore through their saved `extensionID`:
- Uninstalled extension (or no saved id): the page is dropped everywhere.
- Disabled extension: pinned entries, favorites and closed-tab records keep the page for a later enable, but an open tab on it is dropped.
- Enabled extension: the tab is restored sleeping, without its interaction state (its back/forward list is all on the dead origin).
