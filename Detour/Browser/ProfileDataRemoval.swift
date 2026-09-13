import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "profiles")

/// Removes a deleted profile's on-disk WebKit data (TASK-32): the
/// `WKWebsiteDataStore` for the profile's WebKit storage identifier (cookies,
/// local storage, IndexedDB, caches, service workers) and the storage of the
/// profile's `WKWebExtensionController`, which is configured with the same
/// identifier. The identifier is the profile id in the default data directory
/// and derived from the data directory elsewhere (`WebKitStorageScope`, TASK-36).
///
/// WebKit behaviour this relies on, measured on macOS 26 (Xcode 26.3 SDK):
/// - `WKWebsiteDataStore.remove(forIdentifier:)` fails with "Data store is in
///   use" while any `WKWebsiteDataStore` object for the identifier is alive, and
///   with "Data store is in use (by network process)" for a short while after
///   the last web view that used it is released (about 0.25 s in the test
///   host). A store that never hosted a web view is removable at once, and so is
///   an identifier with no store at all.
/// - Once it succeeds, `allDataStoreIdentifiers` no longer lists the identifier
///   and `~/Library/WebKit/<bundle id>/WebsiteDataStore/<uuid>/` is gone.
/// - It does not touch the extension controller's directory,
///   `~/Library/WebKit/<bundle id>/WebExtensions/<UUID>/`, which holds one
///   folder per extension (`LocalStorage.db` for `storage.local`, `State.plist`).
///   A fresh controller configured with the identifier lists the data records of
///   extensions that are not loaded, and `removeData(ofTypes:from:)` empties the
///   storage; the directory and each `State.plist` stay, so the directory is
///   deleted by path afterwards.
///
/// Ordering is the caller's job: everything that holds the store or the
/// controller (web views, extension contexts, the `Profile` itself) must be
/// released first. The removal then runs on a later main-actor turn and retries
/// the in-use failures with backoff. A pending row in `browser.db` (recorded in
/// the same transaction that deletes the profile row) is cleared only on
/// success, and `retryPendingRemovals()` runs at launch for rows left behind.
final class ProfileDataRemoval {

    /// The WebKit side, injectable so tests can simulate failures and successes
    /// without touching real data stores. Both closures take the WebKit storage
    /// identifier (`WebKitStorageScope.identifier(forProfile:)`), which is the
    /// profile id only in the default data directory.
    struct Remover {
        /// Removes the extension controller data kept for the identifier.
        var removeExtensionData: @MainActor (UUID) async throws -> Void
        /// Removes the website data store for the identifier.
        var removeWebsiteDataStore: @MainActor (UUID) async throws -> Void

        /// The real WebKit calls. `ProfileDataRemoval` and
        /// `WebKitStorageScope.removeRecordedStorage` decide which identifiers
        /// reach them.
        static let webKit = Remover(
            removeExtensionData: { identifier in
                try await ProfileDataRemoval.removeWebKitExtensionControllerData(identifier: identifier)
            },
            removeWebsiteDataStore: { identifier in
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
            }
        )
    }

    enum Outcome: Equatable {
        /// Both the extension data and the website data store are gone; the
        /// pending row is cleared.
        case removed
        /// Nothing was removed because the id is the Private profile or a
        /// profile that exists (in memory or in the profile table). The pending
        /// row is cleared: it can never become removable.
        case refusedLiveProfile
        /// Nothing was removed because the app runs in an isolated data
        /// directory that never recorded creating WebKit storage for this
        /// profile (TASK-36), so there is nothing of its own to remove. The
        /// pending row is cleared: retrying every launch would be pointless.
        case skippedUnrecordedStorage
        /// Every attempt failed, or the profile table could not be read. The
        /// pending row stays for the next launch.
        case failed(String)
    }

