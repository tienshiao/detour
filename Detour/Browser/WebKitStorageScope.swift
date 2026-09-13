import CryptoKit
import Foundation
import GRDB
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "profiles")

/// Names, records and removes the persistent WebKit storage of one Detour data
/// directory (TASK-36).
///
/// WebKit keeps identifier stores (`WKWebsiteDataStore(forIdentifier:)`) and
/// persistent extension controllers under `~/Library/WebKit/<bundle id>/`, keyed
/// by bundle id, not by `DETOUR_DATA_DIR`. The test host and every isolated app
/// run share the production app's bundle id, so they would share, and pile up
/// directories in, the production app's WebKit directory. The bundle id stays
/// (Sparkle, keychain items, native messaging manifests and the 1Password
/// browser trust all depend on it); instead the WebKit identifier depends on the
/// data directory:
///
/// - In the default data directory ("Detour", or `DETOUR_DATA_DIR` unset) it is
///   the profile id, so production data keeps its existing stores.
/// - In any other data directory it is a name-based UUID (version 5) over a
///   fixed Detour namespace, the data directory name and the profile id. The
///   same data directory gets the same stores across launches, and no identifier
///   can equal a production profile id (those are random, version 4).
///
/// An isolated data directory records every identifier in its own database
/// before WebKit creates storage for it, so it can later remove exactly what it
/// created (`removeRecordedStorage`) and nothing else.
struct WebKitStorageScope {

    /// Fixed namespace of the version 5 identifiers. Never change it: the
    /// identifiers isolated data directories already created would be orphaned.
    static let namespace = UUID(uuidString: "9DC6C971-6D72-44C8-9541-D6DEBE44E0A3")!

    /// The data directory name of this process. `DETOUR_DATA_DIR` does not change
    /// while the process runs.
    static let currentDataDirectoryName = detourDataDirectoryName()

    /// Whether this process runs in the production data directory. Unlike the
    /// instance property it needs no registry, so it can be asked before the
    /// database exists (AppDelegate decides whether to start Sparkle with it).
    static let currentIsDefaultDataDirectory = currentDataDirectoryName == defaultDetourDataDirectoryName

    /// The scope of this process's data directory.
    static var current: WebKitStorageScope {
        WebKitStorageScope(dataDirectoryName: currentDataDirectoryName, registry: .shared)
    }

    let dataDirectoryName: String
    /// The data directory's own database, where an isolated data directory
    /// records the identifiers it creates.
    let registry: AppDatabase
    /// The profile ids in the production database, or nil when it cannot be
    /// read. A last guard before any removal in an isolated data directory.
    var productionProfileIDs: () -> Set<UUID>? = { WebKitStorageScope.readProductionProfileIDs() }

    var isDefaultDataDirectory: Bool {
        dataDirectoryName == defaultDetourDataDirectoryName
    }

    // MARK: - Identifiers

    /// The WebKit identifier of `profileID`'s website data store and extension
    /// controller in the data directory `dataDirectoryName`.
    static func identifier(profileID: UUID, dataDirectoryName: String) -> UUID {
        guard dataDirectoryName != defaultDetourDataDirectoryName else { return profileID }
        return nameBasedUUIDv5(namespace: namespace, name: "\(dataDirectoryName)/\(profileID.uuidString)")
    }

    func identifier(forProfile profileID: UUID) -> UUID {
        Self.identifier(profileID: profileID, dataDirectoryName: dataDirectoryName)
    }

    /// The identifier to create persistent storage with. An isolated data
    /// directory records it first, so a crash between the two still leaves a
    /// record to clean up with.
    func identifierForCreatingStorage(forProfile profileID: UUID) -> UUID {
        let identifier = identifier(forProfile: profileID)
        if !isDefaultDataDirectory {
            registry.recordWebKitStorageIdentifier(identifier, profileID: profileID)
        }
        return identifier
    }

    /// RFC 4122 §4.3 name-based UUID, SHA-1, version 5.
    static func nameBasedUUIDv5(namespace: UUID, name: String) -> UUID {
        var input = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        input.append(contentsOf: Array(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: input).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func version(of uuid: UUID) -> Int {
        Int(uuid.uuid.6 >> 4)
    }

    // MARK: - Removal guard

    /// Why this isolated data directory must not remove the storage of
    /// `identifier`, or nil when it may. Removal is only ever allowed for an
    /// identifier that
    /// - belongs to an isolated data directory (never the default one),
    /// - is recorded in this data directory's database,
    /// - is version 5 and derives from the recorded profile id and this data
    ///   directory's name,
    /// - equals no profile id in the production database, which must be readable.
    func refusalToRemove(identifier: UUID, productionProfileIDs knownProductionIDs: Set<UUID>?? = nil) -> String? {
        guard !isDefaultDataDirectory else {
            return "the default data directory's storage is removed only through ProfileDataRemoval"
        }
        guard let profileID = registry.recordedWebKitStorageProfileID(for: identifier) else {
            return "not recorded in data directory \(dataDirectoryName)"
        }
        guard Self.version(of: identifier) == 5,
              Self.identifier(profileID: profileID, dataDirectoryName: dataDirectoryName) == identifier else {
            return "not derived from data directory \(dataDirectoryName)"
        }
        guard let productionIDs = knownProductionIDs ?? productionProfileIDs() else {
            return "the production profile table could not be read"
        }
        guard !productionIDs.contains(identifier) else {
            return "equals a production profile id"
        }
        return nil
    }

    /// The production database, `~/Library/Application Support/Detour/browser.db`.
    static var productionDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultDetourDataDirectoryName, isDirectory: true)
            .appendingPathComponent("browser.db")
    }

