import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-notifications")

/// What `ExtensionNotificationManager` needs from the system notification
/// center. A seam so a test can hold an `add` in flight and watch what is shown.
protocol ExtensionNotificationCenter: AnyObject {
    /// Shows the request, replacing any notification with the same identifier.
    func add(_ request: UNNotificationRequest) async throws
    /// Takes the notifications with these identifiers away, delivered or still pending.
    func removeNotifications(withIdentifiers identifiers: [String])
}

/// The real center: `UNUserNotificationCenter.current()`.
final class SystemExtensionNotificationCenter: ExtensionNotificationCenter {
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removeNotifications(withIdentifiers identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Manages notifications for extensions, wrapping UNUserNotificationCenter.
///
/// One manager serves every profile (the system center has one delegate), so
/// every notification belongs to an `Owner`: the profile *and* the extension
/// that created it (TASK-238). The same extension installed in two profiles,
/// the Private one included, is two owners: neither lists, clears, updates or
/// gets the clicks of the other's notifications, and each owner's
/// notification has its own UNNotification identifier, so one owner's
/// `create` never replaces the other's banner and one owner's `clear` never
/// takes it away.
///
/// The identifier is opaque — a fixed prefix and a random UUID per
/// notification — and only this manager can map it back to its owner and id.
/// usernoted keeps delivered identifiers on disk, so an identifier that named
/// the profile would record which notifications came from Private (whose
/// profile id is a well-known constant). See `identifierPrefix`.
///
/// An owner's notifications go when its scope does: `removeAll(for:)` when the
/// extension is unloaded from the profile (disable, uninstall, update or
/// reload), `removeAll(profileID:)` when the profile is deleted or the
/// Private session ends, so nothing carries over into the next one.
///
/// A notification is recorded when `create` is called, before the center's
/// `add` returns, so the calls an extension makes without awaiting apply in
/// the order it made them (TASK-234): a `clear` issued while the `add` is in
/// flight drops the entry at once, and when that `add` returns the manager
/// takes the notification away again, in case the center showed it after the
/// clear. An `update` issued meanwhile finds the entry and re-creates it under
/// the same identifier. Each `create` carries a generation, so an `add` that a
/// later `create` for the same id has superseded leaves the newer entry alone:
/// the newer `add` replaces what it showed.
final class ExtensionNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private static var sharedInstance: ExtensionNotificationManager?

    /// The manager every profile's handler uses, and the system center's
    /// delegate. Created at the first notification call.
    static var shared: ExtensionNotificationManager {
        if let sharedInstance { return sharedInstance }
        let manager = ExtensionNotificationManager(center: SystemExtensionNotificationCenter())
        UNUserNotificationCenter.current().delegate = manager
        sharedInstance = manager
        return manager
    }

    /// `shared` if anything has created it this launch, else nil: with no
    /// manager there is no notification to take away, so a profile or session
    /// ending does not set up the system center.
    static var sharedIfCreated: ExtensionNotificationManager? { sharedInstance }

    /// Who a notification belongs to. The polyfill handler builds it from its
    /// own profile and the request's verified extension id, never from the
    /// request body.
    struct Owner: Hashable {
        let profileID: UUID
        let extensionID: String
    }

    /// A click or close on a notification, resolved to the notification it is
    /// for. See `handleResponse`.
    struct Response: Equatable {
        enum Kind: Equatable { case clicked, closed }
        let owner: Owner
        let notificationID: String
        let kind: Kind
    }

    private struct Key: Hashable {
        let owner: Owner
        let notificationID: String
    }

    private struct Entry {
        let owner: Owner
        let notificationID: String
        /// Which `create` recorded the entry; see `addFinished`.
        let generation: Int
    }

    /// UNNotification identifier → the notification an owner has and has not
    /// cleared, including one whose `add` is still in flight.
    private var entries: [String: Entry] = [:]
    /// The inverse of `entries`: each such notification's identifier.
    private var identifiers: [Key: String] = [:]
    private var lastGeneration = 0
    private let center: any ExtensionNotificationCenter

    /// Production uses `shared`, which is also the center's delegate. A test
    /// builds its own around a fake center.
    init(center: any ExtensionNotificationCenter) {
        self.center = center
        super.init()
    }

    /// What every identifier this build hands the center starts with; the rest
    /// is a random UUID (`newIdentifier()`). Identifiers of earlier builds —
    /// `<extensionID>:<notificationID>` before TASK-238, then
    /// `detour-ext-notification.v2|<profile UUID>|…` — match no entry, so a
    /// click or close on one still on screen is ignored. So is one of this
    /// build's from an earlier launch: the map lives in memory only.
    static let identifierPrefix = "detour-ext-notification.v3|"

    private static func newIdentifier() -> String {
        identifierPrefix + UUID().uuidString
    }

    /// The identifier `owner`'s notification `notificationID` is shown under,
    /// or nil when the owner has no such notification. A notification that is
    /// cleared and created again gets a new one.
    func identifier(for owner: Owner, notificationID: String) -> String? {
        identifiers[Key(owner: owner, notificationID: notificationID)]
    }

    /// Drops the entry for `identifier` and its inverse.
    private func removeEntry(identifier: String) {
        guard let entry = entries.removeValue(forKey: identifier) else { return }
        identifiers.removeValue(forKey: Key(owner: entry.owner, notificationID: entry.notificationID))
    }

    /// Request notification permission if needed.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Create or update a notification. `completion` runs once the center's
    /// `add` has returned, with the notification id, whether or not it succeeded.
    func create(owner: Owner, notificationID: String?, options: [String: Any], completion: @escaping (String) -> Void) {
        show(owner: owner, notificationID: notificationID, options: options) { id, _ in completion(id) }
    }

    /// `create`, also telling `completion` whether the center's `add` succeeded.
    private func show(owner: Owner, notificationID: String?, options: [String: Any],
                      completion: @escaping (_ id: String, _ succeeded: Bool) -> Void) {
        let id = notificationID ?? UUID().uuidString
        // The profile stays out of the log: which profile a Private-profile
        // extension acted in is not something to persist.
        log.info("Creating notification \(id, privacy: .private) for extension \(owner.extensionID, privacy: .public)")
        // An update, or a create for an id the owner already has, keeps the
        // identifier, so the center replaces the banner rather than adding one.
        let key = Key(owner: owner, notificationID: id)
        let identifier = identifiers[key] ?? Self.newIdentifier()

        // Title, body and subtitle only: nothing that names the profile (no
        // threadIdentifier, no userInfo), for the same reason as the identifier.
        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? ""
        content.body = options["message"] as? String ?? ""
        if let iconURL = options["iconUrl"] as? String {
            content.subtitle = iconURL // Store for reference; attachment would require downloading
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        lastGeneration += 1
        let generation = lastGeneration
        entries[identifier] = Entry(owner: owner, notificationID: id, generation: generation)
        identifiers[key] = identifier

        // Awaited from a main-actor task: the completion-handler form of `add`
        // calls back on a background queue, and the entries are main-actor state.
        let center = self.center
        Task { [weak self] in
            var failure: (any Error)?
            do {
                try await center.add(request)
            } catch {
                failure = error
            }
            self?.addFinished(identifier: identifier, generation: generation, failure: failure)
            completion(id, failure == nil)
        }
    }

    /// Settles the entry an `add` was for, now that the center has answered.
    private func addFinished(identifier: String, generation: Int, failure: (any Error)?) {
        let entry = entries[identifier]
        // A later `create` for the same id owns the identifier now. Its `add`
        // replaces whatever this one showed, and settles the entry itself.
        if let entry, entry.generation != generation { return }
        if let failure {
            log.error("Failed to create notification \(identifier, privacy: .private): \(failure.localizedDescription)")
            removeEntry(identifier: identifier)
            // Nothing new is shown, but a notification an earlier `create`
            // showed under this id still is; the extension no longer has it.
            center.removeNotifications(withIdentifiers: [identifier])
            return
        }
        if entry == nil {
            // Cleared (or removed with its owner) while the `add` was in
            // flight. That removal may have reached the center before the
            // notification did. A later `create` for the same id has a new
            // identifier, so this takes away only what this `add` showed.
            center.removeNotifications(withIdentifiers: [identifier])
        }
    }

    /// Update an existing notification of `owner`'s, including one whose
    /// `create` has not finished yet. Answers false when the owner has no such
    /// notification, or when the center refuses the updated one.
    func update(owner: Owner, notificationID: String, options: [String: Any], completion: @escaping (Bool) -> Void) {
        guard identifier(for: owner, notificationID: notificationID) != nil else {
            completion(false)
            return
        }
        // Re-create with updated content. A failed `add` drops the notification
        // (see `addFinished`), so the update did not apply.
        show(owner: owner, notificationID: notificationID, options: options) { _, succeeded in
            completion(succeeded)
        }
    }

    /// Clear a notification of `owner`'s, including one whose `create` has not
    /// finished yet. Another owner's notification with the same id is a
    /// different notification, so it is untouched.
    func clear(owner: Owner, notificationID: String, completion: @escaping (Bool) -> Void) {
        if let identifier = identifier(for: owner, notificationID: notificationID) {
            removeEntry(identifier: identifier)
            center.removeNotifications(withIdentifiers: [identifier])
        }
        completion(true)
    }

    /// Takes away every notification of `owner`'s, delivered or still pending,
    /// including one whose `create` has not finished yet (its `add` takes it
    /// away again when it returns; see `addFinished`). For an extension
    /// unloaded from a profile.
    func removeAll(for owner: Owner) {
        removeAll { $0.owner == owner }
    }

    /// `removeAll(for:)` for every extension's notifications in the profile.
    /// For a deleted profile and for the end of the Private session.
    func removeAll(profileID: UUID) {
        removeAll { $0.owner.profileID == profileID }
    }

    private func removeAll(where matches: (Entry) -> Bool) {
        let removed = entries.filter { matches($0.value) }.map(\.key)
        guard !removed.isEmpty else { return }
        for identifier in removed { removeEntry(identifier: identifier) }
        log.info("Removed \(removed.count) extension notification(s) whose owner went away")
        center.removeNotifications(withIdentifiers: removed)
    }

    /// The ids of `owner`'s notifications, including those whose `create` has
    /// not finished yet.
    func getAll(owner: Owner) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for entry in entries.values where entry.owner == owner {
            result[entry.notificationID] = true
        }
        return result
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Nonisolated: UserNotifications does not say which thread it calls the
    // delegate on. The entries are main-actor state, so the bookkeeping hops there.

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            self.handleResponse(identifier: identifier, action: action)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Resolves a click or close to the one owner and notification it is for,
    /// by the exact identifier, and drops the entry on a close. Nothing else
    /// is touched: the same id in another profile or extension is a different
    /// identifier. An identifier with no entry — another launch's, an earlier
    /// build's, or one already cleared — resolves to nil and changes nothing.
    ///
    /// Nothing delivers the response to the extension yet:
    /// `notifications.onClicked` / `onClosed` never fire (no push channel into
    /// a context; see the polyfill-layer wiki). Delivery belongs here, sent to
    /// the returned owner's profile only.
    @discardableResult
    func handleResponse(identifier: String, action: String) -> Response? {
        guard let entry = entries[identifier] else { return nil }
        let kind: Response.Kind
        if action == UNNotificationDefaultActionIdentifier {
            kind = .clicked
            log.info("Notification clicked: \(entry.notificationID, privacy: .private) for extension \(entry.owner.extensionID, privacy: .public)")
        } else if action == UNNotificationDismissActionIdentifier {
            kind = .closed
            log.info("Notification closed: \(entry.notificationID, privacy: .private) for extension \(entry.owner.extensionID, privacy: .public)")
            removeEntry(identifier: identifier)
        } else {
            return nil
        }
        return Response(owner: entry.owner, notificationID: entry.notificationID, kind: kind)
    }
}
