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
    /// Whether Detour may show notifications now. Asked afresh for every
    /// create: the user can change it in System Settings at any time.
    func authorizationStatus() async -> ExtensionNotificationAuthorization
    /// Asks the user (the system prompt) and answers whether they allowed it.
    /// Only called while the status is `.notDetermined`.
    func requestAuthorization() async -> Bool
}

/// The part of `UNAuthorizationStatus` the manager acts on (TASK-253).
enum ExtensionNotificationAuthorization: Equatable {
    /// Notifications may be shown (provisional counts too; `.ephemeral` is
    /// iOS-only).
    case authorized
    /// The user turned Detour's notifications off, now or earlier.
    case denied
    /// Nobody has asked yet: the next create asks.
    case notDetermined
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

    func authorizationStatus() async -> ExtensionNotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification authorization request failed: \(error.localizedDescription)")
            return false
        }
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
///
/// Before its `add`, each create or update waits for authorization
/// (TASK-253): the first one asks the user, and every one arriving before
/// they answer waits on that same prompt. The entry is recorded first all the
/// same, so a `clear` or `update` issued during the wait applies as it does
/// while an `add` is in flight; a create cleared or superseded during the wait
/// never reaches the center. When notifications are not allowed, the create
/// answers its id as Chrome's does when the OS blocks them, but nothing is
/// shown and the entry goes: `getAll` does not list it, and `clear` and
/// `update` answer false for it.
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

    #if DEBUG
    /// Makes `shared` a manager around `center`, which never becomes the
    /// system center's delegate. For the test host only (TASK-249): it shares
    /// the app's bundle id, so a test reaching `shared` would otherwise post
    /// real banners on the developer's Mac. `TestEnvironmentSetup` calls it at
    /// bundle start.
    ///
    /// A manager that already existed (something reached `shared` before the
    /// bundle started) posted to the system center and is its delegate: its
    /// notifications are taken away and it stops being the delegate, so none
    /// is left on screen with no manager to clear it.
    static func installSharedForTesting(center: any ExtensionNotificationCenter) {
        if let previous = sharedInstance {
            previous.removeAll { _ in true }
            let system = UNUserNotificationCenter.current()
            if system.delegate === previous { system.delegate = nil }
        }
        sharedInstance = ExtensionNotificationManager(center: center)
    }

    /// The center this manager posts to, so the test host can check `shared`
    /// is not the system one.
    var centerForTesting: any ExtensionNotificationCenter { center }
    #endif

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
        /// The options the notification shows (`shownOptionKeys` only): the
        /// create's, with every later update's merged in (TASK-240). What the
        /// next `update` merges into.
        let options: [String: Any]
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

    /// The shows waiting on the authorization check in flight, in call
    /// order; nil when no check is in flight. See `authorize()`.
    private var authorizationWaiters: [CheckedContinuation<Bool, Never>]?

    /// Whether the center may show notifications, asking the user the first
    /// time (TASK-253: Detour asks at the first `notifications.create` of any
    /// extension, and that create waits for the answer). Shows that arrive
    /// while a check is in flight wait on the same one, so the user sees one
    /// prompt however many creates come in before they answer; they resume
    /// in call order, so their adds reach the center in the order the
    /// extensions made them. The status is asked afresh once a check has
    /// finished, as the user can turn notifications on or off in System
    /// Settings at any time.
    private func authorize() async -> Bool {
        if authorizationWaiters != nil {
            return await withCheckedContinuation { authorizationWaiters?.append($0) }
        }
        authorizationWaiters = []
        let authorized: Bool
        switch await center.authorizationStatus() {
        case .authorized:
            authorized = true
        case .denied:
            authorized = false
        case .notDetermined:
            authorized = await center.requestAuthorization()
            log.info("Notification authorization \(authorized ? "granted" : "declined", privacy: .public)")
        }
        let waiters = authorizationWaiters ?? []
        authorizationWaiters = nil
        for waiter in waiters { waiter.resume(returning: authorized) }
        return authorized
    }

    /// Whether `identifier`'s entry is still the one `generation` recorded:
    /// not cleared, removed with its owner, or superseded by a later create
    /// or update meanwhile.
    private func isCurrent(identifier: String, generation: Int) -> Bool {
        entries[identifier]?.generation == generation
    }

    /// What a notification with these options shows (TASK-240). Chrome's
    /// macOS bridge shows `title` as the title, `message` as the body and
    /// `contextMessage` ("alternate notification content with a lower-weight
    /// font") as the subtitle, so this does the same. Nothing is taken from
    /// `iconUrl`: an attachment would mean loading the extension-relative URL
    /// into a file first, so the banner shows Detour's app icon. `imageUrl`,
    /// `buttons`, `items`, `progress`, `priority`, `eventTime`,
    /// `requireInteraction` and `silent` are not shown either (see the
    /// polyfill-layer wiki).
    ///
    /// Title, body and subtitle only: nothing that names the profile (no
    /// threadIdentifier, no userInfo), for the same reason as the identifier.
    static func content(for options: [String: Any]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? ""
        content.body = options["message"] as? String ?? ""
        content.subtitle = options["contextMessage"] as? String ?? ""
        return content
    }

    /// The option fields `content(for:)` reads: all an entry keeps for the
    /// next `update` to merge into. Not the rest (an `iconUrl` or `imageUrl`
    /// is often a large data: URL), since an entry lives until the extension
    /// clears it, and a banner the user dismisses does not end it.
    private static let shownOptionKeys: Set<String> = ["title", "message", "contextMessage"]

    /// `existing` with every field `given` sets replaced, as Chrome's update
    /// applies only the fields the extension passed (TASK-240). A `null` field
    /// counts as not given.
    static func merged(_ given: [String: Any], into existing: [String: Any]) -> [String: Any] {
        existing.merging(given.filter { !($0.value is NSNull) }) { _, new in new }
    }

    /// Create a notification. A create for an id the owner already has
    /// replaces that notification outright, as Chrome's does: unlike `update`,
    /// nothing is merged. `completion` runs once the center's `add` has
    /// returned, or once it is known there will be none (notifications not
    /// allowed, or the create cleared or superseded while authorization was
    /// pending), with the notification id, whether or not it was shown.
    func create(owner: Owner, notificationID: String?, options: [String: Any], completion: @escaping (String) -> Void) {
        show(owner: owner, notificationID: notificationID, options: options) { id, _ in completion(id) }
    }

    /// `create`, also telling `completion` whether the notification was
    /// shown: false when notifications are not allowed or the `add` failed.
    private func show(owner: Owner, notificationID: String?, options: [String: Any],
                      completion: @escaping (_ id: String, _ succeeded: Bool) -> Void) {
        let id = notificationID ?? UUID().uuidString
        // The profile stays out of the log: which profile a Private-profile
        // extension acted in is not something to persist.
        log.info("Creating notification \(id, privacy: .private) for extension \(owner.extensionID, privacy: .public)")
        // An update, or a create for an id the owner already has, keeps the
        // identifier, so the center replaces the banner rather than adding one.
        let key = Key(owner: owner, notificationID: id)
        let existingIdentifier = identifiers[key]
        let identifier = existingIdentifier ?? Self.newIdentifier()

        let request = UNNotificationRequest(identifier: identifier, content: Self.content(for: options), trigger: nil)

        lastGeneration += 1
        let generation = lastGeneration
        entries[identifier] = Entry(owner: owner, notificationID: id, generation: generation,
                                    options: options.filter { Self.shownOptionKeys.contains($0.key) })
        identifiers[key] = identifier

        // Awaited from a main-actor task: the completion-handler form of `add`
        // calls back on a background queue, and the entries are main-actor state.
        let center = self.center
        Task { [weak self] in
            guard let self else {
                completion(id, false)
                return
            }
            let authorized = await self.authorize()
            // Cleared or superseded while authorization was pending: nothing
            // has been shown for this generation, so there is nothing to add
            // or take away. A superseding create or update adds its own, and
            // skipping this one keeps a stale add from landing after it.
            guard self.isCurrent(identifier: identifier, generation: generation) else {
                completion(id, authorized)
                return
            }
            guard authorized else {
                self.notAuthorized(identifier: identifier, mayBeShown: existingIdentifier != nil)
                completion(id, false)
                return
            }
            var failure: (any Error)?
            do {
                try await center.add(request)
            } catch {
                failure = error
            }
            self.addFinished(identifier: identifier, generation: generation, failure: failure)
            completion(id, failure == nil)
        }
    }

    /// Settles the entry of a `show` the user has not allowed notifications
    /// for (TASK-253). Nothing was shown, so the entry goes, as Chrome lists
    /// no notification the OS blocked: `getAll` leaves it out, and `clear` and
    /// `update` answer false for its id. `create` still answers the id.
    /// `mayBeShown`: the identifier was an earlier create's, so something may
    /// be on screen under it; a fresh one has never reached the center.
    private func notAuthorized(identifier: String, mayBeShown: Bool) {
        log.info("Notifications are not allowed; dropping \(identifier, privacy: .private)")
        removeEntry(identifier: identifier)
        // An earlier create may have shown a notification under this
        // identifier while notifications were allowed; the extension no
        // longer has it.
        if mayBeShown { center.removeNotifications(withIdentifiers: [identifier]) }
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
    /// `create` has not finished yet. The given options are merged into the
    /// notification's, as Chrome does: an update that sets only `message`
    /// keeps the title. Answers false when the owner has no such notification,
    /// when notifications are not allowed (which drops it), or when the
    /// center refuses the updated one.
    func update(owner: Owner, notificationID: String, options: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let identifier = identifier(for: owner, notificationID: notificationID),
              let entry = entries[identifier] else {
            completion(false)
            return
        }
        // Re-create with the merged content. A failed `add` drops the
        // notification (see `addFinished`), so the update did not apply.
        let merged = Self.merged(options, into: entry.options)
        show(owner: owner, notificationID: notificationID, options: merged) { _, succeeded in
            completion(succeeded)
        }
    }

    /// Clear a notification of `owner`'s, including one whose `create` has not
    /// finished yet. Answers whether the owner had such a notification, as
    /// Chrome's `clear` does (TASK-240). Another owner's notification with the
    /// same id is a different notification, so it is untouched and the answer
    /// is false.
    func clear(owner: Owner, notificationID: String, completion: @escaping (Bool) -> Void) {
        guard let identifier = identifier(for: owner, notificationID: notificationID) else {
            completion(false)
            return
        }
        removeEntry(identifier: identifier)
        center.removeNotifications(withIdentifiers: [identifier])
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