    /// Profile ids in the production database. An absent database has no
    /// profiles; one that exists but cannot be read gives nil.
    ///
    /// The production app may be running, and its database uses a rollback
    /// journal with GRDB's default immediate-error busy mode: a shared lock held
    /// by this read could make one of its writes fail. So the file is never
    /// opened in place. Its bytes are copied without any SQLite lock, while no
    /// hot journal exists and the file does not change during the copy, and the
    /// copy is opened read-only.
    static func readProductionProfileIDs(databaseURL: URL = productionDatabaseURL) -> Set<UUID>? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else { return [] }
        let journalPath = databaseURL.path + "-journal"
        let copyURL = fileManager.temporaryDirectory
            .appendingPathComponent("detour-production-profiles-\(UUID().uuidString).db")
        defer { try? fileManager.removeItem(at: copyURL) }

        func fingerprint() -> String? {
            guard let attributes = try? fileManager.attributesOfItem(atPath: databaseURL.path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return "\(size)-\(modified.timeIntervalSinceReferenceDate)"
        }

        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
            guard !fileManager.fileExists(atPath: journalPath), let before = fingerprint(),
                  let bytes = try? Data(contentsOf: databaseURL),
                  !fileManager.fileExists(atPath: journalPath), fingerprint() == before else { continue }
            do {
                try bytes.write(to: copyURL)
                var configuration = Configuration()
                configuration.readonly = true
                let queue = try DatabaseQueue(path: copyURL.path, configuration: configuration)
                let ids = try queue.read { db in
                    try String.fetchAll(db, sql: "SELECT id FROM profile")
                }
                return Set(ids.compactMap(UUID.init(uuidString:)))
            } catch {
                log.error("Could not read production profile ids: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        log.error("Could not read production profile ids: the database kept changing")
        return nil
    }

    // MARK: - Cleanup

    struct CleanupReport: Equatable {
        var removed: Set<UUID> = []
        /// Identifier → why it was kept (still in use, refused by the guard).
        /// Kept identifiers stay recorded.
        var kept: [UUID: String] = [:]
    }

    /// Removes the storage of every identifier recorded in this isolated data
    /// directory, except those of `excludingProfileIDs` (profiles alive in this
    /// process), and forgets each one removed. Every identifier passes
    /// `refusalToRemove` right before its WebKit calls. The website data store
    /// goes first: WebKit refuses it while a store object or a web view still
    /// uses it (an extension controller retains its store), so that refusal keeps
    /// a live controller's directory in place too. In-use failures are retried
    /// after each of `retryDelays`.
    @MainActor
    func removeRecordedStorage(
        excludingProfileIDs: Set<UUID> = [],
        remover: ProfileDataRemoval.Remover = .webKit,
        retryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4]
    ) async -> CleanupReport {
        var report = CleanupReport()
        guard !isDefaultDataDirectory else { return report }

        let excluded = Set(excludingProfileIDs.map { identifier(forProfile: $0) })
        let productionIDs = productionProfileIDs()
        var pending: [UUID] = []
        for identifier in registry.recordedWebKitStorageIdentifiers() {
            if excluded.contains(identifier) {
                report.kept[identifier] = "a live profile's storage"
            } else {
                pending.append(identifier)
            }
        }

        for delay in [0] + retryDelays {
            guard !pending.isEmpty else { break }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var stillInUse: [UUID] = []
            for identifier in pending {
                if let refusal = refusalToRemove(identifier: identifier, productionProfileIDs: productionIDs) {
                    log.error("Not removing WebKit storage \(identifier.uuidString, privacy: .public): \(refusal, privacy: .public)")
                    report.kept[identifier] = refusal
                    continue
                }
                do {
                    try await remover.removeWebsiteDataStore(identifier)
                    try await remover.removeExtensionData(identifier)
                    registry.forgetWebKitStorageIdentifier(identifier)
                    report.kept[identifier] = nil
                    report.removed.insert(identifier)
                } catch {
                    report.kept[identifier] = error.localizedDescription
                    stillInUse.append(identifier)
                }
            }
            pending = stillInUse
        }
        if !report.removed.isEmpty || !report.kept.isEmpty {
            log.info("Data dir \(dataDirectoryName, privacy: .public): removed \(report.removed.count) WebKit storage identifier(s), kept \(report.kept.count)")
        }
        return report
    }
}