    static let defaultRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8]

    private let appDB: AppDatabase
    private let remover: Remover
    private let retryDelays: [TimeInterval]
    private let storageScope: WebKitStorageScope

    /// Ids of the profiles alive in memory (`TabStore.profiles`). Checked, with
    /// the profile table, before every removal attempt.
    var inMemoryProfileIDs: () -> Set<UUID> = { [] }

    /// `storageScope` names each profile's WebKit identifier and, outside the
    /// default data directory, holds the records that gate removal. It is the
    /// process's data directory unless a test injects another.
    init(appDB: AppDatabase, remover: Remover = .webKit, retryDelays: [TimeInterval] = defaultRetryDelays,
         storageScope: WebKitStorageScope = .current) {
        self.appDB = appDB
        self.remover = remover
        self.retryDelays = retryDelays
        self.storageScope = storageScope
    }

    /// Removes the data of a profile that has just been deleted. The caller has
    /// already deleted the profile row (which recorded the pending removal) and
    /// released everything that used the store; `released` is the discarded
    /// `Profile`, held weakly only to log when something still retains it.
    @discardableResult
    func removeDataOfDeletedProfile(id: UUID, released releasedProfile: AnyObject? = nil) -> Task<Outcome, Never> {
        weak var released = releasedProfile
        return Task { @MainActor in
            if released != nil {
                log.error("Profile \(id.uuidString, privacy: .public) is still retained after deletion; its data store may stay in use")
            }
            return await self.remove(id, recordKey: id.uuidString)
        }
    }

    /// Retries the removals left pending by an earlier run. Must be called at
    /// launch before anything creates a profile's data store or extension
    /// controller; the pending ids are read synchronously here, the removals run
    /// on later main-actor turns.
    @discardableResult
    func retryPendingRemovals() -> Task<[UUID: Outcome], Never> {
        let pending = appDB.pendingProfileDataRemovals()
        if !pending.isEmpty {
            log.info("Retrying \(pending.count) pending profile data removal(s)")
        }
        return Task { @MainActor in
            var outcomes: [UUID: Outcome] = [:]
            for recordKey in pending {
                guard let id = UUID(uuidString: recordKey) else {
                    log.error("Dropping pending profile data removal with invalid id \(recordKey, privacy: .public)")
                    self.appDB.clearPendingProfileDataRemoval(profileID: recordKey)
                    continue
                }
                outcomes[id] = await self.remove(id, recordKey: recordKey)
            }
            return outcomes
        }
    }

    private enum Removability {
        case removable
        case liveProfile
        case unknown(String)
    }

    /// Whether `id` may have its data removed: never the Private profile, and
    /// never a profile that exists in memory or in the profile table. A profile
    /// table that cannot be read is not a licence to remove anything.
    private func removability(of id: UUID) -> Removability {
        if id == TabStore.incognitoProfileID || inMemoryProfileIDs().contains(id) {
            return .liveProfile
        }
        do {
            let storedIDs = try appDB.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM profile")
            }
            if storedIDs.contains(where: { UUID(uuidString: $0) == id }) {
                return .liveProfile
            }
            return .removable
        } catch {
            return .unknown("profile table unreadable: \(error.localizedDescription)")
        }
    }

    /// The only caller of the remover. Removal is refused for a live profile,
    /// re-checked before every WebKit call; in-use failures are retried with
    /// `retryDelays`.
    ///
    /// The WebKit identifier comes from `storageScope`. In the default data
    /// directory it is the profile id. An isolated data directory shares the
    /// WebKit directory with the production app, so it removes only storage it
    /// recorded creating, under an identifier derived from its own name
    /// (`WebKitStorageScope.refusalToRemove`), and forgets the record after.
    @MainActor
    private func remove(_ id: UUID, recordKey: String) async -> Outcome {
        let identifier = storageScope.identifier(forProfile: id)
        let isolated = !storageScope.isDefaultDataDirectory
        if isolated, storageScope.registry.recordedWebKitStorageProfileID(for: identifier) == nil {
            log.info("Profile \(id.uuidString, privacy: .public) never created WebKit storage in data dir \(self.storageScope.dataDirectoryName, privacy: .public); nothing to remove")
            appDB.clearPendingProfileDataRemoval(profileID: recordKey)
            return .skippedUnrecordedStorage
        }
        var extensionDataRemoved = false
        var lastFailure = "not attempted"

        for delay in [0] + retryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            do {
                if !extensionDataRemoved {
                    if let refusal = try refusal(for: id, identifier: identifier, recordKey: recordKey) { return refusal }
                    try await remover.removeExtensionData(identifier)
                    extensionDataRemoved = true
                }
                if let refusal = try refusal(for: id, identifier: identifier, recordKey: recordKey) { return refusal }
                try await remover.removeWebsiteDataStore(identifier)
                if isolated {
                    storageScope.registry.forgetWebKitStorageIdentifier(identifier)
                }
                appDB.clearPendingProfileDataRemoval(profileID: recordKey)
                log.info("Removed on-disk data of deleted profile \(id.uuidString, privacy: .public)")
                return .removed
            } catch {
                lastFailure = error.localizedDescription
                log.info("Profile \(id.uuidString, privacy: .public) data removal attempt failed: \(lastFailure, privacy: .public)")
            }
        }
        log.error("Could not remove data of deleted profile \(id.uuidString, privacy: .public), retrying at next launch: \(lastFailure, privacy: .public)")
        return .failed(lastFailure)
    }

    /// A profile table that could not be read for the removability check. Thrown
    /// rather than returned so the attempt fails like an in-use store and the
    /// retry loop tries again after its next delay: the read failure is very
    /// likely transient (a busy database), and returning `.failed` from inside the
    /// loop would spend the launch's remaining attempts on it.
    private struct ProfileTableUnreadable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The outcome to stop with when `id` (whose storage is `identifier`) must
    /// not be removed, or nil to go on. When an isolated data directory's storage
    /// guard refuses (say, the production profile table is unreadable), the row
    /// stays pending. Throws `ProfileTableUnreadable` when removability could not
    /// be decided, so the caller retries the attempt instead of giving up.
    private func refusal(for id: UUID, identifier: UUID, recordKey: String) throws -> Outcome? {
        if !storageScope.isDefaultDataDirectory,
           let reason = storageScope.refusalToRemove(identifier: identifier) {
            log.error("Not removing data of profile \(id.uuidString, privacy: .public): \(reason, privacy: .public)")
            return .failed(reason)
        }
        switch removability(of: id) {
        case .removable:
            return nil
        case .liveProfile:
            log.error("Refusing to remove data of existing profile \(id.uuidString, privacy: .public)")
            appDB.clearPendingProfileDataRemoval(profileID: recordKey)
            return .refusedLiveProfile
        case .unknown(let reason):
            throw ProfileTableUnreadable(reason: reason)
        }
    }

    // MARK: - WebKit extension controller data

    /// Empties the storage WebKit keeps for a persistent extension controller
    /// with `identifier`, through a throwaway controller (whose default website
    /// data store is non-persistent, so the profile's store is not recreated),
    /// then deletes the controller directory the API leaves behind.
    @MainActor
    static func removeWebKitExtensionControllerData(identifier: UUID) async throws {
        let types = WKWebExtensionController.allExtensionDataTypes
        do {
            let configuration = WKWebExtensionController.Configuration(identifier: identifier)
            configuration.defaultWebsiteDataStore = .nonPersistent()
            let controller = WKWebExtensionController(configuration: configuration)
            let records = await controller.dataRecords(ofTypes: types)
            if !records.isEmpty {
                await controller.removeData(ofTypes: types, from: records)
                let bytes = records.reduce(0) { $0 + $1.totalSizeInBytes }
                log.info("Removed \(bytes) bytes of extension data (\(records.count) extension(s)) for profile \(identifier.uuidString, privacy: .public)")
            }
        }
        if let directory = webExtensionControllerDirectory(for: identifier),
           FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
            log.info("Deleted extension controller directory for profile \(identifier.uuidString, privacy: .public)")
        }
    }

    /// Where WebKit keeps a persistent extension controller's state for
    /// `identifier` — not API, measured on macOS 26 (see the type comment).
    static func webExtensionControllerDirectory(
        for identifier: UUID, bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return library
            .appendingPathComponent("WebKit", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("WebExtensions", isDirectory: true)
            .appendingPathComponent(identifier.uuidString, isDirectory: true)
    }
}
