import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extension-notifications")

/// Manages notifications for extensions, wrapping UNUserNotificationCenter.
class ExtensionNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ExtensionNotificationManager()

    /// Maps (extensionID, notificationID) → UNNotification identifier.
    private var notificationMap: [String: (extensionID: String, notificationID: String)] = [:]

    /// Active notification IDs per extension.
    private var activeNotifications: [String: Set<String>] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Request notification permission if needed.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Create or update a notification.
    func create(extensionID: String, notificationID: String?, options: [String: Any], completion: @escaping (String) -> Void) {
        let id = notificationID ?? UUID().uuidString
        log.info("Creating notification \(id, privacy: .public) for extension \(extensionID, privacy: .public)")
        let identifier = "\(extensionID):\(id)"

        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? ""
        content.body = options["message"] as? String ?? ""
        if let iconURL = options["iconUrl"] as? String {
            content.subtitle = iconURL // Store for reference; attachment would require downloading
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                log.error("Failed to create notification for extension \(extensionID, privacy: .public): \(error.localizedDescription)")
            }
            if error == nil {
                self?.notificationMap[identifier] = (extensionID, id)
                if self?.activeNotifications[extensionID] == nil {
                    self?.activeNotifications[extensionID] = []
                }
                self?.activeNotifications[extensionID]?.insert(id)
            }
            DispatchQueue.main.async {
                completion(id)
            }
        }
    }

    /// Update an existing notification.
    func update(extensionID: String, notificationID: String, options: [String: Any], completion: @escaping (Bool) -> Void) {
        let identifier = "\(extensionID):\(notificationID)"
        guard notificationMap[identifier] != nil else {
            completion(false)
            return
        }
        // Re-create with updated content
        create(extensionID: extensionID, notificationID: notificationID, options: options) { _ in
            completion(true)
        }
    }

    /// Clear a notification.
    func clear(extensionID: String, notificationID: String, completion: @escaping (Bool) -> Void) {
        let identifier = "\(extensionID):\(notificationID)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        notificationMap.removeValue(forKey: identifier)
        activeNotifications[extensionID]?.remove(notificationID)
        completion(true)
    }

    /// Get all active notification IDs for an extension.
    func getAll(extensionID: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for id in activeNotifications[extensionID] ?? [] {
            result[id] = true
        }
        return result
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier

        if let mapping = notificationMap[identifier] {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                log.info("Notification clicked: \(mapping.notificationID, privacy: .public) for extension \(mapping.extensionID, privacy: .public)")
            } else if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                log.info("Notification closed: \(mapping.notificationID, privacy: .public) for extension \(mapping.extensionID, privacy: .public)")
                notificationMap.removeValue(forKey: identifier)
                activeNotifications[mapping.extensionID]?.remove(mapping.notificationID)
            }
            // Native WKWebExtension handles chrome.notifications event dispatch
        }

        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
