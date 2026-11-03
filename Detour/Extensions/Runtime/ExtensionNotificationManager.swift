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
/// A notification is recorded when `create` is called, before the center's
/// `add` returns, so the calls an extension makes without awaiting apply in
/// the order it made them (TASK-234): a `clear` issued while the `add` is in
/// flight drops the entry at once, and when that `add` returns the manager
/// takes the notification away again, in case the center showed it after the
/// clear. An `update` issued meanwhile finds the entry and re-creates it. Each
/// `create` carries a generation, so an `add` that a later `create` for the
/// same id has superseded leaves the newer entry alone: the newer `add`
/// replaces what it showed.
final class ExtensionNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared: ExtensionNotificationManager = {
        let manager = ExtensionNotificationManager(center: SystemExtensionNotificationCenter())
        UNUserNotificationCenter.current().delegate = manager
        return manager
    }()

    private struct Entry {
        let extensionID: String
        let notificationID: String
        /// Which `create` recorded the entry; see `addFinished`.
        let generation: Int
    }

    /// UNNotification identifier (`<extensionID>:<notificationID>`) → the
    /// notification an extension has and has not cleared, including one whose
    /// `add` is still in flight.
    private var entries: [String: Entry] = [:]
    private var lastGeneration = 0
    private let center: any ExtensionNotificationCenter

    /// Production uses `shared`, which is also the center's delegate. A test
    /// builds its own around a fake center.
    init(center: any ExtensionNotificationCenter) {
        self.center = center
        super.init()
    }

    private static func identifier(extensionID: String, notificationID: String) -> String {
        "\(extensionID):\(notificationID)"
    }

    /// Request notification permission if needed.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Create or update a notification. `completion` runs once the center's
    /// `add` has returned, with the notification id, whether or not it succeeded.
    func create(extensionID: String, notificationID: String?, options: [String: Any], completion: @escaping (String) -> Void) {
        show(extensionID: extensionID, notificationID: notificationID, options: options) { id, _ in completion(id) }
    }

    /// `create`, also telling `completion` whether the center's `add` succeeded.
    private func show(extensionID: String, notificationID: String?, options: [String: Any],
                      completion: @escaping (_ id: String, _ succeeded: Bool) -> Void) {
        let id = notificationID ?? UUID().uuidString
        log.info("Creating notification \(id, privacy: .public) for extension \(extensionID, privacy: .public)")
        let identifier = Self.identifier(extensionID: extensionID, notificationID: id)

        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? ""
        content.body = options["message"] as? String ?? ""
        if let iconURL = options["iconUrl"] as? String {
            content.subtitle = iconURL // Store for reference; attachment would require downloading
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        lastGeneration += 1
        let generation = lastGeneration
        entries[identifier] = Entry(extensionID: extensionID, notificationID: id, generation: generation)

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
            log.error("Failed to create notification \(identifier, privacy: .public): \(failure.localizedDescription)")
            entries.removeValue(forKey: identifier)
            // Nothing new is shown, but a notification an earlier `create`
            // showed under this id still is; the extension no longer has it.
            center.removeNotifications(withIdentifiers: [identifier])
            return
        }
        if entry == nil {
            // Cleared while the `add` was in flight. The clear's own removal
            // may have reached the center before the notification did.
            center.removeNotifications(withIdentifiers: [identifier])
        }
    }

    /// Update an existing notification, including one whose `create` has not
    /// finished yet. Answers false when the extension has no such notification,
    /// or when the center refuses the updated one.
    func update(extensionID: String, notificationID: String, options: [String: Any], completion: @escaping (Bool) -> Void) {
        let identifier = Self.identifier(extensionID: extensionID, notificationID: notificationID)
        guard entries[identifier] != nil else {
            completion(false)
            return
        }
        // Re-create with updated content. A failed `add` drops the notification
        // (see `addFinished`), so the update did not apply.
        show(extensionID: extensionID, notificationID: notificationID, options: options) { _, succeeded in
            completion(succeeded)
        }
    }

    /// Clear a notification, including one whose `create` has not finished yet.
    func clear(extensionID: String, notificationID: String, completion: @escaping (Bool) -> Void) {
        let identifier = Self.identifier(extensionID: extensionID, notificationID: notificationID)
        entries.removeValue(forKey: identifier)
        center.removeNotifications(withIdentifiers: [identifier])
        completion(true)
    }

    /// Get all active notification IDs for an extension, including those whose
    /// `create` has not finished yet.
    func getAll(extensionID: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for entry in entries.values where entry.extensionID == extensionID {
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

    private func handleResponse(identifier: String, action: String) {
        guard let entry = entries[identifier] else { return }
        if action == UNNotificationDefaultActionIdentifier {
            log.info("Notification clicked: \(entry.notificationID, privacy: .public) for extension \(entry.extensionID, privacy: .public)")
        } else if action == UNNotificationDismissActionIdentifier {
            log.info("Notification closed: \(entry.notificationID, privacy: .public) for extension \(entry.extensionID, privacy: .public)")
            entries.removeValue(forKey: identifier)
        }
        // Native WKWebExtension handles chrome.notifications event dispatch
    }
}
