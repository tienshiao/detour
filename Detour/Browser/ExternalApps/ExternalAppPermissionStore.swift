import Foundation

/// Remembered "Always allow <origin> to open links of this type in <app>"
/// decisions, keyed per profile by requesting origin + URL scheme (Chrome's
/// model, TASK-84).
///
/// The Private profile's decisions are held in memory for the session only and
/// never written to the database.
final class ExternalAppPermissionStore {
    static let shared = ExternalAppPermissionStore()
    /// Posted after the UI remembers a new decision, so an open Settings pane
    /// refreshes its count.
    static let didChangeNotification = Notification.Name("ExternalAppPermissionStoreDidChange")

    private struct Key: Hashable {
        let origin: String
        let scheme: String
    }

    private let database: AppDatabase
    private var allowed: [UUID: Set<Key>] = [:]

    init(database: AppDatabase = .shared) {
        self.database = database
        for record in database.loadExternalAppPermissions() {
            guard let profileID = UUID(uuidString: record.profileID) else { continue }
            allowed[profileID, default: []].insert(Self.key(origin: record.origin, scheme: record.scheme))
        }
    }

    func isAllowed(origin: String, scheme: String, profileID: UUID) -> Bool {
        allowed[profileID]?.contains(Self.key(origin: origin, scheme: scheme)) ?? false
    }

    func allow(origin: String, scheme: String, profileID: UUID, isPrivateProfile: Bool) {
        let key = Self.key(origin: origin, scheme: scheme)
        guard allowed[profileID, default: []].insert(key).inserted, !isPrivateProfile else { return }
        database.saveExternalAppPermission(ExternalAppPermissionRecord(
            profileID: profileID.uuidString, origin: key.origin, scheme: key.scheme))
    }

    func count(for profileID: UUID) -> Int {
        allowed[profileID]?.count ?? 0
    }

    func clearAll(for profileID: UUID) {
        allowed[profileID] = nil
        database.deleteExternalAppPermissions(profileID: profileID.uuidString)
    }

    private static func key(origin: String, scheme: String) -> Key {
        Key(origin: origin.lowercased(), scheme: scheme.lowercased())
    }
}
