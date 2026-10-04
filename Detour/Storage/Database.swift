import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "storage")

/// Returns the app's data directory inside Application Support.
/// When the `DETOUR_DATA_DIR` environment variable is set (e.g. in the test scheme),
/// that subdirectory name is used instead of "Detour", keeping test data isolated.
func detourDataDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let subdir = detourDataDirectoryName()
    let dir = appSupport.appendingPathComponent(subdir, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The production data directory's name inside Application Support.
let defaultDetourDataDirectoryName = "Detour"

/// The data directory name in use: `DETOUR_DATA_DIR`, or "Detour" when unset.
func detourDataDirectoryName(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    environment["DETOUR_DATA_DIR"] ?? defaultDetourDataDirectoryName
}

struct AppDatabase {
    static let shared = AppDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let dir = detourDataDirectory()
        let dbPath = dir.appendingPathComponent("browser.db").path

        dbQueue = try! DatabaseQueue(path: dbPath)
        try! Self.migrator.migrate(dbQueue)
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Helpers

    private func performWrite(_ label: String, _ work: (GRDB.Database) throws -> Void) {
        do {
            try dbQueue.write(work)
        } catch {
            log.error("Failed to \(label): \(error.localizedDescription)")
        }
    }

    private func performWrite<T>(_ label: String, default defaultValue: T, _ work: (GRDB.Database) throws -> T) -> T {
        do {
            return try dbQueue.write(work)
        } catch {
            log.error("Failed to \(label): \(error.localizedDescription)")
            return defaultValue
        }
    }

    private func performRead<T>(_ label: String, default defaultValue: T, _ work: (GRDB.Database) throws -> T) -> T {
        #if DEBUG
        Self.countRead(label)
        #endif
        do {
            return try dbQueue.read(work)
        } catch {
            log.error("Failed to \(label): \(error.localizedDescription)")
            return defaultValue
        }
    }

    #if DEBUG
    // MARK: - Read Counters (tests only)

    /// How many read transactions `performRead` has run under each label since
    /// the last reset. Lets a test pin down a query count — e.g. TASK-46, one
    /// enabled-state read per profile at startup no matter how many extensions
    /// are installed — so per-row reads cannot creep back in unnoticed.
    /// Reads happen off the main thread too, so the table is lock-guarded.
    private static let readCountsLock = NSLock()
    private static var readCounts: [String: Int] = [:]

    private static func countRead(_ label: String) {
        readCountsLock.lock()
        readCounts[label, default: 0] += 1
        readCountsLock.unlock()
    }

    static func resetReadCounts() {
        readCountsLock.lock()
        readCounts.removeAll()
        readCountsLock.unlock()
    }

    /// Reads run under `label` — the string `performRead` was called with — since
    /// the last `resetReadCounts()`.
    static func readCount(_ label: String) -> Int {
        readCountsLock.lock()
        defer { readCountsLock.unlock() }
        return readCounts[label] ?? 0
    }
    #endif

    // MARK: - Profiles

    func saveProfile(_ record: ProfileRecord) {
        performWrite("save profile") { db in
            try record.save(db)
        }
    }

    func loadProfiles() -> [ProfileRecord] {
        performRead("load profiles", default: []) { db in
            try ProfileRecord.fetchAll(db)
        }
    }

    /// Deletes the profile (see `deleteProfileRows`) unless a space still
    /// references it.
    ///
    /// Returns whether the profile row was deleted: false when a space still
    /// references it, when there was no such row, or when the write failed.
    @discardableResult
    func deleteProfile(id: String) -> Bool {
        performWrite("delete profile", default: false) { db in
            try Self.deleteProfileRows(ids: [id], in: db, recordingPendingDataRemoval: true).contains(id)
        }
    }

    /// The one way a profile row is deleted (`deleteProfile`, and `saveProfiles`
    /// for profiles missing from the saved set), run inside the caller's write
    /// transaction. For each id that no space references it deletes every row
    /// keyed by the id (TASK-31) — per-profile extension state, the
    /// `runtime.onInstalled` ledger, favourites, the content blocker whitelist
    /// and remembered external-app permissions — then the profile row.
    ///
    /// `recordingPendingDataRemoval` also records a pending removal of the
    /// profile's on-disk WebKit data (TASK-32, `ProfileDataRemoval`) for every id
    /// whose row went, so the data is removed even if the app quits first. Only
    /// `deleteProfile` — an explicit "delete this profile" — passes true; the
    /// `saveProfiles` sweep passes false, because its set of live profiles can be
    /// incomplete.
    ///
    /// `favorite`, `profileExtension`, `contentBlockerWhitelist` and
    /// `externalAppPermission` also cascade
    /// from the profile row, but only while foreign keys are enforced, and
    /// `extensionInstalledEvent` has no foreign key at all, so each is deleted
    /// explicitly. Rows keyed by extension alone (`extension`, `extensionStorage`,
    /// `extensionPermission`) are shared by every profile and are left alone.
    /// An id a space still references is skipped entirely.
    ///
    /// Returns the ids whose profile row was deleted.
    private static func deleteProfileRows(ids: [String], in db: GRDB.Database,
                                          recordingPendingDataRemoval: Bool) throws -> [String] {
        var deletedIDs: [String] = []
        for id in ids {
            let spaceCount = try SpaceRecord.filter(Column("profileID") == id).fetchCount(db)
            guard spaceCount == 0 else {
                log.error("Cannot delete profile \(id): \(spaceCount) space(s) still reference it")
                continue
            }
            try ProfileExtensionRecord.filter(Column("profileID") == id).deleteAll(db)
            try ExtensionInstalledEventRecord.filter(Column("profileID") == id).deleteAll(db)
            try FavoriteRecord.filter(Column("profileID") == id).deleteAll(db)
            try ContentBlockerWhitelistRecord.filter(Column("profileID") == id).deleteAll(db)
            try ExternalAppPermissionRecord.filter(Column("profileID") == id).deleteAll(db)
            if try ProfileRecord.filter(Column("id") == id).deleteAll(db) > 0 {
                if recordingPendingDataRemoval {
                    try recordPendingProfileDataRemoval(profileID: id, in: db)
                }
                deletedIDs.append(id)
            }
        }
        return deletedIDs
    }

    // MARK: - Pending profile data removals (TASK-32)

    /// Records that a deleted profile's on-disk WebKit data (its
    /// `WKWebsiteDataStore` and its extension controller storage, both keyed by
    /// the profile id) still has to be removed. Never recorded for the built-in
    /// Private profile, whose store and controller are non-persistent.
    static func recordPendingProfileDataRemoval(profileID: String, in db: GRDB.Database) throws {
        guard UUID(uuidString: profileID) != TabStore.incognitoProfileID else { return }
        try db.execute(
            sql: "INSERT OR IGNORE INTO pendingProfileDataRemoval (profileID, requestedAt) VALUES (?, ?)",
            arguments: [profileID, Date().timeIntervalSince1970]
        )
    }

    func recordPendingProfileDataRemoval(profileID: String) {
        performWrite("record pending profile data removal") { db in
            try Self.recordPendingProfileDataRemoval(profileID: profileID, in: db)
        }
    }

    /// Profile ids whose data removal has not succeeded yet, oldest first.
    func pendingProfileDataRemovals() -> [String] {
        performRead("load pending profile data removals", default: []) { db in
            try String.fetchAll(db, sql: "SELECT profileID FROM pendingProfileDataRemoval ORDER BY requestedAt, profileID")
        }
    }

    func clearPendingProfileDataRemoval(profileID: String) {
        performWrite("clear pending profile data removal") { db in
            try db.execute(sql: "DELETE FROM pendingProfileDataRemoval WHERE profileID = ?", arguments: [profileID])
        }
    }

    // MARK: - WebKit storage identifiers (TASK-36)

    /// Records that this data directory is about to create persistent WebKit
    /// storage (a website data store and extension controller) under
    /// `identifier` for `profileID`. Only isolated data directories record; see
    /// `WebKitStorageScope`.
    func recordWebKitStorageIdentifier(_ identifier: UUID, profileID: UUID) {
        performWrite("record WebKit storage identifier") { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO webKitStorageIdentifier (identifier, profileID, createdAt) VALUES (?, ?, ?)",
                arguments: [identifier.uuidString, profileID.uuidString, Date().timeIntervalSince1970]
            )
        }
    }

    /// Identifiers this data directory recorded, oldest first.
    func recordedWebKitStorageIdentifiers() -> [UUID] {
        performRead("load WebKit storage identifiers", default: []) { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM webKitStorageIdentifier ORDER BY createdAt, identifier")
                .compactMap(UUID.init(uuidString:))
        }
    }

    /// The profile `identifier` was recorded for, or nil when it is not recorded.
    func recordedWebKitStorageProfileID(for identifier: UUID) -> UUID? {
        performRead("look up WebKit storage identifier", default: nil) { db in
            try String.fetchOne(db, sql: "SELECT profileID FROM webKitStorageIdentifier WHERE identifier = ?",
                                arguments: [identifier.uuidString])
                .flatMap(UUID.init(uuidString:))
        }
    }

    func forgetWebKitStorageIdentifier(_ identifier: UUID) {
        performWrite("forget WebKit storage identifier") { db in
            try db.execute(sql: "DELETE FROM webKitStorageIdentifier WHERE identifier = ?",
                           arguments: [identifier.uuidString])
        }
    }

    // MARK: - Session

    /// Saves `records` as the complete set of profiles, in one transaction. A
    /// stored profile missing from the set has its rows dropped with it
    /// (`deleteProfileRows`, TASK-33), unless a space still references it, in
    /// which case it is kept.
    ///
    /// The sweep drops rows only — it never arms an on-disk data removal, as it
    /// did not before TASK-33. `records` is what TabStore holds in memory, which
    /// is not proof of what the user deleted: a launch that could not load the
    /// profiles (a read error, or a caller that saves before restoring) passes a
    /// set missing profiles that are very much alive, and removing their
    /// `WKWebsiteDataStore` would irreversibly wipe real cookies, logins and
    /// extension storage. Only the explicit `deleteProfile` path records the
    /// pending removal (TASK-32).
    func saveProfiles(_ records: [ProfileRecord]) {
        performWrite("save profiles") { db in
            try Self.writeProfiles(records, in: db)
        }
    }

    private static func writeProfiles(_ records: [ProfileRecord], in db: GRDB.Database) throws {
        let savedIDs = Set(records.map(\.id))
        let removedIDs = try String.fetchAll(db, sql: "SELECT id FROM profile").filter { !savedIDs.contains($0) }
        _ = try deleteProfileRows(ids: removedIDs, in: db, recordingPendingDataRemoval: false)
        for record in records {
            try record.save(db)
        }
    }

    func saveSession(spaces: [(SpaceRecord, [TabRecord])], lastActiveSpaceID: String?) {
        performWrite("save session") { db in
            try Self.writeSession(spaces: spaces, lastActiveSpaceID: lastActiveSpaceID, in: db)
        }
    }

    /// Replaces every space and tab row. Deleting the space rows cascades to
    /// `tab`, `pinnedTab` and `pinnedFolder`, so on its own this leaves the
    /// spaces without pinned rows until `writePinnedFoldersAndTabs` runs —
    /// which is why a whole save goes through `saveSessionSnapshot`.
    private static func writeSession(spaces: [(SpaceRecord, [TabRecord])], lastActiveSpaceID: String?,
                                     in db: GRDB.Database) throws {
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try SpaceRecord.deleteAll(db)

        for (spaceRecord, tabRecords) in spaces {
            try spaceRecord.insert(db)
            for tabRecord in tabRecords {
                try tabRecord.insert(db)
            }
        }

        if let activeID = lastActiveSpaceID {
            try writeLastActiveSpaceID(activeID, in: db)
        }
    }

    private static func writeLastActiveSpaceID(_ activeID: String, in db: GRDB.Database) throws {
        try db.execute(
            sql: "INSERT INTO appState (key, value) VALUES ('lastActiveSpaceID', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [activeID]
        )
    }

    /// Everything one `TabStore.saveNow()` writes, as records (TASK-149).
    struct SessionSnapshot {
        /// One space's pinned folders and entries.
        struct PinnedItems {
            let spaceID: String
            let folders: [PinnedFolderRecord]
            let tabs: [PinnedTabRecord]
        }

        /// One profile's favourites, in bar order.
        struct Favorites {
            let profileID: String
            let records: [FavoriteRecord]
        }

        /// Persistent spaces in order, each with its tab rows: normal tabs,
        /// pinned backing tabs (`sortOrder` -1) and favourite backing tabs (-2).
        var spaces: [(SpaceRecord, [TabRecord])]
        var lastActiveSpaceID: String?
        /// The complete set of profiles; see `saveProfiles` for what happens
        /// to a stored profile that is missing from it.
        var profiles: [ProfileRecord]
        var pinnedItems: [PinnedItems]
        var favorites: [Favorites]
    }

    /// Writes a whole save in ONE transaction (TASK-149), in the order the
    /// foreign keys dictate: spaces and tabs, profiles, each space's pinned
    /// folders and entries, each profile's favourites. The steps are the ones
    /// `saveSession`, `saveProfiles`, `savePinnedFoldersAndTabs` and
    /// `saveFavorites` run, and write the same rows.
    ///
    /// The first step deletes every space row, which cascades to the pinned
    /// rows the third step puts back, and sets `favorite.tabID` to NULL until
    /// the fourth step rewrites it. Run as separate transactions, a crash or a
    /// failed step in between left spaces without their pinned entries and
    /// folders. In one transaction an interrupted save rolls back as a whole,
    /// so the database holds either the previous save or this one.
    ///
    /// That also means one failing statement fails the whole save. The error
    /// is thrown, not logged and dropped (TASK-154): the caller decides what
    /// to do about a save that wrote nothing — `TabStore.saveNow()` falls back
    /// to `saveSessionSnapshotIsolatingFailures` when it is a row the database
    /// refused (`isConstraintFailure`).
    func saveSessionSnapshot(_ snapshot: SessionSnapshot) throws {
        try dbQueue.write { db in
            try Self.writeSession(spaces: snapshot.spaces, lastActiveSpaceID: snapshot.lastActiveSpaceID, in: db)
            try Self.writeProfiles(snapshot.profiles, in: db)
            for pinned in snapshot.pinnedItems {
                try Self.writePinnedFoldersAndTabs(folders: pinned.folders, tabs: pinned.tabs,
                                                   spaceID: pinned.spaceID, in: db)
            }
            for favorites in snapshot.favorites {
                try Self.writeFavorites(favorites.records, profileID: favorites.profileID, in: db)
            }
        }
    }

    /// A part of a session save that `saveSessionSnapshotIsolatingFailures`
    /// could not write.
    struct SessionSaveFailure: Equatable {
        /// What is written, or not, as a whole.
        enum Unit: Equatable {
            /// A space row with its tab rows and its pinned folders and entries.
            case space(id: String)
            /// The profile rows, and the sweep of profiles the store no longer has.
            case profiles
            /// One profile's favourites.
            case favorites(profileID: String)
        }

        let unit: Unit
        /// The database's error.
        let reason: String
    }

    /// Whether `error` is the database refusing a row — a foreign key, a
    /// uniqueness or a NOT NULL violation, or a trigger raising. Such a failure
    /// belongs to the row and comes back on every save of that row; anything
    /// else (a full disk, an I/O error, a locked or damaged file) is not about
    /// one row, and no part of the save can be expected to go through.
    static func isConstraintFailure(_ error: Error) -> Bool {
        (error as? DatabaseError)?.resultCode == .SQLITE_CONSTRAINT
    }

    /// Writes as much of a save as the database accepts (TASK-154), for a
    /// snapshot `saveSessionSnapshot` failed on with a constraint failure.
    /// Still ONE transaction, so an interrupted save still leaves the previous
    /// one whole; inside it each unit (`SessionSaveFailure.Unit`) is written in
    /// its own savepoint:
    ///
    /// - each space: the space row, its tab rows, its pinned folders and
    ///   entries. They are one unit because deleting the space row to rewrite
    ///   it cascades to the other three, so they are replaced together or not
    ///   at all;
    /// - the profiles;
    /// - each profile's favourites.
    ///
    /// A unit that fails with a constraint failure is rolled back to its
    /// savepoint, which leaves its rows as the last good save wrote them — a
    /// space that was never saved is simply not there — and is returned. Every
    /// other unit is written. Any other error is thrown and rolls the whole
    /// save back.
    ///
    /// One exception to "as the last good save wrote them": a favourites unit
    /// that fails after the space hosting its live favourites was written.
    /// Rewriting that space deleted its tab rows, and the cascade set
    /// `favorite.tabID` to NULL in the favourite rows that the rollback then
    /// keeps. Those favourites are kept, but dormant, until a later save
    /// writes the unit; the re-inserted backing tab rows go unreferenced until
    /// then (found in review, not repaired: it takes a refused favourite row
    /// in the same save as a rewritten host space).
    ///
    /// Two things keep the units independent of each other:
    ///
    /// - A row that changed unit (a tab moved to another space) may still be
    ///   held, under the same primary key, by a unit that is not rewritten in
    ///   this pass. Before a unit inserts its rows, such stale copies are
    ///   deleted from every unit this pass has not written. Copies in a unit
    ///   it has written are left to fail the insert: that is a real duplicate.
    /// - A live favourite's backing tab row belongs to the space that hosts
    ///   it. When that space was not written and the row is not among the ones
    ///   it kept, the favourite is saved dormant rather than failing its
    ///   profile's favourites on `favorite.tabID`.
    ///
    /// What a relaunch loads after a partial save is a valid session by the
    /// schema's own rules: every statement ran with the foreign keys enforced.
    func saveSessionSnapshotIsolatingFailures(_ snapshot: SessionSnapshot) throws -> [SessionSaveFailure] {
        try dbQueue.write { db in
            var failures: [SessionSaveFailure] = []
            /// Runs `work` in a savepoint; returns whether it was kept.
            func write(_ unit: SessionSaveFailure.Unit, _ work: () throws -> Void) throws -> Bool {
                do {
                    try db.inSavepoint {
                        try work()
                        return .commit
                    }
                    return true
                } catch where Self.isConstraintFailure(error) {
                    failures.append(SessionSaveFailure(unit: unit, reason: "\(error)"))
                    return false
                }
            }

            // Spaces the store no longer has go, with their tabs and pinned
            // rows (cascade), as they do in the one-step save.
            let spaceIDs = snapshot.spaces.map(\.0.id)
            try SpaceRecord.filter(!spaceIDs.contains(Column("id"))).deleteAll(db)

            let pinnedBySpace = Dictionary(snapshot.pinnedItems.map { ($0.spaceID, $0) }, uniquingKeysWith: { first, _ in first })
            var writtenSpaceIDs: [String] = []
            for (space, tabs) in snapshot.spaces {
                let pinned = pinnedBySpace[space.id]
                let written = try write(.space(id: space.id)) {
                    // Cascades to the space's tab, pinnedFolder and pinnedTab rows.
                    _ = try SpaceRecord.deleteOne(db, key: space.id)
                    try Self.deleteStaleRows(TabRecord.self, ids: tabs.map(\.id),
                                             ownerColumn: "spaceID", writtenOwners: writtenSpaceIDs, in: db)
                    try space.insert(db)
                    for tab in tabs {
                        try tab.insert(db)
                    }
                    guard let pinned else { return }
                    try Self.deleteStaleRows(PinnedFolderRecord.self, ids: pinned.folders.map(\.id),
                                             ownerColumn: "spaceID", writtenOwners: writtenSpaceIDs, in: db)
                    try Self.deleteStaleRows(PinnedTabRecord.self, ids: pinned.tabs.map(\.id),
                                             ownerColumn: "spaceID", writtenOwners: writtenSpaceIDs, in: db)
                    try Self.writePinnedFoldersAndTabs(folders: pinned.folders, tabs: pinned.tabs,
                                                       spaceID: space.id, in: db)
                }
                if written { writtenSpaceIDs.append(space.id) }
            }
            // Pinned rows of a space the snapshot does not hold have no space
            // row to hang from. `TabStore` never builds any; reported, not dropped.
            for pinned in snapshot.pinnedItems where !spaceIDs.contains(pinned.spaceID) {
                _ = try write(.space(id: pinned.spaceID)) {
                    try Self.writePinnedFoldersAndTabs(folders: pinned.folders, tabs: pinned.tabs,
                                                       spaceID: pinned.spaceID, in: db)
                }
            }

            if let activeID = snapshot.lastActiveSpaceID {
                try Self.writeLastActiveSpaceID(activeID, in: db)
            }

            // After the spaces, as in the one-step save: a profile is swept
            // only when no space row references it, and a space that kept its
            // previous rows still references its previous profile.
            _ = try write(.profiles) {
                try Self.writeProfiles(snapshot.profiles, in: db)
            }

            var writtenProfileIDs: [String] = []
            for favorites in snapshot.favorites {
                let written = try write(.favorites(profileID: favorites.profileID)) {
                    try Self.deleteStaleRows(FavoriteRecord.self, ids: favorites.records.map(\.id),
                                             ownerColumn: "profileID", writtenOwners: writtenProfileIDs, in: db)
                    let records = try favorites.records.map { record -> FavoriteRecord in
                        guard let tabID = record.tabID, try !TabRecord.exists(db, key: tabID) else { return record }
                        log.error("Session save: favourite \(record.id, privacy: .public) is saved dormant, its tab's row was not written")
                        var dormant = record
                        dormant.tabID = nil
                        return dormant
                    }
                    try Self.writeFavorites(records, profileID: favorites.profileID, in: db)
                }
                if written { writtenProfileIDs.append(favorites.profileID) }
            }

            return failures
        }
    }

    /// Deletes the rows of `record`'s table that have one of `ids` and belong
    /// to an owner (`ownerColumn`: a space or a profile) outside `writtenOwners`.
    /// See `saveSessionSnapshotIsolatingFailures`.
    private static func deleteStaleRows<Record: TableRecord>(_ record: Record.Type, ids: [String], ownerColumn: String,
                                                             writtenOwners: [String], in db: GRDB.Database) throws {
        // In chunks, to stay far below SQLite's limit on bound values.
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start ..< min(start + 500, ids.count)])
            try record
                .filter(chunk.contains(Column("id")) && !writtenOwners.contains(Column(ownerColumn)))
                .deleteAll(db)
        }
    }

    // MARK: - Closed Tab Stack

    /// `performRead` labels for the closed-tab reads, so tests can pin down that
    /// launch reads none and a reopen reads one full row (TASK-117).
    static let closedTabSummariesReadLabel = "load closed tab summaries"
    static let closedTabReadLabel = "load closed tab"
    static let closedTabsForSpaceReadLabel = "load closed tabs for space"
    static let closedTabSummaryReadLabel = "load closed tab summary"

    /// No row cap (TASK-120): records stay until the user clears them (Clear
    /// Archive, TASK-119) or retention removes them (TASK-118).
    func pushClosedTab(_ record: ClosedTabRecord) {
        performWrite("push closed tab") { db in
            try record.insert(db)
        }
    }

    func popClosedTab(spaceID: String) -> ClosedTabRecord? {
        performWrite("pop closed tab", default: nil) { db in
            guard let record = try ClosedTabRecord
                .filter(Column("spaceID") == spaceID)
                .order(Column("id").desc)
                .fetchOne(db) else { return nil }
            try record.delete(db)
            return record
        }
    }

    /// Closed-tab rows without their interactionState blobs, newest first —
    /// what menu validation, the reopen scan and listings read (TASK-117).
    /// `spaceID == nil` lists every space (the Archived Tabs page, TASK-119). `includeArchived: false`
    /// leaves out archived records (archivedAt set) — the Reopen Closed Tab scan
    /// (TASK-116).
    func closedTabSummaries(spaceID: String? = nil, includeArchived: Bool = true) -> [ClosedTabSummary] {
        performRead(Self.closedTabSummariesReadLabel, default: []) { db in
            var request = ClosedTabSummary.select(
                Column("id"), Column("tabID"), Column("spaceID"), Column("url"),
                Column("title"), Column("faviconURL"), Column("sortOrder"),
                Column("archivedAt"), Column("closedAt"), Column("extensionID"))
            if let spaceID {
                request = request.filter(Column("spaceID") == spaceID)
            }
            if !includeArchived {
                request = request.filter(Column("archivedAt") == nil)
            }
            return try request.order(Column("id").desc).fetchAll(db)
        }
    }

    /// One closed-tab row without its blob — what an Archived Tabs restore
    /// classifies before fetching the full row (TASK-119).
    func closedTabSummary(id: Int64) -> ClosedTabSummary? {
        performRead(Self.closedTabSummaryReadLabel, default: nil) { db in
            try ClosedTabSummary.select(
                Column("id"), Column("tabID"), Column("spaceID"), Column("url"),
                Column("title"), Column("faviconURL"), Column("sortOrder"),
                Column("archivedAt"), Column("closedAt"), Column("extensionID"))
                .filter(Column("id") == id)
                .fetchOne(db)
        }
    }

    /// The full closed-tab row, including its interactionState blob — the only
    /// place a blob is read, for the one record a reopen picks (TASK-117).
    func closedTab(id: Int64) -> ClosedTabRecord? {
        performRead(Self.closedTabReadLabel, default: nil) { db in
            try ClosedTabRecord.fetchOne(db, key: id)
        }
    }

    /// Full rows of one space's closed tabs, oldest first — the Delete Space
    /// undo snapshot.
    func closedTabs(spaceID: String) -> [ClosedTabRecord] {
        performRead(Self.closedTabsForSpaceReadLabel, default: []) { db in
            try ClosedTabRecord
                .filter(Column("spaceID") == spaceID)
                .order(Column("id").asc)
                .fetchAll(db)
        }
    }

    func deleteClosedTab(id: Int64) {
        performWrite("delete closed tab by id") { db in
            _ = try ClosedTabRecord.deleteOne(db, key: id)
        }
    }

    /// Re-inserts closed-tab rows keeping their ORIGINAL ids (Delete Space undo).
    /// The ids were freed by the delete and AUTOINCREMENT never hands them to new
    /// rows, so restoring them puts each record back at its exact place in the
    /// newest-first reopen order, interleaved with anything closed since. (The old
    /// undo re-pushed the records newest-first with fresh ids, reversing them.)
    func insertClosedTabs(_ records: [ClosedTabRecord]) {
        guard !records.isEmpty else { return }
        performWrite("insert closed tabs") { db in
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Deletes the given closed-tab rows in one write (purging uninstalled
    /// extensions' records found by a scan).
    func deleteClosedTabs(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        performWrite("delete closed tabs by id") { db in
            _ = try ClosedTabRecord.deleteAll(db, keys: ids)
        }
    }

    /// Deletes every closed-tab row of the given spaces in one write (Clear
    /// Archive, TASK-119).
    func deleteClosedTabs(spaceIDs: [String]) {
        guard !spaceIDs.isEmpty else { return }
        performWrite("delete closed tabs for spaces") { db in
            _ = try ClosedTabRecord
                .filter(spaceIDs.contains(Column("spaceID")))
                .deleteAll(db)
        }
    }

    func deleteClosedTabs(spaceID: String) {
        performWrite("delete closed tabs for space") { db in
            try ClosedTabRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
        }
    }

    /// Whether a closed-tab row for `tabID` still exists — a close undo checks
    /// it, since the record may have been consumed (restored from the Archived
    /// Tabs page or by Reopen Closed Tab) or deleted since the close.
    func hasClosedTab(tabID: String) -> Bool {
        performRead("has closed tab", default: false) { db in
            try ClosedTabSummary.filter(Column("tabID") == tabID).fetchCount(db) > 0
        }
    }

    /// Deletes the closed-tab row(s) for a specific tab. Used when undoing a tab
    /// close so Cmd+Shift+T does not reopen a duplicate of the restored tab. A given tabID
    /// appears at most once because reopen/undo always mint a fresh tab UUID.
    func deleteClosedTab(tabID: String) {
        performWrite("delete closed tab") { db in
            try ClosedTabRecord
                .filter(Column("tabID") == tabID)
                .deleteAll(db)
        }
    }

    // MARK: - Downloads

    func saveDownload(_ record: DownloadRecord) {
        performWrite("save download") { db in
            try record.save(db)
        }
    }

    func loadDownloads() -> [DownloadRecord] {
        performRead("load downloads", default: []) { db in
            try DownloadRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func deleteDownload(id: String) {
        performWrite("delete download") { db in
            try DownloadRecord.filter(Column("id") == id).deleteAll(db)
        }
    }

    func deleteCompletedDownloads() {
        performWrite("delete completed downloads") { db in
            try DownloadRecord.filter(Column("state") == "completed").deleteAll(db)
        }
    }

    // MARK: - Content Blocker Whitelist

    func saveContentBlockerWhitelistEntry(_ record: ContentBlockerWhitelistRecord) {
        performWrite("save whitelist entry") { db in
            try record.save(db)
        }
    }

    func deleteContentBlockerWhitelistEntry(profileID: String, host: String) {
        performWrite("delete whitelist entry") { db in
            try ContentBlockerWhitelistRecord
                .filter(Column("profileID") == profileID && Column("host") == host)
                .deleteAll(db)
        }
    }

    func loadContentBlockerWhitelist() -> [ContentBlockerWhitelistRecord] {
        performRead("load whitelist", default: []) { db in
            try ContentBlockerWhitelistRecord.fetchAll(db)
        }
    }

    // MARK: - External App Permissions (TASK-84)

    func saveExternalAppPermission(_ record: ExternalAppPermissionRecord) {
        performWrite("save external app permission") { db in
            try record.save(db)
        }
    }

    func deleteExternalAppPermissions(profileID: String) {
        performWrite("delete external app permissions") { db in
            try ExternalAppPermissionRecord.filter(Column("profileID") == profileID).deleteAll(db)
        }
    }

    func loadExternalAppPermissions() -> [ExternalAppPermissionRecord] {
        performRead("load external app permissions", default: []) { db in
            try ExternalAppPermissionRecord.fetchAll(db)
        }
    }

    // MARK: - Pinned Tabs

    func savePinnedTabs(_ records: [PinnedTabRecord], spaceID: String) {
        performWrite("save pinned tabs") { db in
            try PinnedTabRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    func loadPinnedTabs(spaceID: String) -> [PinnedTabRecord] {
        performRead("load pinned tabs", default: []) { db in
            try PinnedTabRecord
                .filter(Column("spaceID") == spaceID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    // MARK: - Pinned Folders

    func savePinnedFolders(_ records: [PinnedFolderRecord], spaceID: String) {
        performWrite("save pinned folders") { db in
            try PinnedFolderRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Saves both folders and tabs in a single transaction to avoid FK violations.
    func savePinnedFoldersAndTabs(folders: [PinnedFolderRecord], tabs: [PinnedTabRecord], spaceID: String) {
        performWrite("save pinned folders and tabs") { db in
            try Self.writePinnedFoldersAndTabs(folders: folders, tabs: tabs, spaceID: spaceID, in: db)
        }
    }

    private static func writePinnedFoldersAndTabs(folders: [PinnedFolderRecord], tabs: [PinnedTabRecord],
                                                  spaceID: String, in db: GRDB.Database) throws {
        // Delete tabs first (they reference folders), then folders
        try PinnedTabRecord
            .filter(Column("spaceID") == spaceID)
            .deleteAll(db)
        try PinnedFolderRecord
            .filter(Column("spaceID") == spaceID)
            .deleteAll(db)
        // Insert folders first (tabs reference them), each parent before its
        // children (folders reference folders)
        for record in parentFirst(folders) {
            try record.insert(db)
        }
        for record in tabs {
            try record.insert(db)
        }
    }

    /// `folders` with every parent ahead of its children, otherwise in the
    /// order given.
    ///
    /// `pinnedFolder.parentFolderID` references `pinnedFolder` and the check is
    /// immediate, so a child row inserted before its parent's fails the
    /// statement — and with it the whole save (`saveSessionSnapshot`). The
    /// order handed in is the store's array order, which is not parent-first:
    /// a folder dragged into one created after it stays ahead of it, Undo
    /// Delete Folder appends the restored parent behind its children, and
    /// after a relaunch the rows come back by their per-level `sortOrder`.
    ///
    /// A folder whose parent is not among `folders` is placed as a root, and
    /// the folders of a parent cycle go last in the order given: neither can
    /// be made valid here, so the insert reports them. `TabStore.saveNow()`
    /// never hands either in: `SessionSnapshot.repairingInvalidRows()` moves
    /// such folders to the root first (TASK-154).
    private static func parentFirst(_ folders: [PinnedFolderRecord]) -> [PinnedFolderRecord] {
        let ids = Set(folders.map(\.id))
        var placed = Set<String>()
        var ordered: [PinnedFolderRecord] = []
        var pending = folders
        while !pending.isEmpty {
            var waiting: [PinnedFolderRecord] = []
            for folder in pending {
                if let parent = folder.parentFolderID, ids.contains(parent), !placed.contains(parent) {
                    waiting.append(folder)
                } else {
                    placed.insert(folder.id)
                    ordered.append(folder)
                }
            }
            // No folder could be placed: what is left is a cycle.
            if waiting.count == pending.count { return ordered + waiting }
            pending = waiting
        }
        return ordered
    }

    func loadPinnedFolders(spaceID: String) -> [PinnedFolderRecord] {
        performRead("load pinned folders", default: []) { db in
            try PinnedFolderRecord
                .filter(Column("spaceID") == spaceID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    func loadSession() -> (spaces: [(SpaceRecord, [TabRecord])], lastActiveSpaceID: String?)? {
        performRead("load session", default: nil) { db in
            let spaceRecords = try SpaceRecord.order(Column("sortOrder")).fetchAll(db)
            guard !spaceRecords.isEmpty else { return nil }

            var spaces: [(SpaceRecord, [TabRecord])] = []
            for spaceRecord in spaceRecords {
                let tabRecords = try TabRecord
                    .filter(Column("spaceID") == spaceRecord.id)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
                spaces.append((spaceRecord, tabRecords))
            }

            let lastActiveSpaceID = try String.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'lastActiveSpaceID'")
            return (spaces, lastActiveSpaceID)
        }
    }

    /// Internal (not private) so tests can migrate a database part-way and check
    /// what a later migration does to existing rows.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            // Profile
            try db.create(table: "profile") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("userAgentMode", .integer).notNull().defaults(to: 0)
                t.column("customUserAgent", .text)
                t.column("archiveThreshold", .double).notNull().defaults(to: 43200)
                t.column("searchEngine", .integer).notNull().defaults(to: 0)
                t.column("searchSuggestionsEnabled", .boolean).notNull().defaults(to: true)
                t.column("isPerTabIsolation", .boolean).notNull().defaults(to: false)
                t.column("sleepThreshold", .double).notNull().defaults(to: 3600)
                t.column("isAdBlockingEnabled", .boolean).notNull().defaults(to: true)
                t.column("isEasyListEnabled", .boolean).notNull().defaults(to: true)
                t.column("isEasyPrivacyEnabled", .boolean).notNull().defaults(to: true)
                t.column("isEasyListCookieEnabled", .boolean).notNull().defaults(to: true)
                t.column("isMalwareFilterEnabled", .boolean).notNull().defaults(to: true)
            }

            // Space
            try db.create(table: "space") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("selectedTabID", .text)
                t.column("profileID", .text).notNull()
                    .references("profile")
            }

            // Tab
            try db.create(table: "tab") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("url", .text)
                t.column("title", .text).notNull().defaults(to: "New Tab")
                t.column("faviconURL", .text)
                t.column("interactionState", .blob)
                t.column("sortOrder", .integer).notNull()
                t.column("lastDeselectedAt", .double)
                t.column("parentID", .text)
                t.column("peekURL", .text)
                t.column("peekInteractionState", .blob)
                t.column("peekFaviconURL", .text)
            }

            // App state
            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

            // Closed tabs
            try db.create(table: "closedTab") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tabID", .text).notNull()
                t.column("spaceID", .text).notNull()
                t.column("url", .text)
                t.column("title", .text).notNull()
                t.column("faviconURL", .text)
                t.column("interactionState", .blob)
                t.column("sortOrder", .integer).notNull()
                t.column("archivedAt", .double)
            }

            // Downloads
            try db.create(table: "download") { t in
                t.primaryKey("id", .text)
                t.column("filename", .text).notNull()
                t.column("sourceURL", .text)
                t.column("destinationURL", .text).notNull()
                t.column("totalBytes", .integer).notNull().defaults(to: -1)
                t.column("bytesWritten", .integer).notNull().defaults(to: 0)
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }

            // Pinned folders
            try db.create(table: "pinnedFolder") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("parentFolderID", .text)
                    .references("pinnedFolder", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("isCollapsed", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull()
            }

            // Pinned tabs (slim: no duplicated tab fields, FK to tab)
            try db.create(table: "pinnedTab") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("pinnedURL", .text).notNull()
                t.column("pinnedTitle", .text).notNull()
                t.column("faviconURL", .text)
                t.column("sortOrder", .integer).notNull()
                t.column("folderID", .text)
                    .references("pinnedFolder", onDelete: .setNull)
                t.column("tabID", .text)
                    .references("tab", onDelete: .setNull)
            }

            // Content blocker whitelist
            try db.create(table: "contentBlockerWhitelist") { t in
                t.column("profileID", .text).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("host", .text).notNull()
                t.uniqueKey(["profileID", "host"])
            }
        }

        migrator.registerMigration("v2") { db in
            // Move extension tables from extensions.db into browser.db
            try db.create(table: "extension") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("version", .text).notNull()
                t.column("manifestJSON", .blob).notNull()
                t.column("basePath", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("installedAt", .double).notNull()
            }

            try db.create(table: "extensionStorage") { t in
                t.column("extensionID", .text).notNull()
                    .references("extension", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("value", .blob).notNull()
                t.primaryKey(["extensionID", "key"])
            }

            // Per-profile extension state. A missing row means the profile's
            // default, which since TASK-74 is off for the built-in Private
            // profile and on everywhere else — see
            // `extensionEnabledByDefault(inProfile:)`.
            try db.create(table: "profileExtension") { t in
                t.column("profileID", .text).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("extensionID", .text).notNull()
                    .references("extension", onDelete: .cascade)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.primaryKey(["profileID", "extensionID"])
            }
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "extensionPermission") { t in
                t.column("extensionID", .text).notNull()
                    .references("extension", onDelete: .cascade)
                t.column("permissionKey", .text).notNull()
                t.column("permissionType", .integer).notNull()
                t.column("status", .integer).notNull()
                t.column("grantedAt", .double).notNull()
                t.primaryKey(["extensionID", "permissionKey", "permissionType"])
            }
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "favorite") { t in
                t.primaryKey("id", .text)
                t.column("profileID", .text).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("faviconURL", .text)
                t.column("sortOrder", .integer).notNull()
                t.column("tabID", .text)
                    .references("tab", onDelete: .setNull)
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "profileExtension") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "tab") { t in
                t.add(column: "splitGroupID", .text)
                t.add(column: "splitFraction", .double)
            }
        }

        migrator.registerMigration("v7") { db in
            try db.alter(table: "pinnedTab") { t in
                t.add(column: "splitGroupID", .text)
                t.add(column: "splitFraction", .double)
            }
        }

        // TASK-24: the durable identity of an extension page. WebKit mints a fresh
        // webkit-extension://<uuid>/ origin per context load, so a stored URL on
        // its own is dead after a relaunch; the id (with the path/query/fragment
        // the URL already carries) lets restore rewrite it onto the current
        // context. NULL for every URL that is not an extension page.
        migrator.registerMigration("v8") { db in
            for table in ["tab", "pinnedTab", "favorite", "closedTab"] {
                try db.alter(table: table) { t in
                    t.add(column: "extensionID", .text)
                }
            }
            // Rows saved before the column existed have no id, and a NULL id on
            // an extension page is the marker for "the extension was uninstalled
            // since" — restore drops those tiles and closed-tab records. Without
            // this back-fill, upgrading Detour would silently delete every
            // extension-page pin and favourite the user already had. The
            // sentinel classifies as a disabled extension's page instead
            // (`classifyPersistedExtensionPage`): kept, but never restored as a
            // live tab, since nothing can tell which extension it belonged to.
            for (table, urlColumn) in [("tab", "url"), ("pinnedTab", "pinnedURL"),
                                       ("favorite", "url"), ("closedTab", "url")] {
                try db.execute(
                    sql: """
                        UPDATE "\(table)" SET extensionID = ?
                        WHERE extensionID IS NULL AND lower("\(urlColumn)") LIKE 'webkit-extension://%'
                        """,
                    arguments: [ExtensionPageURL.unknownExtensionID]
                )
            }
        }

        migrator.registerMigration("v9") { db in
            // runtime.onInstalled ledger (TASK-22, RuntimeInstalledEvent).
            try db.create(table: "extensionInstalledEvent") { t in
                t.column("extensionID", .text).notNull()
                t.column("profileID", .text).notNull()
                t.column("deliveredVersion", .text).notNull()
                t.column("deliveredAt", .double).notNull()
                t.primaryKey(["extensionID", "profileID"])
            }
            // Extensions installed before the ledger existed have had their
            // install (or WebKit's version of it) already: seed every saved
            // profile with the installed version, or upgrading Detour would
            // deliver `install` to all of them at the next launch. Profiles made
            // later have no row and get `install` when the extension first runs
            // there, which is Chrome's per-profile rule.
            try db.execute(sql: """
                INSERT INTO extensionInstalledEvent (extensionID, profileID, deliveredVersion, deliveredAt)
                SELECT e.id, p.id, e.version, ? FROM "extension" e CROSS JOIN profile p
                """, arguments: [Date().timeIntervalSince1970])
        }

        migrator.registerMigration("v10") { db in
            // TASK-29: a reinstall owes an `update` even at the same version, which a
            // version-only ledger cannot tell from a reload.
            try db.alter(table: "extensionInstalledEvent") { t in
                t.add(column: "reinstallPending", .boolean).notNull().defaults(to: false)
            }
            // The Private profile never gets runtime.onInstalled, so the rows v9
            // seeded for it are dead. The literal is TabStore.incognitoProfileID,
            // spelled out so this migration cannot change meaning later.
            try db.execute(sql: "DELETE FROM extensionInstalledEvent WHERE profileID = ?",
                           arguments: ["00000000-0000-0000-0000-000000000001"])
        }

        migrator.registerMigration("v11") { db in
            // TASK-32: deleted profiles whose on-disk WebKit data (the
            // WKWebsiteDataStore and extension controller storage for the profile
            // id) has not been removed yet. No foreign key: the profile row is
            // already gone when a row is added here.
            try db.create(table: "pendingProfileDataRemoval") { t in
                t.primaryKey("profileID", .text)
                t.column("requestedAt", .double).notNull()
            }
        }

        migrator.registerMigration("v12") { db in
            // TASK-36: WebKit storage identifiers an isolated data directory
            // (DETOUR_DATA_DIR other than "Detour") created, so it can remove
            // exactly what it created from the WebKit directory it shares with
            // the production app. The default data directory records nothing.
            try db.create(table: "webKitStorageIdentifier") { t in
                t.primaryKey("identifier", .text)
                t.column("profileID", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
        }

        migrator.registerMigration("v13") { db in
            // TASK-44: drop every nativeMessaging denial saved before TASK-25 made
            // such a row enforceable. The old Settings switch showed OFF across
            // relaunches and pushed a context-level denial for the session, but
            // native-host dispatch never read the row — so it is not a decision to
            // lose native messaging, and honouring it now would silently start
            // refusing every real host on upgrade (1Password's desktop-app unlock
            // first of all). Long-form rationale:
            // docs/1password-integration-plan.md, next to the TASK-25 decision.
            //
            // The literals are ExtensionPermissionType.apiPermission.rawValue (0)
            // and ExtensionPermissionRecord.nativeMessagingKey; `status <> 0` is
            // "not ExtensionPermissionStatus.granted.rawValue", i.e. every row the
            // readers treat as a denial — `permissionStatus` / `statusByKey` fail
            // closed to `.denied` on an unrecognised status. All spelled out so
            // renaming or renumbering those enums cannot change what is deleted.
            try db.execute(sql: """
                DELETE FROM extensionPermission
                WHERE permissionType = 0 AND permissionKey = 'nativeMessaging' AND status <> 0
                """)
        }

        migrator.registerMigration("v14") { db in
            // TASK-84: "Always allow <origin> to open <scheme> links" decisions.
            // Never written for the Private profile.
            try db.create(table: "externalAppPermission") { t in
                t.column("profileID", .text).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("origin", .text).notNull()
                t.column("scheme", .text).notNull()
                t.uniqueKey(["profileID", "origin", "scheme"])
            }
        }

        migrator.registerMigration("v15") { db in
            // TASK-117: the closed-tab stack is read from the DB only — serve the
            // per-space newest-first scan (menu validation, Reopen Closed Tab).
            try db.create(index: "closedTab_on_spaceID_id", on: "closedTab", columns: ["spaceID", "id"])
        }

        migrator.registerMigration("v16") { db in
            // TASK-116: when the tab was closed, on every record. Timer/manual
            // archives already carried archivedAt; backfill from it. Older plain
            // closes stay NULL and keep sorting by id.
            try db.alter(table: "closedTab") { t in t.add(column: "closedAt", .double) }
            try db.execute(sql: "UPDATE closedTab SET closedAt = archivedAt WHERE archivedAt IS NOT NULL")
        }

        migrator.registerMigration("v17") { db in
            // TASK-113: where an extension came from, where its updates are
            // polled, the folder an unpacked one reloads from, and an update's
            // not-yet-accepted new permissions (`ExtensionRecord`).
            try db.alter(table: "extension") { t in
                t.add(column: "source", .text).notNull().defaults(to: "unpacked")
                t.add(column: "updateURL", .text)
                t.add(column: "sourcePath", .text)
                t.add(column: "pendingPermissionApprovalJSON", .blob)
            }
            // Classify the installs that predate the column. The stored
            // manifestJSON never carried update_url (the model had no field), so
            // the on-disk manifest is read; an install whose folder is gone falls
            // back to the id: a CRX id is 32 letters a–p, an unpacked install
            // without a manifest key got a UUID. Literals rather than
            // `ExtensionSource` so a later rename cannot change what this wrote.
            let rows = try Row.fetchAll(db, sql: "SELECT id, basePath FROM extension")
            for row in rows {
                let id: String = row["id"]
                let basePath: String = row["basePath"]
                let manifestURL = URL(fileURLWithPath: basePath).appendingPathComponent("manifest.json")
                let manifest = (try? Data(contentsOf: manifestURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let declaredUpdateURL = (manifest?["update_url"] as? String).flatMap(URL.init(string:))
                let looksLikeCRXID = id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
                // A manifest `key` on disk pins an unpacked extension's id to the
                // same 32-letter shape a CRX gets, and a developer's copy of a
                // store manifest carries `update_url` too. The two cannot be told
                // apart, so a keyed manifest reads as unpacked: the wrong call the
                // other way would replace a developer's folder with the store's
                // CRX on the next poll, while this way only costs a store install
                // its auto-update (reinstalling from the store restores it).
                let hasManifestKey = manifest?["key"] is String
                let source: String
                let updateURL: String?
                if let declaredUpdateURL, looksLikeCRXID, !hasManifestKey {
                    let host = declaredUpdateURL.host?.lowercased() ?? ""
                    // On the domain boundary: "clients2.google.com" is the store,
                    // "notgoogle.com" is not.
                    let isUnder = { (domain: String) in host == domain || host.hasSuffix("." + domain) }
                    source = isUnder("google.com") || isUnder("googleusercontent.com") ? "webStore" : "crx"
                    updateURL = declaredUpdateURL.absoluteString
                } else if manifest == nil, looksLikeCRXID {
                    // The folder is gone but the id shape says CRX; the store is
                    // the only place such an id could have come from without a
                    // manifest key on disk to say otherwise.
                    source = "webStore"
                    updateURL = "https://clients2.google.com/service/update2/crx"
                } else {
                    source = "unpacked"
                    updateURL = nil
                }
                try db.execute(sql: "UPDATE extension SET source = ?, updateURL = ? WHERE id = ?",
                               arguments: [source, updateURL, id])
            }
        }

        return migrator
    }

    // MARK: - Favorites

    func saveFavorites(_ records: [FavoriteRecord], profileID: String) {
        performWrite("save favorites") { db in
            try Self.writeFavorites(records, profileID: profileID, in: db)
        }
    }

    private static func writeFavorites(_ records: [FavoriteRecord], profileID: String, in db: GRDB.Database) throws {
        try FavoriteRecord
            .filter(Column("profileID") == profileID)
            .deleteAll(db)
        for record in records {
            try record.insert(db)
        }
    }

    func loadFavorites(profileID: String) -> [FavoriteRecord] {
        performRead("load favorites", default: []) { db in
            try FavoriteRecord
                .filter(Column("profileID") == profileID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    // MARK: - Extension CRUD

    func saveExtension(_ record: ExtensionRecord) {
        performWrite("save extension") { db in
            try record.save(db)
        }
    }

    func loadExtensions() -> [ExtensionRecord] {
        performRead("load extensions", default: []) { db in
            try ExtensionRecord.fetchAll(db)
        }
    }

    func deleteExtension(id: String) {
        performWrite("delete extension") { db in
            try ExtensionRecord.filter(Column("id") == id).deleteAll(db)
            // A reinstall under the same id (a manifest key) is a new install.
            try ExtensionInstalledEventRecord.filter(Column("extensionID") == id).deleteAll(db)
        }
    }

    /// Record or clear the new permissions an update is waiting on (TASK-113).
    func setExtensionPendingPermissionApproval(id: String, json: Data?) {
        performWrite("set extension pending permission approval") { db in
            try db.execute(sql: "UPDATE extension SET pendingPermissionApprovalJSON = ? WHERE id = ?",
                           arguments: [json, id])
        }
    }

    private static let extensionUpdateLastCheckKey = "extensionUpdateLastCheckAt"

    /// When the last scheduled or manual update check finished, across launches.
    func extensionUpdateLastCheckAt() -> Date? {
        performRead("read extension update last check", default: nil) { db in
            try Double.fetchOne(db, sql: "SELECT CAST(value AS REAL) FROM appState WHERE key = ?",
                                arguments: [Self.extensionUpdateLastCheckKey])
                .map { Date(timeIntervalSince1970: $0) }
        }
    }

    func setExtensionUpdateLastCheckAt(_ date: Date) {
        performWrite("save extension update last check") { db in
            try db.execute(
                sql: "INSERT INTO appState (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [Self.extensionUpdateLastCheckKey, String(date.timeIntervalSince1970)]
            )
        }
    }

    // MARK: - runtime.onInstalled ledger

    /// The `runtime.onInstalled` event the extension's context in `profileID`
    /// still owes, without delivering it. See `RuntimeInstalledEvent`.
    /// `isPrivateProfile` is the profile's `isIncognito`: the Private profile is
    /// never owed the event (TASK-29).
    func pendingRuntimeInstalledEvent(extensionID: String, profileID: String, isPrivateProfile: Bool,
                                      currentVersion: String) -> RuntimeInstalledEvent.Details? {
        guard !isPrivateProfile else { return nil }
        return performRead("read runtime.onInstalled ledger", default: nil) { db in
            let entry = try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == extensionID && Column("profileID") == profileID)
                .fetchOne(db)?.ledgerEntry
            return RuntimeInstalledEvent.pending(ledger: entry, currentVersion: currentVersion,
                                                 isPrivateProfile: false)
        }
    }

    /// Take the owed `runtime.onInstalled` event, if any, and record it delivered —
    /// read and write in one transaction, so of any number of claims for the same
    /// version exactly one gets the event. The ledger advances *before* the worker
    /// dispatches: a worker that dies in between loses the event rather than
    /// risking it twice (Chrome drops its pending dispatch at the same point).
    /// Delivering clears a pending reinstall. Returns nil when nothing is owed —
    /// always for the Private profile, which is never written — or the write fails.
    ///
    /// Whether a claim should be made at all is the caller's decision
    /// (`RuntimeInstalledEvent.claimDisposition`, TASK-134): an event is recorded
    /// as delivered when the claiming context had a listener for it, or had none
    /// and its background content did not fail to load. A claim from a context
    /// whose script threw before registering a listener is not made, or is taken
    /// back with `undoRuntimeInstalledEventClaim`.
    func claimRuntimeInstalledEvent(extensionID: String, profileID: String, isPrivateProfile: Bool,
                                    currentVersion: String) -> RuntimeInstalledEvent.Details? {
        claimRuntimeInstalledEventKeepingPrevious(extensionID: extensionID, profileID: profileID,
                                                  isPrivateProfile: isPrivateProfile,
                                                  currentVersion: currentVersion)?.details
    }

    /// `claimRuntimeInstalledEvent`, also returning the row the claim replaced
    /// and the one it wrote, so the claim can be undone.
    func claimRuntimeInstalledEventKeepingPrevious(extensionID: String, profileID: String, isPrivateProfile: Bool,
                                                   currentVersion: String) -> RuntimeInstalledEventClaim? {
        guard !isPrivateProfile else { return nil }
        return performWrite("claim runtime.onInstalled event", default: nil) { db in
            let previous = try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == extensionID && Column("profileID") == profileID)
                .fetchOne(db)
            guard let details = RuntimeInstalledEvent.pending(ledger: previous?.ledgerEntry, currentVersion: currentVersion,
                                                              isPrivateProfile: false) else {
                return nil
            }
            let written = ExtensionInstalledEventRecord(
                extensionID: extensionID, profileID: profileID,
                deliveredVersion: currentVersion, deliveredAt: Date().timeIntervalSince1970,
                reinstallPending: false
            )
            try written.save(db)
            return RuntimeInstalledEventClaim(details: details, previous: previous, written: written)
        }
    }

    /// Take a claim back: put the ledger row as it was before `claim`, so the
    /// event it answered is owed again. Only while the row is still exactly what
    /// the claim wrote — a later claim, a reinstall mark or a removed extension
    /// has moved the ledger on, and is left alone. Returns whether it was undone.
    @discardableResult
    func undoRuntimeInstalledEventClaim(_ claim: RuntimeInstalledEventClaim) -> Bool {
        performWrite("undo runtime.onInstalled claim", default: false) { db in
            let written = claim.written
            let current = try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == written.extensionID && Column("profileID") == written.profileID)
                .fetchOne(db)
            guard current == written else { return false }
            if let previous = claim.previous {
                try previous.save(db)
            } else {
                _ = try ExtensionInstalledEventRecord
                    .filter(Column("extensionID") == written.extensionID && Column("profileID") == written.profileID)
                    .deleteAll(db)
            }
            return true
        }
    }

    /// Record that the user reinstalled the extension (TASK-29): each profile the
    /// event was already delivered in is owed one `update` from that version, even
    /// when the version did not change. Profiles without a row still get `install`.
    /// Only `ExtensionManager.install` calls this — never a reload or an enable.
    func markRuntimeInstalledEventReinstalled(extensionID: String) {
        performWrite("mark runtime.onInstalled reinstall") { db in
            try db.execute(sql: "UPDATE extensionInstalledEvent SET reinstallPending = 1 WHERE extensionID = ?",
                           arguments: [extensionID])
        }
    }

    func setEnabled(id: String, enabled: Bool) {
        performWrite("update extension enabled state") { db in
            try db.execute(
                sql: "UPDATE \"extension\" SET isEnabled = ? WHERE id = ?",
                arguments: [enabled, id]
            )
        }
    }

    // MARK: - chrome.storage.local

    func storageGet(extensionID: String, keys: [String]) -> [String: Any] {
        performRead("get extension storage", default: [:]) { db in
            var result: [String: Any] = [:]
            for key in keys {
                if let record = try ExtensionStorageRecord
                    .filter(Column("extensionID") == extensionID && Column("key") == key)
                    .fetchOne(db) {
                    if let value = try? JSONSerialization.jsonObject(with: record.value, options: .fragmentsAllowed) {
                        result[key] = value
                    }
                }
            }
            return result
        }
    }

    func storageGetAll(extensionID: String) -> [String: Any] {
        performRead("get all extension storage", default: [:]) { db in
            var result: [String: Any] = [:]
            let records = try ExtensionStorageRecord
                .filter(Column("extensionID") == extensionID)
                .fetchAll(db)
            for record in records {
                if let value = try? JSONSerialization.jsonObject(with: record.value, options: .fragmentsAllowed) {
                    result[record.key] = value
                }
            }
            return result
        }
    }

    func storageSet(extensionID: String, items: [String: Any]) {
        performWrite("set extension storage") { db in
            for (key, value) in items {
                let jsonData = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                let record = ExtensionStorageRecord(
                    extensionID: extensionID,
                    key: key,
                    value: jsonData
                )
                try record.save(db)
            }
        }
    }

    func storageRemove(extensionID: String, keys: [String]) {
        performWrite("remove extension storage") { db in
            for key in keys {
                try ExtensionStorageRecord
                    .filter(Column("extensionID") == extensionID && Column("key") == key)
                    .deleteAll(db)
            }
        }
    }

    func storageClear(extensionID: String) {
        performWrite("clear extension storage") { db in
            try ExtensionStorageRecord
                .filter(Column("extensionID") == extensionID)
                .deleteAll(db)
        }
    }

    // MARK: - Extension Permissions

    /// A user decision (prompt or Settings): replaces any saved row for the key.
    func savePermission(_ record: ExtensionPermissionRecord) {
        savePermissions([record])
    }

    /// User decisions (prompt or Settings): each replaces any saved row for its key.
    func savePermissions(_ records: [ExtensionPermissionRecord]) {
        writePermissions(records, label: "save extension permissions") { try $0.save($1) }
    }

    /// Records manifest-declared permissions without touching a saved decision:
    /// a row that already exists (granted or denied, by prompt or in Settings)
    /// is left as is; only keys with no row yet are inserted. Install/update
    /// use this (TASK-63); a user decision goes through `savePermission(s)`.
    ///
    /// The insert ignores a conflict on the table's composite primary key
    /// (extensionID, permissionKey, permissionType), so a conflict is exactly
    /// "this key already has a decision".
    func recordDeclaredPermissions(_ records: [ExtensionPermissionRecord]) {
        writePermissions(records, label: "record declared extension permissions") {
            try $0.insert($1, onConflict: .ignore)
        }
    }

    private func writePermissions(_ records: [ExtensionPermissionRecord], label: String,
                                  _ write: (ExtensionPermissionRecord, GRDB.Database) throws -> Void) {
        performWrite(label) { db in
            for record in records {
                try write(record, db)
            }
        }
    }

    /// Every saved decision for an extension. Callers partition by type with
    /// `statusByKey(type:)` — never merge types, since a `.url` row can share
    /// its key string with a `.matchPattern` row.
    func loadPermissions(extensionID: String) -> [ExtensionPermissionRecord] {
        performRead("load extension permissions", default: []) { db in
            try ExtensionPermissionRecord
                .filter(Column("extensionID") == extensionID)
                .fetchAll(db)
        }
    }

    /// The saved decision for one key, or nil when none is saved.
    func permissionStatus(extensionID: String, key: String, type: ExtensionPermissionType) -> ExtensionPermissionStatus? {
        performRead("check extension permission", default: nil) { db in
            if let record = try ExtensionPermissionRecord
                .filter(Column("extensionID") == extensionID
                    && Column("permissionKey") == key
                    && Column("permissionType") == type.rawValue)
                .fetchOne(db) {
                // An unrecognised raw status fails closed, as `statusByKey` does:
                // a present-but-unreadable row must not read as "no decision".
                return ExtensionPermissionStatus(rawValue: record.status) ?? .denied
            }
            return nil
        }
    }

    func revokePermission(extensionID: String, key: String, type: ExtensionPermissionType) {
        performWrite("revoke extension permission") { db in
            try ExtensionPermissionRecord
                .filter(Column("extensionID") == extensionID
                    && Column("permissionKey") == key
                    && Column("permissionType") == type.rawValue)
                .deleteAll(db)
        }
    }

    // MARK: - Per-Profile Extension State

    /// `performRead` labels for the two enabled-state queries, so a test can
    /// count them by label without hard-coding the strings (TASK-46).
    static let isExtensionEnabledReadLabel = "check extension enabled for profile"
    static let enabledExtensionIDsReadLabel = "load enabled extension IDs for profile"

    /// What a missing `profileExtension` row means for this profile: on
    /// everywhere except the built-in Private profile, where it means off
    /// (TASK-74).
    ///
    /// Chrome's incognito default, and when it landed it was more than a
    /// convention: the Private profile's extension pages then ran in WebKit's
    /// default *persistent* store, so an extension allowed in Private kept its
    /// storage, caches and cookies after the private session ended. TASK-73 has
    /// since moved those pages to the profile's own ephemeral store, but the
    /// default stands on its own — opting in per extension ("Allow in Private"
    /// in Extension settings) is the state the user can be presumed to want.
    /// No migration was needed: the live DB had no `profileExtension`
    /// rows for the Private profile at all, so flipping the default is exactly
    /// the behaviour change, and a user who had explicitly allowed one would
    /// have a row that still reads ON.
    static func extensionEnabledByDefault(inProfile profileID: String) -> Bool {
        UUID(uuidString: profileID) != TabStore.incognitoProfileID
    }

    /// Check if an extension is enabled for a specific profile.
    /// True if globally enabled AND (the per-profile row says so, or there is no
    /// row and the profile's default is on — see `extensionEnabledByDefault(inProfile:)`).
    func isExtensionEnabled(extensionID: String, profileID: String) -> Bool {
        let byDefault = Self.extensionEnabledByDefault(inProfile: profileID)
        return performRead(Self.isExtensionEnabledReadLabel, default: false) { db in
            // Check global enabled first
            guard let ext = try ExtensionRecord.filter(Column("id") == extensionID).fetchOne(db),
                  ext.isEnabled else {
                return false
            }
            // Check per-profile override
            if let row = try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db) {
                return row.isEnabled
            }
            return byDefault // missing row = the profile's default
        }
    }

    /// The profile's own choice, ignoring the global flag: the row's value, or
    /// the profile's default when it has no row
    /// (`extensionEnabledByDefault(inProfile:)` — on, except in Private).
    func isExtensionEnabledByProfile(extensionID: String, profileID: String) -> Bool {
        let byDefault = Self.extensionEnabledByDefault(inProfile: profileID)
        return performRead("check profile extension enabled row", default: byDefault) { db in
            try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db)?.isEnabled ?? byDefault
        }
    }

    /// Upsert per-profile extension enabled state.
    func setProfileExtensionEnabled(extensionID: String, profileID: String, enabled: Bool) {
        performWrite("set profile extension enabled") { db in
            if var existing = try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db) {
                existing.isEnabled = enabled
                try existing.update(db)
            } else {
                try ProfileExtensionRecord(profileID: profileID, extensionID: extensionID, isEnabled: enabled, isPinned: false).insert(db)
            }
        }
    }

    /// Returns extension IDs that are pinned for this profile.
    func pinnedExtensionIDs(for profileID: String) -> [String] {
        performRead("load pinned extension IDs", default: []) { db in
            try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("isPinned") == true)
                .fetchAll(db)
                .map(\.extensionID)
        }
    }

    /// Toggle the pinned state for an extension in a single transaction.
    func toggleExtensionPinned(extensionID: String, profileID: String) {
        performWrite("toggle extension pinned") { db in
            if var existing = try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db) {
                existing.isPinned = !existing.isPinned
                try existing.update(db)
            } else {
                // A pin must not decide the enabled flag: the fresh row carries
                // the profile's default, so pinning in Private does not silently
                // allow the extension there (TASK-74).
                try ProfileExtensionRecord(profileID: profileID, extensionID: extensionID,
                                           isEnabled: Self.extensionEnabledByDefault(inProfile: profileID),
                                           isPinned: true).insert(db)
            }
        }
    }

    /// Ids of every installed extension, enabled or not.
    func installedExtensionIDs() -> Set<String> {
        performRead("load installed extension IDs", default: []) { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM \"extension\""))
        }
    }

    /// Returns the set of extension IDs that are enabled for this profile.
    ///
    /// The same rule as `isExtensionEnabled(extensionID:profileID:)`, in one
    /// query: globally enabled AND (the profile's row, or with no row the profile's
    /// default — `extensionEnabledByDefault(inProfile:)`, off in Private). An id with no `extension`
    /// row is in neither answer. Ids only — neither row is decoded as a record,
    /// so the `extension` table's `manifestJSON` blob is never read for this
    /// answer (TASK-46).
    func enabledExtensionIDs(for profileID: String) -> Set<String> {
        let byDefault = Self.extensionEnabledByDefault(inProfile: profileID)
        return performRead(Self.enabledExtensionIDsReadLabel, default: []) { db in
            let globallyEnabled = try ExtensionRecord
                .filter(Column("isEnabled") == true)
                .select(Column("id"), as: String.self)
                .fetchSet(db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT extensionID, isEnabled FROM profileExtension WHERE profileID = ?
                """, arguments: [profileID])
            let choices = Dictionary(uniqueKeysWithValues: rows.map { ($0["extensionID"] as String, $0["isEnabled"] as Bool) })
            return globallyEnabled.filter { choices[$0] ?? byDefault }
        }
    }
}
